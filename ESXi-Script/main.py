#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
main.py -- Dell ESXi Firmware + Version Upgrade Tool

DESIGN: ONE SCRIPT INVOCATION = ONE HOST
  Parallelism is handled externally -- by your CI/CD tool or by running
  this script multiple times in separate terminals for manual testing.
  This keeps the script simple, logs clean, and exit codes unambiguous.

  Manual parallel testing (open separate terminals):
    Terminal 1: python main.py --config config.yaml --esxi-host esxi01.corp.local ...
    Terminal 2: python main.py --config config.yaml --esxi-host esxi02.corp.local ...
    Terminal 3: python main.py --config config.yaml --esxi-host esxi03.corp.local ...

  Or a simple shell loop (sequential):
    for HOST in esxi01 esxi02 esxi03; do
        python main.py --esxi-host ${HOST}.corp.local ...
    done

EXIT CODES (your CI/CD tool reads these):
  0  SUCCESS          -- upgrade completed successfully
  1  FAILED           -- upgrade failed (host left in MM -- investigate)
  2  PREFLIGHT_FAILED -- host was never touched (safe to re-run immediately)
  3  SETUP_ERROR      -- config/dependency problem before anything ran

CREDENTIAL PRECEDENCE (highest to lowest):
  1. Environment variables   <- CI/CD tool injects from CyberArk
  2. CLI flags               <- manual override
  3. Config file             <- manual testing / defaults

PER-HOST ROOT PASSWORD:
  ESXi root passwords differ per host. Pass the correct one each invocation:
    --esxi-root-pass "ThisHostsRootPassword"
  Or in config file under esxi_root_credentials per_host section.
  Or via env var: UPGRADE_ESXI_ROOT_PASS (set fresh per invocation by CI/CD).
