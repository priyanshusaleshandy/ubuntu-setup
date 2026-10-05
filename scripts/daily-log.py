#!/usr/bin/env python3
"""Turn today's ActivityWatch data into a topic-wise Obsidian daily note.

Runs at 19:00 via Task Scheduler. No times or durations end up in the note --
only what work was done, so the day can be recalled at a glance.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path

AW = "http://localhost:5600/api/0"
VAULT = Path.home() / "Documents" / "Obsidian Vault" / "Daily Logs"
CLAUDE = Path.home() / ".local" / "bin" / "claude"
START = "<!-- auto-log:start -->"
END = "<!-- auto-log:end -->"

# Window titles from these never leave the machine.
SECRET_APPS = ("bitwarden", "vaultwarden", "keepass", "1password")
# Shell chrome that says nothing about the work itself.
NOISE_APPS = ("lockapp.exe", "searchhost.exe", "shellexperiencehost.exe",
              "startmenuexperiencehost.exe", "textinputhost.exe", "idle")


def aw_query(day):
    """Merged, AFK-filtered window events for `day`, longest first."""
    start = datetime(day.year, day.month, day.day).astimezone()
    end = start + timedelta(days=1)
    body = {
        "timeperiods": [f"{start.isoformat()}/{end.isoformat()}"],
        "query": [" ".join([
            'win = flood(query_bucket(find_bucket("aw-watcher-window_")));',
            'afk = flood(query_bucket(find_bucket("aw-watcher-afk_")));',
            'afk = filter_keyvals(afk, "status", ["not-afk"]);',
            'win = filter_period_intersect(win, afk);',
            'win = merge_events_by_keys(win, ["app", "title"]);',
            'win = sort_by_duration(win);',
            'RETURN = limit_events(win, 400);',
        ])],
    }
    req = urllib.request.Request(
        f"{AW}/query/", data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)[0]


def to_lines(events):
    """One 'app | title | Nm' line per event, noise and secrets dropped."""
    lines = []
    for e in events:
        mins = round(e.get("duration", 0) / 60)
        if mins < 1:
            continue
        app = (e["data"].get("app") or "").strip()
        title = re.sub(r"\s+", " ", (e["data"].get("title") or "").strip())
        low = f"{app} {title}".lower()
        if app.lower() in NOISE_APPS or not title:
            continue
        if any(s in low for s in SECRET_APPS):
            continue
        lines.append(f"{app} | {title[:140]} | {mins}m")
        if len(lines) >= 150:
            break
    return lines


INSTRUCTION = """\
Below is one day of computer activity from ActivityWatch: window titles, browser \
tab titles and terminal titles, each with how long it was focused.

Write the day's work log as Markdown bullets, grouped by topic (the system, client \
or project worked on -- e.g. BioMax, Sophos, Cloudflare, IT Console, Omada, n8n). \
Use a bold topic name at the start of each bullet.

Rules:
- NEVER mention durations, hours, minutes, clock times or "spent time on". The \
reader wants to recall WHAT was done, not how long it took.
- Say what was actually worked on, in past tense, specific enough to jog memory. \
Infer the task from file names, hostnames, dashboards and tab titles.
- Merge everything about one topic into a single bullet. Aim for 4-10 bullets total.
- Drop idle browsing, notifications and background noise. If personal or \
non-work activity was significant, fold it into one final "Other" bullet.
- If the data is too thin to tell what was done, output exactly: - Light activity; \
nothing substantial captured.
- Output ONLY the bullet lines. No preamble, no heading, no closing remark.
"""


def summarise(lines):
    res = subprocess.run(
        [str(CLAUDE), "-p", INSTRUCTION, "--model", "sonnet"],
        input="\n".join(lines), capture_output=True, text=True,
        encoding="utf-8", errors="replace", timeout=600)
    if res.returncode != 0:
        sys.exit(f"claude failed ({res.returncode}): {res.stderr.strip()[:500]}")
    out = res.stdout.strip()
    # Keep only bullet lines, in case of a stray preamble.
    bullets = [l.rstrip() for l in out.splitlines() if l.lstrip().startswith("- ")]
    return "\n".join(bullets) or "- Light activity; nothing substantial captured."


def write_note(day, bullets, dry_run=False):
    path = VAULT / f"{day:%Y-%m-%d}.md"
    block = f"{START}\n{bullets}\n{END}"

    if not path.exists():
        body = (f"# 📅 Daily Log — {day:%Y-%m-%d}\n\n#daily-log\n\n"
                f"**Related:** [[Project]]\n\n---\n\n"
                f"## Notes & Activity Log\n\n{block}\n")
    else:
        existing = path.read_text(encoding="utf-8")
        if START in existing and END in existing:
            body = re.sub(f"{re.escape(START)}.*?{re.escape(END)}",
                          block.replace("\\", "\\\\"), existing, flags=re.S)
        else:
            body = (existing.rstrip() + "\n\n## Auto Log (ActivityWatch)\n\n"
                    + block + "\n")

    if dry_run:
        print(body)
        return path
    VAULT.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8")
    return path


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser()
    ap.add_argument("--date", help="YYYY-MM-DD (default: today)")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    day = (datetime.strptime(a.date, "%Y-%m-%d").date() if a.date
           else datetime.now().date())

    try:
        events = aw_query(day)
    except urllib.error.URLError as e:
        sys.exit(f"ActivityWatch not reachable at {AW}: {e}")

    lines = to_lines(events)
    if not lines:
        sys.exit(f"No activity recorded for {day}; note not written.")

    path = write_note(day, summarise(lines), a.dry_run)
    print(f"{'would write' if a.dry_run else 'wrote'} {path} ({len(lines)} entries)")


if __name__ == "__main__":
    main()
