#!/usr/bin/env python3
"""BioMax attendance console - devices/logs/users viewing + user push."""
import sqlite3
import os
import io
import csv
import base64
import datetime
import subprocess
from concurrent.futures import ThreadPoolExecutor
from flask import Flask, render_template, request, g, redirect, url_for, flash, session, Response
from werkzeug.security import generate_password_hash, check_password_hash
import pyotp
import qrcode

from device_push import (push_user, delete_user, list_device_users, copy_fingerprint,
                         mbio_push_user, mbio_delete_user)

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DB_FILE = os.path.join(BASE_DIR, "biomax.db")
SECRET_KEY_FILE = os.path.join(BASE_DIR, ".secret_key")
DEFAULT_ADMIN_USER = "admin"


def _get_secret_key():
    """A random key per process (the old behavior) logs everyone out on every
    restart - this app gets restarted a lot during normal maintenance, so
    persist one to disk instead. BIOMAX_SECRET_KEY env var still wins if set."""
    env_key = os.environ.get("BIOMAX_SECRET_KEY")
    if env_key:
        return env_key
    if os.path.exists(SECRET_KEY_FILE):
        with open(SECRET_KEY_FILE, "r") as f:
            return f.read().strip()
    key = os.urandom(32).hex()
    with open(SECRET_KEY_FILE, "w") as f:
        f.write(key)
    os.chmod(SECRET_KEY_FILE, 0o600)  # owner-only - this key can forge session cookies
    return key


app = Flask(__name__)
app.secret_key = _get_secret_key()
app.permanent_session_lifetime = datetime.timedelta(days=30)
# Lax blocks the session cookie from riding along on a cross-site POST (the
# classic CSRF pattern) while still working normally for same-site use.
# Not Secure - this deployment is plain HTTP on the LAN, no TLS in front of
# it, so a Secure cookie would just never get sent and break login entirely.
app.config["SESSION_COOKIE_SAMESITE"] = "Lax"
app.config["SESSION_COOKIE_HTTPONLY"] = True


@app.after_request
def add_security_headers(response):
    response.headers["X-Frame-Options"] = "DENY"  # blocks clickjacking (embedding this admin console in a hidden iframe)
    response.headers["X-Content-Type-Options"] = "nosniff"
    return response


def ping_ok(ip):
    try:
        r = subprocess.run(["ping", "-c", "1", "-W", "3", ip], capture_output=True, timeout=6)
        return r.returncode == 0
    except Exception:
        return False


def with_status(devices):
    """Ping every device in parallel and return plain dicts with an 'online' bool
    tacked on - lets templates show a live reachability badge without making
    users find out the hard way (a sync/push that quietly does nothing)."""
    if not devices:
        return []
    with ThreadPoolExecutor(max_workers=len(devices)) as ex:
        statuses = list(ex.map(lambda d: ping_ok(d["ip_address"]), devices))
    out = []
    for d, online in zip(devices, statuses):
        row = dict(d)
        row["online"] = online
        out.append(row)
    return out


