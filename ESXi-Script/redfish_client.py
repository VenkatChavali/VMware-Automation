# -*- coding: utf-8 -*-
"""
redfish_client.py
Exact Python equivalent of all three PowerShell iDRAC modules.
Flow is derived directly from the actual PS module source code.

+-------------------------------------------------------------------------+
|  PS Module                               |  Python method               |
+-------------------------------------------------------------------------+
|  Get-IdracFirmwareVersionREDFISH         -> get_firmware_inventory()     |
|  Set-DeviceFirmwareSimpleUpdateREDFISH   -> upload_and_stage_firmware()  |
|  Invoke-IdracJobQueueManagementREDFISH   -> clear_job_queue_restart_lc() |
+-------------------------------------------------------------------------+

SSL verification is disabled for self-signed iDRAC certs -- same as the
Ignore-SSLCertificates helper compiled inline in the PS modules.
"""

import time
import urllib3
from pathlib import Path

import requests
from requests.auth import HTTPBasicAuth

from logger import HostLogger
from models import FirmwareInventoryItem

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# -- Redfish endpoints -- derived directly from PS module source -------------
_SESSIONS              = "/redfish/v1/Sessions"
_FW_INVENTORY          = "/redfish/v1/UpdateService/FirmwareInventory"
_SIMPLE_UPDATE_ACTION  = "/redfish/v1/UpdateService/Actions/UpdateService.SimpleUpdate"
_TASK_SERVICE          = "/redfish/v1/TaskService/Tasks"
_JOB_COLLECTION        = "/redfish/v1/Managers/iDRAC.Embedded.1/Jobs"
_DELL_JOB_SERVICE      = (
    "/redfish/v1/Dell/Managers/iDRAC.Embedded.1"
    "/DellJobService/Actions/DellJobService.DeleteJobQueue"
)
_DELL_LC_STATUS        = (
    "/redfish/v1/Dell/Managers/iDRAC.Embedded.1"
    "/DellLCService/Actions/DellLCService.GetRemoteServicesAPIStatus"
)

# -- Timing constants -------------------------------------------------------
_DEFAULT_TIMEOUT    = 120    # per-request timeout (seconds)
_INVENTORY_RETRY    = 60     # wait before retrying inventory fetch
_UPLOAD_TIMEOUT     = 600    # firmware binary upload can take a while
_TASK_POLL_SLEEP    = 5      # mirrors PS "Start-Sleep 5" in task poll loop
_TASK_STAGE_TIMEOUT = 30     # minutes -- mirrors PS "AddMinutes(30)" for staging
_LC_POLL_SLEEP      = 10     # mirrors PS "Start-Sleep 10" in LC ready poll
_LC_MAX_POLLS       = 30     # mirrors PS "$count -eq 30" check

# -- Messages that indicate a staged/scheduled job (not yet complete) ------
_SCHEDULED_MSGS = {"Task successfully scheduled."}

# -- Messages that indicate immediate success -------------------------------
_SUCCESS_MSGS = {
    "The specified job has completed successfully.",
    "Job completed successfully.",
}

# -- Error keywords in job messages (mirrors PS Contains() checks) ----------
_FAIL_KEYWORDS = {
    "Lifecycle Controller in use", "Fail", "Failed", "fail", "failed",
    "Job for this device is already present", "Unable", "unable",
}

# -- The "not applicable" error text -- silently skip this binary ------------
_NOT_APPLICABLE_UPGRADE = (
    "Unable to complete the firmware upgrade operation because the specified "
    "firmware image is for a component that is not in the target system inventory "
    "or the component is disabled for performing the upgrade."
)
_NOT_APPLICABLE_UPDATE = (
    "Unable to complete the firmware update operation because the specified "
    "firmware image is for a component that is not in the target system inventory "
    "or the component is disabled for performing the update."
)


