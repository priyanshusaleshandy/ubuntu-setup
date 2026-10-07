#!/usr/bin/env python3
"""
Attendance log retention: keep the last N days, drop everything older.

Runs against the console's SQLite DB (all devices at once). Dry-run by default -
it prints what it would remove and changes nothing until --apply is passed, and
--apply always writes a CSV of every row it deletes first.

Two date shapes live in `attendance.log_date`:
  MM/DD/YY HH:MM:SS   - what every device path writes today
  YYYY-MM-DD HH:MM:SS - what biomax_sync.py's FK623 path would write
Both are handled. Note the column is TEXT, so age can NOT be filtered with a SQL
comparison (lexicographically '01/01/25' sorts before '12/31/24') - rows are
parsed in Python and deleted by rowid.
"""
import argparse
import csv
import datetime
import os
import sqlite3

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DB_FILE = os.path.join(BASE_DIR, "biomax.db")
BACKUP_DIR = os.path.join(BASE_DIR, "retention-backups")
DEFAULT_DAYS = 30

DATE_FORMATS = ("%m/%d/%y %H:%M:%S", "%Y-%m-%d %H:%M:%S")


def parse_log_date(value):
    """Return a datetime, or None if the value is in neither known shape."""
    for fmt in DATE_FORMATS:
        try:
            return datetime.datetime.strptime(value, fmt)
        except (ValueError, TypeError):
            continue
    return None


def classify(conn, cutoff):
    """Split every attendance row into keep / delete / unparseable.

    Unparseable dates are never deleted - a row we can't age is a row we can't
    safely judge, and silently dropping it would be the worst outcome."""
    to_delete, unparseable = [], []
    kept = 0
    for rid, log_date in conn.execute("SELECT rowid, log_date FROM attendance"):
        dt = parse_log_date(log_date)
        if dt is None:
            unparseable.append(rid)
        elif dt < cutoff:
            to_delete.append(rid)
        else:
            kept += 1
    return to_delete, kept, unparseable


def summarise(conn, rowids):
    """Per-device counts for the rows about to go, so the dry run is readable."""
    counts = {}
    for i in range(0, len(rowids), 900):
        chunk = rowids[i:i + 900]
        q = "SELECT device_id, COUNT(*) FROM attendance WHERE rowid IN (%s) GROUP BY device_id" % (
            ",".join("?" * len(chunk)))
        for device_id, n in conn.execute(q, chunk):
            counts[device_id] = counts.get(device_id, 0) + n
    return counts


def backup(conn, rowids, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    written = 0
    with open(path, "w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(["device_id", "user_id", "employee_name", "employee_status",
                         "log_date", "direction", "verification_mode", "synced_at"])
        for i in range(0, len(rowids), 900):
            chunk = rowids[i:i + 900]
            q = ("SELECT device_id, user_id, employee_name, employee_status, log_date, "
                 "direction, verification_mode, synced_at FROM attendance WHERE rowid IN (%s)"
                 % (",".join("?" * len(chunk))))
            for row in conn.execute(q, chunk):
                writer.writerow(row)
                written += 1
    return written


def delete(conn, rowids):
    removed = 0
    for i in range(0, len(rowids), 900):
        chunk = rowids[i:i + 900]
        cur = conn.execute("DELETE FROM attendance WHERE rowid IN (%s)" % (",".join("?" * len(chunk))), chunk)
        removed += cur.rowcount
    conn.commit()
    return removed


def main():
    ap = argparse.ArgumentParser(description="Trim attendance logs to the last N days.")
    ap.add_argument("--days", type=int, default=DEFAULT_DAYS,
                    help=f"how many days of logs to keep (default {DEFAULT_DAYS})")
    ap.add_argument("--apply", action="store_true",
                    help="actually delete; without this it only reports")
    ap.add_argument("--db", default=DB_FILE)
    args = ap.parse_args()

    cutoff = datetime.datetime.now() - datetime.timedelta(days=args.days)
    conn = sqlite3.connect(args.db, timeout=30.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")

    try:
        total = conn.execute("SELECT COUNT(*) FROM attendance").fetchone()[0]
        to_delete, kept, unparseable = classify(conn, cutoff)

        print(f"cutoff        : {cutoff:%Y-%m-%d %H:%M:%S}  (keeping {args.days} days)")
        print(f"total rows    : {total}")
        print(f"keep          : {kept}")
        print(f"delete        : {len(to_delete)}")
        if unparseable:
            print(f"unparseable   : {len(unparseable)}  (kept - date format not recognised)")

        if to_delete:
            print("\nper device:")
            for device_id, n in sorted(summarise(conn, to_delete).items()):
                print(f"  device {device_id}: {n}")

        if not args.apply:
            print("\nDRY RUN - nothing changed. Re-run with --apply to delete.")
            return

        if not to_delete:
            print("\nnothing to delete.")
            return

        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        path = os.path.join(BACKUP_DIR, f"attendance-pruned-{stamp}.csv")
        written = backup(conn, to_delete, path)
        print(f"\nbacked up {written} row(s) -> {path}")

        removed = delete(conn, to_delete)
        print(f"deleted {removed} row(s)")
        print(f"remaining : {conn.execute('SELECT COUNT(*) FROM attendance').fetchone()[0]}")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