def get_db():
    if "db" not in g:
        # timeout=10: if biomax_sync.py's background loop is mid-write, retry for up
        # to 10s instead of failing immediately with "database is locked". WAL mode
        # additionally lets our reads/writes here not block on each other in the
        # first place - both needed, hit a real "database is locked" without them.
        g.db = sqlite3.connect(DB_FILE, timeout=10.0)
        g.db.row_factory = sqlite3.Row
        g.db.execute("PRAGMA journal_mode=WAL")
        g.db.execute(
            """CREATE TABLE IF NOT EXISTS console_users (
                   username TEXT PRIMARY KEY,
                   password_hash TEXT NOT NULL,
                   updated_at TEXT
               )"""
        )
        # migrate in the 2FA columns for a table that already existed before this -
        # ALTER TABLE has no "ADD COLUMN IF NOT EXISTS", so check first
        existing_cols = {row["name"] for row in g.db.execute("PRAGMA table_info(console_users)")}
        if "totp_secret" not in existing_cols:
            g.db.execute("ALTER TABLE console_users ADD COLUMN totp_secret TEXT")
        if "totp_enabled" not in existing_cols:
            g.db.execute("ALTER TABLE console_users ADD COLUMN totp_enabled INTEGER DEFAULT 0")
        # seed the one default admin account, but only the very first time this
        # table is empty - never touches it again after that, so a changed
        # password is never silently reset back to the default on a redeploy.
        # No hardcoded password in source (this file is committed to a public
        # repo) - either BIOMAX_ADMIN_SEED_PASSWORD is set, or a random one-time
        # password is generated and printed to the service log (journalctl) so
        # whoever deploys it can grab it once and change it via Change Password.
        if g.db.execute("SELECT COUNT(*) FROM console_users").fetchone()[0] == 0:
            seed_password = os.environ.get("BIOMAX_ADMIN_SEED_PASSWORD")
            if not seed_password:
                seed_password = os.urandom(9).hex()
                print(
                    f"[console] No BIOMAX_ADMIN_SEED_PASSWORD set - generated one-time "
                    f"admin password: {seed_password}  (log in as '{DEFAULT_ADMIN_USER}' "
                    f"and change it via Change Password right away)"
                )
            g.db.execute(
                "INSERT INTO console_users (username, password_hash, updated_at) VALUES (?, ?, ?)",
                (DEFAULT_ADMIN_USER, generate_password_hash(seed_password), datetime.datetime.now().isoformat()),
            )
            g.db.commit()

        # Outbound ADMS command queue + a device_type flag so create/delete route
        # to the right path: FK623 devices are pushed to directly; iclock/ADMS
        # pull devices (Mantra 604) get a queued command they fetch on their next
        # check-in. Both idempotent, mirroring what the ADMS listener ensures.
        g.db.execute(
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
        device_cols = {row["name"] for row in g.db.execute("PRAGMA table_info(devices)")}
        if "device_type" not in device_cols:
            g.db.execute("ALTER TABLE devices ADD COLUMN device_type TEXT DEFAULT 'fk623'")
        g.db.commit()
    return g.db


@app.teardown_appcontext
def close_db(exc):
    db = g.pop("db", None)
    if db is not None:
        db.close()


def _device_type(device):
    """'fk623' (push straight to the device via FK623Attend.dll), 'mbio' (604 -
    push straight to it too, but via the EBKN SBXPCDLL.dll bridge), or 'adms'
    (queue a command the device pulls on its next check-in). Defaults to fk623
    for any row that predates the device_type column."""
    try:
        return device["device_type"] or "fk623"
    except (KeyError, IndexError):
        return "fk623"


def _adms_cmd_text(op, enroll_number, name=None):
    """Build the iClock/ADMS command body (the 'C:<id>:' prefix is added by the
    ADMS listener from the queue row id). Fields are TAB-separated per the
    standard ZKTeco push spec."""
    if op == "create":
        fields = [
            f"PIN={enroll_number}", f"Name={name or ''}",
            "Pri=0", "Passwd=", "Card=", "Grp=1", "TZ=0000000000000000",
        ]
        return "DATA UPDATE USERINFO " + "\t".join(fields)
    if op == "delete":
        return f"DATA DELETE USERINFO PIN={enroll_number}"
    raise ValueError(f"unknown adms op: {op}")


def _enqueue_adms_command(db, device_id, op, enroll_number, name=None):
    """Queue a user create/delete for a pull-based device. The ADMS listener
    hands it over on the device's next poll and records the result."""
    db.execute(
        """INSERT INTO adms_commands (device_id, op, enroll_number, name, cmd_text, status, created_at)
           VALUES (?, ?, ?, ?, ?, 'pending', ?)""",
        (device_id, op, enroll_number, name, _adms_cmd_text(op, enroll_number, name),
         datetime.datetime.now().isoformat()),
    )
    db.commit()


def _queue_delete_retry(db, device_id, enroll_number, full_delete, error):
    """Remember a delete that didn't land so biomax_autosync can keep retrying it.
    Created here rather than only in the autosync service so a delete attempted
    before that service has ever run still gets queued."""
    db.execute(
        """CREATE TABLE IF NOT EXISTS pending_deletes (
               device_id TEXT, employee_code TEXT, full_delete INTEGER DEFAULT 1,
               created_at TEXT, attempts INTEGER DEFAULT 0,
               last_attempt_at TEXT, last_error TEXT,
               PRIMARY KEY (device_id, employee_code))"""
    )
    now = datetime.datetime.now().isoformat()
    db.execute(
        """INSERT INTO pending_deletes
               (device_id, employee_code, full_delete, created_at, attempts, last_attempt_at, last_error)
           VALUES (?, ?, ?, ?, 1, ?, ?)
           ON CONFLICT(device_id, employee_code) DO UPDATE SET
               attempts = attempts + 1, last_attempt_at = excluded.last_attempt_at,
               last_error = excluded.last_error,
               full_delete = MAX(full_delete, excluded.full_delete)""",
        (device_id, enroll_number, 1 if full_delete else 0, now, now, error),
    )
    db.commit()


def _clear_delete_retry(db, device_id, enroll_number):
    db.execute(
        """CREATE TABLE IF NOT EXISTS pending_deletes (
               device_id TEXT, employee_code TEXT, full_delete INTEGER DEFAULT 1,
               created_at TEXT, attempts INTEGER DEFAULT 0,
               last_attempt_at TEXT, last_error TEXT,
               PRIMARY KEY (device_id, employee_code))"""
    )
    db.execute("DELETE FROM pending_deletes WHERE device_id=? AND employee_code=?",
               (device_id, enroll_number))
    db.commit()


def _safe_next(path):
    """Only allow a relative, in-app path for ?next= / hidden next fields.
    Passing it straight to redirect() unchecked is a classic open-redirect:
    a crafted link like /login?next=https://evil.example/phish would bounce
    a just-authenticated user straight to it. "//evil.example" is also
    rejected - browsers treat a leading // as protocol-relative (still
    external), not as this app's root."""
    if not path or not path.startswith("/") or path.startswith("//"):
        return url_for("dashboard")
    return path


@app.before_request
def require_login():
    if request.endpoint in ("login_page", "login_2fa_page", "static"):
        return
    if not session.get("logged_in"):
        return redirect(url_for("login_page", next=request.path))


@app.route("/login", methods=["GET", "POST"])
def login_page():
    if session.get("logged_in"):
        return redirect(url_for("dashboard"))

    error = None
    if request.method == "POST":
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "")
        next_path = _safe_next(request.form.get("next"))
        db = get_db()
        row = db.execute("SELECT * FROM console_users WHERE username = ?", (username,)).fetchone()
        if row and check_password_hash(row["password_hash"], password):
            session.clear()
            if row["totp_enabled"]:
                # password alone isn't enough - park them one step short of
                # logged_in until they also pass the 6-digit code
                session["pending_2fa_username"] = row["username"]
                session["pending_2fa_next"] = next_path
                return redirect(url_for("login_2fa_page"))
            session["logged_in"] = True
            session["username"] = row["username"]
            session.permanent = True
            return redirect(next_path)
        error = "Invalid username or password."

    return render_template("login.html", error=error, next=request.args.get("next", ""))


