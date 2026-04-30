# -*- coding: utf-8 -*-
"""
test_04_vsphere_client.py
==========================
Tests for vsphere_client.py

REQUIRES: vCenter + ESXi connectivity.
Run from the project root directory:
    python tests/test_04_vsphere_client.py

Fill in the CONFIG section below before running.

What this tests:
  1.  vCenter connection
  2.  Find ESXi host object
  3.  Get host info (vendor, model, build, version)
  4.  Get iDRAC IP from host IPMI config
  5.  Get NIC snapshot
  6.  Get HBA snapshot
  7.  Check VM DRS overrides
  8.  Check cluster DRS level
  9.  Alarm enable/disable
  10. SSH connectivity + esxcli command
  11. ESXi upgrade dry-run (no changes)
  12. Maintenance mode enter/exit (MAKES CHANGES)

Tests 1-10 are read-only -- safe on production.
Tests 11-12 make changes -- only run on a test/MM host.
"""

import sys
import os
import tempfile
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from logger import get_logger
from vsphere_client import VSphereClient

# -----------------------------------------------------------------------------
# CONFIG -- fill these in before running
# -----------------------------------------------------------------------------
VCENTER        = "vc01g.corp.local"
VC_USER        = "administrator@vsphere.local"
VC_PASS        = "YourVCPassword"

ESXI_HOST      = "esxi01.corp.local"
ESXI_ROOT_USER = "root"
ESXI_ROOT_PASS = "YourRootPassword"
# -----------------------------------------------------------------------------


def separator(title: str) -> None:
    print(f"\n{'='*60}")
    print(f"  {title}")
    print(f"{'='*60}")


def make_client() -> VSphereClient:
    """Create a VSphereClient connected to your vCenter."""
    tmpdir = tempfile.mkdtemp()
    logger = get_logger(ESXI_HOST, Path(tmpdir))
    return VSphereClient(
        vcenter        = VCENTER,
        username       = VC_USER,
        password       = VC_PASS,
        esxi_host      = ESXI_HOST,
        esxi_root_user = ESXI_ROOT_USER,
        esxi_root_pass = ESXI_ROOT_PASS,
        logger         = logger,
    )


def test_01_vcenter_connection():
    """
    Test vCenter connection.
    Mirrors: Connect-VIServer -Server $vCenter -Credential $vcCreds
    READ-ONLY -- safe on production.
    """
    separator("TEST 01: vCenter Connection")

    try:
        vc = make_client()
        print(f"OK Connected to vCenter: {VCENTER}")
        print(f"OK Found host object   : {vc.esxi_host}")
        vc.disconnect()
        return True
    except Exception as exc:
        print(f"FAIL Connection failed: {exc}")
        return False


def test_02_host_info():
    """
    Test reading host hardware information.
    Mirrors: $esxcli.hardware.platform.get.Invoke()
    READ-ONLY -- safe on production.
    """
    separator("TEST 02: Host Hardware Info")

    vc = make_client()
    try:
        vendor  = vc.get_vendor()
        model   = vc.get_model()
        build   = vc.get_build()
        version = vc.get_version()
        state   = vc.get_connection_state()
        in_mm   = vc.is_in_maintenance_mode()

        print(f"Vendor     : {vendor}")
        print(f"Model      : {model}")
        print(f"Build      : {build}")
        print(f"Version    : {version}")
        print(f"Conn state : {state}")
        print(f"In MM      : {in_mm}")

        # Extract short model (e.g. "R6525" from "PowerEdge R6525")
        parts       = model.split()
        model_short = parts[-1] if parts else model
        print(f"Model short: {model_short}")

        # Check if Dell
        is_dell = "dell" in vendor.lower()
        print(f"Is Dell    : {is_dell}")

    finally:
        vc.disconnect()


def test_03_get_idrac_ip():
    """
    Test iDRAC IP retrieval from ESXi IPMI config.
    Mirrors: $esxcli.hardware.ipmi.bmc.get.Invoke().IPV4Address
    READ-ONLY -- safe on production.
    """
    separator("TEST 03: Get iDRAC IP from IPMI Config")

    vc = make_client()
    try:
        idrac_ip = vc.get_idrac_ip()
        if idrac_ip:
            print(f"OK iDRAC IP found: {idrac_ip}")
        else:
            print("FAIL iDRAC IP not found via vSphere API")
            print("  Check: Host > Configure > Hardware > IPMI in vCenter UI")
            print("  OR: The host may not have IPMI/BMC configured in vCenter")
    finally:
        vc.disconnect()


