"""
state.py
Run state file — tracks which hosts have completed so a failed Jenkins run
can be resumed without re-running already-completed hosts.

Format: JSON file at log_dir/upgrade-state-<start_date>.json

  {
    "start_date": "22-Apr-2025-10-30",
    "depcr": "CHG0012345",
    "hosts": {
      "esxi01.corp.local": {
        "status": "completed",
        "firmware_ok": true,
        "esxi_ok": true,
        "elapsed_minutes": 45.3,
        "completed_at": "2025-04-22T11:15:00"
      },
      "esxi02.corp.local": {
        "status": "failed",
        "firmware_ok": false,
        "esxi_ok": false,
        "elapsed_minutes": 12.1,
        "completed_at": "2025-04-22T11:27:00"
      },
      "esxi03.corp.local": {
        "status": "pending"
      }
    }
  }

Usage in Jenkins pipeline:
  If a run is interrupted, re-run the pipeline with the same start_date.
  Hosts with status "completed" are skipped automatically.
  Hosts with status "failed" or "pending" are retried.

  Or pass --resume to main.py to pick up a previous run's state file.
"""

import json
import os
import threading
from datetime import datetime
from pathlib import Path


# ── Status values ────────────────────────────────────────────────────────────
STATUS_PENDING   = "pending"
STATUS_RUNNING   = "running"
STATUS_COMPLETED = "completed"
STATUS_FAILED    = "failed"
STATUS_SKIPPED   = "skipped"    # pre-flight failed — host never touched


class RunStateManager:
    """
    Thread-safe state file manager.
    Each upgrade run has one state file shared across all hosts.
    Multiple hosts can update it concurrently (multiprocessing writes are serialised
    by the OS since each process writes atomically via json.dump then rename).
    """

    def __init__(self, log_dir: Path, start_date: str, depcr: str) -> None:
        self._path       = log_dir / f"upgrade-state-{start_date}.json"
        self._start_date = start_date
        self._depcr      = depcr
        self._lock       = threading.Lock()

        # Initialise file if it doesn't exist
        if not self._path.exists():
            self._write({"start_date": start_date, "depcr": depcr, "hosts": {}})

    # ─────────────────────────────────────────────────────────
    # Public API
    # ─────────────────────────────────────────────────────────

    def register_hosts(self, hosts: list[str]) -> None:
        """Register all hosts as pending at start of run."""
        state = self._read()
        for host in hosts:
            if host not in state["hosts"]:
                state["hosts"][host] = {"status": STATUS_PENDING}
        self._write(state)

    def mark_running(self, host: str) -> None:
        """Mark host as actively being upgraded."""
        self._update_host(host, {
            "status":     STATUS_RUNNING,
            "started_at": datetime.now().isoformat(timespec="seconds"),
        })

    def mark_completed(self, host: str, result) -> None:
        """Mark host as successfully completed."""
        self._update_host(host, {
            "status":           STATUS_COMPLETED,
            "firmware_ok":      result.firmware_ok,
            "esxi_ok":          result.esxi_ok,
            "nic_health_ok":    result.nic_health_ok,
            "storage_health_ok":result.storage_health_ok,
            "elapsed_minutes":  round(result.elapsed_minutes, 2),
            "completed_at":     datetime.now().isoformat(timespec="seconds"),
        })

    def mark_failed(self, host: str, result=None, reason: str = "") -> None:
        """Mark host as failed."""
        data = {
            "status":       STATUS_FAILED,
            "completed_at": datetime.now().isoformat(timespec="seconds"),
        }
        if reason:
            data["reason"] = reason
        if result:
            data["firmware_ok"]       = result.firmware_ok
            data["esxi_ok"]           = result.esxi_ok
            data["elapsed_minutes"]   = round(result.elapsed_minutes, 2)
        self._update_host(host, data)

    def mark_skipped(self, host: str, reason: str = "") -> None:
        """Mark host as skipped (pre-flight failed — host never modified)."""
        self._update_host(host, {
            "status":   STATUS_SKIPPED,
            "reason":   reason,
            "skipped_at": datetime.now().isoformat(timespec="seconds"),
        })

    def get_pending_hosts(self, hosts: list[str]) -> list[str]:
        """
        Return hosts that still need to be run.
        Completed hosts are filtered out — enables resume.
        """
        state   = self._read()
        pending = []
        for host in hosts:
            host_state = state["hosts"].get(host, {}).get("status", STATUS_PENDING)
            if host_state == STATUS_COMPLETED:
                print(f"  [{host}] Already completed in previous run — skipping ✓")
            else:
                pending.append(host)
        return pending

    def get_summary(self) -> dict:
        """Return count of each status."""
        state   = self._read()
        summary = {s: 0 for s in [STATUS_PENDING, STATUS_RUNNING,
                                    STATUS_COMPLETED, STATUS_FAILED, STATUS_SKIPPED]}
        for host_data in state["hosts"].values():
            status = host_data.get("status", STATUS_PENDING)
            summary[status] = summary.get(status, 0) + 1
        return summary

    @property
    def path(self) -> Path:
        return self._path

    # ─────────────────────────────────────────────────────────
    # Internal
    # ─────────────────────────────────────────────────────────

    def _read(self) -> dict:
        with self._lock:
            try:
                return json.loads(self._path.read_text())
            except (json.JSONDecodeError, FileNotFoundError):
                return {"start_date": self._start_date, "depcr": self._depcr, "hosts": {}}

    def _write(self, data: dict) -> None:
        """Atomic write using temp file + rename to avoid corruption."""
        with self._lock:
            tmp = self._path.with_suffix(".tmp")
            tmp.write_text(json.dumps(data, indent=2))
            tmp.replace(self._path)   # atomic on POSIX systems

    def _update_host(self, host: str, updates: dict) -> None:
        state = self._read()
        if host not in state["hosts"]:
            state["hosts"][host] = {}
        state["hosts"][host].update(updates)
        self._write(state)
