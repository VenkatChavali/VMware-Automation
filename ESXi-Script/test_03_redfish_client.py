# -*- coding: utf-8 -*-
"""
test_03_redfish_client.py
==========================
Tests for redfish_client.py

REQUIRES: Real iDRAC connectivity.
Run from the project root directory:
    python tests/test_03_redfish_client.py

Fill in your iDRAC details in the CONFIG section below before running.

What this tests -- each function individually:
  1. Session creation (POST /redfish/v1/Sessions)
  2. get_firmware_inventory() -- retrieve installed firmware list
  3. clear_job_queue_restart_lc() -- clear iDRAC job queue
  4. upload_and_stage_firmware() -- upload a single binary
  5. wait_for_task() -- poll a job to completion
  6. is_reachable() -- basic connectivity check

Run tests selectively -- comment out the ones you don't want to run yet.
Each test is independent -- you can run just test_01 first to verify connectivity.
"""

import sys
import os
import time
import tempfile
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from logger import get_logger
from redfish_client import RedfishClient

# -----------------------------------------------------------------------------
# CONFIG -- fill these in before running
# -----------------------------------------------------------------------------
IDRAC_IP   = "192.168.1.10"      # iDRAC IP of your test host
IDRAC_USER = "vpcidracadmin"     # iDRAC username
IDRAC_PASS = "YourPassword"      # iDRAC password

# For upload test -- set to a real firmware binary on your machine
# Leave as None to skip the upload test
TEST_BINARY_PATH = None
# TEST_BINARY_PATH = r"C:\Upgrade\Firmware-Binaries\R6525\Baseline0\iDRAC_7.10.50.00.EXE"
# -----------------------------------------------------------------------------


def separator(title: str) -> None:
    print(f"\n{'='*60}")
    print(f"  {title}")
    print(f"{'='*60}")


def make_logger(host: str = "test-host") -> object:
    """Create a logger that writes to console only for testing."""
    tmpdir = tempfile.mkdtemp()
    return get_logger(host, Path(tmpdir))


def test_01_connectivity():
    """
    Test basic iDRAC reachability.
    This is your first test -- if this fails, nothing else will work.
    Equivalent to testing if you can reach the iDRAC at all.
    """
    separator("TEST 01: Basic iDRAC Connectivity")

    logger = make_logger()

    with RedfishClient(IDRAC_IP, IDRAC_USER, IDRAC_PASS, logger) as rf:
        reachable = rf.is_reachable()
        print(f"iDRAC {IDRAC_IP} is reachable: {reachable}")

        if reachable:
            print("OK iDRAC is responding to Redfish API calls")
        else:
            print("FAIL Cannot reach iDRAC -- check IP, credentials, and network")

    return reachable


def test_02_get_firmware_inventory():
    """
    Test firmware inventory retrieval.
    Mirrors: Get-IdracFirmwareVersionREDFISH

    This is a READ-ONLY operation -- safe to run at any time.
    Shows you exactly what firmware versions are installed right now.
    """
    separator("TEST 02: Get Firmware Inventory")

    logger = make_logger()

    with RedfishClient(IDRAC_IP, IDRAC_USER, IDRAC_PASS, logger) as rf:
        print("Fetching firmware inventory from iDRAC ...")
        inventory = rf.get_firmware_inventory()

        print(f"\nTotal installed components: {len(inventory)}")
        print(f"\n{'Component Name':<50} {'Version':<20}")
        print(f"{'-'*50} {'-'*20}")

        for item in inventory:
            print(f"{item.name:<50} {item.version:<20}")

        # Spot-check for common components
        names = [item.name for item in inventory]

        has_idrac = any("Remote Access Controller" in n for n in names)
        has_bios  = any("BIOS" in n for n in names)

        print(f"\nContains iDRAC entry : {has_idrac}")
        print(f"Contains BIOS entry  : {has_bios}")

    return inventory