"""

import argparse
import csv
import os
import sys
import time
from datetime import datetime
from pathlib import Path

import yaml

from models import UpgradeOption, UpgradeResult

# -- Exit codes ----------------------------------------------------------------
EXIT_SUCCESS          = 0
EXIT_FAILED           = 1
EXIT_PREFLIGHT_FAILED = 2
EXIT_SETUP_ERROR      = 3

BANNER = """
################################################################################
#  Dell Firmware + ESXi Upgrade Tool                                           #
#  Authorized VPCOPS use only. Requires valid DEP (UAT) or CR (PROD).          #
################################################################################
"""


# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Dell firmware + ESXi version upgrade -- single host per run",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
UPGRADE OPTIONS:
  1  Firmware upgrade only     (Redfish iDRAC push, all baselines)
  2  ESXi version upgrade only (esxcli software profile update)
  4  Both firmware + ESXi      (default, recommended)

EXIT CODES:
  0  Success          -- upgrade completed
  1  Failed           -- upgrade failed, host left in Maintenance Mode
  2  Pre-flight failed -- host NOT touched, safe to re-run immediately
  3  Setup error       -- fix config/dependencies and re-run

CREDENTIAL ENVIRONMENT VARIABLES (set by CI/CD tool from CyberArk):
  UPGRADE_VC_USER         vCenter username
  UPGRADE_VC_PASS         vCenter password
  UPGRADE_IDRAC_USER      iDRAC username
  UPGRADE_IDRAC_PASS      iDRAC password
  UPGRADE_ESXI_ROOT_USER  ESXi root username  (default: root)
  UPGRADE_ESXI_ROOT_PASS  ESXi root password  (DIFFERENT PER HOST)
  UPGRADE_LICENSE_KEY     ESXi license key
  TEAMS_WEBHOOK_URL       Teams channel webhook URL

EXAMPLES:
  # Dry run first -- always do this before a real upgrade
  python main.py \\
    --vcenter vc01g.corp.local --esxi-host esxi01.corp.local \\
    --depcr CHG0012345 --firmware-repo /opt/upgrade/Firmware-Binaries \\
    --vc-user admin@vsphere.local --vc-pass Password1 \\
    --idrac-user vpcidracadmin --idrac-pass Password2 \\
    --esxi-root-pass Password3 \\
    --dry-run

  # Real upgrade (using config file for non-sensitive settings)
  python main.py --config config.yaml \\
    --esxi-host esxi01.corp.local \\
    --esxi-root-pass "esxi01RootPassword" \\
    --depcr CHG0012345

  # CI/CD tool invocation (credentials from env vars set by the tool)
  python main.py \\
    --vcenter vc01g.corp.local \\
    --esxi-host esxi01.corp.local \\
    --depcr CHG0012345 \\
    --upgrade-option 4
        """,
    )

    # -- Non-sensitive settings (can be in config file) ----------------------
    p.add_argument("--config", "-c", metavar="PATH",
                   help="YAML config file for non-sensitive settings")
    p.add_argument("--vcenter",       metavar="FQDN",
                   help="vCenter server FQDN")
    p.add_argument("--esxi-host",     metavar="FQDN",
                   help="ESXi host FQDN (one host per run)")
    p.add_argument("--depcr",         metavar="CHGXXXXXXX",
                   help="DEP/CR number for audit trail")
    p.add_argument("--firmware-repo", metavar="PATH",
                   help="Path to firmware binary repository")
    p.add_argument("--log-dir",       metavar="PATH", default="./logs",
                   help="Log output directory (default: ./logs)")
    p.add_argument("--upgrade-option", type=int, choices=[1, 2, 4], default=4,
                   help="Upgrade option: 1=FW, 2=ESXi, 4=Both (default: 4)")
    p.add_argument("--license-key",   metavar="KEY", default="NA",
                   help="ESXi license key for this host (default: NA)")
    p.add_argument("--teams-webhook", metavar="URL",
                   help="Teams webhook URL (overrides TEAMS_WEBHOOK_URL env var)")
    p.add_argument("--dry-run",       action="store_true",
                   help="Validate everything but make NO changes to any system")
    p.add_argument("--resume",        metavar="RUN_ID",
                   help="Resume a previous interrupted run using its run ID")

    # -- Credentials (env vars take precedence -- these are CLI fallbacks) -----
    cred = p.add_argument_group(
        "credentials",
        "Prefer env vars for CI/CD. Use CLI flags for manual testing.\n"
        "ESXi root password is per-host -- pass the correct one each time."
    )
    cred.add_argument("--vc-user",         metavar="USER",
                      help="vCenter username  [env: UPGRADE_VC_USER]")
    cred.add_argument("--vc-pass",         metavar="PASS",
                      help="vCenter password  [env: UPGRADE_VC_PASS]")
    cred.add_argument("--idrac-user",      metavar="USER",
                      help="iDRAC username    [env: UPGRADE_IDRAC_USER]")
    cred.add_argument("--idrac-pass",      metavar="PASS",
                      help="iDRAC password    [env: UPGRADE_IDRAC_PASS]")
    cred.add_argument("--esxi-root-user",  metavar="USER", default="root",
                      help="ESXi root user    [env: UPGRADE_ESXI_ROOT_USER] (default: root)")
    cred.add_argument("--esxi-root-pass",  metavar="PASS",
                      help="ESXi root password -- DIFFERENT PER HOST  [env: UPGRADE_ESXI_ROOT_PASS]")

    return p.parse_args()


# -----------------------------------------------------------------------------
# Config resolution
# -----------------------------------------------------------------------------

def _resolve(
    env_key:  str,
    cli_val:  str | None,
    cfg_val:  str | None,
    required: bool = True,
    label:    str  = "",
) -> str:
    """
    Resolve a single value with precedence: env var > CLI flag > config file.

    This is the key integration point with your CI/CD tool:
      - CI/CD tool sets env vars (from CyberArk) before calling the script
      - Env vars always win regardless of what's in the config file or CLI
      - For manual testing, CLI flags or config file work fine
    """
    value = os.environ.get(env_key) or cli_val or cfg_val
    if required and not value:
        print(
            f"\n[ERROR] Required value not provided: {label or env_key}\n"
            f"  Via env var : export {env_key}=...\n"
            f"  Via CLI     : see --help\n"
            f"  Via config  : add to config.yaml under the relevant section\n"
        )
        sys.exit(EXIT_SETUP_ERROR)
    return value or ""