class RedfishClient:
    """
    Stateful Redfish client for a single iDRAC IP.
    Manages an X-Auth-Token session (same as PS modules).
    One instance per host per upgrade run.

    Usage (preferred -- auto session management):
        with RedfishClient(ip, user, pw, logger) as rf:
            inventory = rf.get_firmware_inventory()
            job_id    = rf.upload_and_stage_firmware(path)
            rf.wait_for_task(job_id)
            rf.clear_job_queue_restart_lc()
    """

    def __init__(
        self,
        idrac_ip: str,
        username: str,
        password: str,
        logger: HostLogger,
        timeout: int = _DEFAULT_TIMEOUT,
    ) -> None:
        self.idrac_ip   = idrac_ip
        self.base_url   = f"https://{idrac_ip}"
        self._username  = username
        self._password  = password
        self._logger    = logger
        self._timeout   = timeout

        self._session   = requests.Session()
        self._session.verify = False          # mirrors Ignore-SSLCertificates
        self._session.auth   = HTTPBasicAuth(username, password)  # fallback

        self._token: str | None     = None
        self._location: str | None  = None

    # ---------------------------------------------------------
    # Context manager -- auto-creates + destroys Redfish session
    # ---------------------------------------------------------

    def __enter__(self) -> "RedfishClient":
        self._create_session()
        return self

    def __exit__(self, *_) -> None:
        self._delete_session()

    # ---------------------------------------------------------
    # Session management
    # Mirrors: POST /redfish/v1/Sessions in Get-IdracFirmwareVersionREDFISH
    # ---------------------------------------------------------

    def _create_session(self) -> None:
        """
        Create an authenticated Redfish session and store the X-Auth-Token.
        Mirrors the POST /redfish/v1/Sessions call at the top of
        Get-IdracFirmwareVersionREDFISH.
        """
        body = {"UserName": self._username, "Password": self._password}
        try:
            resp = self._session.post(
                self.base_url + _SESSIONS,
                json=body,
                headers={"Accept": "application/json"},
                timeout=self._timeout,
            )
            resp.raise_for_status()
            self._token    = resp.headers.get("X-Auth-Token")
            self._location = resp.headers.get("Location", "")
            # Inject token into all subsequent requests
            self._session.headers.update({"X-Auth-Token": self._token})
            self._session.auth = None   # token supersedes basic auth
            self._logger.info(f"Redfish session created on iDRAC {self.idrac_ip}")
        except Exception as exc:
            self._logger.warning(
                f"Could not create Redfish session on {self.idrac_ip}, "
                f"falling back to basic auth: {exc}"
            )

    def _delete_session(self) -> None:
        """Delete the Redfish session on cleanup."""
        if self._location:
            try:
                url = (
                    self.base_url + self._location
                    if self._location.startswith("/")
                    else self._location
                )
                self._session.delete(url, timeout=self._timeout)
                self._logger.info("Redfish session closed")
            except Exception:
                pass

    # ---------------------------------------------------------
    # PUBLIC API
    # ---------------------------------------------------------

    def get_firmware_inventory(self, retries: int = 2) -> list[FirmwareInventoryItem]:
        """
        Replaces: Get-IdracFirmwareVersionREDFISH

        Exact flow from PS source:
          1. GET /redfish/v1/UpdateService/FirmwareInventory/
          2. Filter members where @odata.id contains 'Installed'
             (mirrors: $firmware_url | Where-Object { $_.'@odata.id' -match 'Installed' })
          3. GET each member URL -> extract Name, Id, Version into DataTable rows

        Retries once after 60s on failure (mirrors the PS retry pattern).
        """
        for attempt in range(1, retries + 1):
            try:
                resp_data   = self._get(_FW_INVENTORY + "/")
                all_members = resp_data.get("Members", [])

                # Mirror PS filter: only 'Installed' entries
                installed_urls = [
                    m["@odata.id"]
                    for m in all_members
                    if "Installed" in m.get("@odata.id", "")
                ]

                self._logger.info(
                    f"Firmware inventory: {len(all_members)} total, "
                    f"{len(installed_urls)} Installed"
                )

                inventory: list[FirmwareInventoryItem] = []
                for url in installed_urls:
                    try:
                        item = self._get(url)
                        inventory.append(FirmwareInventoryItem(
                            name      = item.get("Name", ""),
                            version   = item.get("Version", ""),
                            updateable= item.get("Updateable", True),
                        ))
                    except Exception as exc:
                        self._logger.warning(
                            f"Skipping inventory item {url}: {exc}"
                        )

                self._logger.info(
                    f"Retrieved {len(inventory)} installed firmware components"
                )
                return inventory

            except Exception as exc:
                self._logger.warning(
                    f"Inventory fetch attempt {attempt}/{retries} failed: {exc}"
                )
                if attempt < retries:
                    self._logger.info(f"Retrying in {_INVENTORY_RETRY}s ...")
                    time.sleep(_INVENTORY_RETRY)

        raise RuntimeError(
            f"Cannot get firmware inventory from {self.idrac_ip} "
            f"after {retries} attempts"
        )

    def upload_and_stage_firmware(
        self,
        binary_path: Path,
        dry_run: bool = False,
    ) -> str | None:
        """
        Replaces: Set-DeviceFirmwareSimpleUpdateREDFISH  (-reboot_server n)

        Exact two-step flow from PS source:

        STEP 1 -- download_image_payload():
          * GET ETag from /redfish/v1/UpdateService/FirmwareInventory
          * POST binary as multipart/form-data (Content-Type: multipart/form-data)
            to /redfish/v1/UpdateService/FirmwareInventory
          * Response 201 -> Location header = "/redfish/v1/UpdateService/FirmwareInventory/Available-XXX"

        STEP 2 -- install_image_payload_query_job_status_reboot_server():
          * POST {"ImageURI": "<base_url><available_entry>"} to
            /redfish/v1/UpdateService/Actions/UpdateService.SimpleUpdate
          * Response 202 -> Location header -> Job ID
          * Poll /redfish/v1/TaskService/Tasks/<job_id> until scheduled or complete

        Returns Job ID string, or None if binary is not applicable to this hw.
        Raises RuntimeError on genuine failures.
        """
        if dry_run:
            self._logger.info(f"[DRY-RUN] Would upload and stage: {binary_path.name}")
            return "DRY-RUN-JOB"

        # -- STEP 1: Upload binary to iDRAC staging --
        self._logger.info(f"Uploading firmware binary: {binary_path.name}")

        etag = self._get_etag(_FW_INVENTORY)
        headers = {"Accept": "application/json"}
        if etag:
            headers["If-Match"] = etag

        with open(binary_path, "rb") as fh:
            files = {"file": (binary_path.name, fh, "application/octet-stream")}
            try:
                upload_resp = self._session.post(
                    self.base_url + _FW_INVENTORY,
                    files=files,
                    headers=headers,
                    timeout=_UPLOAD_TIMEOUT,
                )
            except requests.RequestException as exc:
                raise RuntimeError(
                    f"Network error uploading {binary_path.name}: {exc}"
                ) from exc

        if upload_resp.status_code == 201:
            available_entry = upload_resp.headers.get("Location", "")
            self._logger.info(
                f"Binary staged (HTTP 201) -> Available entry: {available_entry}"
            )
        else:
            err_msg = self._extract_error(upload_resp)
            if self._is_not_applicable(err_msg):
                self._logger.info(
                    f"  Skipping {binary_path.name}: "
                    f"component not in inventory or disabled on this server"
                )
                return None
            raise RuntimeError(
                f"Upload of {binary_path.name} failed "
                f"(HTTP {upload_resp.status_code}): {err_msg}"
            )

        # -- STEP 2: Trigger SimpleUpdate with Available entry URI --
        # Mirrors PS: $JsonBody = @{'ImageURI'= $image_uri} -> POST SimpleUpdate
        image_uri = (
            self.base_url + available_entry
            if available_entry.startswith("/")
            else available_entry
        )
        body = {"ImageURI": image_uri}
        self._logger.info(f"Calling SimpleUpdate for: {available_entry}")

        try:
            update_resp = self._session.post(
                self.base_url + _SIMPLE_UPDATE_ACTION,
                json=body,
                headers={"Accept": "application/json", "Content-Type": "application/json"},
                timeout=self._timeout,
            )
        except requests.RequestException as exc:
            raise RuntimeError(
                f"SimpleUpdate POST failed for {binary_path.name}: {exc}"
            ) from exc

        if update_resp.status_code == 202:
            location = update_resp.headers.get("Location", "")
            job_id   = location.split("/")[-1] if location else "UNKNOWN"
            self._logger.info(
                f"Update job created (HTTP 202) -> Job ID: {job_id} OK"
            )
            return job_id
        else:
            err_msg = self._extract_error(update_resp)
            if self._is_not_applicable(err_msg):
                self._logger.info(
                    f"  Skipping {binary_path.name}: "
                    f"component not in inventory or disabled on this server"
                )
                return None
            raise RuntimeError(
                f"SimpleUpdate rejected for {binary_path.name} "
                f"(HTTP {update_resp.status_code}): {err_msg}"
            )

    def wait_for_task(
        self,
        job_id: str,
        timeout_min: int = _TASK_STAGE_TIMEOUT,
    ) -> bool:
        """
        Replaces: The job polling loop in install_image_payload_query_job_status_reboot_server
                  (the first polling loop -- staging, before reboot)

        Polls /redfish/v1/TaskService/Tasks/<job_id> every 5 seconds.
        Mirrors PS loop with -reboot_server n:
          * "Task successfully scheduled." -> done (will apply on next reboot)
          * "completed" / success message  -> done (immediate update)
          * any fail keyword               -> failure
          * timeout (30 min default)       -> failure
        """
        if job_id in (None, "DRY-RUN-JOB", "UNKNOWN"):
            return True

        task_url = f"{_TASK_SERVICE}/{job_id}"
        deadline = time.time() + (timeout_min * 60)
        self._logger.info(
            f"Polling task {job_id} (timeout {timeout_min} min) ..."
        )

        while time.time() < deadline:
            try:
                task    = self._get(task_url)
                state   = task.get("TaskState", "")
                msgs    = task.get("Messages", [])
                message = msgs[0].get("Message", "") if msgs else ""

                self._logger.info(
                    f"  Task {job_id}: State={state}  |  {message}"
                )

                # -- Fail check --
                if any(kw in message for kw in _FAIL_KEYWORDS):
                    self._logger.error(
                        f"Task {job_id} failed: {message}"
                    )
                    return False

                # -- Scheduled -> staged, will apply on next reboot --
                if message in _SCHEDULED_MSGS:
                    self._logger.info(
                        f"Task {job_id} scheduled -- will apply on next host reboot OK"
                    )
                    return True

                # -- Immediate completion (e.g. iDRAC self-update) --
                if (
                    message in _SUCCESS_MSGS
                    or "complete" in message.lower()
                    or state == "Completed"
                ):
                    self._logger.info(f"Task {job_id} completed OK")
                    return True

                # -- UserIntervention at 100% --
                if state == "UserIntervention" and task.get("PercentComplete", 0) == 100:
                    self._logger.warning(
                        f"Task {job_id} at 100% with UserIntervention: {message}"
                    )
                    return True

            except Exception as exc:
                self._logger.warning(f"Task poll error for {job_id}: {exc}")

            time.sleep(_TASK_POLL_SLEEP)

        self._logger.error(
            f"Task {job_id} timed out after {timeout_min} minutes"
        )
        return False

    def clear_job_queue_restart_lc(self, dry_run: bool = False) -> bool:
        """
        Replaces: Invoke-IdracJobQueueManagementREDFISH
                  with -delete_job_queue_restart_LC_services y

        Exact flow from PS source:
          1. POST {"JobID": "JID_CLEARALL_FORCE"}
             -> /redfish/v1/Dell/Managers/iDRAC.Embedded.1/DellJobService/Actions/DellJobService.DeleteJobQueue
          2. Poll DellLCService.GetRemoteServicesAPIStatus every 10s
             until LCStatus == "Ready" (max 30 polls = 5 min)
          3. GET /redfish/v1/Managers/iDRAC.Embedded.1/Jobs
             verify Members.count == 0
        """
        if dry_run:
            self._logger.info(
                "[DRY-RUN] Would clear iDRAC job queue with JID_CLEARALL_FORCE "
                "and wait for LC Ready"
            )
            return True

        self._logger.info(
            "Clearing iDRAC job queue (JID_CLEARALL_FORCE) + restarting LC ..."
        )

        # -- Step 1: POST JID_CLEARALL_FORCE --
        body = {"JobID": "JID_CLEARALL_FORCE"}
        try:
            resp = self._session.post(
                self.base_url + _DELL_JOB_SERVICE,
                json=body,
                headers={"Accept": "application/json", "Content-Type": "application/json"},
                timeout=self._timeout,
            )
            if resp.status_code == 200:
                self._logger.info(
                    "Job queue clear + LC restart accepted (HTTP 200)"
                )
            else:
                self._logger.warning(
                    f"Job queue clear returned HTTP {resp.status_code}: "
                    f"{resp.text[:200]}"
                )
        except Exception as exc:
            self._logger.warning(f"Job queue clear request error: {exc}")

        # -- Step 2: Poll LC status --
        # Mirrors: Start-Sleep 10 then while ($lc_status -ne "Ready") $count++
        time.sleep(_LC_POLL_SLEEP)
        self._logger.info(
            "Waiting for LC services to return to Ready state ..."
        )
        lc_ready = False

        for poll in range(_LC_MAX_POLLS):
            try:
                resp = self._session.post(
                    self.base_url + _DELL_LC_STATUS,
                    json={},
                    headers={
                        "Accept": "application/json",
                        "Content-Type": "application/json",
                    },
                    timeout=self._timeout,
                )
                if resp.status_code == 200:
                    lc_status = resp.json().get("LCStatus", "")
                    self._logger.info(
                        f"  LC status [{poll + 1}/{_LC_MAX_POLLS}]: {lc_status}"
                    )
                    if lc_status == "Ready":
                        lc_ready = True
                        break
                else:
                    self._logger.warning(
                        f"  LC status poll returned HTTP {resp.status_code}"
                    )
            except Exception as exc:
                self._logger.warning(f"  LC status poll error: {exc}")

            time.sleep(_LC_POLL_SLEEP)

        if not lc_ready:
            self._logger.error(
                f"LC did not reach Ready within "
                f"{_LC_MAX_POLLS * _LC_POLL_SLEEP}s -- "
                f"check iDRAC LC logs"
            )
            return False

        self._logger.info("LC services back in Ready state OK")

        # -- Step 3: Verify job queue empty --
        # Mirrors: GET Jobs -> $get_member_array.count -gt 0 check
        try:
            jobs   = self._get(_JOB_COLLECTION)
            count  = len(jobs.get("Members", []))
            if count == 0:
                self._logger.info("iDRAC job queue is empty OK")
                return True
            else:
                self._logger.warning(
                    f"Job queue still has {count} job(s) -- manually verify"
                )
                return False
        except Exception as exc:
            self._logger.warning(
                f"Could not verify job queue empty: {exc}"
            )
            return True   # LC is Ready, proceed

    def is_reachable(self) -> bool:
        """Quick connectivity check -- GET the Redfish root document."""
        try:
            self._get("/redfish/v1/")
            return True
        except Exception:
            return False

    # ---------------------------------------------------------
    # Internal helpers
    # ---------------------------------------------------------

    def _get(self, path: str) -> dict:
        url = self.base_url + path if path.startswith("/") else path
        resp = self._session.get(
            url,
            headers={"Accept": "application/json"},
            timeout=self._timeout,
        )
        resp.raise_for_status()
        return resp.json()

    def _get_etag(self, path: str) -> str | None:
        """
        GET a URL and return its ETag header value.
        Mirrors PS: $get_result.Headers.ETag used before upload.
        """
        try:
            url  = self.base_url + path if path.startswith("/") else path
            resp = self._session.get(
                url,
                headers={"Accept": "application/json"},
                timeout=self._timeout,
            )
            etag = resp.headers.get("ETag", "")
            return etag.strip('"') if etag else None
        except Exception:
            return None

    def _extract_error(self, resp: requests.Response) -> str:
        """
        Extract error message from @Message.ExtendedInfo.
        Mirrors PS: ConvertFrom-Json -> .Error.("@Message.ExtendedInfo").Message | Select -Unique
        """
        try:
            body     = resp.json()
            ext_info = body.get("error", {}).get("@Message.ExtendedInfo", [])
            if ext_info and isinstance(ext_info, list):
                return ext_info[0].get("Message", resp.text)
        except Exception:
            pass
        return resp.text[:500]

    def _is_not_applicable(self, error_msg: str) -> bool:
        """
        Return True if the error means this binary doesn't apply to this server.
        Mirrors the two specific error string checks in the PS upload loop.
        """
        return (
            _NOT_APPLICABLE_UPGRADE in error_msg
            or _NOT_APPLICABLE_UPDATE in error_msg
        )