def test_03_compliance_check_against_baselines():
    """
    Test the compliance check logic WITHOUT making any changes.
    Compares what's installed against your baseline targets.
    READ-ONLY -- safe to run at any time.

    This is the most useful test to understand the firmware state
    of your host before running the actual upgrade.
    """
    separator("TEST 03: Compliance Check Against Baselines (Read-Only)")

    from firmware_baselines import get_baselines, resolve_disk_version

    # Detect model first -- you can hardcode this for testing
    # MODEL = "R6525"  # uncomment and hardcode if needed
    # For now we'll fetch from iDRAC via inventory name patterns
    MODEL = input("Enter server model (R6525/R7425/R6625/R7625): ").strip().upper()

    baselines = get_baselines(MODEL)
    if not baselines:
        print(f"No baselines found for model {MODEL}")
        return

    logger = make_logger()

    with RedfishClient(IDRAC_IP, IDRAC_USER, IDRAC_PASS, logger) as rf:
        inventory = rf.get_firmware_inventory()

    print(f"\nCompliance check for {MODEL}:")
    print(f"{'Component':<45} {'Baseline Target':<15} {'Installed':<15} {'Status'}")
    print(f"{'-'*45} {'-'*15} {'-'*15} {'-'*10}")

    compliant_count     = 0
    non_compliant_count = 0
    not_found_count     = 0

    for comp in baselines:
        matches = [
            item for item in inventory
            if comp.source_name.lower() in item.name.lower()
        ]

        if not matches:
            print(f"{comp.source_name:<45} {comp.version:<15} {'N/A':<15} NOT FOUND")
            not_found_count += 1
            continue

        actual_item = matches[0]
        actual_ver  = actual_item.version

        if comp.source_name == "Disk":
            target = resolve_disk_version(actual_ver)
        else:
            target = comp.version

        if target == "NotFound":
            status = "SKIP (disk prefix unknown)"
        elif actual_ver == target:
            status = "OK COMPLIANT"
            compliant_count += 1
        else:
            status = "FAIL NEEDS UPDATE"
            non_compliant_count += 1

        print(f"{actual_item.name:<45} {target:<15} {actual_ver:<15} {status}")

    print(f"\nSummary:")
    print(f"  Compliant    : {compliant_count}")
    print(f"  Needs update : {non_compliant_count}")
    print(f"  Not found    : {not_found_count}")


def test_04_clear_job_queue():
    """
    Test clearing the iDRAC job queue.
    Mirrors: Invoke-IdracJobQueueManagementREDFISH -delete_job_queue_restart_LC_services y

    WARNING: This DOES make changes to the iDRAC -- it clears all pending jobs
    and restarts LC services. Only run this if you're OK with that.
    It's safe to run on a host that's already in maintenance mode.
    """
    separator("TEST 04: Clear iDRAC Job Queue + Restart LC")

    confirm = input(
        "\nThis clears the iDRAC job queue and restarts LC services.\n"
        "Only run on a host in maintenance mode.\n"
        "Continue? (yes/no): "
    ).strip().lower()

    if confirm != "yes":
        print("Skipped.")
        return

    logger = make_logger()

    with RedfishClient(IDRAC_IP, IDRAC_USER, IDRAC_PASS, logger) as rf:
        print("\nClearing job queue (this takes ~5 min for LC to restart) ...")
        start  = time.time()
        result = rf.clear_job_queue_restart_lc(dry_run=False)
        elapsed = (time.time() - start) / 60

        print(f"\nResult  : {'OK Success' if result else 'FAIL Failed'}")
        print(f"Elapsed : {elapsed:.1f} min")