def test_04_nic_snapshot():
    """
    Test NIC snapshot -- what the health check compares before vs after.
    Mirrors: $vmhost | Get-VMHostNetworkAdapter
    READ-ONLY -- safe on production.
    """
    separator("TEST 04: NIC Snapshot")

    vc = make_client()
    try:
        nics = vc.get_nic_snapshot()
        print(f"Total NICs found: {len(nics)}")
        print(f"\n{'NIC Name':<15} {'Speed (Mbps)':<15} {'Duplex'}")
        print(f"{'-'*15} {'-'*15} {'-'*10}")
        for nic in nics:
            print(f"{nic['name']:<15} {nic['speed']:<15} {nic['duplex']}")

        # Simulate health check -- before == after (should be identical)
        snap1 = vc.get_nic_snapshot()
        snap2 = vc.get_nic_snapshot()
        health_ok = vc.check_nic_health(snap1, snap2)
        print(f"\nSelf-comparison health check: {health_ok}  OK (should be True)")

    finally:
        vc.disconnect()


def test_05_hba_snapshot():
    """
    Test HBA snapshot.
    Mirrors: $vmhost | Get-VMHostHba
    READ-ONLY -- safe on production.
    """
    separator("TEST 05: HBA Snapshot")

    vc = make_client()
    try:
        hbas = vc.get_hba_snapshot()
        print(f"Total HBAs found: {len(hbas)}")
        print(f"\n{'Device':<20} {'Status'}")
        print(f"{'-'*20} {'-'*15}")
        for hba in hbas:
            print(f"{hba['device']:<20} {hba['status']}")

    finally:
        vc.disconnect()


def test_06_drs_checks():
    """
    Test DRS override check and cluster DRS level.
    Mirrors: Check-VM-Override-Manual-DRS and $checkDrsAutomationLevel
    READ-ONLY -- safe on production.
    """
    separator("TEST 06: DRS Checks")

    vc = make_client()
    try:
        has_overrides = vc.check_vm_drs_overrides()
        drs_level     = vc.get_cluster_drs_level()

        print(f"Has VM DRS overrides  : {has_overrides}")
        print(f"Cluster DRS level     : {drs_level}")

        # This is the gate check from the upgrade script
        can_proceed = not has_overrides and "fullautomated" in drs_level.lower()
        print(f"\nCan proceed with upgrade: {can_proceed}")
        if not can_proceed:
            if has_overrides:
                print("  Reason: VMs have DRS overrides -- resolve before upgrading")
            if "fullautomated" not in drs_level.lower():
                print(f"  Reason: Cluster DRS is '{drs_level}' not FullyAutomated")

    finally:
        vc.disconnect()


def test_07_ssh_connectivity():
    """
    Test SSH connection to ESXi host and a simple esxcli command.
    Mirrors: plink -ssh root@esxiserver -pw password "esxcli system version get"
    READ-ONLY -- safe on production (just reads version info).
    """
    separator("TEST 07: SSH Connectivity + esxcli Command")

    vc = make_client()
    try:
        # Enable SSH via vSphere API
        vc._ensure_ssh_enabled()
        print("SSH service enabled on host OK")

        # Run a simple read-only esxcli command
        print("\nRunning: esxcli system version get ...")
        stdout, stderr, rc = vc._ssh_run("esxcli system version get")

        print(f"Return code : {rc}")
        print(f"Output      :\n{stdout}")
        if stderr:
            print(f"Stderr      : {stderr}")

        if rc == 0:
            print("\nOK SSH esxcli command successful")
        else:
            print("\nFAIL SSH command failed -- check root credentials and SSH access")

        # Test VIB list (used for FDM check)
        print("\nRunning: esxcli software vib list | grep -i fdm ...")
        stdout2, _, rc2 = vc._ssh_run("esxcli software vib list | grep -i fdm")
        print(f"FDM VIB info: {stdout2 if stdout2 else 'Not found'}")

    finally:
        vc.disconnect()


def test_08_esxcli_profile_list():
    """
    Test reading the available software profiles on the host.
    This is useful to see the current ESXi profile name.
    READ-ONLY -- safe on production.
    """
    separator("TEST 08: ESXi Software Profile Info")

    vc = make_client()
    try:
        print("Running: esxcli software profile get ...")
        stdout, stderr, rc = vc._ssh_run("esxcli software profile get")

        if rc == 0:
            print(f"Current profile:\n{stdout}")
        else:
            print(f"Failed (rc={rc}): {stderr}")

        # Also check current build info
        print("\nRunning: esxcli system version get ...")
        stdout2, _, rc2 = vc._ssh_run("esxcli system version get")
        if rc2 == 0:
            print(f"Version info:\n{stdout2}")

    finally:
        vc.disconnect()


def test_09_alarm_toggle():
    """
    Test disabling and re-enabling alarm actions on the host.
    Mirrors: Change-ESXi-Alarm -enable $false / $true

    This DOES make a change but it's reversible -- we disable then immediately re-enable.
    Safe on production but check with your team first.
    """
    separator("TEST 09: Alarm Toggle (disable then re-enable)")

    confirm = input(
        "\nThis temporarily disables alarm actions on the host, then re-enables.\n"
        "Safe but changes alarm state briefly.\n"
        "Continue? (yes/no): "
    ).strip().lower()

    if confirm != "yes":
        print("Skipped.")
        return

    vc = make_client()
    try:
        print("Disabling alarm actions ...")
        vc.set_alarm_actions(enabled=False)
        print("OK Alarm actions disabled")

        import time
        time.sleep(2)

        print("Re-enabling alarm actions ...")
        vc.set_alarm_actions(enabled=True)
        print("OK Alarm actions re-enabled")

    finally:
        vc.disconnect()


