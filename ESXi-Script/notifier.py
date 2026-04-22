"""
notifier.py
Microsoft Teams webhook notifications.

Sends a card to a Teams channel at key events:
  - Upgrade started
  - Phase completed (firmware / ESXi / health)
  - Upgrade completed (success or failure)
  - Critical failure mid-run

Configuration:
  Set TEAMS_WEBHOOK_URL in your environment or config file.
  If not set, all notifications are silently skipped — the upgrade still runs.

  TEAMS_WEBHOOK_URL = "https://dbs1bank.webhook.office.com/webhookb2/..."
  (This is the same webhook URL that was commented out in the original PS script)

Usage:
    from notifier import Notifier
    notifier = Notifier(webhook_url, host, depcr, logger)
    notifier.send_started()
    notifier.send_phase_result("Firmware", success=True, detail="All compliant")
    notifier.send_completed(result)
"""

import json
import time
from typing import Any

try:
    import requests as _requests
    _REQUESTS_AVAILABLE = True
except ImportError:
    _REQUESTS_AVAILABLE = False


# Colours for Teams cards
_COLOUR_GREEN  = "00b050"   # success
_COLOUR_RED    = "d13438"   # failure
_COLOUR_ORANGE = "ff8c00"   # warning / in-progress
_COLOUR_BLUE   = "0078d4"   # info


class Notifier:
    """
    Sends Microsoft Teams adaptive card notifications for upgrade events.
    All methods are safe to call even if webhook is not configured —
    they silently no-op rather than crashing the upgrade.
    """

    def __init__(
        self,
        webhook_url: str | None,
        host: str,
        depcr: str,
        logger,
    ) -> None:
        self._url    = webhook_url
        self._host   = host
        self._depcr  = depcr
        self._logger = logger
        self._start  = time.time()

        if not webhook_url:
            self._logger.info(
                "Teams webhook not configured — notifications disabled. "
                "Set TEAMS_WEBHOOK_URL to enable."
            )

    # ─────────────────────────────────────────────────────────
    # Public API
    # ─────────────────────────────────────────────────────────

    def send_started(self, upgrade_option: str) -> None:
        """Send notification when upgrade begins."""
        self._send(
            title  = f"🔄 Upgrade Started — {self._host}",
            colour = _COLOUR_BLUE,
            facts  = [
                ("Host",    self._host),
                ("DEP/CR",  self._depcr),
                ("Option",  upgrade_option),
                ("Time",    self._timestamp()),
            ],
        )

    def send_phase_result(
        self,
        phase: str,
        success: bool,
        detail: str = "",
    ) -> None:
        """Send notification when a phase completes."""
        icon   = "✅" if success else "❌"
        colour = _COLOUR_GREEN if success else _COLOUR_RED
        self._send(
            title  = f"{icon} {phase} — {self._host}",
            colour = colour,
            facts  = [
                ("Host",    self._host),
                ("Phase",   phase),
                ("Result",  "Success" if success else "FAILED"),
                ("Detail",  detail or "—"),
                ("Time",    self._timestamp()),
            ],
        )

    def send_preflight_failed(self, reason: str) -> None:
        """Send notification when pre-flight fails — no host changes made."""
        self._send(
            title  = f"⛔ Pre-flight Failed — {self._host}",
            colour = _COLOUR_RED,
            facts  = [
                ("Host",    self._host),
                ("DEP/CR",  self._depcr),
                ("Reason",  reason),
                ("Impact",  "No changes made to host — safe to investigate"),
                ("Time",    self._timestamp()),
            ],
        )

    def send_completed(self, result: Any) -> None:
        """
        Send final summary notification.
        result is an UpgradeResult object.
        """
        overall_ok = result.overall_ok
        icon       = "✅" if overall_ok else "❌"
        colour     = _COLOUR_GREEN if overall_ok else _COLOUR_RED
        elapsed    = f"{result.elapsed_minutes:.1f} min"

        facts = [
            ("Host",           self._host),
            ("DEP/CR",         self._depcr),
            ("Firmware",       result.firmware_remarks),
            ("ESXi Upgrade",   result.esxi_remarks),
            ("NIC Health",     "OK" if result.nic_health_ok     else "FAIL"),
            ("Storage Health", "OK" if result.storage_health_ok else "FAIL"),
            ("Elapsed",        elapsed),
            ("MM Status",      "Host left in Maintenance Mode — validate manually"),
        ]

        self._send(
            title  = f"{icon} Upgrade {'Complete' if overall_ok else 'FAILED'} — {self._host}",
            colour = colour,
            facts  = facts,
        )

    def send_critical(self, phase: str, error: str) -> None:
        """Send notification for unhandled exceptions."""
        self._send(
            title  = f"🚨 Critical Error — {self._host}",
            colour = _COLOUR_RED,
            facts  = [
                ("Host",    self._host),
                ("DEP/CR",  self._depcr),
                ("Phase",   phase),
                ("Error",   error[:500]),   # truncate long tracebacks
                ("Action",  "Investigate immediately — host state unknown"),
                ("Time",    self._timestamp()),
            ],
        )

    # ─────────────────────────────────────────────────────────
    # Internal
    # ─────────────────────────────────────────────────────────

    def _send(self, title: str, colour: str, facts: list[tuple[str, str]]) -> None:
        """
        Build and POST a Teams message card.
        Uses the legacy Connector Card format (O365 webhook compatible).
        Silently skips if webhook is not configured or requests is not installed.
        """
        if not self._url:
            return

        if not _REQUESTS_AVAILABLE:
            self._logger.warning(
                "Cannot send Teams notification — requests library not installed"
            )
            return

        payload = {
            "@type":       "MessageCard",
            "@context":    "http://schema.org/extensions",
            "themeColor":  colour,
            "summary":     title,
            "sections": [{
                "activityTitle": title,
                "facts": [
                    {"name": k, "value": str(v)}
                    for k, v in facts
                ],
                "markdown": True,
            }],
        }

        try:
            resp = _requests.post(
                self._url,
                json    = payload,
                timeout = 15,
                headers = {"Content-Type": "application/json"},
            )
            if resp.status_code not in (200, 202):
                self._logger.warning(
                    f"Teams notification returned HTTP {resp.status_code}: "
                    f"{resp.text[:200]}"
                )
        except Exception as exc:
            # Never let notification failure crash the upgrade
            self._logger.warning(f"Teams notification failed (non-fatal): {exc}")

    def _timestamp(self) -> str:
        from datetime import datetime
        return datetime.now().strftime("%Y-%m-%d %H:%M:%S")
