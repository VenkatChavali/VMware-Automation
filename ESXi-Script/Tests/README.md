# Test Files — How to Use

Run from the **project root directory** (not from inside the tests/ folder):

```bash
cd /opt/upgrade    # or wherever your project is
python tests/test_01_models_and_baselines.py
```

---

## Test Order — Start Here

### Step 1 — No connectivity needed (run these first)
```bash
python tests/test_01_models_and_baselines.py
python tests/test_02_logger.py
```
These test pure Python logic — no vCenter, no iDRAC, no network.
If these fail something is wrong with your Python installation or file paths.

---

### Step 2 — iDRAC connectivity (fill in CONFIG at top of file first)
```bash
python tests/test_03_redfish_client.py
```
Choose option `1` first (connectivity check).
If that passes, try option `2` (get firmware inventory) — this is read-only and
tells you exactly what firmware versions are installed right now on your host.

---

### Step 3 — vCenter + ESXi connectivity (fill in CONFIG first)
```bash
python tests/test_04_vsphere_client.py
```
Choose option `a` to run all read-only tests.
This validates:
  - vCenter connection
  - Host found in vCenter
  - iDRAC IP retrieved
  - NIC/HBA snapshots work
  - DRS state is correct
  - SSH into ESXi works
  - esxcli commands run

---

### Step 4 — Full end-to-end dry-run (fill in CONFIG first)
```bash
python tests/test_05_upgrade_engine_dryrun.py
```
Choose option `1` — runs every phase of the upgrade engine with dry_run=True.
Zero changes made. Shows you exactly what the script would do.

**Run this on every host before the first real upgrade.**

---

## What each test file covers

| File | What it tests | Network needed |
|------|---------------|----------------|
| test_01_models_and_baselines.py | Data structures, baseline tables, disk version resolver | No |
| test_02_logger.py | Log file creation, hostname prefixing, multiple hosts | No |
| test_03_redfish_client.py | iDRAC session, firmware inventory, job queue, upload | iDRAC only |
| test_04_vsphere_client.py | vCenter connect, host info, NIC/HBA, DRS, SSH, esxcli | vCenter + ESXi |
| test_05_upgrade_engine_dryrun.py | Full upgrade flow, dry-run mode | vCenter + iDRAC + ESXi |

---

## Safe vs changes

**Always safe (read-only):**
- test_01, test_02 — no network at all
- test_03 options 1, 2, 3, 6 — reads from iDRAC only
- test_04 options 1-8, 10 — reads from vCenter/ESXi
- test_05 option 1 (dry-run) — reads everything, changes nothing

**Makes reversible changes:**
- test_04 option 9 — disables then immediately re-enables alarms

**Makes real changes (test/MM host only):**
- test_03 options 4, 5 — clears job queue, uploads firmware
- test_04 option 11 — maintenance mode enter/exit

---

## Filling in CONFIG

Each test file has a CONFIG section at the top:

```python
# ─────────────────────────────────────────────────────────────────────────────
# CONFIG — fill these in before running
# ─────────────────────────────────────────────────────────────────────────────
VCENTER        = "vc01g.corp.local"
VC_USER        = "administrator@vsphere.local"
VC_PASS        = "YourVCPassword"
...
```

Just edit the values directly in the file before running.