@app.route("/login-2fa", methods=["GET", "POST"])
def login_2fa_page():
    pending_user = session.get("pending_2fa_username")
    if not pending_user:
        return redirect(url_for("login_page"))

    error = None
    if request.method == "POST":
        code = request.form.get("code", "").strip()
        db = get_db()
        row = db.execute("SELECT * FROM console_users WHERE username = ?", (pending_user,)).fetchone()
        totp = pyotp.TOTP(row["totp_secret"]) if row and row["totp_secret"] else None
        if totp and totp.verify(code, valid_window=1):
            next_path = session.get("pending_2fa_next") or url_for("dashboard")
            session.clear()
            session["logged_in"] = True
            session["username"] = pending_user
            session.permanent = True
            return redirect(next_path)
        error = "Invalid or expired code."

    return render_template("login_2fa.html", error=error)


@app.route("/logout")
def logout_page():
    session.clear()
    return redirect(url_for("login_page"))


@app.route("/change-password", methods=["GET", "POST"])
def change_password_page():
    db = get_db()
    result = None

    if request.method == "POST":
        current_password = request.form.get("current_password", "")
        new_password = request.form.get("new_password", "")
        confirm_password = request.form.get("confirm_password", "")

        row = db.execute("SELECT * FROM console_users WHERE username = ?", (session["username"],)).fetchone()

        if not row or not check_password_hash(row["password_hash"], current_password):
            result = {"success": False, "error": "Current password is incorrect."}
        elif len(new_password) < 6:
            result = {"success": False, "error": "New password must be at least 6 characters."}
        elif new_password != confirm_password:
            result = {"success": False, "error": "New password and confirmation don't match."}
        else:
            db.execute(
                "UPDATE console_users SET password_hash = ?, updated_at = ? WHERE username = ?",
                (generate_password_hash(new_password), datetime.datetime.now().isoformat(), session["username"]),
            )
            db.commit()
            result = {"success": True}

    return render_template("change_password.html", result=result, active="change_password")


