#!/usr/bin/env python3
"""
Minimal ZKTeco/BioMax ADMS (Push) protocol listener.
Stdlib only, no dependencies. Isolated single-file service.

Implements the standard iClock push endpoints:
  GET  /iclock/cdata        -> handshake, returns poll options
  POST /iclock/cdata        -> attendance/user data upload (table=ATTLOG etc.)
  GET  /iclock/getrequest   -> device polls for pending commands (we send none)
  POST /iclock/devicecmd    -> device posts command execution results
  POST /iclock/fdata        -> biometric/face blob upload (just ack, log size)

Also handles device 502's proprietary FK push protocol at /hdata.aspx: the
body is a 4-byte little-endian length prefix followed by that many bytes of
JSON (RTLogSendAction = a real attendance punch, RTEnrollDataAction = a user's
enrollment/fingerprint data - we only care about the former). Real attendance
punches get written straight into biomax.db so the console picks them up
immediately, deduped the same way as the direct device-pull path.

IMPORTANT: this device retries a push until it gets an ack it's happy with,
and can retry the SAME record hundreds of thousands of times over days if
that never happens - so logging must stay minimal/deduped, never "write the
full raw body every time" (a real 4.9GB/4-day incident on 2026-08-11).
"""
import http.server
import socketserver
import urllib.parse
import datetime
import struct
import sqlite3
import json
import os
import threading

PORT = 7005          # existing FK /hdata.aspx push devices are already configured here
ICLOCK_PORT = 5005   # Mantra 604 / standard iclock ADMS devices push here
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
RAW_LOG = os.path.join(BASE_DIR, "raw_requests.log")
ATTLOG_FILE = os.path.join(BASE_DIR, "attendance.jsonl")
DB_FILE = os.path.join(BASE_DIR, "..", "biomax-sync", "biomax.db")
HDATA_DEVICE_ID = "7"  # device 502 in the devices table

_last_hdata_summary = {}  # dedupe per device: dev_id -> last (cmd_id, payload) seen, only log/store on change


def log_raw(line: str):
    ts = datetime.datetime.now().isoformat()
    with open(RAW_LOG, "a", encoding="utf-8") as f:
        f.write(f"[{ts}] {line}\n")


def parse_qs(path: str):
    parsed = urllib.parse.urlparse(path)
    qs = urllib.parse.parse_qs(parsed.query)
    return parsed.path, {k: v[0] for k, v in qs.items()}


def extract_hdata_json(body_bytes: bytes):
    """Body is a 4-byte LE length prefix + that many bytes of JSON (rest of
    the payload, if any, is binary fingerprint template data we don't need)."""
    if len(body_bytes) < 4:
        return None
    (json_len,) = struct.unpack("<I", body_bytes[:4])
    chunk = body_bytes[4:4 + json_len].rstrip(b"\x00\r\n\t ")
    try:
        return json.loads(chunk.decode("utf-8", errors="replace"))
    except Exception:
        return None


def _resolve_device_id(sn: str):
    """Map an iclock device's reported serial number (SN=... in the URL) to
    our internal device_id, via the devices.serial_number column. Returns
    None if this SN hasn't been registered yet (e.g. a brand new device
    whose real SN we haven't seen/recorded until its first push)."""
    conn = sqlite3.connect(DB_FILE, timeout=10.0)
    try:
        row = conn.execute("SELECT device_id FROM devices WHERE serial_number = ?", (sn,)).fetchone()
        return row[0] if row else None
    finally:
        conn.close()


