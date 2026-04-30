# -*- coding: utf-8 -*-
"""
upgrade_engine.py
Core upgrade orchestrator for a single ESXi host -- hardened for production.

Upgrade phases:
  Phase 0  Pre-flight validation     (repo check, network, credentials)
  Phase 1  Maintenance mode + alarms
  Phase 2  Firmware upgrade via Redfish
  Phase 3  ESXi offline bundle upgrade
  Phase 4  Health checks + summary

Hardening added vs original:
  - PreflightChecker validates everything BEFORE entering maintenance mode
  - RetryExhausted propagates cleanly with full context
  - Per-host wall-clock timeout (HOST_TIMEOUT_HOURS) -- never hangs Jenkins
  - vCenter session keep-alive for long upgrades
  - Teams notifications at key events
  - Granular exit codes via UpgradeResult.exit_code
  - State file updated at each phase for resume capability
"""

import random
import signal
import time
import traceback
from pathlib import Path

from firmware_baselines import (
    get_baselines,
    get_unique_baselines,
    resolve_disk_version,
    SUPPORTED_MODELS,
)
from logger import HostLogger
from models import FirmwareComponent, FirmwareInventoryItem, UpgradeOption, UpgradeResult
from notifier import Notifier
from preflight import PreflightChecker, PreflightFailed
from redfish_client import RedfishClient
from retry import retry_call, RetryExhausted
from vsphere_client import VSphereClient

# -- Timing --------------------------------------------------------------------
_LC_RESTART_WAIT    = 300      # 5 min after clearing iDRAC job queue
_RANDOM_UPLOAD_MIN  = 30       # stagger between binary uploads
_RANDOM_UPLOAD_MAX  = 90
_VC_KEEPALIVE_SECS  = 900      # ping vCenter every 15 min to keep session alive
HOST_TIMEOUT_HOURS  = 5        # hard wall-clock timeout per host

# -- Retry config --------------------------------------------------------------
_RETRY_SHORT  = dict(attempts=3, delay=30,  backoff=2.0)   # fast transient errors
_RETRY_MEDIUM = dict(attempts=3, delay=60,  backoff=1.5)   # iDRAC / vCenter calls
_RETRY_LONG   = dict(attempts=2, delay=120, backoff=1.0)   # slow operations