@app.route("/setup-2fa", methods=["GET", "POST"])
def setup_2fa_page():
    db = get_db()
    row = db.execute("SELECT * FROM console_users WHERE username = ?", (session["username"],)).fetchone()
    error = None
    success = False

    if row["totp_enabled"]:
        # already on - this page just offers to turn it off (needs the
        # password, not a code, since losing the code is exactly why someone
        # would be here)
        if request.method == "POST":
            password = request.form.get("password", "")
            if not check_password_hash(row["password_hash"], password):
                error = "Password is incorrect."
            else:
                db.execute(
                    "UPDATE console_users SET totp_enabled=0, totp_secret=NULL, updated_at=? WHERE username=?",
                    (datetime.datetime.now().isoformat(), session["username"]),
                )
                db.commit()
                return redirect(url_for("setup_2fa_page"))
        return render_template("setup_2fa.html", enabled=True, error=error, active="setup_2fa")

    # not enabled yet - generate (or reuse, mid-setup) a pending secret and
    # ask for one valid code before actually turning it on, so a bad
    # scan/typo can't lock the account out
    if request.method == "POST":
        code = request.form.get("code", "").strip()
        pending_secret = session.get("pending_totp_secret")
        totp = pyotp.TOTP(pending_secret) if pending_secret else None
        if totp and totp.verify(code, valid_window=1):
            db.execute(
                "UPDATE console_users SET totp_secret=?, totp_enabled=1, updated_at=? WHERE username=?",
                (pending_secret, datetime.datetime.now().isoformat(), session["username"]),
            )
            db.commit()
            session.pop("pending_totp_secret", None)
            success = True
        else:
            error = "That code didn't match — try the current code from your app."

    if not success and "pending_totp_secret" not in session:
        session["pending_totp_secret"] = pyotp.random_base32()

    qr_data_uri = None
    secret = session.get("pending_totp_secret")
    if secret and not success:
        otp_uri = pyotp.totp.TOTP(secret).provisioning_uri(name=session["username"], issuer_name="BioMax Console")
        img = qrcode.make(otp_uri)
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        qr_data_uri = "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode("ascii")

    return render_template(
        "setup_2fa.html", enabled=False, error=error, success=success,
        secret=secret, qr_data_uri=qr_data_uri, active="setup_2fa",
    )


@app.route("/manage-admins", methods=["GET", "POST"])
def manage_admins_page():
    db = get_db()
    error = None
    success = None

    if request.method == "POST":
        action = request.form.get("action", "")

        if action == "add":
            new_username = request.form.get("new_username", "").strip()
            new_password = request.form.get("new_password", "")
            if not new_username or not new_username.replace("_", "").replace("-", "").isalnum():
                error = "Username can only contain letters, numbers, - and _."
            elif len(new_password) < 6:
                error = "Password must be at least 6 characters."
            elif db.execute("SELECT 1 FROM console_users WHERE username = ?", (new_username,)).fetchone():
                error = "That username already exists."
            else:
                db.execute(
                    "INSERT INTO console_users (username, password_hash, updated_at) VALUES (?, ?, ?)",
                    (new_username, generate_password_hash(new_password), datetime.datetime.now().isoformat()),
                )
                db.commit()
                success = f'Admin "{new_username}" created.'

        elif action == "delete":
            target_username = request.form.get("username", "")
            total_admins = db.execute("SELECT COUNT(*) c FROM console_users").fetchone()["c"]
            if target_username == session["username"]:
                error = "You can't remove your own account while logged in as it — ask another admin to do it."
            elif total_admins <= 1:
                error = "Can't remove the last remaining admin account — that would lock everyone out."
            else:
                db.execute("DELETE FROM console_users WHERE username = ?", (target_username,))
                db.commit()
                success = f'Admin "{target_username}" removed.'

    admins = db.execute("SELECT username, totp_enabled, updated_at FROM console_users ORDER BY username").fetchall()
    return render_template(
        "manage_admins.html", admins=admins, error=error, success=success, active="manage_admins",
    )


@app.route("/")
def dashboard():
    db = get_db()
    devices = with_status(db.execute("SELECT * FROM devices ORDER BY name").fetchall())
    total_users = db.execute("SELECT COUNT(*) c FROM employees WHERE status='Working'").fetchone()["c"]
    today = datetime.date.today().strftime("%m/%d/%y")
    today_punches = db.execute(
        "SELECT COUNT(*) c FROM attendance WHERE log_date LIKE ?", (f"{today}%",)
    ).fetchone()["c"]
    recent = db.execute(
        "SELECT * FROM attendance ORDER BY device_log_id DESC LIMIT 15"
    ).fetchall()
    return render_template(
        "dashboard.html", devices=devices, total_users=total_users,
        today_punches=today_punches, recent=recent, active="dashboard",
    )


