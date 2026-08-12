#!/usr/bin/env python3
"""
BioMax attendance sync tool.

Pulls attendance logs DIRECTLY from each device via FK623Attend.dll (through
Wine on the Mac Mini) into a local SQLite database that the console
(console.py) reads from. No dependency on SmartOffice or the Windows PC it
runs on (.188) - devices and employees are maintained locally: the `devices`
table is seeded once (device IPs rarely change) and `employees` is kept
current by the console's own Create User / Delete User actions.
"""
import sqlite3
import os
import datetime
import subprocess
import time

from device_push import list_device_logs

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DB_FILE = os.path.join(BASE_DIR, "biomax.db")
POLL_INTERVAL_SECONDS = 5 * 60  # 5 minutes

SCHEMA = """
CREATE TABLE IF NOT EXISTS attendance (
    device_log_id INTEGER PRIMARY KEY,
    device_id TEXT,
    user_id TEXT,
    employee_name TEXT,
    employee_status TEXT,
    log_date TEXT,
    direction TEXT,
    verification_mode TEXT,
    synced_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_attendance_user ON attendance(user_id);
CREATE INDEX IF NOT EXISTS idx_attendance_logdate ON attendance(log_date);
-- one real-world punch (device + person + exact timestamp) should only ever
-- land once, no matter how many times we re-pull (we always pull everything
-- and rely on this to dedupe, rather than trusting the device's own fragile
-- internal "read mark")
CREATE UNIQUE INDEX IF NOT EXISTS idx_attendance_dedupe ON attendance(device_id, user_id, log_date);

CREATE TABLE IF NOT EXISTS devices (
    device_id TEXT PRIMARY KEY,
    name TEXT,
    ip_address TEXT,
    serial_number TEXT,
    connection_type TEXT,
    last_log_download_date TEXT,
    last_ping TEXT,
    user_count TEXT,
    updated_at TEXT
);

CREATE TABLE IF NOT EXISTS employees (
    employee_code TEXT PRIMARY KEY,
    employee_name TEXT,
    status TEXT,
    department_id TEXT,
    designation TEXT,
    doj TEXT,
    updated_at TEXT
);

CREATE TABLE IF NOT EXISTS sync_state (
    key TEXT PRIMARY KEY,
    value TEXT
);

-- who is actually enrolled ON each device (source of truth, read live from the
-- device itself via the console's "Sync Users" action - not from SmartOffice's DB)
CREATE TABLE IF NOT EXISTS device_users (
    device_id TEXT,
    employee_code TEXT,
    employee_name TEXT,
    backup_number TEXT,
    privilege TEXT,
    enabled TEXT,
    synced_at TEXT,
    PRIMARY KEY (device_id, employee_code, backup_number)
);
"""


def get_db():
    # timeout=10 + WAL: this loop and the console (console.py) hit the same
    # file concurrently - without these, a console click while this loop is
    # mid-sync fails outright with "database is locked" instead of just
    # waiting a moment (hit this for real, 2026-08-12).
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


def sync_attendance(conn):
    """Pull every log currently on each device and insert whatever's new.
    Always a full pull (read_mark=0) - simpler and more robust than trusting
    the device's own internal mark, since dedup happens on our side via the
    unique index instead."""
    now = datetime.datetime.now().isoformat()
    employees = {row["employee_code"]: dict(row) for row in conn.execute("SELECT * FROM employees")}
    devices = conn.execute("SELECT * FROM devices").fetchall()

    new_count = 0
    for device in devices:
        if not ping_ok(device["ip_address"]):
            continue
        result = list_device_logs(device["ip_address"], read_mark=0)
        if not result["success"]:
            continue
        for log in result["logs"]:
            emp = employees.get(log["enroll_number"], {})
            cur = conn.execute(
                """INSERT OR IGNORE INTO attendance
                   (device_id, user_id, employee_name, employee_status,
                    log_date, direction, verification_mode, synced_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    device["device_id"], log["enroll_number"],
                    emp.get("employee_name"), emp.get("status"),
                    log["log_date"], log["direction"], log["verify_mode"], now,
                ),
            )
            if cur.rowcount:
                new_count += 1
        conn.execute(
            "UPDATE devices SET last_log_download_date=?, last_ping=? WHERE device_id=?",
            (now, now, device["device_id"]),
        )
        # commit per-device rather than once at the end - keeps the write lock
        # window short (just this device's inserts) instead of holding it across
        # all devices' worth of work.
        conn.commit()
    return new_count


def sync_once():
    conn = get_db()
    try:
        new_count = sync_attendance(conn)
    finally:
        conn.close()
    return new_count


if __name__ == "__main__":
    while True:
        try:
            n = sync_once()
            print(f"[{datetime.datetime.now().isoformat()}] synced {n} new record(s)")
        except Exception as e:
            print(f"[{datetime.datetime.now().isoformat()}] ERROR: {e}")
        time.sleep(POLL_INTERVAL_SECONDS)
