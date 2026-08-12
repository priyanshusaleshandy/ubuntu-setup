#!/usr/bin/env python3
"""BioMax attendance console - devices/logs/users viewing + user push."""
import sqlite3
import os
import datetime
import subprocess
from concurrent.futures import ThreadPoolExecutor
from flask import Flask, render_template, request, g, redirect, url_for, flash

from device_push import push_user, delete_user, list_device_users, copy_fingerprint

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DB_FILE = os.path.join(BASE_DIR, "biomax.db")

app = Flask(__name__)
app.secret_key = os.environ.get("BIOMAX_SECRET_KEY", os.urandom(24))


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
        g.db = sqlite3.connect(DB_FILE)
        g.db.row_factory = sqlite3.Row
    return g.db


@app.teardown_appcontext
def close_db(exc):
    db = g.pop("db", None)
    if db is not None:
        db.close()


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
        "logs.html", logs=logs, devices=devices,
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
        query = "SELECT * FROM employees"
        params = []
        if search:
            query += " WHERE employee_name LIKE ? OR employee_code LIKE ?"
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
            results = []
            for target in targets:
                if target["device_id"] == source["device_id"]:
                    results.append({"success": False, "device_name": target["name"], "error": "Same as source device — skipped."})
                    continue
                if not target["online"]:
                    results.append({"success": False, "device_name": target["name"], "error": f"({target['ip_address']}) not reachable right now — skipped."})
                    continue
                r = copy_fingerprint(source["ip_address"], target["ip_address"], form_values["enroll_number"])
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
