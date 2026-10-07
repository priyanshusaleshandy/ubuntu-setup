#!/usr/bin/env python3
"""EBKN/Realand LogClient listener for device 604 (MORX mBio-M18, TerminalType A30C).

The device opens one TCP connection per event, sends a raw XML <Message>, waits
for an ack, then closes. The ack that makes it advance TransID is:

    <?xml version="1.0"?><Message><Request>UploadedLog</Request><TransID>N</TransID></Message>\\x00

The tag is <Request> (not <Response>) and the trailing NUL byte is mandatory.
KeepAlive is acked with <Request>KeptAlive</Request> instead.

A TimeLog is written to biomax.db BEFORE it is acked - acking first would let a
failed insert lose the punch permanently, whereas staying silent makes the device
retry, which is what we want.
"""
import datetime
import os
import re
import socket
import sqlite3
import sys
import threading

HOST = "0.0.0.0"
PORT = 9099
DEVICE_ID = "9"
BASE = os.path.expanduser("~/biomax-mbio")
DB_FILE = os.path.expanduser("~/biomax-sync/biomax.db")
LOG = os.path.join(BASE, "mbio.log")
PIDFILE = os.path.join(BASE, "mbio.pid")

ACK_FOR = {
    "TimeLog": "UploadedLog",
    "AdminLog": "UploadedLog",
    "Alarm": "UploadedLog",
    "KeepAlive": "KeptAlive",
}

_log_lock = threading.Lock()


def log(msg):
    line = "%s %s\n" % (datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"), msg)
    with _log_lock:
        with open(LOG, "a") as fh:
            fh.write(line)
            fh.flush()


def tag(data, name, default=""):
    m = re.search(r"<%s>(.*?)</%s>" % (name, name), data, re.S)
    return m.group(1).strip() if m else default


def store_timelog(text):
    """Insert one punch into the same attendance table every other device path
    writes to. Returns True once the row is stored (or was already there).

    log_date is MM/DD/YY HH:MM:SS to match every existing row and what the
    console's Logs date filter and CSV export assume. The device does not
    zero-pad its date parts, so they are reformatted rather than concatenated.

    verification_mode holds the device's own text ('FP', 'Card', ...) - the SDK
    pull path reports the same thing as a packed number instead, so 604's older
    pulled rows look different from these. Both are the device's own value; no
    translation is invented here."""
    user_id = tag(text, "UserID")
    if not user_id:
        return False
    try:
        dt = datetime.datetime(
            int(tag(text, "Year")), int(tag(text, "Month")), int(tag(text, "Day")),
            int(tag(text, "Hour")), int(tag(text, "Minute")), int(tag(text, "Second")),
        )
    except (ValueError, TypeError):
        return False

    stat = tag(text, "AttendStat")
    # 'Duty On' / 'OT On' / 'Break On' vs the matching '... Off'. Blank when the
    # device does not report one, rather than guessing a direction.
    direction = "in" if stat.endswith("On") else ("out" if stat.endswith("Off") else "")

    conn = sqlite3.connect(DB_FILE, timeout=15.0)
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        emp = conn.execute(
            "SELECT employee_name, status FROM employees WHERE employee_code=?", (user_id,)
        ).fetchone()
        conn.execute(
            """INSERT OR IGNORE INTO attendance
               (device_id, user_id, employee_name, employee_status,
                log_date, direction, verification_mode, synced_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            (DEVICE_ID, user_id, emp[0] if emp else None, emp[1] if emp else None,
             dt.strftime("%m/%d/%y %H:%M:%S"), direction,
             tag(text, "VerifMode") or None, datetime.datetime.now().isoformat()),
        )
        conn.commit()
        return True
    finally:
        conn.close()


def handle(conn, addr):
    # The device also opens an idle connection every ~9s and sends nothing; a
    # short timeout retires those cheaply instead of tying up a thread.
    conn.settimeout(8)
    try:
        data = b""
        while b"</Message>" not in data:
            chunk = conn.recv(8192)
            if not chunk:
                break
            data += chunk
            if len(data) > 262144:
                break

        if not data:
            return  # idle/keep-open connection - normal, not worth logging

        text = data.decode("utf-8", "replace")
        event = tag(text, "Event")
        tid = tag(text, "TransID", "0")

        if event == "TimeLog":
            if not store_timelog(text):
                # Don't ack - the device will resend and we get another chance.
                log("ERR store failed tid=%s user=%s - not acking" % (tid, tag(text, "UserID")))
                return
            log("RX TimeLog tid=%s user=%s %s-%s-%s %s:%s:%s stat=%r verif=%s -> stored"
                % (tid, tag(text, "UserID"), tag(text, "Year"), tag(text, "Month"),
                   tag(text, "Day"), tag(text, "Hour"), tag(text, "Minute"),
                   tag(text, "Second"), tag(text, "AttendStat"), tag(text, "VerifMode")))
        elif event == "KeepAlive":
            pass  # every ~9s, nothing to record
        elif event:
            log("RX %s tid=%s raw=%s" % (event, tid, text.replace("\n", "")))
        else:
            log("RX unparsed from=%s raw=%s" % (addr[0], text.replace("\n", "")[:500]))
            return

        request = ACK_FOR.get(event, "UploadedLog")
        reply = ('<?xml version="1.0"?><Message><Request>%s</Request>'
                 '<TransID>%s</TransID></Message>' % (request, tid)).encode("ascii") + b"\x00"
        conn.sendall(reply)
    except socket.timeout:
        pass  # idle connection that never sent anything
    except Exception as exc:
        log("ERR %s: %r" % (addr[0], exc))
    finally:
        try:
            conn.close()
        except Exception:
            pass


def serve():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((HOST, PORT))
    srv.listen(64)
    log("=== listener started on %s:%d pid=%d db=%s ===" % (HOST, PORT, os.getpid(), DB_FILE))
    while True:
        conn, addr = srv.accept()
        threading.Thread(target=handle, args=(conn, addr), daemon=True).start()


def daemonize():
    if os.fork() > 0:
        sys.exit(0)
    os.setsid()
    if os.fork() > 0:
        sys.exit(0)
    devnull = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(devnull, fd)
    with open(PIDFILE, "w") as fh:
        fh.write(str(os.getpid()))


if __name__ == "__main__":
    os.makedirs(BASE, exist_ok=True)
    if "--foreground" not in sys.argv:
        daemonize()
    serve()
