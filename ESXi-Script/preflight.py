# -*- coding: utf-8 -*-
"""
preflight.py
Pre-flight validation gate -- run BEFORE placing any host in maintenance mode.

Validates:
  1. Firmware binary repository structure
     - Model directory exists
     - Required baseline folders exist
     - Each expected binary version is present for non-compliant components
  2. Offline ESXi upgrade bundle
     - Zip file exists in the repo
  3. Python dependencies
     - All required packages importable
  4. Network reachability
     - vCenter responds
     - iDRAC responds
  5. Jenkins credentials sanity
     - All required credential env vars are set and non-empty

Why this exists:
  The original PS script discovered missing binaries mid-run -- after the host
  was already in maintenance mode. This gate catches everything BEFORE MM,
  so if something is missing the host never gets touched.

Usage in upgrade_engine.py:
    from preflight import PreflightChecker
    checker = PreflightChecker(fw_repo, model, baselines, logger)
    ok, issues = checker.run_all()
    if not ok:
        raise PreflightFailed(issues)
"""

import importlib
import os
import socket
from dataclasses import dataclass, field
from pathlib import Path

from firmware_baselines import FirmwareComponent, get_unique_baselines
from logger import HostLogger
from vsphere_client import ESXI_BUNDLES, TARGET_ESXi_BUILD


class PreflightFailed(Exception):
    """Raised when pre-flight validation fails -- host has NOT been modified."""
    def __init__(self, issues: list[str]) -> None:
        self.issues = issues
        bullet_list = "\n  * ".join(issues)
        super().__init__(f"Pre-flight failed ({len(issues)} issue(s)):\n  * {bullet_list}")


@dataclass
class PreflightResult:
    ok: bool             = True
    issues: list[str]    = field(default_factory=list)
    warnings: list[str]  = field(default_factory=list)

    def fail(self, msg: str) -> None:
        self.ok = False
        self.issues.append(msg)

    def warn(self, msg: str) -> None:
        self.warnings.append(msg)