def store_iclock_attendance(device_id: str, pin: str, timestamp: str, status, verify_method):
    """Standard iclock ATTLOG format: timestamp is 'YYYY-MM-DD HH:MM:SS' -
    reformat to 'MM/DD/YY HH:MM:SS' to match every other device/path in this
    system (the Logs date-range filter and CSV export both assume that
    format), so this doesn't create a second inconsistent date shape."""
    try:
        dt = datetime.datetime.strptime(timestamp, "%Y-%m-%d %H:%M:%S")
        log_date = dt.strftime("%m/%d/%y %H:%M:%S")
    except ValueError:
        log_date = timestamp  # unexpected format - store as-is rather than drop it
    direction = {"0": "in", "1": "out"}.get(str(status), str(status) if status else "")
    now = datetime.datetime.now().isoformat()
    conn = sqlite3.connect(DB_FILE, timeout=10.0)
    conn.execute("PRAGMA journal_mode=WAL")
    try:
        emp = conn.execute(
            "SELECT employee_name, status FROM employees WHERE employee_code=?", (pin,)
        ).fetchone()
        conn.execute(
            """INSERT OR IGNORE INTO attendance
               (device_id, user_id, employee_name, employee_status,
                log_date, direction, verification_mode, synced_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            (device_id, pin, emp[0] if emp else None, emp[1] if emp else None,
             log_date, direction, str(verify_method) if verify_method else None, now),
        )
        conn.commit()
    finally:
        conn.close()


def store_attendance_punch(device_id: str, user_id: str, io_time: str, io_mode, verify_mode):
    """io_time is YYYYMMDDHHMMSS. Same dedupe key/shape as the direct device-pull
    path (biomax_sync.py) so both sources land in the same place without clashing."""
    if not user_id or not io_time or len(io_time) != 14:
        return
    log_date = f"{io_time[0:4]}-{io_time[4:6]}-{io_time[6:8]} {io_time[8:10]}:{io_time[10:12]}:{io_time[12:14]}"
    direction = {0: "in", 1: "out", 2: "io"}.get(io_mode, str(io_mode))
    now = datetime.datetime.now().isoformat()
    conn = sqlite3.connect(DB_FILE, timeout=10.0)
    conn.execute("PRAGMA journal_mode=WAL")
    try:
        emp = conn.execute(
            "SELECT employee_name, status FROM employees WHERE employee_code=?", (user_id,)
        ).fetchone()
        conn.execute(
            """INSERT OR IGNORE INTO attendance
               (device_id, user_id, employee_name, employee_status,
                log_date, direction, verification_mode, synced_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            (device_id, user_id, emp[0] if emp else None, emp[1] if emp else None,
             log_date, direction, str(verify_mode), now),
        )
        conn.commit()
    finally:
        conn.close()


# --- Outbound command queue (user create/delete on iclock/ADMS pull devices) ---
# The FK623 devices are pushed to directly (console -> device). A Mantra/iclock
# device can't be pushed to - it only ever reaches out to us - so user
# create/delete is done by queueing a command here and handing it over on the
# device's next /iclock/getrequest poll, then recording its /iclock/devicecmd
# result. The console writes into adms_commands; this listener drains it.

def ensure_command_schema():
    """Make sure the command queue + device_type flag exist. Idempotent - the
    console ensures the same objects; whichever process opens the DB first wins,
    the other no-ops. Runs once at startup."""
    conn = sqlite3.connect(DB_FILE, timeout=10.0)
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute(
            """CREATE TABLE IF NOT EXISTS adms_commands (
                   id INTEGER PRIMARY KEY AUTOINCREMENT,
                   device_id TEXT NOT NULL,
                   op TEXT,
                   enroll_number TEXT,
                   name TEXT,
                   cmd_text TEXT NOT NULL,
                   status TEXT NOT NULL DEFAULT 'pending',
                   return_code TEXT,
                   created_at TEXT,
                   sent_at TEXT,
                   acked_at TEXT
               )"""
        )
        cols = {r[1] for r in conn.execute("PRAGMA table_info(devices)")}
        if "device_type" not in cols:
            conn.execute("ALTER TABLE devices ADD COLUMN device_type TEXT DEFAULT 'fk623'")
        conn.commit()
    finally:
        conn.close()


def bind_unknown_sn(sn: str):
    """First time a real iclock unit checks in, its SN isn't in the devices
    table yet (we register the unit with a blank serial_number until we see what
    it actually reports). If EXACTLY ONE adms device is still waiting for its SN,
    bind this one to it automatically - that's the 'point the device at us and it
    self-registers' flow, no manual SQL. If it's ambiguous (0 or >1 blank adms
    rows), don't guess; just log it. Returns the device_id if bound, else None."""
    if not sn or sn == "unknown":
        return None
    conn = sqlite3.connect(DB_FILE, timeout=10.0)
    try:
        rows = conn.execute(
            "SELECT device_id FROM devices WHERE device_type='adms' "
            "AND (serial_number IS NULL OR serial_number='')"
        ).fetchall()
        if len(rows) == 1:
            device_id = rows[0][0]
            conn.execute(
                "UPDATE devices SET serial_number=?, updated_at=? WHERE device_id=?",
                (sn, datetime.datetime.now().isoformat(), device_id),
            )
            conn.commit()
            log_raw(f"AUTO-BOUND new iclock SN={sn} -> device_id={device_id}")
            return device_id
        log_raw(f"iclock SN={sn} not registered; {len(rows)} adms device(s) awaiting an SN - not auto-binding")
        return None
    finally:
        conn.close()


def take_pending_commands(device_id, limit: int = 10):
    """Pull a device's not-yet-delivered commands and mark them 'sent'. Returns
    a list of (id, cmd_text). Handed out once; the device confirms via
    /iclock/devicecmd which flips it to done/failed. DATA UPDATE/DELETE USERINFO
    are idempotent, so a rare missed ack is safe to re-issue by re-queuing from
    the console - we don't auto-spam the same command every poll."""
    if device_id is None:
        return []
    conn = sqlite3.connect(DB_FILE, timeout=10.0)
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        rows = conn.execute(
            "SELECT id, cmd_text FROM adms_commands WHERE device_id=? AND status='pending' "
            "ORDER BY id LIMIT ?",
            (str(device_id), limit),
        ).fetchall()
        if rows:
            now = datetime.datetime.now().isoformat()
            conn.executemany(
                "UPDATE adms_commands SET status='sent', sent_at=? WHERE id=?",
                [(now, r[0]) for r in rows],
            )
            conn.commit()
        return [(r[0], r[1]) for r in rows]
    finally:
        conn.close()


def ack_command(cmd_id, return_code):
    """Record a device's result for a handed-out command. Return=0 -> applied."""
    conn = sqlite3.connect(DB_FILE, timeout=10.0)
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        status = "done" if str(return_code) == "0" else "failed"
        conn.execute(
            "UPDATE adms_commands SET status=?, return_code=?, acked_at=? WHERE id=?",
            (status, str(return_code), datetime.datetime.now().isoformat(), str(cmd_id)),
        )
        conn.commit()
    finally:
        conn.close()


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "BioMaxADMS/1.0"

    def _send(self, body: str, code: int = 200):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path, params = parse_qs(self.path)
        sn = params.get("SN", "unknown")

        if path == "/iclock/cdata":
            log_raw(f"GET {self.path} SN={sn}")
            resp = (
                f"GET OPTION FROM: {sn}\r\n"
                "Stamp=9999\r\n"
                "OpStamp=9999\r\n"
                "ErrorDelay=30\r\n"
                "Delay=10\r\n"
                "TransTimes=00:00;23:59\r\n"
                "TransInterval=1\r\n"
                "TransFlag=1111000000\r\n"
                "Realtime=1\r\n"
                "Encrypt=0\r\n"
            )
            self._send(resp)
        elif path == "/iclock/getrequest":
            # device polls here for work to do; hand over any queued user
            # create/delete commands, else "OK" (a frequent heartbeat - not logged)
            device_id = _resolve_device_id(sn)
            if device_id is None:
                device_id = bind_unknown_sn(sn)
            cmds = take_pending_commands(device_id)
            if cmds:
                body = "\r\n".join(f"C:{cid}:{ctext}" for cid, ctext in cmds)
                log_raw(f"getrequest SN={sn} dev={device_id} handed {len(cmds)} cmd(s) ids={[c[0] for c in cmds]}")
                self._send(body)
            else:
                self._send("OK")
        else:
            self._send("OK")

    def do_POST(self):
        global _last_hdata_summary
        path, params = parse_qs(self.path)
        sn = params.get("SN", "unknown")
        table = params.get("table", "")
        length = int(self.headers.get("Content-Length", 0))
        body_bytes = self.rfile.read(length) if length else b""

        if path == "/hdata.aspx":
            cmd_id = self.headers.get("cmd_id", "")
            dev_id = self.headers.get("dev_id", "")
            if cmd_id == "ReceiveCommandAction":
                # periodic device status heartbeat - carries a live timestamp so it
                # never looks "the same" to the dedupe below; nothing useful to us,
                # just ack it and move on (same treatment as /iclock/getrequest)
                self._send_hdata_ack()
                return
            payload = extract_hdata_json(body_bytes)
            dedupe_key = (dev_id, cmd_id)
            summary = json.dumps(payload, sort_keys=True) if payload else None
            if _last_hdata_summary.get(dedupe_key) != summary:
                _last_hdata_summary[dedupe_key] = summary
                log_raw(f"POST /hdata.aspx cmd_id={cmd_id} dev_id={dev_id} payload={payload}")
                if cmd_id == "RTLogSendAction" and payload:
                    user_id = payload.get("user_id") or ""
                    try:
                        store_attendance_punch(
                            HDATA_DEVICE_ID, user_id, payload.get("io_time", ""),
                            payload.get("io_mode"), payload.get("verify_mode"),
                        )
                    except Exception as e:
                        log_raw(f"  ERROR storing punch: {e}")
            # else: identical retry of something we already saw - skip logging/storing entirely
            self._send_hdata_ack()
            return

        body = body_bytes.decode("utf-8", errors="replace")
        log_raw(f"POST {self.path} SN={sn} table={table} bytes={length}")
        if path == "/iclock/cdata" and table.upper() == "ATTLOG":
            self._store_attlog(sn, body)
        elif path == "/iclock/cdata":
            log_raw(f"  body[{table}]: {body[:500]}")
        elif path == "/iclock/devicecmd":
            self._handle_devicecmd(body)
        elif path == "/iclock/fdata":
            log_raw(f"  fdata (biometric blob) bytes={length}, not stored")
        else:
            log_raw(f"  UNKNOWN PATH bytes={length}")

        self._send("OK")

    def _handle_devicecmd(self, body: str):
        """Device reports the result of a command we handed it. Standard shape is
        'ID=<cmdid>&Return=<code>&CMD=DATA', one per line. Return=0 = applied OK;
        anything else is a device-side failure."""
        for line in body.splitlines():
            line = line.strip()
            if not line or "ID=" not in line:
                continue
            fields = urllib.parse.parse_qs(line)
            cmd_id = (fields.get("ID") or [None])[0]
            ret = (fields.get("Return") or fields.get("return") or ["?"])[0]
            if not cmd_id:
                continue
            try:
                ack_command(cmd_id, ret)
                log_raw(f"devicecmd ack id={cmd_id} return={ret}")
            except Exception as e:
                log_raw(f"  ERROR acking devicecmd id={cmd_id}: {e}")

    def _send_hdata_ack(self):
        # Trial response for the proprietary FK push protocol: empty 200 body.
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _store_attlog(self, sn: str, body: str):
        device_id = _resolve_device_id(sn)
        for line in body.splitlines():
            line = line.strip()
            if not line:
                continue
            fields = line.split("\t")
            pin = fields[0] if len(fields) > 0 else None
            timestamp = fields[1] if len(fields) > 1 else None
            status = fields[2] if len(fields) > 2 else None
            verify_method = fields[3] if len(fields) > 3 else None

            record = {
                "received_at": datetime.datetime.now().isoformat(),
                "device_sn": sn,
                "pin": pin,
                "timestamp": timestamp,
                "status": status,
                "verify_method": verify_method,
                "raw": line,
            }
            with open(ATTLOG_FILE, "a", encoding="utf-8") as f:
                f.write(json.dumps(record, ensure_ascii=False) + "\n")

            if not device_id:
                log_raw(f"  ATTLOG from unknown SN={sn} - add it to the devices.serial_number column to store this in the real attendance table")
                continue
            if not pin or not timestamp:
                continue
            try:
                store_iclock_attendance(device_id, pin, timestamp, status, verify_method)
            except Exception as e:
                log_raw(f"  ERROR storing ATTLOG punch: {e}")

    def log_message(self, fmt, *args):
        pass  # suppress default stderr access log; we log to RAW_LOG instead


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    # default request_queue_size is 5 (stdlib default) - these devices retry
    # frequently and 3 of them can burst-reconnect around the same moment
    # (e.g. after any brief network blip), which is enough to overflow a
    # backlog that small; the OS then refuses/resets the new connection
    # attempt before we ever see it. Bumped generously - found via a live
    # ConnectionResetError pattern in the logs (47 failed connection
    # attempts since 2026-08-12, no successful push since), 2026-08-23.
    request_queue_size = 64


if __name__ == "__main__":
    ensure_command_schema()
    # Same handler on both ports: the existing FK /hdata.aspx push devices are
    # already configured to reach us on 7005; the Mantra 604 pushes on 5005.
    extra = ThreadingHTTPServer(("0.0.0.0", ICLOCK_PORT), Handler)
    threading.Thread(target=extra.serve_forever, daemon=True).start()
    print(f"BioMax ADMS listener also running on 0.0.0.0:{ICLOCK_PORT}")
    with ThreadingHTTPServer(("0.0.0.0", PORT), Handler) as httpd:
        print(f"BioMax ADMS listener running on 0.0.0.0:{PORT}")
        httpd.serve_forever()
