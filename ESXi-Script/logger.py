"""
logger.py — Per-host structured logger.

Mirrors the PowerShell Write-Log module:
  Severity: Information | Warning | Error
Each line is timestamped and tagged with the host name.
"""

import logging
import sys
from pathlib import Path


_SEVERITY_MAP = {
    "Information": logging.INFO,
    "Warning":     logging.WARNING,
    "Error":       logging.ERROR,
}

_FMT = "%(asctime)s | %(levelname)-8s | %(message)s"
_DATE_FMT = "%Y-%m-%d %H:%M:%S"


def get_logger(host: str, transcript_dir: Path) -> "HostLogger":
    return HostLogger(host, transcript_dir)


class HostLogger:
    """
    Thin wrapper that writes to:
      • A per-host rotating file  (transcript_dir/<host>-<date>.log)
      • stdout  (so the operator console shows live progress)
    """

    def __init__(self, host: str, transcript_dir: Path) -> None:
        self.host = host
        name = f"upgrade.{host.replace('.', '_')}"
        self._log = logging.getLogger(name)
        self._log.setLevel(logging.DEBUG)

        if not self._log.handlers:
            fmt = logging.Formatter(_FMT, datefmt=_DATE_FMT)

            # ── File handler ──
            log_file = transcript_dir / f"{host}-upgrade.log"
            fh = logging.FileHandler(log_file, encoding="utf-8")
            fh.setFormatter(fmt)
            self._log.addHandler(fh)

            # ── Console handler ──
            ch = logging.StreamHandler(sys.stdout)
            ch.setFormatter(fmt)
            self._log.addHandler(ch)

    # ── Public API ──────────────────────────────────────────

    def info(self, msg: str) -> None:
        self._log.info(f"[{self.host}] {msg}")

    def warning(self, msg: str) -> None:
        self._log.warning(f"[{self.host}] {msg}")

    def error(self, msg: str) -> None:
        self._log.error(f"[{self.host}] {msg}")

    def section(self, title: str) -> None:
        sep = "─" * 80
        self._log.info(sep)
        self._log.info(f"[{self.host}]  ▶  {title}")
        self._log.info(sep)