def load_yaml(path: str) -> dict:
    """Load and parse a YAML config file."""
    p = Path(path)
    if not p.exists():
        print(f"\n[ERROR] Config file not found: {path}\n")
        sys.exit(EXIT_SETUP_ERROR)
    with open(p) as f:
        cfg = yaml.safe_load(f)
    return cfg or {}


def build_config(args: argparse.Namespace) -> dict:
    """
    Merge config file + CLI flags + env vars into a single runtime config.

    Per-host root password handling:
      The config file supports a per_host section under esxi_root_credentials
      for manual batch testing. In CI/CD, the tool sets UPGRADE_ESXI_ROOT_PASS
      to the correct password for each host before calling the script.

      Config file per-host example:
        esxi_root_credentials:
          username: root
          password: "default_if_no_per_host_match"
          per_host:
            esxi01.corp.local: "esxi01Password"
            esxi02.corp.local: "esxi02Password"
    """
    file_cfg: dict = {}
    if args.config:
        file_cfg = load_yaml(args.config)

    # -- Resolve ESXi host -----------------------------------------------------
    esxi_host = (
        args.esxi_host
        or file_cfg.get("esxi_host")    # single host in config
        or None
    )
    if not esxi_host:
        print(
            "\n[ERROR] No ESXi host specified.\n"
            "  Via CLI    : --esxi-host esxi01.corp.local\n"
            "  Via config : esxi_host: esxi01.corp.local\n"
        )
        sys.exit(EXIT_SETUP_ERROR)
    esxi_host = esxi_host.strip()

    # -- Resolve non-sensitive settings ----------------------------------------
    vcenter = (
        args.vcenter
        or file_cfg.get("vcenter")
    )
    if not vcenter:
        print("\n[ERROR] --vcenter or config 'vcenter' is required\n")
        sys.exit(EXIT_SETUP_ERROR)

    depcr = (
        args.depcr
        or file_cfg.get("depcr")
    )
    if not depcr:
        print("\n[ERROR] --depcr or config 'depcr' is required\n")
        sys.exit(EXIT_SETUP_ERROR)

    firmware_repo = (
        args.firmware_repo
        or file_cfg.get("firmware_repo")
    )
    if not firmware_repo:
        print("\n[ERROR] --firmware-repo or config 'firmware_repo' is required\n")
        sys.exit(EXIT_SETUP_ERROR)

    log_dir = args.log_dir or file_cfg.get("log_dir", "./logs")

    # -- Resolve credentials ---------------------------------------------------
    fvc    = file_cfg.get("vcenter_credentials",    {})
    fidrac = file_cfg.get("idrac_credentials",      {})
    froot  = file_cfg.get("esxi_root_credentials",  {})

    vc_creds = {
        "username": _resolve("UPGRADE_VC_USER",    args.vc_user,    fvc.get("username"),   label="vCenter username"),
        "password": _resolve("UPGRADE_VC_PASS",    args.vc_pass,    fvc.get("password"),   label="vCenter password"),
    }

    idrac_creds = {
        "username": _resolve("UPGRADE_IDRAC_USER", args.idrac_user, fidrac.get("username"), label="iDRAC username"),
        "password": _resolve("UPGRADE_IDRAC_PASS", args.idrac_pass, fidrac.get("password"), label="iDRAC password"),
    }

    # -- Per-host root password resolution -------------------------------------
    # Priority:
    #   1. UPGRADE_ESXI_ROOT_PASS env var  (CI/CD sets this per host invocation)
    #   2. --esxi-root-pass CLI flag       (manual CLI override for this host)
    #   3. per_host map in config file     (manual config for multiple hosts)
    #   4. default password in config file (fallback)
    per_host_map = froot.get("per_host", {})
    root_pass = (
        os.environ.get("UPGRADE_ESXI_ROOT_PASS")          # CI/CD -- always wins
        or args.esxi_root_pass                              # CLI flag
        or per_host_map.get(esxi_host)                     # config per-host map
        or froot.get("password")                            # config default
    )
    if not root_pass:
        print(
            f"\n[ERROR] ESXi root password not provided for {esxi_host}.\n"
            f"  Via env var    : export UPGRADE_ESXI_ROOT_PASS=...\n"
            f"  Via CLI        : --esxi-root-pass ...\n"
            f"  Via config     : esxi_root_credentials.per_host.{esxi_host}: ...\n"
            f"  Via config     : esxi_root_credentials.password: ...  (default)\n"
        )
        sys.exit(EXIT_SETUP_ERROR)

    root_creds = {
        "username": (
            os.environ.get("UPGRADE_ESXI_ROOT_USER")
            or args.esxi_root_user
            or froot.get("username", "root")
        ),
        "password": root_pass,
    }

    # -- License key -----------------------------------------------------------
    license_key = (
        os.environ.get("UPGRADE_LICENSE_KEY")
        or (args.license_key if args.license_key != "NA" else None)
        or file_cfg.get("license_keys", {}).get(esxi_host)
        or "NA"
    )

    # -- Teams webhook ---------------------------------------------------------
    teams_webhook = (
        args.teams_webhook
        or os.environ.get("TEAMS_WEBHOOK_URL")
        or file_cfg.get("teams_webhook")
    )

    return {
        "esxi_host":             esxi_host,
        "vcenter":               vcenter,
        "depcr":                 depcr,
        "firmware_repo":         firmware_repo,
        "log_dir":               log_dir,
        "vcenter_credentials":   vc_creds,
        "idrac_credentials":     idrac_creds,
        "esxi_root_credentials": root_creds,
        "license_key":           license_key,
        "teams_webhook":         teams_webhook,
        "upgrade_option":        UpgradeOption(args.upgrade_option),
        "dry_run":               args.dry_run,
        "resume":                args.resume,
    }


