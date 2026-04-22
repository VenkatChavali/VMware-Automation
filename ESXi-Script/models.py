"""
models.py — Shared data classes and enums.
"""

from dataclasses import dataclass, field
from enum import IntEnum


class UpgradeOption(IntEnum):
    FIRMWARE_ONLY = 1
    ESXI_ONLY     = 2
    ALL           = 4


@dataclass
class FirmwareComponent:
    """A single firmware component target for a given hardware model."""
    baseline: str          # e.g. "Baseline0"
    source_name: str       # e.g. "BIOS", "Disk", "QLE"
    version: str           # target version string


@dataclass
class FirmwareInventoryItem:
    """A single item returned by the iDRAC Redfish firmware inventory."""
    name: str
    version: str
    updateable: bool = True


@dataclass
class UpgradeResult:
    """Final result object for one ESXi host — mirrors the PS $MyObj output."""
    host: str

    firmware_ok: bool       = False
    firmware_skipped: bool  = False
    firmware_remarks: str   = ""

    esxi_ok: bool           = False
    esxi_skipped: bool      = False
    esxi_remarks: str       = ""

    nic_health_ok: bool     = False
    storage_health_ok: bool = False

    elapsed_minutes: float  = 0.0

    @property
    def overall_ok(self) -> bool:
        return (
            (self.firmware_ok or self.firmware_skipped) and
            (self.esxi_ok     or self.esxi_skipped)
        )


@dataclass
class HostSnapshot:
    """Pre-upgrade NIC + HBA snapshot for health-check comparison."""
    nics: list[dict] = field(default_factory=list)
    hbas: list[dict] = field(default_factory=list)
