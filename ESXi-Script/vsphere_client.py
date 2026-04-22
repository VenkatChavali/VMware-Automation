"""
vsphere_client.py
vSphere + ESXi interaction layer.

Two distinct APIs are used here:

  pyVmomi  → vCenter-level operations
             (maintenance mode, alarm actions, reboot, NIC/HBA snapshots,
              host connection state, license assignment)

  SSH      → ESXi host-level esxcli commands
             (software profile update, vib list/remove/install)

SSH BACKEND — auto-detected in this order:
  1. Paramiko   (pip install paramiko) — preferred, pure Python, no binary needed
  2. system ssh (ssh.exe / ssh)        — built into Windows 10+, Linux, macOS
  3. plink.exe                         — PuTTY's CLI tool, already used in the PS script

Set SSH_BACKEND and SSH_BINARY in this file to force a specific backend.
If Paramiko is not installed the script automatically tries the system SSH binary.

WHY NOT pyVmomi FOR ESXCLI?
  pyVmomi's EsxCLI support is unreliable for complex commands like software
  profile update. SSH is what Ansible VMware modules and Dell's own tooling use.
"""

import shutil
import socket
import ssl
import subprocess
import time
from typing import Any

# Paramiko is optional — used if installed, otherwise falls back to
# the system SSH binary (ssh on Linux/Mac, plink.exe or ssh.exe on Windows).
# This means the script works even in environments where pip installs are blocked.
try:
    import paramiko
    _PARAMIKO_AVAILABLE = True
except ImportError:
    _PARAMIKO_AVAILABLE = False

from pyVim.connect import SmartConnect, Disconnect
from pyVmomi import vim

from logger import HostLogger

# ── Polling constants ──────────────────────────────────────────────────────
_MM_ENTER_TIMEOUT   = 3600      # 1h max to enter maintenance mode
_MM_ENTER_WARN_MIN  = 45        # warn after this many minutes
_REBOOT_OFFLINE_MAX = 15 * 60   # 15 min max to go offline
_REBOOT_ONLINE_MAX  = 15 * 60   # 15 min max to come back
_MM_POST_REBOOT_MAX = 15 * 60   # 15 min to re-enter MM after reboot
_POLL_SLEEP         = 60
_TASK_POLL_SLEEP    = 15

# ── SSH backend config ─────────────────────────────────────────────────────
# SSH_BACKEND options:
#   "auto"    → try Paramiko first, fall back to system binary (default)
#   "paramiko"→ force Paramiko (fails clearly if not installed)
#   "binary"  → force system SSH binary (use when pip is blocked)
SSH_BACKEND = "auto"

# SSH_BINARY: path to SSH binary used when backend is "binary" or Paramiko
# is not available. Leave as None to auto-detect from PATH.
#   Linux/Mac : "ssh"          (built-in)
#   Windows   : "ssh"          (built into Windows 10+ OpenSSH)
#               or full path to plink.exe e.g. r"C:\Scripts\plink.exe"
SSH_BINARY: str | None = None
_SSH_PORT           = 22
_SSH_TIMEOUT        = 30
_SSH_CMD_TIMEOUT    = 300       # esxcli software profile update can be slow
_SSH_CONNECT_RETRY  = 3
_SSH_RETRY_SLEEP    = 30

# ── ESXi upgrade bundles ───────────────────────────────────────────────────
# This is the ONLY place you need to change when upgrading to a new ESXi version.
#
# TARGET_ESXi_BUILD : the build number to check against. If the host already
#                     has this build, the upgrade is skipped.
#
# ESXI_BUNDLES      : maps vendor → zip filename + profile name.
#                     The zip must exist in the local datastore under
#                     ESXi-Upgrade-OfflineBinaries/<zip_filename>
#
# HOW TO CHANGE TO A NEW VERSION:
#   1. Update TARGET_ESXi_BUILD to the new build number
#   2. Update the zip and profile strings for each vendor
#   3. Drop the new zip files into your firmware repo's
#      Offline-Upgrade-Binaries/ folder
#   That's it — nothing else in the codebase needs changing.
#
# EXAMPLE — upgrading from 8.0 U3 (24022510) to a hypothetical 8.0 U4:
#   TARGET_ESXi_BUILD = "25000000"          ← new build number
#   ESXI_BUNDLES = {
#       "Dell": {
#           "zip":     "VMware-VMvisor-Installer-8.0.0.update04-25000000.x86_64-Dell_Customized-A00.zip",
#           "profile": "DEL-ESXi_804.25000000-A00",
#       },
#       ...
#   }