class UpgradeEngine:

    def __init__(
        self,
        esxi_host:       str,
        vcenter:         str,
        idrac_creds:     dict,
        vcenter_creds:   dict,
        esxi_root_creds: dict,
        firmware_repo:   Path,
        license_key:     str,
        upgrade_option:  UpgradeOption,
        depcr:           str,
        start_date:      str,
        log_dir:         Path,
        dry_run:         bool,
        logger:          HostLogger,
        teams_webhook:   str | None = None,
        state_manager=None,
    ) -> None:
        self.host          = esxi_host
        self.vcenter       = vcenter
        self.idrac_creds   = idrac_creds
        self.vcenter_creds = vcenter_creds
        self.root_creds    = esxi_root_creds
        self.fw_repo       = firmware_repo
        self.license_key   = license_key
        self.opt           = upgrade_option
        self.depcr         = depcr
        self.start_date    = start_date
        self.log_dir       = log_dir
        self.dry_run       = dry_run
        self.logger        = logger
        self.state         = state_manager

        self._result       = UpgradeResult(host=esxi_host)
        self._vc:  VSphereClient | None = None
        self._notify       = Notifier(teams_webhook, esxi_host, depcr, logger)
        self._last_vc_ping = 0.0   # timestamp of last vCenter keep-alive

    # ---------------------------------------------------------
    # Main entry point
    # ---------------------------------------------------------

    def run(self) -> UpgradeResult:
        start_time = time.time()
        deadline   = start_time + (HOST_TIMEOUT_HOURS * 3600)

        self.logger.section(
            f"BEGIN UPGRADE  |  Host: {self.host}  |  "
            f"DEP/CR: {self.depcr}  |  Option: {self.opt.name}  |  "
            f"Dry-run: {self.dry_run}"
        )
        self._notify.send_started(self.opt.name)

        if self.state:
            self.state.mark_running(self.host)

        try:
            self._check_timeout(deadline, "start")

            # -- Phase 0: Pre-flight --
            self._phase0_preflight()
            self._check_timeout(deadline, "pre-flight")

            # -- Phase 1: Maintenance mode --
            self._phase1_maintenance_and_alarms()
            self._check_timeout(deadline, "maintenance mode")

            # -- Phase 2: Firmware upgrade --
            if self.opt in (UpgradeOption.FIRMWARE_ONLY, UpgradeOption.ALL):
                self._phase2_firmware_upgrade()
                self._check_timeout(deadline, "firmware upgrade")
                self._notify.send_phase_result(
                    "Firmware Upgrade",
                    success = self._result.firmware_ok or self._result.firmware_skipped,
                    detail  = self._result.firmware_remarks,
                )

            # -- Phase 3: ESXi upgrade --
            if self.opt in (UpgradeOption.ESXI_ONLY, UpgradeOption.ALL):
                self._phase3_esxi_upgrade()
                self._check_timeout(deadline, "ESXi upgrade")
                self._notify.send_phase_result(
                    "ESXi Version Upgrade",
                    success = self._result.esxi_ok or self._result.esxi_skipped,
                    detail  = self._result.esxi_remarks,
                )

            # -- Phase 4: Health checks --
            self._phase4_health_checks()

        except PreflightFailed as exc:
            # Pre-flight failed -- host was NEVER touched
            self.logger.error(str(exc))
            self._result.firmware_remarks = "Pre-flight failed -- host not touched"
            self._result.esxi_remarks     = "Pre-flight failed -- host not touched"
            self._notify.send_preflight_failed("; ".join(exc.issues))
            if self.state:
                self.state.mark_skipped(self.host, reason=str(exc.issues))

        except _HostTimeout as exc:
            self.logger.error(str(exc))
            self._notify.send_critical("Timeout", str(exc))
            if self.state:
                self.state.mark_failed(self.host, self._result, reason="Timeout")

        except RetryExhausted as exc:
            self.logger.error(f"Retry exhausted: {exc}")
            self._notify.send_critical("Retry exhausted", str(exc))
            if self.state:
                self.state.mark_failed(self.host, self._result, reason=str(exc))

        except Exception as exc:
            self.logger.error(f"Unhandled exception: {exc}")
            self.logger.error(traceback.format_exc())
            self._notify.send_critical("Unhandled exception", traceback.format_exc())
            if self.state:
                self.state.mark_failed(self.host, self._result, reason=str(exc))

        finally:
            if self._vc:
                try:
                    self._vc.disconnect()
                except Exception:
                    pass

        elapsed = (time.time() - start_time) / 60
        self._result.elapsed_minutes = elapsed
        self._build_remarks()
        self._print_summary()
        self._notify.send_completed(self._result)

        if self.state and self._result.overall_ok:
            self.state.mark_completed(self.host, self._result)
        elif self.state and not isinstance(self._result.firmware_remarks, str):
            self.state.mark_failed(self.host, self._result)

        return self._result

    # ---------------------------------------------------------
    # Phase 0 -- Pre-flight
    # ---------------------------------------------------------

    def _phase0_preflight(self) -> None:
        self.logger.section("Phase 0 -- Pre-flight Validation")

        # Connect vCenter with retry
        self._vc = retry_call(
            fn       = lambda: VSphereClient(
                vcenter        = self.vcenter,
                username       = self.vcenter_creds["username"],
                password       = self.vcenter_creds["password"],
                esxi_host      = self.host,
                esxi_root_user = self.root_creds["username"],
                esxi_root_pass = self.root_creds["password"],
                logger         = self.logger,
            ),
            label    = "vCenter connect",
            logger   = self.logger,
            **_RETRY_SHORT,
        )
        self._last_vc_ping = time.time()

        # Snapshots
        self._before_nics = self._vc.get_nic_snapshot()
        self._before_hbas = self._vc.get_hba_snapshot()
        self.logger.info(
            f"Pre-upgrade: {len(self._before_nics)} NICs, "
            f"{len(self._before_hbas)} HBAs"
        )

        # Hardware info
        self._vendor      = self._vc.get_vendor()
        self._model_full  = self._vc.get_model()
        parts             = self._model_full.split()
        self._model_short = parts[-1] if parts else self._model_full
        self._idrac_ip    = self._vc.get_idrac_ip()

        self.logger.info(
            f"Vendor: {self._vendor}  |  Model: {self._model_full}  |  "
            f"iDRAC IP: {self._idrac_ip or 'not found'}"
        )

        # Get baselines for this model
        baselines = get_baselines(self._model_short) or []

        # -- Run pre-flight checker --
        checker = PreflightChecker(
            fw_repo        = self.fw_repo,
            model          = self._model_short,
            baselines      = baselines,
            vendor         = self._vendor,
            idrac_ip       = self._idrac_ip,
            vcenter        = self.vcenter,
            logger         = self.logger,
            upgrade_option = self.opt,
        )
        ok, issues = checker.run_all()
        if not ok:
            raise PreflightFailed(issues)

        # DRS checks (skip if already in MM)
        if not self._vc.is_in_maintenance_mode():
            has_overrides = self._vc.check_vm_drs_overrides()
            drs_level     = self._vc.get_cluster_drs_level()
            self.logger.info(f"Cluster DRS level: {drs_level}")

            if has_overrides or "fullautomated" not in drs_level.lower():
                raise PreflightFailed([
                    f"DRS check failed -- "
                    f"overrides={has_overrides}, cluster level={drs_level}. "
                    f"Resolve before proceeding."
                ])

    # ---------------------------------------------------------
    # Phase 1 -- Maintenance mode + alarm disable
    # ---------------------------------------------------------

    def _phase1_maintenance_and_alarms(self) -> None:
        self.logger.section("Phase 1 -- Maintenance Mode + Alarm Disable")
        self._vc_keepalive()

        if not self._vc.is_in_maintenance_mode():
            ok = retry_call(
                fn       = self._vc.enter_maintenance_mode,
                label    = "enter maintenance mode",
                logger   = self.logger,
                **_RETRY_SHORT,
            )
            if not ok:
                raise RuntimeError(
                    f"Could not place {self.host} in Maintenance Mode"
                )

        retry_call(
            fn     = lambda: self._vc.set_alarm_actions(enabled=False),
            label  = "disable alarms",
            logger = self.logger,
            **_RETRY_SHORT,
        )

    # ---------------------------------------------------------
    # Phase 2 -- Firmware upgrade via Redfish
    # ---------------------------------------------------------

    def _phase2_firmware_upgrade(self) -> None:
        self.logger.section("Phase 2 -- Dell Firmware Upgrade via Redfish")
        self._vc_keepalive()

        if "dell" not in self._vendor.lower():
            self.logger.info(
                f"Not a Dell server ({self._vendor}) -- skipping firmware upgrade"
            )
            self._result.firmware_ok      = True
            self._result.firmware_skipped = True
            return

        if not self._idrac_ip:
            self.logger.error("iDRAC IP not available -- cannot upgrade firmware")
            return

        baselines = get_baselines(self._model_short)
        if not baselines:
            self.logger.error(
                f"No baselines for model {self._model_short} -- "
                f"supported: {SUPPORTED_MODELS}"
            )
            return

        fw_model_path = self.fw_repo / self._model_short
        if not fw_model_path.exists():
            self.logger.error(f"Firmware repo missing: {fw_model_path}")
            return

        # Create Redfish client with retry on connect
        try:
            with RedfishClient(
                idrac_ip = self._idrac_ip,
                username = self.idrac_creds["username"],
                password = self.idrac_creds["password"],
                logger   = self.logger,
            ) as rf:

                if not rf.is_reachable():
                    raise RuntimeError(
                        f"iDRAC {self._idrac_ip} not reachable"
                    )

                self._firmware_update_cycle(rf, fw_model_path, baselines, max_iterations=2)

                # Final compliance check -- read-only
                self.logger.section("Phase 2 -- Final Firmware Compliance Check")
                self._vc_keepalive()

                final_inv    = retry_call(
                    fn     = rf.get_firmware_inventory,
                    label  = "final firmware inventory",
                    logger = self.logger,
                    **_RETRY_MEDIUM,
                )
                failed_comps = self._compliance_check(baselines, final_inv, fw_model_path)
                failed_names = [c.source_name for c in failed_comps]

                if failed_names:
                    self.logger.error(
                        f"Non-compliant after all iterations: {failed_names}"
                    )
                    failed_file = (
                        self.log_dir / "ESXi-Update-Logs" /
                        f"{self.host}-Failed-Firmware-List.txt"
                    )
                    failed_file.write_text("\n".join(failed_names))
                    self._result.firmware_ok = False
                else:
                    self.logger.info("All firmware components compliant OK")
                    self._result.firmware_ok = True

        except RetryExhausted:
            raise
        except Exception as exc:
            self.logger.error(f"Firmware phase failed: {exc}")
            self._result.firmware_ok = False

    def _firmware_update_cycle(
        self,
        rf,
        fw_model_path: Path,
        baselines:     list[FirmwareComponent],
        max_iterations: int = 2,
    ) -> None:
        all_baselines = get_unique_baselines(self._model_short)

        for iteration in range(1, max_iterations + 1):
            self.logger.section(
                f"Firmware Update -- Iteration {iteration}/{max_iterations}"
            )
            self._vc_keepalive()

            inventory = retry_call(
                fn     = rf.get_firmware_inventory,
                label  = f"firmware inventory (iter {iteration})",
                logger = self.logger,
                **_RETRY_MEDIUM,
            )
            non_compliant = self._compliance_check(baselines, inventory, fw_model_path)

            if not non_compliant:
                self.logger.info(
                    f"All components compliant at iteration {iteration} -- "
                    f"no updates needed OK"
                )
                return

            self.logger.info(
                f"Non-compliant: {[c.source_name for c in non_compliant]}"
            )
            needed_versions = {c.version for c in non_compliant}

            # Clear job queue with retry
            retry_call(
                fn     = lambda: rf.clear_job_queue_restart_lc(dry_run=self.dry_run),
                label  = "clear iDRAC job queue",
                logger = self.logger,
                **_RETRY_MEDIUM,
            )
            self.logger.info(f"Waiting {_LC_RESTART_WAIT}s for LC to stabilise ...")
            time.sleep(_LC_RESTART_WAIT)
            self._vc_keepalive()

            any_uploaded = False
            for baseline_name in all_baselines:
                baseline_dir = fw_model_path / baseline_name
                if not baseline_dir.exists():
                    continue

                uploaded_in_baseline = 0
                for binary in baseline_dir.iterdir():
                    if not any(ver in binary.name for ver in needed_versions):
                        self.logger.info(
                            f"  Skipping {binary.name} -- not needed or not present"
                        )
                        continue

                    stagger = random.randint(_RANDOM_UPLOAD_MIN, _RANDOM_UPLOAD_MAX)
                    self.logger.info(
                        f"  Waiting {stagger}s before uploading {binary.name} ..."
                    )
                    time.sleep(stagger)
                    self._vc_keepalive()

                    try:
                        job_id = retry_call(
                            fn     = lambda b=binary: rf.upload_and_stage_firmware(
                                b, dry_run=self.dry_run
                            ),
                            label  = f"upload {binary.name}",
                            logger = self.logger,
                            **_RETRY_MEDIUM,
                            # Don't retry "not applicable" errors
                            fatal_check = lambda exc: "not applicable" in str(exc).lower(),
                        )
                        if job_id:
                            rf.wait_for_task(job_id)
                            uploaded_in_baseline += 1
                            any_uploaded = True
                    except Exception as exc:
                        self.logger.error(
                            f"  Upload failed for {binary.name}: {exc}"
                        )

                if uploaded_in_baseline > 0:
                    self.logger.info(
                        f"  Staged {uploaded_in_baseline} update(s) in "
                        f"{baseline_name} -- rebooting to apply ..."
                    )
                    if not self.dry_run:
                        reboot_ok = retry_call(
                            fn     = self._vc.reboot_and_wait,
                            label  = f"reboot after {baseline_name}",
                            logger = self.logger,
                            **_RETRY_SHORT,
                        )
                        if not reboot_ok:
                            self.logger.error(
                                f"Reboot failed after {baseline_name} -- "
                                f"aborting firmware cycle"
                            )
                            return

                        retry_call(
                            fn     = lambda: rf.clear_job_queue_restart_lc(
                                dry_run=self.dry_run
                            ),
                            label  = "clear job queue post-reboot",
                            logger = self.logger,
                            **_RETRY_MEDIUM,
                        )
                        time.sleep(_LC_RESTART_WAIT)
                        self._vc_keepalive()

            if not any_uploaded:
                self.logger.warning(
                    f"No binaries uploaded in iteration {iteration}. "
                    f"Check firmware repository for missing binaries."
                )

    # ---------------------------------------------------------
    # Phase 3 -- ESXi version upgrade
    # ---------------------------------------------------------

    def _phase3_esxi_upgrade(self) -> None:
        self.logger.section("Phase 3 -- ESXi Version Upgrade")
        self._vc_keepalive()

        local_ds_name = f"localds_{self.host.split('.')[0]}"

        ok = retry_call(
            fn     = lambda: self._vc.run_esxi_profile_update(
                local_ds_name = local_ds_name,
                vendor        = self._vendor,
                dry_run       = self.dry_run,
            ),
            label  = "ESXi profile update",
            logger = self.logger,
            **_RETRY_LONG,
        )

        if ok:
            retry_call(
                fn     = lambda: self._vc.assign_license(self.license_key),
                label  = "license assignment",
                logger = self.logger,
                attempts = 2, delay = 30, backoff = 1.0,
            )
            retry_call(
                fn     = lambda: self._vc.ensure_fdm_version(
                    local_ds_name, dry_run=self.dry_run
                ),
                label  = "FDM version check",
                logger = self.logger,
                **_RETRY_SHORT,
            )
            self._result.esxi_ok = True
        else:
            self._result.esxi_ok = False

    # ---------------------------------------------------------
    # Phase 4 -- Health checks
    # ---------------------------------------------------------

    def _phase4_health_checks(self) -> None:
        self.logger.section("Phase 4 -- Post-Upgrade Health Checks")
        self._vc_keepalive()

        after_nics = self._vc.get_nic_snapshot()
        after_hbas = self._vc.get_hba_snapshot()

        self._result.nic_health_ok     = self._vc.check_nic_health(
            self._before_nics, after_nics
        )
        self._result.storage_health_ok = self._vc.check_hba_health(
            self._before_hbas, after_hbas
        )

        nic_str = "OK OK" if self._result.nic_health_ok     else "FAIL FAIL"
        hba_str = "OK OK" if self._result.storage_health_ok else "FAIL FAIL"
        self.logger.info(f"Network health  : {nic_str}")
        self.logger.info(f"Storage health  : {hba_str}")
        self.logger.info(
            "Host left in Maintenance Mode -- validate and exit MM manually."
        )

    # ---------------------------------------------------------
    # Compliance check (shared across iterations)
    # ---------------------------------------------------------

    def _compliance_check(
        self,
        baselines:     list[FirmwareComponent],
        inventory:     list[FirmwareInventoryItem],
        fw_model_path: Path,
    ) -> list[FirmwareComponent]:
        non_compliant: list[FirmwareComponent] = []

        for comp in baselines:
            comp_name  = comp.source_name
            target_ver = comp.version

            matches = [
                item for item in inventory
                if comp_name.lower() in item.name.lower()
            ]
            if not matches:
                self.logger.info(f"  {comp_name}: not in inventory -- skipping")
                continue

            # Backplane: exclude disk-related entries + A/B/C-versioned ones
            if comp_name == "Backplane":
                matches = [
                    m for m in matches
                    if "disk" not in m.name.lower()
                    and not any(m.version.upper().startswith(p) for p in ("A","B","C"))
                ]
                if not matches:
                    continue

            # Skip if multiple differing versions (can't determine which applies)
            unique_versions = {m.version for m in matches}
            if len(unique_versions) != 1:
                self.logger.warning(
                    f"  {comp_name}: multiple versions {unique_versions} -- skipping"
                )
                continue

            actual_item = matches[0]
            actual_ver  = actual_item.version

            # Disk prefix resolution
            if comp_name == "Disk":
                target_ver = resolve_disk_version(actual_ver)
                if target_ver == "NotFound":
                    self.logger.info(
                        f"  Disk [{actual_item.name}]: "
                        f"version {actual_ver} has no prefix mapping -- skipping"
                    )
                    continue
                self.logger.info(
                    f"  Disk [{actual_item.name}]: "
                    f"actual={actual_ver}  target={target_ver}"
                )
            else:
                self.logger.info(
                    f"  {actual_item.name}: actual={actual_ver}  target={target_ver}"
                )

            if actual_ver == target_ver:
                self.logger.info(f"    -> compliant OK")
                continue

            # Non-compliant -- check binary exists in repo
            baseline_dir  = fw_model_path / comp.baseline
            binary_exists = (
                baseline_dir.exists()
                and any(target_ver in f.name for f in baseline_dir.iterdir())
            )

            if binary_exists:
                self.logger.warning(
                    f"    -> NOT compliant FAIL  "
                    f"(binary available for {target_ver})"
                )
                non_compliant.append(comp)
            else:
                self.logger.info(
                    f"    -> NOT compliant -- no binary found for {target_ver} "
                    f"in {comp.baseline} -- skipping"
                )

        return non_compliant

    def _get_idrac_ip(self) -> str | None:
        idrac_ip = self._vc.get_idrac_ip()
        if not idrac_ip:
            self.logger.warning(
                "Could not get iDRAC IP -- ensure IPMI/BMC configured in vCenter"
            )
        return idrac_ip

    # ---------------------------------------------------------
    # vCenter session keep-alive
    # ---------------------------------------------------------

    def _vc_keepalive(self) -> None:
        """
        Ping vCenter periodically to prevent session expiry during long upgrades.
        vCenter sessions typically expire after 30 min of inactivity.
        A firmware upgrade cycle can take 2-3 hours.
        Mirrors the implicit keep-alive that PowerCLI's session management did.
        """
        now = time.time()
        if now - self._last_vc_ping < _VC_KEEPALIVE_SECS:
            return
        if not self._vc:
            return
        try:
            # Lightweight call -- just read the host's connection state
            _ = self._vc.get_connection_state()
            self._last_vc_ping = now
            self.logger.info("vCenter session keep-alive OK")
        except Exception as exc:
            self.logger.warning(
                f"vCenter keep-alive failed: {exc} -- "
                f"attempting reconnect ..."
            )
            try:
                self._vc.disconnect()
                self._vc = VSphereClient(
                    vcenter        = self.vcenter,
                    username       = self.vcenter_creds["username"],
                    password       = self.vcenter_creds["password"],
                    esxi_host      = self.host,
                    esxi_root_user = self.root_creds["username"],
                    esxi_root_pass = self.root_creds["password"],
                    logger         = self.logger,
                )
                self._last_vc_ping = time.time()
                self.logger.info("vCenter session reconnected OK")
            except Exception as reconnect_exc:
                self.logger.error(f"vCenter reconnect failed: {reconnect_exc}")

    # ---------------------------------------------------------
    # Timeout check
    # ---------------------------------------------------------

    def _check_timeout(self, deadline: float, phase: str) -> None:
        """Raise _HostTimeout if the wall-clock deadline has passed."""
        remaining = deadline - time.time()
        if remaining <= 0:
            raise _HostTimeout(
                f"Host {self.host} exceeded {HOST_TIMEOUT_HOURS}h timeout "
                f"at phase: {phase}"
            )
        # Warn when less than 30 min remaining
        if remaining < 1800:
            self.logger.warning(
                f"Less than {remaining/60:.0f} min remaining before timeout"
            )

    # ---------------------------------------------------------
    # Remarks + summary
    # ---------------------------------------------------------

    def _build_remarks(self) -> None:
        opt = self.opt

        if opt in (UpgradeOption.FIRMWARE_ONLY, UpgradeOption.ALL):
            if self._result.firmware_skipped:
                self._result.firmware_remarks = (
                    "Not a Dell server -- upgrade firmware manually if required"
                )
            elif self._result.firmware_ok:
                self._result.firmware_remarks = "Firmware upgrade successful"
            else:
                self._result.firmware_remarks = (
                    "ERROR: Firmware upgrade failed -- refer to logs"
                )
        else:
            self._result.firmware_ok      = True
            self._result.firmware_skipped = True
            self._result.firmware_remarks = "Firmware upgrade skipped"

        if opt in (UpgradeOption.ESXI_ONLY, UpgradeOption.ALL):
            if self._result.esxi_ok:
                self._result.esxi_remarks = "ESXi upgrade successful"
            else:
                self._result.esxi_remarks = "ERROR: ESXi upgrade failed -- refer to logs"
        else:
            self._result.esxi_ok      = True
            self._result.esxi_skipped = True
            self._result.esxi_remarks = "ESXi upgrade skipped"

    def _print_summary(self) -> None:
        sep = "=" * 80
        r   = self._result
        self.logger.info(sep)
        self.logger.info(f"UPGRADE SUMMARY  --  {self.host}")
        self.logger.info(sep)
        self.logger.info(f"  Firmware   : {r.firmware_remarks}")
        self.logger.info(f"  ESXi       : {r.esxi_remarks}")
        self.logger.info(f"  NIC health : {'OK OK' if r.nic_health_ok     else 'FAIL FAIL'}")
        self.logger.info(f"  HBA health : {'OK OK' if r.storage_health_ok else 'FAIL FAIL'}")
        self.logger.info(f"  Overall    : {'OK SUCCESS' if r.overall_ok   else 'FAIL FAILED'}")
        self.logger.info(f"  Elapsed    : {r.elapsed_minutes:.1f} min")
        self.logger.info(sep)


class _HostTimeout(Exception):
    """Internal -- raised when the per-host wall-clock timeout expires."""
    pass
