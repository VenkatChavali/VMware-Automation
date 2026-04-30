# -*- coding: utf-8 -*-
"""
test_01_models_and_baselines.py
================================
Tests for models.py and firmware_baselines.py.

NO network connectivity needed. These are pure data/logic tests.
Run from the project root directory:
    python tests/test_01_models_and_baselines.py

What this tests:
  - UpgradeOption enum values
  - FirmwareComponent creation
  - UpgradeResult defaults and overall_ok logic
  - Baseline lookup by model name
  - Disk version prefix resolver
  - get_unique_baselines returns correct folder names
"""

import sys
import os

# -- Add parent directory to path so we can import our modules --
# This is needed because the test file is in a subdirectory
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from models import UpgradeOption, FirmwareComponent, FirmwareInventoryItem, UpgradeResult
from firmware_baselines import (
    get_baselines,
    get_unique_baselines,
    resolve_disk_version,
    SUPPORTED_MODELS,
)


def separator(title: str) -> None:
    print(f"\n{'='*60}")
    print(f"  {title}")
    print(f"{'='*60}")


def test_upgrade_options():
    separator("TEST: UpgradeOption Enum")

    print(f"FIRMWARE_ONLY value : {UpgradeOption.FIRMWARE_ONLY}")   # should be 1
    print(f"ESXI_ONLY value     : {UpgradeOption.ESXI_ONLY}")       # should be 2
    print(f"ALL value           : {UpgradeOption.ALL}")              # should be 4

    # Test comparison -- mirrors PS: if ($opt -eq 1 -or $opt -eq 4)
    opt = UpgradeOption.ALL
    if opt in (UpgradeOption.FIRMWARE_ONLY, UpgradeOption.ALL):
        print("Firmware upgrade will run for option ALL  OK")
    if opt in (UpgradeOption.ESXI_ONLY, UpgradeOption.ALL):
        print("ESXi upgrade will run for option ALL      OK")

    # Create from integer -- mirrors receiving $opt = 4 from command line
    opt_from_int = UpgradeOption(4)
    print(f"Created from int 4  : {opt_from_int.name}")  # should be ALL


def test_firmware_component():
    separator("TEST: FirmwareComponent")

    # Create exactly like the baseline tables
    comp = FirmwareComponent(
        baseline    = "Baseline1",
        source_name = "BIOS",
        version     = "2.15.2",
    )
    print(f"baseline    : {comp.baseline}")     # Baseline1
    print(f"source_name : {comp.source_name}")  # BIOS
    print(f"version     : {comp.version}")      # 2.15.2

    # Access like a regular object -- same as $comp.Baseline in PS
    print(f"Is BIOS?    : {comp.source_name == 'BIOS'}")  # True


def test_firmware_inventory_item():
    separator("TEST: FirmwareInventoryItem")

    # Simulates what get_firmware_inventory() returns from iDRAC
    item = FirmwareInventoryItem(
        name    = "BIOS",
        version = "2.10.0",   # old version -- not at target
    )
    print(f"name      : {item.name}")
    print(f"version   : {item.version}")
    print(f"updateable: {item.updateable}")  # True (default)


def test_upgrade_result():
    separator("TEST: UpgradeResult -- defaults and overall_ok")

    result = UpgradeResult(host="esxi01.corp.local")

    print(f"host              : {result.host}")
    print(f"firmware_ok       : {result.firmware_ok}")        # False (default)
    print(f"esxi_ok           : {result.esxi_ok}")            # False (default)
    print(f"overall_ok        : {result.overall_ok}")         # False (nothing done yet)
    print(f"elapsed_minutes   : {result.elapsed_minutes}")    # 0.0

    # Simulate firmware upgrade succeeded, ESXi skipped
    result.firmware_ok      = True
    result.esxi_ok          = True
    result.esxi_skipped     = True
    result.elapsed_minutes  = 45.3

    print(f"\nAfter firmware success + ESXi skipped:")
    print(f"overall_ok  : {result.overall_ok}")   # True -- both conditions met
    print(f"elapsed     : {result.elapsed_minutes} min")

    # Simulate firmware failed
    result2 = UpgradeResult(host="esxi02.corp.local")
    result2.firmware_ok = False   # failed
    result2.esxi_ok     = True
    print(f"\nWith firmware failed:")
    print(f"overall_ok  : {result2.overall_ok}")  # False


