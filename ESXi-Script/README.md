# Dell ESXi Firmware + Version Upgrade Tool — Python Edition

Converted from PowerCLI original by Venkat Praveen Kumar Chavali (VPCOPS).

---

## What This Script Does — Full Workflow Explanation

### Background
The original PowerShell script ran a background job per ESXi host, each job
going through firmware upgrade (via Redfish/iDRAC), ESXi version upgrade, and
post-upgrade hardening tasks. This Python version reproduces that exact workflow
using `ThreadPoolExecutor` for parallelism instead of PowerShell background jobs.

---

## Module-by-Module Explanation

### `main.py` — Entry point and orchestrator
- Parses CLI args and the YAML config file
- Creates the run directory structure (`ESXi-Update-Logs/<run-id>/`)
- Archives log dirs older than 24 hours (mirrors the PS `Get-ChildItem ... AddHours(-24)`)
- Spawns one `UpgradeEngine` per host, either sequentially or in parallel
- Prints and saves the final summary table to CSV

### `models.py` — Data classes
- `UpgradeOption` enum — mirrors PS `$opt` values 1-4
- `FirmwareComponent` — one row of a baseline table (Baseline, SourceName, Version)
- `FirmwareInventoryItem` — one component from iDRAC firmware inventory
- `UpgradeResult` — the per-host result object, mirrors PS `$MyObj`
- `HostSnapshot` — pre-upgrade NIC/HBA state for health checks

### `logger.py` — Per-host structured logger
- Each host gets its own log file in `Transcripts/`
- Also streams to stdout so you see live progress
- Mirrors the PS `Write-Log` module with Information/Warning/Error severities

### `redfish_client.py` — iDRAC Redfish API client
Replaces all three PowerShell iDRAC modules:

| PS module | Python method | Redfish endpoint |
|---|---|---|
| `Get-IdracFirmwareVersionREDFISH` | `get_firmware_inventory()` | `GET /redfish/v1/UpdateService/FirmwareInventory` |
| `Set-DeviceFirmwareSimpleUpdateREDFISH` | `upload_firmware()` | `POST /redfish/v1/UpdateService/SimpleUpdate` |
| `Invoke-IdracJobQueueManagementREDFISH` | `clear_job_queue()` | `DELETE /redfish/v1/Managers/iDRAC.Embedded.1/Jobs/JID_CLEARALL` |

Key guard rails:
- Retry once after 60s on inventory fetch failure (same as PS)
- HTTP 202 = success; extracts Job ID from `Location` header
- Parses `@Message.ExtendedInfo` for error messages (same structure as PS ConvertFrom-Json)
- Silently skips binaries that are "not applicable to this system" (mirrors PS error check)
- SSL verification disabled (mirrors PS `Ignore-SSLCertificates`)

### `firmware_baselines.py` — Hardware baseline definitions
- Direct Python translation of the PS `$R6525`, `$R7425`, `$R6625`, `$R7625` arrays
- `resolve_disk_version()` — implements the disk version prefix mapping (B0→B02A, BA→BA48, etc.)
- `get_baselines(model)` — returns the baseline list for a given model
- Easily extensible: add a new model by adding a `_RXXXX` list and registering it in `BASELINES`