# -----------------------------------------------------------------------------
# Directory setup
# -----------------------------------------------------------------------------

def setup_directories(log_dir_str: str, run_id: str) -> dict:
    """
    Create log directory structure for this run.
    Each run gets its own folder under ESXi-Update-Logs/<run_id>/
    """
    log_dir     = Path(log_dir_str)
    run_dir     = log_dir / "ESXi-Update-Logs" / run_id
    transcript  = run_dir / "Transcripts"
    results_dir = run_dir / f"Results-{run_id}"
    archive_dir = log_dir / "ESXi-Update-Logs" / "Archive"

    for d in [run_dir, transcript, results_dir, archive_dir]:
        d.mkdir(parents=True, exist_ok=True)

    # Archive run dirs older than 24h
    cutoff    = time.time() - 86400
    esxi_logs = log_dir / "ESXi-Update-Logs"
    for child in esxi_logs.iterdir():
        if child.is_dir() and child.name not in ("Archive",):
            try:
                if child.stat().st_mtime < cutoff:
                    import shutil
                    shutil.move(str(child), str(archive_dir / child.name))
            except Exception:
                pass

    return {
        "run_dir":     run_dir,
        "transcript":  transcript,
        "results_dir": results_dir,
        "log_dir":     log_dir,
    }


# -----------------------------------------------------------------------------
# Result output
# -----------------------------------------------------------------------------

def print_result(result: UpgradeResult) -> None:
    sep = "=" * 80
    print(f"\n{sep}")
    print(f"  RESULT -- {result.host}")
    print(sep)
    print(f"  Firmware   : {result.firmware_remarks}")
    print(f"  ESXi       : {result.esxi_remarks}")
    print(f"  NIC health : {'OK OK' if result.nic_health_ok     else 'FAIL FAIL'}")
    print(f"  HBA health : {'OK OK' if result.storage_health_ok else 'FAIL FAIL'}")
    print(f"  Overall    : {'OK SUCCESS' if result.overall_ok   else 'FAIL FAILED'}")
    print(f"  Elapsed    : {result.elapsed_minutes:.1f} min")
    print(f"  Host left in Maintenance Mode -- validate and exit MM manually.")
    print(sep)


def write_result_csv(result: UpgradeResult, results_dir: Path, run_id: str) -> None:
    out = results_dir / f"upgrade-result-{result.host}-{run_id}.csv"
    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=[
            "ESXiHost", "FirmwareUpdate", "ESXiUpdate",
            "NICHealth", "StorageHealth", "Overall", "ElapsedMinutes",
        ])
        w.writeheader()
        w.writerow({
            "ESXiHost":       result.host,
            "FirmwareUpdate": result.firmware_remarks,
            "ESXiUpdate":     result.esxi_remarks,
            "NICHealth":      "OK" if result.nic_health_ok     else "FAIL",
            "StorageHealth":  "OK" if result.storage_health_ok else "FAIL",
            "Overall":        "SUCCESS" if result.overall_ok   else "FAILED",
            "ElapsedMinutes": round(result.elapsed_minutes, 2),
        })
    print(f"  Result CSV  -> {out}")


