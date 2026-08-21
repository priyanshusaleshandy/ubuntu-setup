#!/usr/bin/env python3
"""
Auto-syncs newly-enrolled fingerprints across all BioMax devices.

When someone's finger gets physically enrolled at any one device, this
notices (by polling each device's live user list) and copies that same
person's name + fingerprint to the other devices automatically - no need
to walk them around to every device, or manually click Copy Fingerprint.

Deliberately a SEPARATE process/service from biomax_sync.py (attendance
logs) - this only ever touches enrollment/identity via its own table
(fingerprint_seen), never the attendance table. A bug here can't bleed
into log sync, and vice versa.

Trigger is "brand new (device, employee_code) pair I've never seen before" -
NOT an ongoing reconciliation. Once a pair is marked seen, it's never
revisited: if someone is later deleted from a device on purpose, this
will not silently re-add them. On first ever run, every currently-enrolled
person is bootstrapped as already-seen so it doesn't replay the whole
existing workforce as a flood of "new" events - only genuinely new
enrollments from that point on ever fire a copy.
"""
import sqlite3
import os
import subprocess
import datetime
import time

from device_push import list_device_users, copy_fingerprint

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DB_FILE = os.path.join(BASE_DIR, "biomax.db")
POLL_INTERVAL_SECONDS = 5 * 60  # matches biomax_sync.py's cadence

SCHEMA = """
CREATE TABLE IF NOT EXISTS fingerprint_seen (
    device_id TEXT,
    employee_code TEXT,
    first_seen_at TEXT,
    PRIMARY KEY (device_id, employee_code)
);
"""


def get_db():
    conn = sqlite3.connect(DB_FILE, timeout=10.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.executescript(SCHEMA)
    return conn


def ping_ok(ip):
    try:
        r = subprocess.run(["ping", "-c", "1", "-W", "3", ip], capture_output=True, timeout=6)
        return r.returncode == 0
    except Exception:
        return False


def mark_seen(conn, device_id, code, now):
    conn.execute(
        "INSERT OR IGNORE INTO fingerprint_seen (device_id, employee_code, first_seen_at) VALUES (?, ?, ?)",
        (device_id, code, now),
    )


def bootstrap_if_needed(conn):
    """First ever run only: mark everyone currently live on each device as
    already-seen, so this only reacts to genuinely new enrollments from here
    on, not the entire pre-existing workforce."""
    count = conn.execute("SELECT COUNT(*) FROM fingerprint_seen").fetchone()[0]
    if count > 0:
        return False
    devices = conn.execute("SELECT * FROM devices ORDER BY name").fetchall()
    now = datetime.datetime.now().isoformat()
    for device in devices:
        if not ping_ok(device["ip_address"]):
            continue
        result = list_device_users(device["ip_address"])
        if not result["success"]:
            continue
        for u in result["users"]:
            mark_seen(conn, device["device_id"], u["code"], now)
    conn.commit()
    return True


def autosync_once(conn):
    """Poll every device's live user list. For any (device, code) pair never
    seen before, copy that person's current fingerprint(s) + name onto every
    other device that doesn't already have them, then mark all of them seen
    so this doesn't re-trigger. Returns how many propagations happened."""
    devices = conn.execute("SELECT * FROM devices ORDER BY name").fetchall()
    now = datetime.datetime.now().isoformat()
    propagated = 0

    live_by_device = {}
    for device in devices:
        if not ping_ok(device["ip_address"]):
            continue
        result = list_device_users(device["ip_address"])
        if result["success"]:
            live_by_device[device["device_id"]] = {u["code"] for u in result["users"]}

    already_seen = {
        (row["device_id"], row["employee_code"])
        for row in conn.execute("SELECT device_id, employee_code FROM fingerprint_seen")
    }

    for device in devices:
        codes = live_by_device.get(device["device_id"])
        if codes is None:
            continue
        for code in codes:
            if (device["device_id"], code) in already_seen:
                continue

            for target in devices:
                if target["device_id"] == device["device_id"]:
                    continue
                target_codes = live_by_device.get(target["device_id"])
                if target_codes is not None and code in target_codes:
                    mark_seen(conn, target["device_id"], code, now)
                    continue
                if not ping_ok(target["ip_address"]):
                    continue
                r = copy_fingerprint(device["ip_address"], target["ip_address"], code)
                if r.get("success"):
                    mark_seen(conn, target["device_id"], code, now)
                    propagated += 1

            mark_seen(conn, device["device_id"], code, now)
            conn.commit()

    return propagated


if __name__ == "__main__":
    conn = get_db()
    if bootstrap_if_needed(conn):
        print(f"[{datetime.datetime.now().isoformat()}] bootstrap: existing enrollments marked as already-seen")
    while True:
        try:
            n = autosync_once(conn)
            print(f"[{datetime.datetime.now().isoformat()}] autosync: {n} propagation(s)")
        except Exception as e:
            print(f"[{datetime.datetime.now().isoformat()}] ERROR: {e}")
        time.sleep(POLL_INTERVAL_SECONDS)
