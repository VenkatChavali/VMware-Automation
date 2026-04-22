"""
test_05_upgrade_engine_dryrun.py
=================================
Tests for upgrade_engine.py using dry-run mode.

REQUIRES: vCenter + ESXi + iDRAC connectivity.
NO firmware binaries are uploaded. NO host changes are made.
Run from the project root directory:
    python tests/test_05_upgrade_engine_dryrun.py

Fill in the CONFIG section below before running.

What this tests:
  - Full Phase 0: pre-flight (DRS check, NIC/HBA snapshot, vendor/model detection)
  - Full Phase 2: firmware compliance check (read-only — just checks, doesn't update)
  - Full Phase 3: ESXi upgrade dry-run (checks current build, selects bundle, doesn't run)
  - Full Phase 4: health check comparison

This is the safest end-to-end test before your first real run.
Think of it as: run this on every host BEFORE the real upgrade to confirm
the script can see everything it needs.
"""

import sys
import os
import tempfile
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from logger import get_logger
from models import UpgradeOption
from upgrade_engine import UpgradeEngine

# ─────────────────────────────────────────────────────────────────────────────
# CONFIG — fill these in before running
# ─────────────────────────────────────────────────────────────────────────────
VCENTER        = "vc01g.corp.local"
VC_USER        = "administrator@vsphere.local"
VC_PASS        = "YourVCPassword"

ESXI_HOST      = "esxi01.corp.local"
ESXI_ROOT_USER = "root"
ESXI_ROOT_PASS = "YourRootPassword"

IDRAC_USER     = "vpcidracadmin"
IDRAC_PASS     = "YourIDRACPassword"

FIRMWARE_REPO  = "/opt/upgrade/Firmware-Binaries"
# FIRMWARE_REPO = r"C:\Upgrade\Firmware-Binaries"   # Windows path

UPGRADE_OPTION = UpgradeOption.ALL   # Test all phases in dry-run
# ─────────────────────────────────────────────────────────────────────────────


def separator(title: str) -> None:
    print(f"\n{'='*60}")
    print(f"  {title}")
    print(f"{'='*60}")


def test_full_dry_run():
    """
    Run the complete upgrade engine in dry-run mode.
    All phases execute their LOGIC but make ZERO changes:
      - No firmware binaries uploaded
      - No host reboots
      - No maintenance mode changes
      - No ESXi profile update

    What you WILL see:
      - Pre-flight checks (DRS, vendor, model)
      - Firmware compliance check (reads from iDRAC, compares to baselines)
      - Which components need updating and which are already compliant
      - Which ESXi bundle would be selected for this vendor
      - NIC/HBA health check comparison (before vs after — same since no reboot)
      - Full summary with pass/fail per phase

    This is your best validation tool before the first real run.
    """
    separator("Full Upgrade Engine Dry-Run")

    log_dir    = Path(tempfile.mkdtemp())
    start_date = "TEST-DRY-RUN"

    # Create transcript directory (engine expects it to exist)
    transcript_dir = log_dir / "Transcripts"
    transcript_dir.mkdir(parents=True)

    logger = get_logger(ESXI_HOST, transcript_dir)

    print(f"Log dir      : {log_dir}")
    print(f"Firmware repo: {FIRMWARE_REPO}")
    print(f"Upgrade opt  : {UPGRADE_OPTION.name}")
    print(f"DRY RUN      : YES — no changes will be made")
    print()

    engine = UpgradeEngine(
        esxi_host       = ESXI_HOST,
        vcenter         = VCENTER,
        idrac_creds     = {"username": IDRAC_USER, "password": IDRAC_PASS},
        vcenter_creds   = {"username": VC_USER,    "password": VC_PASS},
        esxi_root_creds = {"username": ESXI_ROOT_USER, "password": ESXI_ROOT_PASS},
        firmware_repo   = Path(FIRMWARE_REPO),
        license_key     = "NA",
        upgrade_option  = UPGRADE_OPTION,
        depcr           = "TEST-DRY-RUN",
        start_date      = start_date,
        log_dir         = log_dir,
        dry_run         = True,    # ← THE KEY FLAG — nothing will actually happen
        logger          = logger,
    )

    print("Starting engine.run() in dry-run mode ...\n")
    result = engine.run()

    # Print result summary
    separator("Dry-Run Result Summary")
    print(f"Host              : {result.host}")
    print(f"Firmware result   : {result.firmware_remarks}")
    print(f"ESXi result       : {result.esxi_remarks}")
    print(f"NIC health        : {'✓ OK' if result.nic_health_ok     else '✗ FAIL'}")
    print(f"Storage health    : {'✓ OK' if result.storage_health_ok else '✗ FAIL'}")
    print(f"Overall           : {'✓ OK' if result.overall_ok        else '✗ FAIL'}")
    print(f"Elapsed           : {result.elapsed_minutes:.1f} min")

    print(f"\nFull log written to: {log_dir / 'Transcripts' / f'{ESXI_HOST}-upgrade.log'}")

    return result


def test_phase0_only():
    """
    Test ONLY Phase 0 — pre-flight checks.
    Useful to quickly verify:
      - vCenter connection works
      - Host object is found
      - NIC/HBA snapshot works
      - DRS state is correct
      - Vendor/model detection works

    This creates the UpgradeEngine and manually calls just _phase0_preflight().
    """
    separator("Phase 0 Only — Pre-flight Validation")

    log_dir        = Path(tempfile.mkdtemp())
    transcript_dir = log_dir / "Transcripts"
    transcript_dir.mkdir(parents=True)

    logger = get_logger(ESXI_HOST, transcript_dir)

    engine = UpgradeEngine(
        esxi_host       = ESXI_HOST,
        vcenter         = VCENTER,
        idrac_creds     = {"username": IDRAC_USER, "password": IDRAC_PASS},
        vcenter_creds   = {"username": VC_USER,    "password": VC_PASS},
        esxi_root_creds = {"username": ESXI_ROOT_USER, "password": ESXI_ROOT_PASS},
        firmware_repo   = Path(FIRMWARE_REPO),
        license_key     = "NA",
        upgrade_option  = UpgradeOption.ALL,
        depcr           = "TEST",
        start_date      = "TEST",
        log_dir         = log_dir,
        dry_run         = True,
        logger          = logger,
    )

    print("Running Phase 0 pre-flight only ...")

    try:
        engine._phase0_preflight()

        print(f"\n✓ Phase 0 complete")
        print(f"  Vendor      : {engine._vendor}")
        print(f"  Model full  : {engine._model_full}")
        print(f"  Model short : {engine._model_short}")
        print(f"  NIC count   : {len(engine._before_nics)}")
        print(f"  HBA count   : {len(engine._before_hbas)}")

    except Exception as exc:
        print(f"✗ Phase 0 failed: {exc}")
        import traceback
        traceback.print_exc()
    finally:
        if engine._vc:
            engine._vc.disconnect()


# ── Menu ──────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    print("\n" + "="*60)
    print("  Upgrade Engine Dry-Run Tests")
    print(f"  vCenter : {VCENTER}")
    print(f"  ESXi    : {ESXI_HOST}")
    print("="*60)

    print("""
Select a test:
  1  Full dry-run (all phases, no changes) — RECOMMENDED FIRST TEST
  2  Phase 0 only (pre-flight checks)
""")

    choice = input("Enter choice: ").strip()

    if choice == "1":
        test_full_dry_run()
    elif choice == "2":
        test_phase0_only()
    else:
        print("Invalid choice")