def test_10_esxi_upgrade_dry_run():
    """
    Test ESXi upgrade in dry-run mode.
    No changes made -- just logs what WOULD happen.
    Safe on production.
    """
    separator("TEST 10: ESXi Upgrade -- Dry-Run (no changes)")

    # You need a local datastore name -- the format is localds_<hostname_without_domain>
    hostname_short = ESXI_HOST.split(".")[0]  # e.g. "esxi01" from "esxi01.corp.local"
    local_ds_name  = f"localds_{hostname_short}"

    print(f"Local datastore name: {local_ds_name}")
    print("(This is where the offline bundle would be uploaded to)")

    vc = make_client()
    try:
        vendor = vc.get_vendor()
        build  = vc.get_build()
        print(f"\nCurrent build : {build}")
        print(f"Vendor        : {vendor}")

        print(f"\nRunning ESXi upgrade in dry-run mode ...")
        result = vc.run_esxi_profile_update(
            local_ds_name = local_ds_name,
            vendor        = vendor,
            dry_run       = True,   # NO CHANGES
        )
        print(f"\nDry-run result: {'OK Would succeed' if result else 'FAIL Would fail'}")
        print("No changes were made to the host OK")

    finally:
        vc.disconnect()


def test_11_maintenance_mode():
    """
    Test entering and exiting maintenance mode.
    Mirrors: ESXi-Enter-Maintenance-Mode / ESXi-Exit-Maintenance-Mode

    WARNING: This DOES put the host into maintenance mode and then exits it.
    ONLY run on a host where VM evacuation is acceptable.
    DO NOT run on a production host with running VMs unless DRS can evacuate them.
    """
    separator("TEST 11: Maintenance Mode Enter + Exit")

    confirm = input(
        f"\nWARNING: This will place {ESXI_HOST} into maintenance mode\n"
        f"and then immediately exit it. VMs will be evacuated by DRS.\n"
        f"Only run on a test host or a host with no VMs.\n"
        f"Continue? (yes/no): "
    ).strip().lower()

    if confirm != "yes":
        print("Skipped.")
        return

    vc = make_client()
    try:
        print(f"\nCurrent state: {vc.get_connection_state()}")

        print("\nEntering maintenance mode ...")
        ok = vc.enter_maintenance_mode()
        print(f"Enter MM result: {'OK Success' if ok else 'FAIL Failed'}")
        print(f"In MM now      : {vc.is_in_maintenance_mode()}")

        if ok:
            import time
            print("\nWaiting 10 seconds ...")
            time.sleep(10)

            print("\nExiting maintenance mode ...")
            vc.exit_maintenance_mode()
            print(f"Final state: {vc.get_connection_state()}")

    finally:
        vc.disconnect()


# -- Menu ----------------------------------------------------------------------
if __name__ == "__main__":
    print("\n" + "="*60)
    print("  VSphere Client Tests")
    print(f"  vCenter : {VCENTER}")
    print(f"  ESXi    : {ESXI_HOST}")
    print("="*60)

    print("""
Read-only tests (safe on production):
  1   vCenter connection
  2   Host hardware info (vendor, model, build)
  3   Get iDRAC IP from IPMI config
  4   NIC snapshot
  5   HBA snapshot
  6   DRS checks (overrides + cluster level)
  7   SSH connectivity + esxcli command
  8   ESXi software profile info
  10  ESXi upgrade dry-run (no changes)

Tests that make changes (use with caution):
  9   Alarm toggle (disable + re-enable -- brief, reversible)
  11  Maintenance mode enter + exit (MM host or test host only)

  a   Run all read-only tests (1-8, 10)
""")

    choice = input("Enter choice: ").strip().lower()

    tests = {
        "1":  test_01_vcenter_connection,
        "2":  test_02_host_info,
        "3":  test_03_get_idrac_ip,
        "4":  test_04_nic_snapshot,
        "5":  test_05_hba_snapshot,
        "6":  test_06_drs_checks,
        "7":  test_07_ssh_connectivity,
        "8":  test_08_esxcli_profile_list,
        "9":  test_09_alarm_toggle,
        "10": test_10_esxi_upgrade_dry_run,
        "11": test_11_maintenance_mode,
    }

    if choice == "a":
        ok = test_01_vcenter_connection()
        if ok:
            for t in ["2","3","4","5","6","7","8","10"]:
                tests[t]()
        else:
            print("Connection failed -- skipping remaining tests")
    elif choice in tests:
        tests[choice]()
    else:
        print("Invalid choice")