@app.route("/devices")
def devices_page():
    db = get_db()
    devices = with_status(db.execute("SELECT * FROM devices ORDER BY name").fetchall())
    return render_template("devices.html", devices=devices, active="devices")


def _build_logs_query(user_filter, date_from, date_to, device_filter, limit):
    """Shared by the Logs page and the CSV export - same filters, same
    chronological-safe date range handling, just a different row limit."""
    query = "SELECT * FROM attendance WHERE 1=1"
    params = []
    if user_filter:
        query += " AND (user_id LIKE ? OR employee_name LIKE ?)"
        params += [f"%{user_filter}%", f"%{user_filter}%"]
    if device_filter:
        query += " AND device_id = ?"
        params.append(device_filter)
    # log_date is stored as text "MM/DD/YY HH:MM:SS" - a plain string
    # compare on that breaks across year boundaries (e.g. "01/15/27" <
    # "12/01/26" as strings, even though Jan 2027 is later). Reorder to
    # YY/MM/DD first so the comparison is actually chronological.
    sortable_log_date = "substr(log_date,7,2) || substr(log_date,1,2) || substr(log_date,4,2)"
    if date_from:
        try:
            d = datetime.datetime.strptime(date_from, "%Y-%m-%d")
            query += f" AND {sortable_log_date} >= ?"
            params.append(d.strftime("%y%m%d"))
        except ValueError:
            pass
    if date_to:
        try:
            d = datetime.datetime.strptime(date_to, "%Y-%m-%d")
            query += f" AND {sortable_log_date} <= ?"
            params.append(d.strftime("%y%m%d"))
        except ValueError:
            pass
    query += f" ORDER BY device_log_id DESC LIMIT {int(limit)}"
    return query, params


@app.route("/logs")
def logs_page():
    db = get_db()
    user_filter = request.args.get("user", "").strip()
    date_from = request.args.get("date_from", "").strip()  # YYYY-MM-DD
    date_to = request.args.get("date_to", "").strip()  # YYYY-MM-DD
    device_filter = request.args.get("device", "").strip()
    # don't dump the whole recent-logs table by default - only search once a
    # date or a user/ID has actually been picked (device alone doesn't count,
    # that's still "show me everything on this device")
    searched = bool(user_filter or date_from or date_to)

    logs = []
    if searched:
        query, params = _build_logs_query(user_filter, date_from, date_to, device_filter, limit=500)
        logs = db.execute(query, params).fetchall()

    devices = db.execute("SELECT * FROM devices ORDER BY name").fetchall()
    return render_template(
        "logs.html", logs=logs, devices=devices, searched=searched,
        user_filter=user_filter, date_from=date_from, date_to=date_to, device_filter=device_filter,
        active="logs",
    )


@app.route("/logs/export.csv")
def logs_export():
    db = get_db()
    user_filter = request.args.get("user", "").strip()
    date_from = request.args.get("date_from", "").strip()
    date_to = request.args.get("date_to", "").strip()
    device_filter = request.args.get("device", "").strip()

    query, params = _build_logs_query(user_filter, date_from, date_to, device_filter, limit=100000)
    rows = db.execute(query, params).fetchall()

    output = io.StringIO()
    writer = csv.writer(output)
    writer.writerow(["Log ID", "User ID", "Name", "Date/Time", "Direction", "Device ID", "Status"])
    for r in rows:
        writer.writerow([
            r["device_log_id"], r["user_id"], r["employee_name"] or "",
            r["log_date"], r["direction"], r["device_id"], r["employee_status"] or "",
        ])

    filename = f"biomax_logs_{datetime.date.today().isoformat()}.csv"
    return Response(
        output.getvalue(),
        mimetype="text/csv",
        headers={"Content-Disposition": f"attachment; filename={filename}"},
    )