TARGET_ESXi_BUILD = "24022510"   # ESXi 8.0 Update 3

ESXI_BUNDLES: dict[str, dict[str, str]] = {
    "Dell": {
        "zip":     "VMware-VMvisor-Installer-8.0.0.update03-24022510.x86_64-Dell_Customized-A00.zip",
        "profile": "DEL-ESXi_803.24022510-A00",
    },
    "Lenovo": {
        "zip":     "Lenovo-VMware-ESXi-8.0.3-24022510-LNV-S01-20240620.zip",
        "profile": "LVO_8.0.3-LVO.803.12.1",
    },
    "HP": {
        "zip":     "VMware-ESXi-8.0.3-24022510-HPE-803.0.0.11.7.0.23-Jun2024-depot.zip",
        "profile": "HPE-Custom-AddOn_803.0.0.11.7.0-23",
    },
}

# ── FDM target version ─────────────────────────────────────────────────────
# Update this alongside TARGET_ESXi_BUILD when moving to a new ESXi version.
TARGET_FDM_VERSION = "8.0.3-24022515"


class VSphereClient:
    """
    Handles all vCenter-level operations via pyVmomi + all ESXi host-level
    esxcli operations via SSH.

    One instance per host per upgrade run.
    Call disconnect() when done, or use as a context manager.
    """

    def __init__(
        self,
        vcenter: str,
        username: str,
        password: str,
        esxi_host: str,
        esxi_root_user: str,
        esxi_root_pass: str,
        logger: HostLogger,
    ) -> None:
        self.vcenter        = vcenter
        self.esxi_host      = esxi_host
        self._esxi_user     = esxi_root_user
        self._esxi_pass     = esxi_root_pass
        self._logger        = logger
        self._si: Any       = None
        self._host_obj: Any = None

        self._connect_vcenter(vcenter, username, password)

    # ─────────────────────────────────────────────────────────
    # vCenter connection
    # ─────────────────────────────────────────────────────────

    def _connect_vcenter(self, vcenter: str, username: str, password: str) -> None:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode    = ssl.CERT_NONE   # mirrors -InvalidCertificateAction Ignore
        self._logger.info(f"Connecting to vCenter {vcenter} ...")
        self._si = SmartConnect(
            host=vcenter, user=username, pwd=password, sslContext=ctx
        )
        self._logger.info("Connected to vCenter ✓")
        self._host_obj = self._find_host(self.esxi_host)

    def disconnect(self) -> None:
        if self._si:
            try:
                Disconnect(self._si)
            except Exception:
                pass

    def _find_host(self, hostname: str) -> Any:
        content   = self._si.RetrieveContent()
        container = content.viewManager.CreateContainerView(
            content.rootFolder, [vim.HostSystem], True
        )
        for host in container.view:
            if host.name.lower() == hostname.lower():
                container.Destroy()
                return host
        container.Destroy()
        raise RuntimeError(f"Host {hostname} not found in vCenter {self.vcenter}")

    # ─────────────────────────────────────────────────────────
    # Host info (via pyVmomi — no SSH needed)
    # ─────────────────────────────────────────────────────────

    def get_connection_state(self) -> str:
        return str(self._host_obj.runtime.connectionState)

    def is_in_maintenance_mode(self) -> bool:
        return self._host_obj.runtime.inMaintenanceMode

    def get_vendor(self) -> str:
        return self._host_obj.hardware.systemInfo.vendor

    def get_model(self) -> str:
        return self._host_obj.hardware.systemInfo.model

    def get_build(self) -> str:
        return self._host_obj.config.product.build

    def get_version(self) -> str:
        return self._host_obj.config.product.version

    def get_idrac_ip(self) -> str | None:
        """
        Get iDRAC IP from the host's IPMI/BMC config via vSphere API.
        Mirrors: $esxcli.hardware.ipmi.bmc.get.Invoke().IPV4Address
        Using pyVmomi here because it doesn't require SSH to be enabled.
        """
        try:
            bmc = self._host_obj.config.ipmi
            if bmc and bmc.bmcIpAddress:
                return bmc.bmcIpAddress
        except Exception as exc:
            self._logger.warning(f"Could not get iDRAC IP from vSphere API: {exc}")
        return None

    def get_nic_snapshot(self) -> list[dict]:
        """Mirrors: $vmhost | Get-VMHostNetworkAdapter"""
        nics = []
        for pnic in self._host_obj.config.network.pnic:
            speed  = pnic.linkSpeed.speedMb if pnic.linkSpeed else 0
            duplex = pnic.linkSpeed.duplex  if pnic.linkSpeed else False
            nics.append({"name": pnic.device, "speed": speed, "duplex": duplex})
        return nics

    def get_hba_snapshot(self) -> list[dict]:
        """Mirrors: $vmhost | Get-VMHostHba"""
        hbas = []
        for hba in self._host_obj.config.storageDevice.hostBusAdapter:
            hbas.append({"device": hba.device, "status": str(hba.status)})
        return hbas

    # ─────────────────────────────────────────────────────────
    # Pre-flight checks (via pyVmomi)
    # ─────────────────────────────────────────────────────────

    def check_vm_drs_overrides(self) -> bool:
        """
        Mirrors: Check-VM-Override-Manual-DRS
        Returns True if ANY VM on this host has DRS level Manual or Disabled.
        """
        cluster = self._host_obj.parent
        if not hasattr(cluster, "configuration"):
            return False
        vm_configs = {
            ov.key: ov.behavior
            for ov in (cluster.configuration.drsConfig.vmConfig or [])
        }
        for vm in self._host_obj.vm:
            behavior = vm_configs.get(vm._moId, "")
            if str(behavior).lower() in ("manual", "disabled"):
                self._logger.warning(
                    f"VM {vm.name} has DRS override: {behavior}"
                )
                return True
        return False

    def get_cluster_drs_level(self) -> str:
        cluster = self._host_obj.parent
        if hasattr(cluster, "configuration"):
            return str(cluster.configuration.drsConfig.defaultVmBehavior)
        return "unknown"

    # ─────────────────────────────────────────────────────────
    # Alarm management (via pyVmomi)
    # ─────────────────────────────────────────────────────────

    def set_alarm_actions(self, enabled: bool) -> None:
        """Mirrors: Change-ESXi-Alarm -enable $true/$false"""
        content   = self._si.RetrieveContent()
        alarm_mgr = content.alarmManager
        alarm_mgr.EnableAlarmActions(self._host_obj, enabled)
        self._logger.info(f"Alarm actions {'enabled' if enabled else 'disabled'}")

    # ─────────────────────────────────────────────────────────
    # Maintenance mode (via pyVmomi)
    # ─────────────────────────────────────────────────────────

    def enter_maintenance_mode(self, timeout_s: int = _MM_ENTER_TIMEOUT) -> bool:
        """Mirrors: ESXi-Enter-Maintenance-Mode"""
        self._logger.section("Entering Maintenance Mode")

        if self.is_in_maintenance_mode():
            self._logger.info("Host is already in Maintenance Mode")
            return True

        deadline = time.time() + timeout_s

        # Wait until host is at least Connected before issuing MM task
        while not self._is_connected_or_mm():
            if time.time() > deadline:
                self._logger.error("Host did not reach Connected state within timeout")
                return False
            self._logger.info(f"Connection state: {self.get_connection_state()} — waiting ...")
            time.sleep(_POLL_SLEEP)

        if self.is_in_maintenance_mode():
            return True

        self._logger.info("Issuing EnterMaintenanceMode task ...")
        try:
            task = self._host_obj.EnterMaintenanceMode_Task(
                timeout=0, evacuatePoweredOffVms=True
            )
        except Exception as exc:
            self._logger.warning(f"EnterMaintenanceMode_Task raised: {exc}")
            task = None

        if task:
            self._wait_for_task(task, label="EnterMaintenanceMode")

        # Poll until actually in MM
        start = time.time()
        while not self.is_in_maintenance_mode():
            elapsed_min = (time.time() - start) / 60
            if time.time() > deadline:
                self._logger.error("Timed out waiting for Maintenance Mode")
                return False
            if elapsed_min > _MM_ENTER_WARN_MIN:
                self._logger.warning(
                    f"Still not in Maintenance Mode after {elapsed_min:.1f} min — "
                    f"please check manually"
                )
            self._logger.info(
                f"Waiting for Maintenance Mode ... ({elapsed_min:.1f} min elapsed)"
            )
            time.sleep(_POLL_SLEEP)

        self._logger.info("Host is in Maintenance Mode ✓")
        return True

    def exit_maintenance_mode(self) -> bool:
        """Mirrors: ESXi-Exit-Maintenance-Mode"""
        self._logger.section("Exiting Maintenance Mode")
        task = self._host_obj.ExitMaintenanceMode_Task(timeout=0)
        return self._wait_for_task(task, label="ExitMaintenanceMode")

    # ─────────────────────────────────────────────────────────
    # Host reboot + wait (pyVmomi reboot, socket polling)
    # ─────────────────────────────────────────────────────────

    def reboot_and_wait(self) -> bool:
        """
        Mirrors the PS three-phase reboot pattern:
          1. Restart-VMHost
          2. Wait until OFFLINE  (port 443 stops responding)
          3. Wait until ONLINE   (port 443 responds again)
          4. Wait until back in Maintenance Mode
        """
        self._logger.info(f"Rebooting {self.esxi_host} ...")
        try:
            self._host_obj.Reboot(force=True)
        except Exception as exc:
            self._logger.warning(f"Reboot call returned: {exc} — continuing anyway")

        self._logger.info("Phase 1: Waiting for host to go offline ...")
        if not self._wait_for_offline():
            self._logger.error("Host did not go offline within timeout")
            return False

        self._logger.info("Phase 2: Waiting for host to come back online ...")
        if not self._wait_for_online():
            self._logger.error("Host did not come back online within timeout")
            return False

        self._logger.info("Phase 3: Waiting for host to re-enter Maintenance Mode ...")
        deadline = time.time() + _MM_POST_REBOOT_MAX
        while not self.is_in_maintenance_mode():
            if time.time() > deadline:
                self._logger.warning(
                    "Host did not re-enter Maintenance Mode within 15 min post reboot"
                )
                return False
            time.sleep(_POLL_SLEEP)

        self._logger.info("Host is back online and in Maintenance Mode ✓")
        return True

    # ─────────────────────────────────────────────────────────
    # ESXi profile update via SSH esxcli
    # ─────────────────────────────────────────────────────────

    def run_esxi_profile_update(
        self,
        local_ds_name: str,
        vendor: str,
        dry_run: bool = False,
    ) -> bool:
        """
        Mirrors: $esxcli.software.profile.update.invoke($argsInstall)

        Runs via SSH because pyVmomi's EsxCLI support is unreliable for
        software profile update — this is the same approach used by Ansible's
        VMware modules and Dell's own automation tooling.

        Steps:
          1. Check current build — skip if already at target
          2. Select OEM bundle based on vendor
          3. SSH in and run: esxcli software profile update -d <depot> -p <profile>
          4. Reboot and wait
          5. Validate build number post-reboot
        """
        self._logger.section("ESXi Offline Profile Update")

        build   = self.get_build()
        version = self.get_version()
        self._logger.info(f"Current ESXi version: {version}  Build: {build}")

        # Already at target — skip
        if TARGET_ESXi_BUILD in build:
            self._logger.info(
                f"ESXi already at target build {TARGET_ESXi_BUILD} — skipping"
            )
            return True

        # Select OEM bundle by vendor prefix match
        vendor_key = next(
            (k for k in ESXI_BUNDLES if vendor.lower().startswith(k.lower())),
            None
        )
        if not vendor_key:
            self._logger.error(
                f"No offline bundle configured for vendor '{vendor}'. "
                f"Add it to ESXI_BUNDLES in vsphere_client.py"
            )
            return False

        bundle  = ESXI_BUNDLES[vendor_key]
        depot   = (
            f"/vmfs/volumes/{local_ds_name}"
            f"/ESXi-Upgrade-OfflineBinaries/{bundle['zip']}"
        )
        profile = bundle["profile"]

        self._logger.info(f"Bundle : {bundle['zip']}")
        self._logger.info(f"Profile: {profile}")
        self._logger.info(f"Depot  : {depot}")

        if dry_run:
            self._logger.info(
                f"[DRY-RUN] Would run: "
                f"esxcli software profile update -d {depot} -p {profile} --force"
            )
            return True

        # Run esxcli via SSH
        cmd = (
            f"esxcli software profile update "
            f"-d {depot} "
            f"-p {profile} "
            f"--force "
            f"--no-hardware-warning"
        )
        self._logger.info(f"Running esxcli command via SSH ...")
        stdout, stderr, rc = self._ssh_run(cmd, timeout=_SSH_CMD_TIMEOUT)

        if stdout:
            self._logger.info(f"esxcli stdout: {stdout[:500]}")
        if stderr:
            self._logger.warning(f"esxcli stderr: {stderr[:500]}")

        if rc != 0 and "reboot" not in stdout.lower():
            self._logger.error(
                f"esxcli software profile update failed (rc={rc})"
            )
            return False

        self._logger.info("Profile update command completed — rebooting host ...")
        if not self.reboot_and_wait():
            return False

        # Validate build post-reboot
        new_build = self.get_build()
        self._logger.info(f"Post-upgrade build: {new_build}")
        if TARGET_ESXi_BUILD in new_build:
            self._logger.info("ESXi upgrade successful ✓")
            return True
        else:
            self._logger.error(
                f"Post-upgrade build is {new_build}, expected {TARGET_ESXi_BUILD}. "
                f"Upgrade may have failed — validate manually."
            )
            return False

    # ─────────────────────────────────────────────────────────
    # FDM (HA agent) check + reinstall via SSH esxcli
    # ─────────────────────────────────────────────────────────

    def ensure_fdm_version(self, local_ds_name: str, dry_run: bool = False) -> bool:
        """
        Mirrors the FDM VIB check / remove / reinstall block in the PS script.
        Uses SSH esxcli because pyVmomi VIB operations are unreliable.
        """
        self._logger.info("Checking VMware HA agent (FDM) VIB version ...")

        # List VIBs and find FDM
        stdout, _, rc = self._ssh_run("esxcli software vib list | grep -i fdm")
        if rc != 0 or not stdout.strip():
            self._logger.warning("FDM VIB not found on host — skipping FDM check")
            return True   # not critical enough to fail the upgrade

        # Parse version from output — format: "vmware-fdm   8.0.3-24022515   ..."
        fdm_line    = stdout.strip().splitlines()[0]
        fdm_version = fdm_line.split()[1] if len(fdm_line.split()) > 1 else ""
        self._logger.info(f"FDM version installed: {fdm_version}")

        if fdm_version == TARGET_FDM_VERSION:
            self._logger.info("FDM version is correct ✓")
            return True

        self._logger.warning(
            f"FDM version {fdm_version} does not match target {TARGET_FDM_VERSION}"
        )

        if dry_run:
            self._logger.info(
                f"[DRY-RUN] Would reinstall FDM {TARGET_FDM_VERSION}"
            )
            return True

        # Remove old FDM
        self._logger.info("Removing old FDM VIB ...")
        _, _, rc = self._ssh_run("esxcli software vib remove -n vmware-fdm --force")
        if rc != 0:
            self._logger.warning("FDM remove returned non-zero — continuing anyway")

        time.sleep(60)

        # Install correct version from local datastore
        vib_path = (
            f"/vmfs/volumes/{local_ds_name}/ESXi-Upgrade-TempFiles/"
            f"VMware_bootbank_vmware-fdm_{TARGET_FDM_VERSION}.vib"
        )
        self._logger.info(f"Installing FDM VIB from: {vib_path}")
        _, _, rc = self._ssh_run(
            f"esxcli software vib install -v {vib_path} --force"
        )
        if rc != 0:
            self._logger.error(f"FDM install failed (rc={rc})")
            return False

        # Verify
        stdout, _, _ = self._ssh_run("esxcli software vib list | grep -i fdm")
        fdm_line     = stdout.strip().splitlines()[0] if stdout.strip() else ""
        new_version  = fdm_line.split()[1] if len(fdm_line.split()) > 1 else ""

        if new_version == TARGET_FDM_VERSION:
            self._logger.info(f"FDM reinstalled successfully → {new_version} ✓")
            return True
        else:
            self._logger.error(
                f"FDM version after reinstall is {new_version}, "
                f"expected {TARGET_FDM_VERSION}"
            )
            return False

    # ─────────────────────────────────────────────────────────
    # License assignment (via pyVmomi)
    # ─────────────────────────────────────────────────────────

    def assign_license(self, license_key: str) -> bool:
        """Mirrors: Set-VMHost -LicenseKey"""
        if not license_key or license_key.upper() == "NA":
            self._logger.warning(
                "No license key provided — skipping license assignment"
            )
            return False
        try:
            content = self._si.RetrieveContent()
            lm      = content.licenseManager
            lm.UpdateAssignedLicense(
                entity=self._host_obj._moId,
                licenseKey=license_key,
            )
            self._logger.info("License key assigned successfully ✓")
            return True
        except Exception as exc:
            self._logger.error(f"License assignment failed: {exc}")
            return False

    # ─────────────────────────────────────────────────────────
    # Health checks (via pyVmomi)
    # ─────────────────────────────────────────────────────────

    def check_nic_health(self, before: list[dict], after: list[dict]) -> bool:
        """
        Mirrors: Check-Network-Adapters
        Compares NIC count, speed, and duplex before vs after.
        """
        if len(before) != len(after):
            self._logger.warning(
                f"NIC count changed: {len(before)} before → {len(after)} after"
            )
            return False
        before_map = {n["name"]: n for n in before}
        for nic in after:
            pre = before_map.get(nic["name"])
            if not pre:
                self._logger.warning(f"NIC {nic['name']} missing from pre-upgrade snapshot")
                return False
            if pre["speed"] != nic["speed"] or pre["duplex"] != nic["duplex"]:
                self._logger.warning(
                    f"NIC {nic['name']} link changed: "
                    f"{pre['speed']}M/{pre['duplex']} → {nic['speed']}M/{nic['duplex']}"
                )
                return False
        return True

    def check_hba_health(self, before: list[dict], after: list[dict]) -> bool:
        """Mirrors: Check-HBA-Aapters"""
        if len(before) != len(after):
            self._logger.warning(
                f"HBA count changed: {len(before)} before → {len(after)} after"
            )
            return False
        before_map = {h["device"]: h for h in before}
        for hba in after:
            pre = before_map.get(hba["device"])
            if not pre:
                self._logger.warning(f"HBA {hba['device']} missing from pre-upgrade snapshot")
                return False
            if pre["status"] != hba["status"]:
                self._logger.warning(
                    f"HBA {hba['device']} status changed: "
                    f"{pre['status']} → {hba['status']}"
                )
                return False
        return True

    # ─────────────────────────────────────────────────────────
    # SSH helpers — auto-detecting backend
    # ─────────────────────────────────────────────────────────

    def _ssh_run(
        self,
        cmd: str,
        timeout: int = _SSH_CMD_TIMEOUT,
    ) -> tuple[str, str, int]:
        """
        SSH into the ESXi host, run a command, return (stdout, stderr, exit_code).

        Backend selection (controlled by SSH_BACKEND at top of file):
          "auto"    → Paramiko if installed, else system SSH binary
          "paramiko"→ Paramiko only (raises clearly if not installed)
          "binary"  → system SSH binary only (ssh or plink.exe)

        All backends:
          - Enable SSH service on host via vSphere API first
          - Retry connection up to _SSH_CONNECT_RETRY times
          - Auto-accept host key (mirrors "echo y | plink ... exit")
        """
        self._ensure_ssh_enabled()

        use_paramiko = (
            SSH_BACKEND == "paramiko"
            or (SSH_BACKEND == "auto" and _PARAMIKO_AVAILABLE)
        )

        if use_paramiko:
            if not _PARAMIKO_AVAILABLE:
                raise RuntimeError(
                    "SSH_BACKEND is set to 'paramiko' but Paramiko is not installed. "
                    "Run: pip install paramiko  OR  set SSH_BACKEND = 'binary'"
                )
            return self._ssh_run_paramiko(cmd, timeout)
        else:
            return self._ssh_run_binary(cmd, timeout)

    def _ssh_run_paramiko(
        self,
        cmd: str,
        timeout: int,
    ) -> tuple[str, str, int]:
        """
        Run SSH command via Paramiko.
        Preferred backend — pure Python, no external binary needed.
        """
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

        for attempt in range(1, _SSH_CONNECT_RETRY + 1):
            try:
                client.connect(
                    self.esxi_host,
                    port=_SSH_PORT,
                    username=self._esxi_user,
                    password=self._esxi_pass,
                    timeout=_SSH_TIMEOUT,
                    look_for_keys=False,
                    allow_agent=False,
                )
                break
            except Exception as exc:
                self._logger.warning(
                    f"Paramiko connect attempt {attempt}/{_SSH_CONNECT_RETRY} "
                    f"failed: {exc}"
                )
                if attempt == _SSH_CONNECT_RETRY:
                    return "", f"Paramiko connection failed: {exc}", 1
                time.sleep(_SSH_RETRY_SLEEP)

        try:
            _, stdout_f, stderr_f = client.exec_command(cmd, timeout=timeout)
            stdout = stdout_f.read().decode("utf-8", errors="replace").strip()
            stderr = stderr_f.read().decode("utf-8", errors="replace").strip()
            rc     = stdout_f.channel.recv_exit_status()
            self._logger.info(f"[Paramiko] cmd={cmd[:80]}  rc={rc}")
            return stdout, stderr, rc
        except Exception as exc:
            self._logger.warning(f"Paramiko exec error: {exc}")
            return "", str(exc), 1
        finally:
            client.close()

    def _ssh_run_binary(
        self,
        cmd: str,
        timeout: int,
    ) -> tuple[str, str, int]:
        """
        Run SSH command via system binary (ssh or plink.exe).
        Fallback when Paramiko is not installed.

        Supports:
          - OpenSSH  (ssh)    — built into Windows 10+, Linux, macOS
          - PuTTY    (plink)  — already present if you used the PS script

        SSH_BINARY at top of file controls which binary to use.
        If SSH_BINARY is None, auto-detects from PATH.
        """
        binary = self._resolve_ssh_binary()
        if not binary:
            return (
                "",
                "No SSH binary found. Install Paramiko (pip install paramiko) "
                "or ensure 'ssh' or 'plink.exe' is in your PATH.",
                1,
            )

        is_plink = "plink" in binary.lower()

        for attempt in range(1, _SSH_CONNECT_RETRY + 1):
            try:
                if is_plink:
                    # plink syntax — mirrors original PS plink usage
                    # -batch disables interactive prompts
                    # -hostkey * accepts any host key (mirrors AutoAddPolicy)
                    full_cmd = [
                        binary,
                        "-ssh",
                        f"{self._esxi_user}@{self.esxi_host}",
                        "-pw", self._esxi_pass,
                        "-batch",
                        "-noagent",
                        "-hostkey", "*",
                        cmd,
                    ]
                else:
                    # OpenSSH syntax
                    # -o StrictHostKeyChecking=no mirrors AutoAddPolicy
                    # -o BatchMode=yes prevents password prompts
                    full_cmd = [
                        binary,
                        "-o", "StrictHostKeyChecking=no",
                        "-o", "BatchMode=no",
                        "-o", f"ConnectTimeout={_SSH_TIMEOUT}",
                        "-p", str(_SSH_PORT),
                        f"{self._esxi_user}@{self.esxi_host}",
                        cmd,
                    ]

                proc = subprocess.run(
                    full_cmd,
                    capture_output=True,
                    text=True,
                    timeout=timeout,
                    # Pass password via env for OpenSSH (sshpass style)
                    # For plink it's already in -pw flag above
                    env={**__import__("os").environ, "SSH_ASKPASS": ""},
                )
                stdout = proc.stdout.strip()
                stderr = proc.stderr.strip()
                rc     = proc.returncode
                self._logger.info(
                    f"[{binary}] cmd={cmd[:80]}  rc={rc}"
                )
                return stdout, stderr, rc

            except subprocess.TimeoutExpired:
                self._logger.warning(
                    f"SSH binary command timed out after {timeout}s "
                    f"(attempt {attempt}/{_SSH_CONNECT_RETRY})"
                )
                if attempt == _SSH_CONNECT_RETRY:
                    return "", "SSH command timed out", 1

            except Exception as exc:
                self._logger.warning(
                    f"SSH binary attempt {attempt}/{_SSH_CONNECT_RETRY} "
                    f"failed: {exc}"
                )
                if attempt == _SSH_CONNECT_RETRY:
                    return "", str(exc), 1
                time.sleep(_SSH_RETRY_SLEEP)

        return "", "SSH binary failed after all retries", 1

    def _resolve_ssh_binary(self) -> str | None:
        """
        Find the SSH binary to use. Priority:
          1. SSH_BINARY config constant (explicit path)
          2. 'ssh'      in PATH  (OpenSSH — Windows 10+, Linux, macOS)
          3. 'plink'    in PATH  (PuTTY)
          4. 'plink.exe' in current directory (mirrors PS script's plink location)
        """
        import os

        # Explicit config wins
        if SSH_BINARY:
            if os.path.isfile(SSH_BINARY):
                self._logger.info(f"Using configured SSH binary: {SSH_BINARY}")
                return SSH_BINARY
            else:
                self._logger.warning(
                    f"Configured SSH_BINARY not found: {SSH_BINARY}"
                )

        # Auto-detect from PATH
        for candidate in ("ssh", "plink", "plink.exe"):
            found = shutil.which(candidate)
            if found:
                self._logger.info(f"Using SSH binary from PATH: {found}")
                return found

        # Last resort: plink.exe in current working directory
        # (mirrors PS script behaviour — plink lived in the script folder)
        local_plink = os.path.join(os.getcwd(), "plink.exe")
        if os.path.isfile(local_plink):
            self._logger.info(f"Using plink.exe from current directory: {local_plink}")
            return local_plink

        self._logger.error(
            "No SSH binary found. Options:\n"
            "  1. pip install paramiko           (recommended)\n"
            "  2. Install OpenSSH                (built into Windows 10+)\n"
            "  3. Set SSH_BINARY = r'C:\\path\\to\\plink.exe' in vsphere_client.py\n"
            "  4. Place plink.exe in the script's working directory"
        )
        return None

    def _ensure_ssh_enabled(self) -> None:
        """
        Enable SSH service on the host via vSphere API if not already running.
        Mirrors: Get-VMHostService | Where-Object{$_.Label -eq "SSH"} | Start-VMHostService
        """
        try:
            svc_system = self._host_obj.configManager.serviceSystem
            for svc in svc_system.serviceInfo.service:
                if svc.key == "TSM-SSH":
                    if not svc.running:
                        self._logger.info("Enabling SSH service on host ...")
                        svc_system.StartService(id="TSM-SSH")
                    return
        except Exception as exc:
            self._logger.warning(f"Could not check/enable SSH service: {exc}")

    # ─────────────────────────────────────────────────────────
    # Internal pyVmomi helpers
    # ─────────────────────────────────────────────────────────

    def _is_connected_or_mm(self) -> bool:
        state = self.get_connection_state()
        return state in ("connected", "maintenance")

    def _wait_for_task(self, task: Any, label: str = "task") -> bool:
        """Poll a vSphere task until it reaches a terminal state."""
        while task.info.state == vim.TaskInfo.State.running:
            time.sleep(_TASK_POLL_SLEEP)
        if task.info.state == vim.TaskInfo.State.success:
            self._logger.info(f"{label} completed ✓")
            return True
        else:
            err = task.info.error.msg if task.info.error else "unknown error"
            self._logger.error(f"{label} failed: {err}")
            return False

    def _wait_for_offline(self, max_wait: int = _REBOOT_OFFLINE_MAX) -> bool:
        """Poll until port 443 stops responding — host is going down."""
        deadline = time.time() + max_wait
        while time.time() < deadline:
            try:
                s = socket.create_connection((self.esxi_host, 443), timeout=5)
                s.close()
                self._logger.info("Host still reachable — waiting ...")
                time.sleep(_POLL_SLEEP)
            except (socket.timeout, ConnectionRefusedError, OSError):
                self._logger.info("Host is offline ✓")
                return True
        return False

    def _wait_for_online(self, max_wait: int = _REBOOT_ONLINE_MAX) -> bool:
        """Poll until port 443 responds again — host is back up."""
        deadline = time.time() + max_wait
        while time.time() < deadline:
            try:
                s = socket.create_connection((self.esxi_host, 443), timeout=5)
                s.close()
                self._logger.info("Host is back online ✓")
                return True
            except (socket.timeout, ConnectionRefusedError, OSError):
                self._logger.info("Host still offline — waiting ...")
                time.sleep(_POLL_SLEEP)
        return False