def test_05_upload_single_firmware():
    """
    Test uploading a single firmware binary to iDRAC.
    Mirrors: Set-DeviceFirmwareSimpleUpdateREDFISH (Step 1 -- upload to staging)

    WARNING: This DOES upload a binary to iDRAC and creates a staged update job.
    The job won't apply until the host reboots -- so it's semi-safe on a MM host.
    But only run this if you have a real binary and intend to use it.

    Set TEST_BINARY_PATH at the top of this file before running.
    """
    separator("TEST 05: Upload Single Firmware Binary")

    if not TEST_BINARY_PATH:
        print("TEST_BINARY_PATH is not set -- skipping.")
        print("Set TEST_BINARY_PATH at the top of this file to a real .EXE binary.")
        return

    binary = Path(TEST_BINARY_PATH)
    if not binary.exists():
        print(f"Binary not found: {binary}")
        return

    confirm = input(
        f"\nThis will upload {binary.name} to iDRAC {IDRAC_IP}.\n"
        f"A staged update job will be created (applies on next reboot).\n"
        f"Continue? (yes/no): "
    ).strip().lower()

    if confirm != "yes":
        print("Skipped.")
        return

    logger = make_logger()

    with RedfishClient(IDRAC_IP, IDRAC_USER, IDRAC_PASS, logger) as rf:
        print(f"\nUploading {binary.name} ...")
        start  = time.time()

        job_id = rf.upload_and_stage_firmware(binary, dry_run=False)

        elapsed = (time.time() - start) / 60
        print(f"\nJob ID  : {job_id}")
        print(f"Elapsed : {elapsed:.1f} min")

        if job_id and job_id != "DRY-RUN-JOB":
            print(f"\nPolling task {job_id} ...")
            success = rf.wait_for_task(job_id)
            print(f"Task result: {'OK Scheduled/Complete' if success else 'FAIL Failed'}")


def test_06_dry_run_upload():
    """
    Test the dry-run mode for upload.
    No changes made -- just logs what WOULD happen.
    Safe to run at any time.
    """
    separator("TEST 06: Dry-Run Upload (no changes)")

    if not TEST_BINARY_PATH:
        # Use a fake path for dry-run testing -- dry-run doesn't actually open the file
        fake_binary = Path("BIOS_2.15.2_A00.EXE")
    else:
        fake_binary = Path(TEST_BINARY_PATH)

    logger = make_logger()

    with RedfishClient(IDRAC_IP, IDRAC_USER, IDRAC_PASS, logger) as rf:
        print(f"Dry-run upload of {fake_binary.name} ...")
        job_id = rf.upload_and_stage_firmware(fake_binary, dry_run=True)
        print(f"Dry-run job ID: {job_id}")  # should be "DRY-RUN-JOB"
        print("OK Dry-run completed -- no changes made to iDRAC")


# -- Menu to select which test to run -----------------------------------------
if __name__ == "__main__":
    print("\n" + "="*60)
    print("  Redfish Client Tests")
    print(f"  iDRAC: {IDRAC_IP}")
    print("="*60)

    print("""
Select a test to run:
  1  Connectivity check (read-only, always safe)
  2  Get firmware inventory (read-only, always safe)
  3  Compliance check vs baselines (read-only, always safe)
  4  Clear job queue + restart LC  (MAKES CHANGES -- MM host only)
  5  Upload single firmware binary  (MAKES CHANGES -- MM host only)
  6  Dry-run upload (read-only, always safe)
  a  Run all read-only tests (1, 2, 6)
""")

    choice = input("Enter choice: ").strip().lower()

    if choice == "1":
        test_01_connectivity()
    elif choice == "2":
        test_02_get_firmware_inventory()
    elif choice == "3":
        test_03_compliance_check_against_baselines()
    elif choice == "4":
        test_04_clear_job_queue()
    elif choice == "5":
        test_05_upload_single_firmware()
    elif choice == "6":
        test_06_dry_run_upload()
    elif choice == "a":
        ok = test_01_connectivity()
        if ok:
            test_02_get_firmware_inventory()
            test_06_dry_run_upload()
        else:
            print("Connectivity failed -- skipping remaining tests")
    else:
        print("Invalid choice")