def test_get_baselines():
    separator("TEST: get_baselines() -- retrieve baseline list for a model")

    print(f"Supported models: {SUPPORTED_MODELS}")

    # Test valid model
    baselines_r6525 = get_baselines("R6525")
    if baselines_r6525:
        print(f"\nR6525 has {len(baselines_r6525)} baseline entries")
        # Show first 3 entries
        for comp in baselines_r6525[:3]:
            print(f"  {comp.baseline:12} | {comp.source_name:45} | {comp.version}")
    else:
        print("R6525 baselines NOT FOUND -- check firmware_baselines.py")

    # Test uppercase/lowercase handling
    baselines_lower = get_baselines("r6525")  # should work same as R6525
    print(f"\nLowercase 'r6525' works: {baselines_lower is not None}")

    # Test unsupported model
    baselines_unknown = get_baselines("R9999")
    print(f"Unknown model returns None: {baselines_unknown is None}")


def test_get_unique_baselines():
    separator("TEST: get_unique_baselines() -- folder names to iterate")

    for model in SUPPORTED_MODELS:
        folders = get_unique_baselines(model)
        print(f"{model}: {folders}")
        # Should be something like ['Baseline0', 'Baseline1', 'Baseline2', 'Baseline3', 'Baseline4']

    # Verify they're sorted -- important because Baseline0 (iDRAC) must run first
    r6525_folders = get_unique_baselines("R6525")
    is_sorted = r6525_folders == sorted(r6525_folders)
    print(f"\nBaselines are sorted: {is_sorted}  OK")


def test_resolve_disk_version():
    separator("TEST: resolve_disk_version() -- disk firmware prefix mapping")

    # These mirror the actual disk version strings you'd see from iDRAC
    test_cases = [
        ("B02A1234",  "B02A"),   # starts with B0 -> B02A
        ("BA481234",  "BA48"),   # starts with BA -> BA48
        ("AS101234",  "AS10"),   # starts with AS -> AS10
        ("C10C5678",  "C10C"),   # starts with C  -> C10C
        ("EJ091234",  "EJ09"),   # starts with E  -> EJ09
        ("BD481234",  "BD48"),   # starts with BD -> BD48
        ("DSG81234",  "DSG8"),   # starts with DS -> DSG8
        ("2.0.1.000", "2.0.1"),  # starts with 2  -> 2.0.1
        ("UNKNOWN",   "NotFound"),# no match -> NotFound
    ]

    all_passed = True
    for raw_version, expected in test_cases:
        result = resolve_disk_version(raw_version)
        status = "OK" if result == expected else "FAIL FAIL"
        if result != expected:
            all_passed = False
        print(f"  {raw_version:15} -> {result:10} (expected {expected:10}) {status}")

    print(f"\nAll disk version tests passed: {all_passed}")

    # Critical edge case: BD must not match B0 prefix
    # If order is wrong, "BD481234" would match "B0" and return "B02A" incorrectly
    bd_result = resolve_disk_version("BD481234")
    print(f"\nEdge case -- BD not mismatched as B0: {bd_result == 'BD48'}  OK")


def test_baseline_count_per_model():
    separator("TEST: Baseline entry counts per model")

    for model in SUPPORTED_MODELS:
        baselines  = get_baselines(model)
        folders    = get_unique_baselines(model)
        print(f"{model}: {len(baselines):3} total entries | "
              f"{len(folders)} baseline folders: {folders}")


# -- Run all tests ----------------------------------------------------------
if __name__ == "__main__":
    print("\nRunning models + baselines tests (no network needed)")
    print("=" * 60)

    test_upgrade_options()
    test_firmware_component()
    test_firmware_inventory_item()
    test_upgrade_result()
    test_get_baselines()
    test_get_unique_baselines()
    test_resolve_disk_version()
    test_baseline_count_per_model()

    print("\n" + "=" * 60)
    print("  All model/baseline tests complete")
    print("=" * 60)