### `vsphere_client.py` — vCenter + ESXi interactions
Replaces PowerCLI. Uses `pyVmomi` (VMware's official Python SDK).

| PS function / cmdlet | Python method |
|---|---|
| `Connect-VIServer` | `VSphereClient.__init__()` |
| `Check-VM-Override-Manual-DRS` | `check_vm_drs_overrides()` |
| `ESXi-Enter-Maintenance-Mode` | `enter_maintenance_mode()` |
| `ESXi-Exit-Maintenance-Mode` | `exit_maintenance_mode()` |
| `Change-ESXi-Alarm` | `set_alarm_actions()` |
| `Restart-VMHost` + wait loops | `reboot_and_wait()` |
| `Check-Network-Adapters` | `check_nic_health()` |
| `Check-HBA-Aapters` | `check_hba_health()` |
| `$esxcli.software.profile.update` | `run_esxi_profile_update()` |
| FDM VIB check + reinstall block | `ensure_fdm_version()` |
| `Set-VMHost -LicenseKey` | `assign_license()` |

Reboot wait logic mirrors the PS three-phase pattern exactly:
1. Issue reboot
2. Poll until host goes OFFLINE (port 443 stops responding)
3. Poll until host comes back ONLINE (port 443 responds again)
4. Poll until host re-enters Maintenance Mode

### `ssh_tasks.py` — Post-upgrade SSH tasks
Replaces all `plink.exe -m <script>` invocations. Uses `Paramiko` (pure Python SSH).

| PS plink script | Python equivalent |
|---|---|
| `echo y \| plink ... exit` | `paramiko.AutoAddPolicy()` — auto-accepts host key |
| `esxishell-tls-profile-get.txt` | `_CMD_TLS_GET` = `esxcli system tls server get` |
| `esxishell-tls-profile-update.txt` | `_CMD_TLS_SET` = `esxcli system tls server set --profile NIST_2024` |
| `esxishell-set-banner.txt` | `_CMD_BANNER_SET` = `esxcli system settings advanced set ...` |

### `upgrade_engine.py` — Per-host upgrade orchestrator
The Python equivalent of the `$ESXiUpgrade` scriptblock.

**Phase 0 — Pre-flight**
- Connects to vCenter
- Takes NIC + HBA snapshots (for health checks later)
- Gets hardware vendor and model
- Checks DRS overrides and cluster DRS level

**Phase 1 — Maintenance mode + alarm disable**
- Calls `enter_maintenance_mode()` with full task polling
- Disables alarm actions on the host

**Phase 2 — Firmware upgrade (Option 1 or 4)**
- Validates iDRAC reachability
- Runs up to 2 iterations of: compliance-check → upload binaries → reboot
- Staggers uploads randomly (30-90s) to avoid iDRAC overload
- Final read-only compliance check after all iterations
- Writes failed component list to a text file if any remain non-compliant

**Phase 3 — ESXi version upgrade (Option 2 or 4)**
- Checks current build — skips if already at target
- Selects OEM bundle based on vendor (Dell/Lenovo/HP)
- Runs `esxcli software profile update` via pyVmomi
- Reboots and validates build number
- Assigns license key
- Checks/reinstalls FDM VIB

**Phase 4 — Post-upgrade tasks (Option 3 or 4)**
- Waits 5 min (same as PS)
- SSHes in, checks TLS profile
- Sets NIST_2024 if needed, sets banner
- Reboots if TLS profile change requires it
- Validates TLS profile post-reboot

**Phase 5 — Health checks**
- Compares NIC count/speed/duplex before vs after
- Compares HBA count/status before vs after
- Logs summary table
- **Host intentionally left in Maintenance Mode** — same policy as original

---

## Differences from the PowerShell Script

| Area | PowerShell | Python |
|---|---|---|
| Parallelism | `Start-Job` per host | `ThreadPoolExecutor` with configurable `max_workers` |
| UI | WinForms dialogs | CLI args + YAML config (CI/CD friendly) |
| SSH | `plink.exe` (Windows binary) | `Paramiko` (cross-platform) |
| vSphere API | PowerCLI | `pyVmomi` |
| SSL ignore | `Ignore-SSLCertificates` (C# compiled inline) | `urllib3.disable_warnings` + `verify=False` |
| Credentials | Encrypted XML (`Export-Clixml`) | YAML config or env vars |
| OME (Dell OpenManage Enterprise) | Used for device discovery | **Removed** — iDRAC IP read directly from ESXi IPMI config via vSphere API |
| Broadcom NIC firmware | In-band via plink + niccli/bnxtnet | **Not included** — add as a separate SSH task if needed |

---

## Quick Start

```bash
# 1. Install dependencies
pip install -r requirements.txt

# 2. Copy and edit the config file
cp config.yaml.example config.yaml
vi config.yaml

# 3. Dry run first — validates connectivity without making changes
python main.py --config config.yaml --dry-run

# 4. Full upgrade (all 4 phases)
python main.py --config config.yaml --upgrade-option 4

# 5. Firmware only, 2 hosts in parallel
python main.py --config config.yaml --upgrade-option 1 --max-workers 2

# 6. CI/CD pipeline — all params on CLI, no prompts
python main.py \
  --vcenter vc01.corp.local \
  --esxi-hosts esxi01.corp.local,esxi02.corp.local \
  --depcr CHG0012345 \
  --upgrade-option 4 \
  --config config.yaml
```

---

## Firmware Repository Structure

```
/opt/upgrade/Firmware-Binaries/
├── R6525/
│   ├── Baseline0/
│   │   └── iDRAC-with-Lifecycle-Controller_Firmware_7.10.50.00_A00.EXE
│   ├── Baseline1/
│   │   ├── BIOS_2.15.2_A00.EXE
│   │   ├── Backplane_7.10_A00.EXE
│   │   └── ...
│   ├── Baseline2/
│   ├── Baseline3/
│   └── Baseline4/
├── R7425/
├── R6625/
└── R7625/
```

The script matches binaries by checking if the target version string appears in
the filename (`"7.10.50.00" in binary_name`). This mirrors the PS logic
`$fwBinary -like "*$inclHw*"`.