def exit_code_from_result(result: UpgradeResult) -> int:
    """
    Map upgrade result to exit code for CI/CD tool to consume.

    0 = success
    1 = failed (host in MM, investigate)
    2 = pre-flight failed (host never touched, safe to retry)
    """
    if result.overall_ok:
        return EXIT_SUCCESS

    # Pre-flight failure -- host was never modified
    if "Pre-flight" in result.firmware_remarks:
        return EXIT_PREFLIGHT_FAILED

    return EXIT_FAILED


# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

def main() -> None:
    print(BANNER)

    args   = parse_args()
    cfg    = build_config(args)
    run_id = args.resume or datetime.now().strftime("%d-%b-%Y-%H-%M")
    dirs   = setup_directories(cfg["log_dir"], run_id)

    host = cfg["esxi_host"]

    # -- Print run summary -----------------------------------------------------
    print(f"  Run ID        : {run_id}")
    print(f"  vCenter       : {cfg['vcenter']}")
    print(f"  ESXi host     : {host}")
    print(f"  DEP/CR        : {cfg['depcr']}")
    print(f"  Option        : {cfg['upgrade_option'].name} ({cfg['upgrade_option'].value})")
    print(f"  Dry run       : {cfg['dry_run']}")
    print(f"  Teams webhook : {'configured OK' if cfg.get('teams_webhook') else 'not set'}")
    print(f"  Log dir       : {dirs['run_dir']}")
    print(f"  iDRAC user    : {cfg['idrac_credentials']['username']}")
    print(f"  ESXi root user: {cfg['esxi_root_credentials']['username']}")
    print()

    # -- Interactive confirmation (manual runs only) ---------------------------
    # Skip in dry-run and when running non-interactively (CI/CD)
    if not cfg["dry_run"] and sys.stdin.isatty():
        try:
            input("  Press Enter to start or Ctrl+C to abort ... ")
            print()
        except KeyboardInterrupt:
            print("\n  Aborted.")
            sys.exit(EXIT_SUCCESS)

    # -- State file (for resume capability) ------------------------------------
    from state import RunStateManager
    state = RunStateManager(dirs["log_dir"], run_id, cfg["depcr"])
    state.register_hosts([host])

    # Check if already completed in a previous run
    if args.resume:
        pending = state.get_pending_hosts([host])
        if not pending:
            print(f"  [{host}] Already completed in run {run_id} -- nothing to do.")
            sys.exit(EXIT_SUCCESS)

    # -- Run the upgrade -------------------------------------------------------
    from logger import get_logger
    from upgrade_engine import UpgradeEngine

    logger = get_logger(host, dirs["transcript"])

    engine = UpgradeEngine(
        esxi_host       = host,
        vcenter         = cfg["vcenter"],
        idrac_creds     = cfg["idrac_credentials"],
        vcenter_creds   = cfg["vcenter_credentials"],
        esxi_root_creds = cfg["esxi_root_credentials"],
        firmware_repo   = Path(cfg["firmware_repo"]),
        license_key     = cfg["license_key"],
        upgrade_option  = cfg["upgrade_option"],
        depcr           = cfg["depcr"],
        start_date      = run_id,
        log_dir         = dirs["log_dir"],
        dry_run         = cfg["dry_run"],
        logger          = logger,
        teams_webhook   = cfg.get("teams_webhook"),
        state_manager   = state,
    )

    result = engine.run()

    # -- Output ----------------------------------------------------------------
    print_result(result)
    write_result_csv(result, dirs["results_dir"], run_id)

    log_file = dirs["transcript"] / f"{host}-upgrade.log"
    print(f"  Full log    -> {log_file}")

    # -- Exit with correct code for CI/CD tool ---------------------------------
    code = exit_code_from_result(result)
    print(f"  Exit code   : {code}\n")
    sys.exit(code)


if __name__ == "__main__":
    main()
