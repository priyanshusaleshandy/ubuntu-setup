"""
Push a user (enrollNumber + name) to a BioMax device by calling SmartOffice's
own vendor DLL (FK623Attend.dll) through Wine on the Mac Mini (192.168.126.101).
No custom wire-protocol/checksum needed, and no dependency on the SmartOffice
Windows PC (.188) being online - this is a fully independent, self-contained
path: a small compiled Windows console program (fk_push.exe) runs under Wine
and calls the DLL's official exported functions directly.
"""
import subprocess
import re

MAC_HOST = "admin@192.168.126.101"
WINE_BINARY = "/Users/admin/wine-setup/Wine Devel.app/Contents/Resources/wine/bin/wine"
WINEPREFIX = "/Users/admin/biomax-push/wineprefix"
WORKDIR = "/Users/admin/biomax-push"


def _sq(s):
    """Safely single-quote a value for the remote (bash/zsh) shell."""
    return "'" + s.replace("'", "'\\''") + "'"


def push_user(device_ip, enroll_number, user_name, timeout=30):
    """Push a user (enrollNumber + name) to a device via FK623Attend.dll under Wine.
    Returns a dict describing what happened."""
    if not re.match(r"^[A-Za-z0-9_/\-]{1,20}$", enroll_number):
        return {"success": False, "error": "Invalid enrollNumber format"}
    if not user_name or len(user_name) > 100:
        return {"success": False, "error": "Invalid name"}

    remote_cmd = (
        f"cd {_sq(WORKDIR)} && "
        f"WINEPREFIX={_sq(WINEPREFIX)} WINEDEBUG=-all "
        f"{_sq(WINE_BINARY)} fk_push.exe {_sq(device_ip)} {_sq(enroll_number)} {_sq(user_name)}"
    )

    try:
        result = subprocess.run(
            ["ssh", "-o", "ConnectTimeout=10", MAC_HOST, remote_cmd],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return {"success": False, "error": "Timed out talking to the push host (Mac Mini)"}

    output = result.stdout
    connect_ok = "CONNECT 1" in output
    setname_ok = "SETNAME 1" in output
    enable_ok = len(re.findall(r"ENABLE \d+ 1", output)) == 13

    return {
        "success": connect_ok and setname_ok and enable_ok,
        "connect_ok": connect_ok,
        "setname_ok": setname_ok,
        "enable_ok": enable_ok,
        "raw_output": output,
        "stderr": result.stderr,
    }


def delete_user(device_ip, enroll_number, timeout=30):
    """Delete a user's enrollment data (fingerprint templates) from a device
    via FK623Attend.dll under Wine. Returns a dict describing what happened."""
    if not re.match(r"^[A-Za-z0-9_/\-]{1,20}$", enroll_number):
        return {"success": False, "error": "Invalid enrollNumber format"}

    remote_cmd = (
        f"cd {_sq(WORKDIR)} && "
        f"WINEPREFIX={_sq(WINEPREFIX)} WINEDEBUG=-all "
        f"{_sq(WINE_BINARY)} fk_delete.exe {_sq(device_ip)} {_sq(enroll_number)}"
    )

    try:
        result = subprocess.run(
            ["ssh", "-o", "ConnectTimeout=10", MAC_HOST, remote_cmd],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return {"success": False, "error": "Timed out talking to the push host (Mac Mini)"}

    output = result.stdout
    connect_ok = "CONNECT 1" in output
    # at least one backup slot actually had data and was deleted (others legitimately
    # come back -6 "no data at this slot", which is normal for name-only entries)
    any_deleted = len(re.findall(r"DELETE \d+ 1", output)) > 0
    # covers users who were never physically fingerprint-enrolled (console-created,
    # ID+name only): nothing to erase biometrically, so we disable + blank their name
    name_cleared = "CLEARNAME 1" in output

    return {
        "success": connect_ok and (any_deleted or name_cleared),
        "connect_ok": connect_ok,
        "any_deleted": any_deleted,
        "name_cleared": name_cleared,
        "raw_output": output,
        "stderr": result.stderr,
    }


def list_device_users(device_ip, timeout=60):
    """Enumerate every user actually enrolled ON THE DEVICE (source of truth,
    not our synced SmartOffice snapshot). Read-only, safe. Returns a dict with
    success + a list of {code, name, backup_number, privilege, enabled}."""
    remote_cmd = (
        f"cd {_sq(WORKDIR)} && "
        f"WINEPREFIX={_sq(WINEPREFIX)} WINEDEBUG=-all "
        f"{_sq(WINE_BINARY)} fk_listusers.exe {_sq(device_ip)}"
    )
    try:
        result = subprocess.run(
            ["ssh", "-o", "ConnectTimeout=10", MAC_HOST, remote_cmd],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return {"success": False, "error": "Timed out talking to the push host (Mac Mini)", "users": []}

    output = result.stdout
    if "CONNECT 1" not in output:
        return {"success": False, "error": "Could not connect to device", "users": [], "raw_output": output}

    users = []
    for line in output.splitlines():
        if not line.startswith("USER|"):
            continue
        parts = line.split("|")
        if len(parts) != 6:
            continue
        _, code, name, backup, privilege, enabled = parts
        users.append({
            "code": code,
            "name": name,
            "backup_number": backup,
            "privilege": privilege,
            "enabled": enabled,
        })

    return {"success": True, "users": users, "raw_output": output}


_VERIFY_MODE_LABELS = {
    1: "fingerprint", 2: "password", 3: "card",
    4: "password+fingerprint", 5: "card+fingerprint",
    6: "fingerprint+password", 7: "fingerprint+card",
    10: "door-open", 11: "door-close", 12: "door-open-key", 13: "door-open-threat",
    14: "door-open-remote", 15: "door-close-remote", 16: "door-open-illegal", 17: "door-close-illegal",
    18: "cover-open", 19: "cover-close",
}
_IN_OUT_LABELS = {0: "in", 1: "out", 2: "io"}


def list_device_logs(device_ip, read_mark=0, timeout=120):
    """Pull attendance logs directly from the device (bypasses SmartOffice
    entirely). read_mark=0 reads every record currently on the device;
    read_mark=1 reads only what's new since the device's own internal mark
    (fragile if something else also reads/clears it - the console always
    uses read_mark=0 and dedups on our side instead). Read-only, safe.
    Returns a dict with success + a list of
    {enroll_number, verify_mode, direction, log_date (YYYY-MM-DD HH:MM:SS)}."""
    remote_cmd = (
        f"cd {_sq(WORKDIR)} && "
        f"WINEPREFIX={_sq(WINEPREFIX)} WINEDEBUG=-all "
        f"{_sq(WINE_BINARY)} fk_getlogs.exe {_sq(device_ip)} {read_mark}"
    )
    try:
        result = subprocess.run(
            ["ssh", "-o", "ConnectTimeout=10", MAC_HOST, remote_cmd],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return {"success": False, "error": "Timed out talking to the push host (Mac Mini)", "logs": []}

    output = result.stdout
    if "CONNECT 1" not in output:
        return {"success": False, "error": "Could not connect to device", "logs": [], "raw_output": output}

    logs = []
    for line in output.splitlines():
        if not line.startswith("LOG|"):
            continue
        # format: LOG|enrollNumber|verifyMode|inOutMode|YYYY-MM-DD HH:MM:SS
        parts = line.split("|")
        if len(parts) != 5:
            continue
        _, enroll_number, verify_mode, io_mode, log_date = parts
        try:
            verify_mode_i = int(verify_mode)
            io_mode_i = int(io_mode)
        except ValueError:
            continue
        logs.append({
            "enroll_number": enroll_number,
            "verify_mode": _VERIFY_MODE_LABELS.get(verify_mode_i, verify_mode),
            "direction": _IN_OUT_LABELS.get(io_mode_i, io_mode),
            "log_date": log_date,
        })

    return {"success": True, "logs": logs, "raw_output": output}


def copy_fingerprint(source_ip, target_ip, enroll_number, name=None, timeout=60):
    """Copy a person's enrolled fingerprint(s) from one device to another via
    FK623Attend.dll, so they don't have to physically re-enroll at every
    device. Uses the _StringID enrollment-data functions - the plain numeric
    FK_GetEnrollData/FK_PutEnrollData return RUNERR_NOSUPPORT on this device
    (same pattern as StringID being required for user-management but not for
    logs). Reads every non-empty backup slot (0-9, i.e. up to 10 fingers) off
    the source and writes them onto the target under the same enrollNumber.
    Confirmed via round-trip test that a written-then-read-back template comes
    back ~98% byte-identical (the small diff is localized to one region,
    consistent with an internal checksum/metadata field, not corruption) -
    but this only verifies the API round-trip, not an actual physical finger
    match, which can't be checked remotely.

    Also pushes the person's name to the target (via push_user, same as
    Create User) - the enrollment-data functions only move the biometric
    template, not identity, so without this the copied fingerprint would sit
    on the target under a blank/"-" name. Best-effort: if no name is found,
    or the name-push fails, the fingerprint copy itself still counts as
    successful - that's the main ask.

    Every Wine invocation has a fixed ~4.6s cold-start cost (measured) on top
    of the actual work, so each extra one is expensive. Pass `name` in
    directly (e.g. from the caller's own cached DB) to skip a whole separate
    live lookup call - if not given, falls back to querying the source
    device's live user list (slower, but correct even for someone enrolled
    by walking up to a device directly, who won't be in any local cache).

    Returns a dict describing what happened."""
    if not re.match(r"^[A-Za-z0-9_/\-]{1,20}$", enroll_number):
        return {"success": False, "error": "Invalid enrollNumber format"}

    if name == "-":
        name = None
    if name is None:
        users_result = list_device_users(source_ip)
        if users_result["success"]:
            match = next((u for u in users_result["users"] if u["code"] == enroll_number), None)
            if match and match["name"] and match["name"] != "-":
                name = match["name"]

    remote_cmd = (
        f"cd {_sq(WORKDIR)} && "
        f"WINEPREFIX={_sq(WINEPREFIX)} WINEDEBUG=-all "
        f"{_sq(WINE_BINARY)} fk_copyenroll.exe {_sq(source_ip)} {_sq(target_ip)} {_sq(enroll_number)}"
    )

    try:
        result = subprocess.run(
            ["ssh", "-o", "ConnectTimeout=10", MAC_HOST, remote_cmd],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return {"success": False, "error": "Timed out talking to the push host (Mac Mini)"}

    output = result.stdout
    src_connect_ok = "SRC_CONNECT 1" in output
    dst_connect_ok = "DST_CONNECT 1" in output
    slots_found = len(re.findall(r"SRC_SLOT\|", output))
    total_copied_match = re.search(r"TOTAL_COPIED (\d+)", output)
    total_copied = int(total_copied_match.group(1)) if total_copied_match else 0
    fingerprint_ok = src_connect_ok and dst_connect_ok and total_copied > 0 and total_copied == slots_found

    name_pushed = False
    if fingerprint_ok and name:
        name_result = push_user(target_ip, enroll_number, name)
        name_pushed = name_result["success"]

    if not src_connect_ok:
        error = "Could not connect to source device"
    elif "NO_DATA_FOUND" in output:
        error = "No fingerprint enrolled for this ID on the source device"
    elif not dst_connect_ok:
        error = "Could not connect to target device"
    elif total_copied < slots_found:
        error = f"Only {total_copied}/{slots_found} finger(s) copied successfully"
    elif name and not name_pushed:
        error = f"Fingerprint copied OK, but couldn't set the name (\"{name}\") on the target — will show blank until fixed"
    else:
        error = None

    return {
        # fingerprint working is the main ask, but if we found a name on the
        # source and failed to also set it on the target, don't call it a
        # clean success - that's exactly the "blank name" gap this was meant
        # to close, and it should surface as a visible warning, not silently.
        "success": fingerprint_ok and (not name or name_pushed),
        "slots_found": slots_found,
        "total_copied": total_copied,
        "name": name,
        "name_pushed": name_pushed,
        "error": error,
        "raw_output": output,
        "stderr": result.stderr,
    }
