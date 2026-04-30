# -*- coding: utf-8 -*-
"""
firmware_baselines.py
Firmware baseline definitions for all supported Dell hardware models.
Direct translation of the PowerShell $R6525, $R7425, $R6625, $R7625 arrays.

Structure:
    BASELINES[model] = list of FirmwareComponent

Each FirmwareComponent maps:
    baseline    -> which sub-folder under Firmware-Binaries/<model>/
    source_name -> substring matched against iDRAC firmware inventory Name
    version     -> target version (what we want the component to be at)
"""

from models import FirmwareComponent

# ------------------------------------------------------------------------------
# Disk version prefix -> canonical version string mapping.
# Mirrors the large if/elseif block in the original PS script.
# ------------------------------------------------------------------------------
DISK_VERSION_PREFIX_MAP: dict[str, str] = {
    "B0": "B02A",
    "BA": "BA48",
    "AS": "AS10",
    "C":  "C10C",
    "E":  "EJ09",
    "BD": "BD48",
    "DS": "DSG8",
    "2":  "2.0.1",
}

# Prefix test order matters -- longest/most specific first
DISK_PREFIX_ORDER = ["B0", "BA", "AS", "BD", "DS", "C", "E", "2"]


def resolve_disk_version(raw_version: str) -> str:
    """
    Given an actual disk firmware version string from iDRAC inventory,
    return the canonical target version string used for baseline comparison.

    Mirrors the nested if/elseif disk-version block in ESXi-Firmware-Update-iDrac.
    """
    for prefix in DISK_PREFIX_ORDER:
        if raw_version.upper().startswith(prefix.upper()):
            return DISK_VERSION_PREFIX_MAP[prefix]
    return "NotFound"


# ------------------------------------------------------------------------------
# R6525
# ------------------------------------------------------------------------------
_R6525: list[FirmwareComponent] = [
    FirmwareComponent("Baseline0", "Integrated Dell Remote Access Controller", "7.10.50.00"),
    FirmwareComponent("Baseline1", "BIOS",                                     "2.15.2"),
    FirmwareComponent("Baseline1", "Backplane",                                "7.10"),
    FirmwareComponent("Baseline1", "Broadcom Adv",                             "22.92.06.10"),
    FirmwareComponent("Baseline1", "Disk",                                     "B02A"),
    FirmwareComponent("Baseline1", "X710",                                     "22.5.7"),
    FirmwareComponent("Baseline2", "Disk",                                     "C10C"),
    FirmwareComponent("Baseline2", "PERC H755",                                "52.26.0-5179"),
    FirmwareComponent("Baseline2", "Broadcom NetXtreme Gigabit Ethernet",      "22.91.5"),
    FirmwareComponent("Baseline2", "Broadcom Gigabit Ethernet",                "22.91.5"),
    FirmwareComponent("Baseline2", "QLE",                                      "16.20.10"),
    FirmwareComponent("Baseline2", "X550/I350",                                "22.5.7"),
    FirmwareComponent("Baseline2", "I350/X550",                                "22.5.7"),
    FirmwareComponent("Baseline3", "QLE",                                      "16.20.10"),
    FirmwareComponent("Baseline3", "Disk",                                     "BA48"),
    FirmwareComponent("Baseline3", "I350",                                     "22.5.7"),
    FirmwareComponent("Baseline3", "X550",                                     "22.5.7"),
    FirmwareComponent("Baseline3", "PERC H740P",                               "51.16.0-5150"),
    FirmwareComponent("Baseline3", "PERC H745",                                "51.16.0-5150"),
    FirmwareComponent("Baseline4", "System CPLD",                              "1.2.0"),
]

# ------------------------------------------------------------------------------
# R7425
# ------------------------------------------------------------------------------
_R7425: list[FirmwareComponent] = [
    FirmwareComponent("Baseline0", "Integrated Dell Remote Access Controller", "7.00.00.172"),
    FirmwareComponent("Baseline1", "BIOS",                                     "1.21.0"),
    FirmwareComponent("Baseline1", "Backplane",                                "2.52"),
    FirmwareComponent("Baseline1", "I350",                                     "22.5.7"),
    FirmwareComponent("Baseline1", "Disk",                                     "B02A"),
    FirmwareComponent("Baseline1", "PERC H745",                                "51.16.0-5150"),
    FirmwareComponent("Baseline1", "PERC H740P",                               "51.16.0-5150"),
    FirmwareComponent("Baseline1", "PERC H830",                                "25.5.9.0001"),
    FirmwareComponent("Baseline1", "X550",                                     "22.5.7"),
    FirmwareComponent("Baseline1", "Broadcom Adv",                             "22.92.06.10"),
    FirmwareComponent("Baseline2", "QLE",                                      "16.20.10"),
    FirmwareComponent("Baseline2", "X550/I350",                                "22.5.7"),
    FirmwareComponent("Baseline2", "I350/X550",                                "22.5.7"),
    FirmwareComponent("Baseline2", "Broadcom NetXtreme Gigabit Ethernet",      "22.91.5"),
    FirmwareComponent("Baseline2", "Broadcom Gigabit Ethernet",                "22.91.5"),
    FirmwareComponent("Baseline3", "PERC H840",                                "51.16.0-5148"),
    FirmwareComponent("Baseline3", "Disk",                                     "AS10"),
    FirmwareComponent("Baseline3", "X710",                                     "22.5.7"),
    FirmwareComponent("Baseline3", "QLE",                                      "16.20.10"),
    FirmwareComponent("Baseline4", "System CPLD",                              "1.0.11"),
]