@app.route("/users")
def users_page():
    db = get_db()
    search = request.args.get("q", "").strip()
    device_filter = request.args.get("device", "").strip()
    devices = with_status(db.execute("SELECT * FROM devices ORDER BY name").fetchall())
    device_sync_info = None
    device_online = next((d["online"] for d in devices if d["device_id"] == device_filter), None)

    if device_filter:
        # source of truth: what's actually enrolled on that device (device_users,
        # populated by the "Sync Users" button) - not the global SmartOffice list.
        # one person can have several backup slots (fingers) -> collapse to 1 row each.
        query = """SELECT employee_code, employee_name, MAX(enabled) as enabled, COUNT(*) as backup_number
                   FROM device_users WHERE device_id = ?"""
        params = [device_filter]
        if search:
            query += " AND (employee_name LIKE ? OR employee_code LIKE ?)"
            params += [f"%{search}%", f"%{search}%"]
        query += " GROUP BY employee_code, employee_name ORDER BY employee_name"
        employees = db.execute(query, params).fetchall()
        sync_row = db.execute(
            "SELECT synced_at FROM device_users WHERE device_id = ? ORDER BY synced_at DESC LIMIT 1",
            (device_filter,),
        ).fetchone()
        device_sync_info = sync_row["synced_at"] if sync_row else None
    else:
        # IS NOT (not !=) so a NULL status doesn't get accidentally excluded too -
        # != against NULL is NULL, not true, which would hide the row entirely.
        query = "SELECT * FROM employees WHERE status IS NOT 'Deleted'"
        params = []
        if search:
            query += " AND (employee_name LIKE ? OR employee_code LIKE ?)"
            params += [f"%{search}%", f"%{search}%"]
        query += " ORDER BY employee_name"
        employees = db.execute(query, params).fetchall()

    return render_template(
        "users.html", employees=employees, search=search, devices=devices,
        device_filter=device_filter, device_sync_info=device_sync_info,
        device_online=device_online, active="users",
    )


@app.route("/sync-users", methods=["POST"])
def sync_users():
    db = get_db()
    device_id = request.form.get("device_id", "")
    devices = db.execute("SELECT * FROM devices ORDER BY name").fetchall()
    targets = devices if device_id == "all" else [d for d in devices if d["device_id"] == device_id]

    now = datetime.datetime.now().isoformat()
    synced, skipped = [], []
    adopted = 0  # device-enrolled people we didn't previously know about
    for device in targets:
        if not ping_ok(device["ip_address"]):
            skipped.append(f"{device['name']} (unreachable)")
            continue
        result = list_device_users(device["ip_address"])
        if not result["success"]:
            skipped.append(f"{device['name']} ({result.get('error', 'sync failed')})")
            continue
        db.execute("DELETE FROM device_users WHERE device_id = ?", (device["device_id"],))
        for u in result["users"]:
            db.execute(
                """INSERT INTO device_users (device_id, employee_code, employee_name, backup_number, privilege, enabled, synced_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?)""",
                (device["device_id"], u["code"], u["name"], u["backup_number"], u["privilege"], u["enabled"], now),
            )
            # Anyone enrolled by walking up to a device never passes through Create
            # User, so they never reach `employees` - which is what the Users search,
            # Copy Fingerprint and Delete User pickers all read from. They were
            # therefore invisible in those three places despite being on the device.
            # INSERT OR IGNORE, never UPDATE: an existing row may say 'Deleted' on
            # purpose, and rewriting it here would silently undo an offboarding.
            cur = db.execute(
                """INSERT OR IGNORE INTO employees (employee_code, employee_name, status, updated_at)
                   VALUES (?, ?, 'Working', ?)""",
                (u["code"], u["name"] if u["name"] and u["name"] != "-" else None, now),
            )
            adopted += cur.rowcount
        db.commit()
        synced.append(f"{device['name']} ({len(result['users'])} users)")

    if synced:
        flash(f"✅ Synced: {', '.join(synced)}", "success")
    if adopted:
        flash(f"➕ Added {adopted} employee(s) who were enrolled directly at a device — "
              f"they'll now show up in Users, Copy Fingerprint and Delete User.", "success")
    if skipped:
        flash(f"⚠️ Skipped: {', '.join(skipped)}", "error")

    return redirect(url_for("users_page", device=device_id if device_id != "all" else ""))


