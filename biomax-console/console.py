#!/usr/bin/env python3
"""BioMax attendance console - devices/logs/users viewing + user push."""
import sqlite3
import os
import io
import base64
import datetime
import subprocess
from concurrent.futures import ThreadPoolExecutor
from flask import Flask, render_template, request, g, redirect, url_for, flash, session
from werkzeug.security import generate_password_hash, check_password_hash
import pyotp
import qrcode

from device_push import push_user, delete_user, list_device_users, copy_fingerprint

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
    return g.db


@app.teardown_appcontext
def close_db(exc):
    db = g.pop("db", None)
    if db is not None:
        db.close()


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


@app.route("/logs")
def logs_page():
    db = get_db()
    user_filter = request.args.get("user", "").strip()
    date_filter = request.args.get("date", "").strip()  # YYYY-MM-DD
    device_filter = request.args.get("device", "").strip()
    # don't dump the whole recent-logs table by default - only search once a
    # date or a user/ID has actually been picked (device alone doesn't count,
    # that's still "show me everything on this device")
    searched = bool(user_filter or date_filter)

    logs = []
    if searched:
        query = "SELECT * FROM attendance WHERE 1=1"
        params = []
        if user_filter:
            query += " AND (user_id LIKE ? OR employee_name LIKE ?)"
            params += [f"%{user_filter}%", f"%{user_filter}%"]
        if device_filter:
            query += " AND device_id = ?"
            params.append(device_filter)
        if date_filter:
            try:
                d = datetime.datetime.strptime(date_filter, "%Y-%m-%d")
                mdy = d.strftime("%m/%d/%y")
                query += " AND log_date LIKE ?"
                params.append(f"{mdy}%")
            except ValueError:
                pass
        query += " ORDER BY device_log_id DESC LIMIT 500"
        logs = db.execute(query, params).fetchall()

    devices = db.execute("SELECT * FROM devices ORDER BY name").fetchall()
    return render_template(
        "logs.html", logs=logs, devices=devices, searched=searched,
        user_filter=user_filter, date_filter=date_filter, device_filter=device_filter,
        active="logs",
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
        db.commit()
        synced.append(f"{device['name']} ({len(result['users'])} users)")

    if synced:
        flash(f"✅ Synced: {', '.join(synced)}", "success")
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
        elif not ping_ok(device["ip_address"]):
            result = {"success": False, "error": f"Device {device['name']} ({device['ip_address']}) is not reachable right now. Not attempting the push."}
        else:
            result = push_user(device["ip_address"], form_values["enroll_number"], form_values["name"])
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
                if not ping_ok(device["ip_address"]):
                    results.append({
                        "success": False, "device_name": device["name"],
                        "error": f"({device['ip_address']}) not reachable right now — skipped.",
                    })
                    continue
                r = delete_user(device["ip_address"], form_values["enroll_number"])
                r["device_name"] = device["name"]
                results.append(r)

            if any(r.get("success") for r in results):
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
        "delete_user.html", devices=devices, results=results,
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