# ------------------------------------------------------------------------------
# R6625
# ------------------------------------------------------------------------------
_R6625: list[FirmwareComponent] = [
    FirmwareComponent("Baseline0", "Integrated Dell Remote Access Controller", "7.10.50.00"),
    FirmwareComponent("Baseline1", "BIOS",                                     "1.8.3"),
    FirmwareComponent("Baseline1", "Backplane",                                "7.10"),
    FirmwareComponent("Baseline1", "Broadcom Adv",                             "22.92.06.10"),
    FirmwareComponent("Baseline1", "Disk",                                     "2.0.1"),
    FirmwareComponent("Baseline1", "Disk",                                     "C10C"),
    FirmwareComponent("Baseline1", "X550/I350",                                "22.5.7"),
    FirmwareComponent("Baseline1", "I350/X550",                                "22.5.7"),
    FirmwareComponent("Baseline2", "Disk",                                     "BD48"),
    FirmwareComponent("Baseline2", "Broadcom NetXtreme Gigabit Ethernet",      "22.91.5"),
    FirmwareComponent("Baseline2", "Broadcom Gigabit Ethernet",                "22.91.5"),
    FirmwareComponent("Baseline2", "QLE",                                      "16.20.10"),
    FirmwareComponent("Baseline2", "X710",                                     "22.5.7"),
    FirmwareComponent("Baseline3", "PERC H755",                                "52.26.0-5179"),
    FirmwareComponent("Baseline3", "Disk",                                     "EJ09"),
    FirmwareComponent("Baseline3", "I350",                                     "22.5.7"),
    FirmwareComponent("Baseline3", "X550",                                     "22.5.7"),
    FirmwareComponent("Baseline4", "System CPLD",                              "1.6.1"),
]

# ------------------------------------------------------------------------------
# R7625
# ------------------------------------------------------------------------------
_R7625: list[FirmwareComponent] = [
    FirmwareComponent("Baseline0", "Integrated Dell Remote Access Controller", "7.10.50.00"),
    FirmwareComponent("Baseline1", "BIOS",                                     "1.8.3"),
    FirmwareComponent("Baseline1", "Backplane",                                "7.10"),
    FirmwareComponent("Baseline1", "Broadcom Adv",                             "22.92.06.10"),
    FirmwareComponent("Baseline1", "Disk",                                     "2.0.1"),
    FirmwareComponent("Baseline1", "X550/I350",                                "22.5.7"),
    FirmwareComponent("Baseline1", "I350/X550",                                "22.5.7"),
    FirmwareComponent("Baseline2", "Disk",                                     "C10C"),
    FirmwareComponent("Baseline2", "Broadcom NetXtreme Gigabit Ethernet",      "22.91.5"),
    FirmwareComponent("Baseline2", "Broadcom Gigabit Ethernet",                "22.91.5"),
    FirmwareComponent("Baseline2", "QLE",                                      "16.20.10"),
    FirmwareComponent("Baseline2", "X710",                                     "22.5.7"),
    FirmwareComponent("Baseline3", "PERC H755",                                "52.26.0-5179"),
    FirmwareComponent("Baseline3", "I350",                                     "22.5.7"),
    FirmwareComponent("Baseline3", "X550",                                     "22.5.7"),
    FirmwareComponent("Baseline3", "Disk",                                     "DSG8"),
    FirmwareComponent("Baseline4", "System CPLD",                              "1.6.1"),
]

# ------------------------------------------------------------------------------
# Registry
# ------------------------------------------------------------------------------
BASELINES: dict[str, list[FirmwareComponent]] = {
    "R6525": _R6525,
    "R7425": _R7425,
    "R6625": _R6625,
    "R7625": _R7625,
}

SUPPORTED_MODELS = list(BASELINES.keys())


def get_baselines(model: str) -> list[FirmwareComponent] | None:
    """Return the baseline list for a given hardware model, or None if unsupported."""
    return BASELINES.get(model.upper())


def get_unique_baselines(model: str) -> list[str]:
    """Return sorted unique baseline folder names for a model, e.g. ['Baseline0', 'Baseline1', ...]"""
    comps = get_baselines(model)
    if not comps:
        return []
    return sorted(set(c.baseline for c in comps))