@app.route("/create-user", methods=["GET", "POST"])
def create_user_page():
    db = get_db()
    devices = with_status(db.execute("SELECT * FROM devices ORDER BY name").fetchall())
    result = None
    form_values = {"device_id": "", "enroll_number": "", "name": ""}

    if request.method == "POST":
        form_values["device_id"] = request.form.get("device_id", "")
        form_values["enroll_number"] = request.form.get("enroll_number", "").strip()
        form_values["name"] = request.form.get("name", "").strip()

        device = db.execute(
            "SELECT * FROM devices WHERE device_id = ?", (form_values["device_id"],)
        ).fetchone()

        if not device:
            result = {"success": False, "error": "Please select a device."}
        elif not form_values["enroll_number"] or not form_values["name"]:
            result = {"success": False, "error": "Employee ID and name are required."}
        elif _device_type(device) == "adms":
            # pull-based device (Mantra 604): can't push to it - queue a
            # DATA UPDATE USERINFO it'll apply on its next check-in.
            _enqueue_adms_command(db, device["device_id"], "create",
                                  form_values["enroll_number"], form_values["name"])
            db.execute(
                """INSERT INTO employees (employee_code, employee_name, status, updated_at)
                   VALUES (?, ?, 'Working', ?)
                   ON CONFLICT(employee_code) DO UPDATE SET
                       employee_name=excluded.employee_name, status='Working', updated_at=excluded.updated_at""",
                (form_values["enroll_number"], form_values["name"], datetime.datetime.now().isoformat()),
            )
            db.commit()
            result = {"success": True, "queued": True, "device_name": device["name"]}
        elif not ping_ok(device["ip_address"]):
            result = {"success": False, "error": f"Device {device['name']} ({device['ip_address']}) is not reachable right now. Not attempting the push."}
        else:
            pusher = mbio_push_user if _device_type(device) == "mbio" else push_user
            result = pusher(device["ip_address"], form_values["enroll_number"], form_values["name"])
            result["device_name"] = device["name"]
            if result["success"]:
                # SmartOffice doesn't know about this user (we pushed straight to the
                # device), so it won't show up via the normal MDB sync. Record it in
                # our own table immediately so it appears in Users right away.
                db.execute(
                    """INSERT INTO employees (employee_code, employee_name, status, updated_at)
                       VALUES (?, ?, 'Working', ?)
                       ON CONFLICT(employee_code) DO UPDATE SET
                           employee_name=excluded.employee_name, status='Working', updated_at=excluded.updated_at""",
                    (form_values["enroll_number"], form_values["name"], datetime.datetime.now().isoformat()),
                )
                db.commit()

    return render_template(
        "create_user.html", devices=devices, result=result,
        form_values=form_values, active="create_user",
    )


@app.route("/delete-user", methods=["GET", "POST"])
def delete_user_page():
    db = get_db()
    devices = with_status(db.execute("SELECT * FROM devices ORDER BY name").fetchall())
    results = None
    summary = None
    form_values = {"device_id": "", "enroll_number": ""}
    selected_employee = None

    if request.method == "POST":
        form_values["device_id"] = request.form.get("device_id", "")
        form_values["enroll_number"] = request.form.get("enroll_number", "").strip()
        confirmed = request.form.get("confirm") == "yes"

        if form_values["device_id"] == "all":
            targets = devices
        else:
            targets = [d for d in devices if d["device_id"] == form_values["device_id"]]

        if not targets:
            results = [{"success": False, "device_name": "—", "error": "Please select a device."}]
        elif not form_values["enroll_number"]:
            results = [{"success": False, "device_name": "—", "error": "Employee ID is required."}]
        elif not confirmed:
            results = [{"success": False, "device_name": "—", "error": "You must tick the confirmation checkbox — this is irreversible."}]
        else:
            results = []
            for device in targets:
                if _device_type(device) == "adms":
                    # pull-based device (Mantra 604): queue a DATA DELETE USERINFO
                    _enqueue_adms_command(db, device["device_id"], "delete",
                                          form_values["enroll_number"])
                    results.append({
                        "success": True, "queued": True, "device_name": device["name"],
                    })
                    continue
                full = form_values["device_id"] == "all"
                if not ping_ok(device["ip_address"]):
                    err = f"({device['ip_address']}) not reachable right now — queued for retry."
                    _queue_delete_retry(db, device["device_id"],
                                        form_values["enroll_number"], full, err)
                    results.append({
                        "success": False, "device_name": device["name"], "error": err,
                    })
                    continue
                deleter = mbio_delete_user if _device_type(device) == "mbio" else delete_user
                r = deleter(device["ip_address"], form_values["enroll_number"])
                r["device_name"] = device["name"]
                if r.get("success"):
                    _clear_delete_retry(db, device["device_id"], form_values["enroll_number"])
                else:
                    # 606 is on Wi-Fi and its SDK handshake fails intermittently even
                    # while it still pings, so a failure here is usually temporary.
                    _queue_delete_retry(db, device["device_id"], form_values["enroll_number"],
                                        full, r.get("error") or "delete failed")
                results.append(r)

            # Marking someone Deleted locally is a claim that they can no longer
            # punch anywhere. Previously any single success was enough, so a
            # delete run while one device happened to be offline marked them
            # Deleted while they were still enrolled on the device it skipped -
            # they kept clocking in, and the console hid them from Users, so
            # nobody could see it. Only make that claim when every targeted
            # device actually confirmed, and only when all devices were targeted.
            failed = [r["device_name"] for r in results if not r.get("success")]
            all_devices_targeted = form_values["device_id"] == "all"

            if failed:
                reason = ("Still enrolled on " + ", ".join(failed) +
                          " — queued, and retried automatically every few minutes until "
                          "that device confirms. They'll be marked Deleted then.")
            elif not all_devices_targeted:
                reason = ("Left active because only one device was targeted — "
                          "the other devices were not part of this delete.")
            else:
                reason = None

            summary = {
                "succeeded": [r["device_name"] for r in results if r.get("success")],
                "failed": failed,
                "marked_deleted": reason is None,
                "reason": reason,
            }

            if reason is None:
                # mirror the deletion locally too, so Users/Delete dropdowns stop
                # showing this person as Working right away
                db.execute(
                    "UPDATE employees SET status='Deleted', updated_at=? WHERE employee_code=?",
                    (datetime.datetime.now().isoformat(), form_values["enroll_number"]),
                )
                db.commit()

    if form_values["enroll_number"]:
        selected_employee = db.execute(
            "SELECT * FROM employees WHERE employee_code = ?", (form_values["enroll_number"],)
        ).fetchone()

    employees = db.execute(
        "SELECT * FROM employees WHERE status='Working' ORDER BY employee_name"
    ).fetchall()

    return render_template(
        "delete_user.html", devices=devices, results=results, summary=summary,
        form_values=form_values, employees=employees,
        selected_employee=selected_employee, active="delete_user",
    )