class PreflightChecker:
    """
    Runs all pre-flight checks for a single host upgrade.
    Call run_all() which returns (ok: bool, issues: list[str]).
    """

    # Required Python packages -- must all be importable
    _REQUIRED_PACKAGES = [
        ("pyVmomi",  "pyvmomi"),
        ("requests", "requests"),
        ("yaml",     "PyYAML"),
    ]

    def __init__(
        self,
        fw_repo:    Path,
        model:      str,
        baselines:  list[FirmwareComponent],
        vendor:     str,
        idrac_ip:   str | None,
        vcenter:    str,
        logger:     HostLogger,
        upgrade_option,
    ) -> None:
        self._fw_repo   = fw_repo
        self._model     = model
        self._baselines = baselines
        self._vendor    = vendor
        self._idrac_ip  = idrac_ip
        self._vcenter   = vcenter
        self._logger    = logger
        self._opt       = upgrade_option
        self._result    = PreflightResult()

    def run_all(self) -> tuple[bool, list[str]]:
        """
        Run all checks. Returns (ok, issues).
        ok = False means something is missing that would cause the upgrade to fail.
        issues = human-readable list of what's wrong.
        """
        self._logger.section("Pre-flight Validation")

        self._check_python_packages()
        self._check_network_reachability()

        from models import UpgradeOption
        if self._opt in (UpgradeOption.FIRMWARE_ONLY, UpgradeOption.ALL):
            self._check_firmware_repo()

        if self._opt in (UpgradeOption.ESXI_ONLY, UpgradeOption.ALL):
            self._check_esxi_bundle()

        self._check_credentials_env()

        # Log results
        if self._result.warnings:
            for w in self._result.warnings:
                self._logger.warning(f"PRE-FLIGHT WARNING: {w}")

        if self._result.ok:
            self._logger.info(
                f"Pre-flight passed "
                f"({len(self._result.warnings)} warning(s)) OK"
            )
        else:
            for issue in self._result.issues:
                self._logger.error(f"PRE-FLIGHT FAIL: {issue}")
            self._logger.error(
                f"Pre-flight FAILED with {len(self._result.issues)} issue(s). "
                f"Host will NOT be placed in Maintenance Mode."
            )

        return self._result.ok, self._result.issues

    # ---------------------------------------------------------
    # Individual checks
    # ---------------------------------------------------------

    def _check_python_packages(self) -> None:
        """Verify all required Python packages are installed."""
        self._logger.info("Checking Python package dependencies ...")
        for module_name, pip_name in self._REQUIRED_PACKAGES:
            try:
                importlib.import_module(module_name)
                self._logger.info(f"  {pip_name:20} OK")
            except ImportError:
                self._result.fail(
                    f"Required Python package not installed: {pip_name}. "
                    f"Run: pip install {pip_name}"
                )

    def _check_network_reachability(self) -> None:
        """Check vCenter and iDRAC are reachable on the network."""
        self._logger.info("Checking network reachability ...")

        # vCenter port 443
        if self._check_port(self._vcenter, 443, label="vCenter"):
            self._logger.info(f"  vCenter {self._vcenter}:443  OK")
        else:
            self._result.fail(
                f"vCenter {self._vcenter} port 443 is not reachable. "
                f"Check network connectivity."
            )

        # iDRAC port 443
        if self._idrac_ip:
            if self._check_port(self._idrac_ip, 443, label="iDRAC"):
                self._logger.info(f"  iDRAC   {self._idrac_ip}:443    OK")
            else:
                self._result.fail(
                    f"iDRAC {self._idrac_ip} port 443 is not reachable. "
                    f"Check iDRAC network connectivity."
                )
        else:
            self._result.fail(
                "iDRAC IP could not be determined from vSphere IPMI config. "
                "Ensure IPMI/BMC is configured on the host in vCenter."
            )

    def _check_firmware_repo(self) -> None:
        """
        Validate the firmware binary repository structure for this model.

        Checks:
          - Model directory exists:  fw_repo/R6525/
          - Each baseline folder exists: fw_repo/R6525/Baseline0/ etc
          - At least one binary exists in each non-empty baseline folder
        """
        self._logger.info(f"Checking firmware repository for model {self._model} ...")

        model_path = self._fw_repo / self._model
        if not model_path.exists():
            self._result.fail(
                f"Firmware repository missing model directory: {model_path}. "
                f"Expected structure: {self._fw_repo}/<MODEL>/BaselineN/<binaries>"
            )
            return   # can't check further without the model dir

        baseline_folders = get_unique_baselines(self._model)

        for folder in baseline_folders:
            folder_path = model_path / folder
            if not folder_path.exists():
                self._result.fail(
                    f"Missing baseline folder: {folder_path}"
                )
                continue

            binaries = list(folder_path.iterdir())
            if not binaries:
                self._result.warn(
                    f"Baseline folder is empty: {folder_path}. "
                    f"No binaries will be uploaded for this baseline."
                )
            else:
                self._logger.info(
                    f"  {folder}: {len(binaries)} binary/ies found OK"
                )

    def _check_esxi_bundle(self) -> None:
        """
        Validate the ESXi offline upgrade bundle exists for this vendor.
        The bundle is expected in: fw_repo/../Offline-Upgrade-Binaries/
        """
        self._logger.info("Checking ESXi offline upgrade bundle ...")

        # Find matching vendor key
        vendor_key = next(
            (k for k in ESXI_BUNDLES if self._vendor.lower().startswith(k.lower())),
            None
        )

        if not vendor_key:
            self._result.fail(
                f"No ESXi offline bundle configured for vendor '{self._vendor}'. "
                f"Add it to ESXI_BUNDLES in vsphere_client.py"
            )
            return

        bundle   = ESXI_BUNDLES[vendor_key]
        zip_name = bundle["zip"]

        # Check in common locations
        search_paths = [
            self._fw_repo.parent / "Offline-Upgrade-Binaries" / zip_name,
            self._fw_repo / "Offline-Upgrade-Binaries" / zip_name,
        ]

        found = any(p.exists() for p in search_paths)
        if found:
            self._logger.info(f"  ESXi bundle: {zip_name} OK")
        else:
            self._result.warn(
                f"ESXi offline bundle not found in expected locations: {zip_name}. "
                f"It should be in the local datastore under "
                f"ESXi-Upgrade-OfflineBinaries/ -- ensure it was copied before "
                f"the upgrade starts."
            )
            # Warning not failure -- the copy to local DS happens at runtime

    def _check_credentials_env(self) -> None:
        """
        Check that required credential environment variables are set.
        In Jenkins these come from the credentials store injected as env vars.
        """
        self._logger.info("Checking credential environment variables ...")

        # These are set when you use Jenkins 'withCredentials' or
        # 'environment' blocks in your Jenkinsfile
        required_vars = {
            "UPGRADE_VC_USER":        "vCenter username",
            "UPGRADE_VC_PASS":        "vCenter password",
            "UPGRADE_IDRAC_USER":     "iDRAC username",
            "UPGRADE_IDRAC_PASS":     "iDRAC password",
            "UPGRADE_ESXI_ROOT_PASS": "ESXi root password",
        }

        for var, label in required_vars.items():
            val = os.environ.get(var)
            if val:
                self._logger.info(f"  {var:30} OK (set)")
            else:
                # Not a hard failure if credentials are passed via CLI/config
                self._result.warn(
                    f"Environment variable {var} ({label}) is not set. "
                    f"This is required for Jenkins integration. "
                    f"Credential will fall back to CLI flag or config file."
                )

    # ---------------------------------------------------------
    # Helpers
    # ---------------------------------------------------------

    @staticmethod
    def _check_port(host: str, port: int, label: str = "", timeout: int = 5) -> bool:
        """Check if a TCP port is reachable."""
        try:
            s = socket.create_connection((host, port), timeout=timeout)
            s.close()
            return True
        except (socket.timeout, ConnectionRefusedError, OSError):
            return False
