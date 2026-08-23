#!/usr/bin/env python3
"""
BioMax health monitor - watches for exactly the kind of silent failure that
happened 2026-08-07 to 2026-08-23: nobody noticed attendance sync had gone
stale for 16 days because nothing was watching it. This closes that gap.

Two checks, every 30 min:
  1. Device reachability - ping all 3 devices, alert if one drops, alert
     again (recovered) when it comes back.
  2. Attendance sync staleness - alert if no new record has landed in over
     STALE_THRESHOLD_HOURS, alert again (resumed) once fresh data appears.

Both use a small dedup table (healthcheck_state) so a still-ongoing problem
doesn't re-alert every single cycle - one alert when it starts, one when it
clears. Pushes to ntfy - both the local server (reachable even if internet
is down) and the cloud one (reachable from outside the LAN), matching the
same pattern already used for the Telegram/Omada alerts elsewhere.

Deliberately its own process/service, not folded into biomax_sync.py or
biomax_autosync.py - this only ever reads, never writes attendance/device
data, so a bug here can't touch either of those pipelines.
"""
import sqlite3
import os
import subprocess
import datetime
import time
import urllib.request

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DB_FILE = os.path.join(BASE_DIR, "biomax.db")
CHECK_INTERVAL_SECONDS = 30 * 60
STALE_THRESHOLD_HOURS = 36  # survives a single day off (e.g. Sunday closed) without false-alarming

NTFY_TARGETS = [
    "http://192.168.126.101:8080/biomax-alerts",
    "https://ntfy.sh/biomax-alerts-priyanshu99",
]

SCHEMA = """
CREATE TABLE IF NOT EXISTS healthcheck_state (
    check_key TEXT PRIMARY KEY,
    alerted_at TEXT
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


def send_ntfy(message, title="BioMax Alert", priority="default", tags=""):
    for url in NTFY_TARGETS:
        try:
            req = urllib.request.Request(url, data=message.encode("utf-8"), method="POST")
            req.add_header("Title", title)
            if priority:
                req.add_header("Priority", priority)
            if tags:
                req.add_header("Tags", tags)
            urllib.request.urlopen(req, timeout=10)
        except Exception as e:
            print(f"[{datetime.datetime.now().isoformat()}] ntfy send failed ({url}): {e}")


def is_alerted(conn, key):
    return conn.execute("SELECT 1 FROM healthcheck_state WHERE check_key = ?", (key,)).fetchone() is not None


def mark_alerted(conn, key):
    conn.execute(
        "INSERT OR REPLACE INTO healthcheck_state (check_key, alerted_at) VALUES (?, ?)",
        (key, datetime.datetime.now().isoformat()),
    )
    conn.commit()


def clear_alerted(conn, key):
    conn.execute("DELETE FROM healthcheck_state WHERE check_key = ?", (key,))
    conn.commit()


def check_devices(conn):
    devices = conn.execute("SELECT * FROM devices").fetchall()
    for d in devices:
        key = f"device_down_{d['device_id']}"
        down = not ping_ok(d["ip_address"])
        alerted = is_alerted(conn, key)
        if down and not alerted:
            send_ntfy(
                f"Device {d['name']} ({d['ip_address']}) is unreachable.",
                title="BioMax device down", priority="high", tags="warning",
            )
            mark_alerted(conn, key)
        elif not down and alerted:
            send_ntfy(
                f"Device {d['name']} ({d['ip_address']}) is reachable again.",
                title="BioMax device recovered", tags="white_check_mark",
            )
            clear_alerted(conn, key)


def check_sync_staleness(conn):
    key = "sync_stale"
    row = conn.execute("SELECT MAX(synced_at) AS m FROM attendance").fetchone()
    if not row or not row["m"]:
        return  # no data at all yet - nothing to judge staleness against
    last_synced = datetime.datetime.fromisoformat(row["m"])
    hours_stale = (datetime.datetime.now() - last_synced).total_seconds() / 3600
    alerted = is_alerted(conn, key)

    if hours_stale > STALE_THRESHOLD_HOURS and not alerted:
        send_ntfy(
            f"No new attendance record synced in {hours_stale:.0f}h "
            f"(last one: {last_synced.strftime('%Y-%m-%d %H:%M')}). "
            f"Devices may be up but not actually syncing.",
            title="BioMax attendance sync stale", priority="high", tags="warning",
        )
        mark_alerted(conn, key)
    elif hours_stale <= STALE_THRESHOLD_HOURS and alerted:
        send_ntfy(
            f"Attendance sync is fresh again (last record: {last_synced.strftime('%Y-%m-%d %H:%M')}).",
            title="BioMax attendance sync resumed", tags="white_check_mark",
        )
        clear_alerted(conn, key)


if __name__ == "__main__":
    conn = get_db()
    while True:
        try:
            check_devices(conn)
            check_sync_staleness(conn)
            print(f"[{datetime.datetime.now().isoformat()}] healthcheck cycle OK")
        except Exception as e:
            print(f"[{datetime.datetime.now().isoformat()}] ERROR: {e}")
        time.sleep(CHECK_INTERVAL_SECONDS)