@app.route("/copy-fingerprint", methods=["GET", "POST"])
def copy_fingerprint_page():
    db = get_db()
    devices = with_status(db.execute("SELECT * FROM devices ORDER BY name").fetchall())
    results = None
    form_values = {"source_device_id": "", "enroll_number": "", "target_device_ids": []}
    selected_employee = None

    if request.method == "POST":
        form_values["source_device_id"] = request.form.get("source_device_id", "")
        form_values["enroll_number"] = request.form.get("enroll_number", "").strip()
        form_values["target_device_ids"] = request.form.getlist("target_device_ids")

        source = next((d for d in devices if d["device_id"] == form_values["source_device_id"]), None)
        targets = [d for d in devices if d["device_id"] in form_values["target_device_ids"]]

        if not source:
            results = [{"success": False, "device_name": "—", "error": "Please select a source device."}]
        elif not form_values["enroll_number"]:
            results = [{"success": False, "device_name": "—", "error": "Employee ID is required."}]
        elif not targets:
            results = [{"success": False, "device_name": "—", "error": "Select at least one target device."}]
        elif not source["online"]:
            results = [{"success": False, "device_name": source["name"], "error": f"Source device ({source['ip_address']}) is not reachable right now."}]
        else:
            # try the local cache first (instant) so copy_fingerprint can skip its
            # own live lookup - every extra Wine invocation costs ~4.6s cold-start,
            # measured, so avoiding one here roughly a third of the total time.
            # Falls back to a live device query on its own if this misses/is stale.
            cached_row = db.execute(
                """SELECT employee_name FROM device_users
                   WHERE device_id=? AND employee_code=? AND employee_name IS NOT NULL AND employee_name != '-'
                   ORDER BY synced_at DESC LIMIT 1""",
                (source["device_id"], form_values["enroll_number"]),
            ).fetchone()
            cached_name = cached_row["employee_name"] if cached_row else None

            results = []
            for target in targets:
                if target["device_id"] == source["device_id"]:
                    results.append({"success": False, "device_name": target["name"], "error": "Same as source device — skipped."})
                    continue
                if not target["online"]:
                    results.append({"success": False, "device_name": target["name"], "error": f"({target['ip_address']}) not reachable right now — skipped."})
                    continue
                r = copy_fingerprint(source["ip_address"], target["ip_address"], form_values["enroll_number"], name=cached_name)
                r["device_name"] = target["name"]
                results.append(r)

    if form_values["enroll_number"]:
        selected_employee = db.execute(
            "SELECT * FROM employees WHERE employee_code = ?", (form_values["enroll_number"],)
        ).fetchone()

    employees = db.execute(
        "SELECT * FROM employees WHERE status='Working' ORDER BY employee_name"
    ).fetchall()

    return render_template(
        "copy_fingerprint.html", devices=devices, results=results,
        form_values=form_values, employees=employees,
        selected_employee=selected_employee, active="copy_fingerprint",
    )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5001)
