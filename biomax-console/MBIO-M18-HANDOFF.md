# Device 604 — MORX mBio-M18 (EBKN/Realand A30C) Integration

> Reference for the "604" attendance device in the BioMax console. Started as a
> reverse-engineering handoff; as of **2026-09-03 the integration is live and
> working**, so this is now the current-state document rather than a to-do list.
> Historical dead ends are kept only where they stop someone repeating them.

## Status

| Capability | State |
|---|---|
| Live attendance punches → `biomax.db` | ✅ working (push channel) |
| Bulk history pull | ✅ working (SDK), ~81k records in <60s |
| Create user from the console | ✅ working |
| Delete user from the console | ✅ working |
| Read/copy fingerprint templates | ❌ not possible — see [Fingerprints](#fingerprints-cannot-be-copied-onto-604) |
| Listener survives a reboot | ⚠️ not yet — systemd unit staged, needs sudo |

## The device — hard facts

| Field | Value |
|---|---|
| Model | **MORX mBio-M18** (brand MORX; OEM Union Business Machines) |
| Firmware family | **EBKN / Realand**, "BioFace Modular Protocol" |
| TerminalType | `A30C` · TerminalID `1` · DeviceUID `38AC61E4-2E342D93` |
| DeviceSerialNo | `M2023081315` |
| IP / MAC | `192.168.126.10` · `00:23:79:B9:E7:A0` (OUI = Union Business Machines) |
| Ports | pushes to Manager PC `:9099`; **listens on TCP 5005** for the SDK |
| DB row | `devices.device_id = 9`, name `604`, `device_type = 'mbio'` |
| Capacity in use | 77 users, 99 fingerprints, 3 managers, 1 card |

M50 / M61 / A30C / F500 terminals — sold as MORX, Mantra, Secureye and Union
Business Machines — are all the **same firmware family and protocol**.

**It is not an FK623 device and not an iclock/ADMS device.** An earlier commit
assumed iclock; that was wrong. `FK_ConnectNet` returning `-2` is not a licence
problem — `FK623Attend.dll` is simply the wrong DLL for this hardware.

### Device menu settings that make this work
- **[Communication Settings] → Event Send Type = `TCP/IP`** (this is what makes it push)
- **[BG PC Settings] → Manager PC Addr = `192.168.126.180`, Port = `9099`**
- **[AC Setting] → Authenticate by Server = `NO`** (so it never waits on us to admit people)
- [TCP/IP Settings] TCP Port `5005`, Subnet `255.255.254.0`, GW `192.168.126.1`

---

## Architecture: two independent channels

The device speaks **two protocols at once**, and — unlike the M61 firmware other
people have documented — the A30C happily runs both simultaneously. No mode
toggle is needed.

```
                    push (device is the client)
  604 ──────── raw XML over TCP ────────▶ .180:9099   mbio_listener.py ──▶ biomax.db
  .10
      ◀─────── SBXPCDLL.dll over TCP 5005 ──────── .101 (Wine)  ◀── console.py / device_push.py
                    SDK (device is the server)
```

- **Push channel** = live attendance. One TCP connection per event, device closes it.
- **SDK channel** = everything else: create/delete users, bulk log pull, device
  status, clock, wiping log memory.

---

## Push protocol (live punches)

The device opens a connection, sends one raw XML `<Message>` (no HTTP envelope),
waits for an ack, closes, and reconnects for the next event. It also opens an
idle connection roughly every 9s and sends nothing — that is normal churn, not a
command channel.

```xml
<?xml version="1.0"?><Message>
<TerminalType>A30C</TerminalType><TerminalID>1</TerminalID>
<DeviceSerialNo>M2023081315</DeviceSerialNo><DeviceUID>38AC61E4-2E342D93</DeviceUID>
<TransID>76359</TransID><Event>TimeLog</Event>
<Year>2026</Year><Month>7</Month><Day>13</Day>
<Hour>12</Hour><Minute>0</Minute><Second>31</Second>
<UserID>315</UserID><DoorID>1</DoorID>
<AttendStat> </AttendStat><VerifMode>FP</VerifMode><APStat>None</APStat><ewi>0</ewi>
</Message>
```

Date parts are **not zero-padded** (`Month=7`, not `07`).

### The ack — this was the whole blocker

```
<?xml version="1.0"?><Message><Request>UploadedLog</Request><TransID>{tid}</TransID></Message>\x00
```

- The tag is **`<Request>`**, counter-intuitively — not `<Response>`, not `<Return>`.
- **The trailing `0x00` byte is mandatory.** Without it the device's parser never
  sees end-of-message, times out, and resends the same TransID forever.
- ASCII, no HTTP headers, no Content-Length, no trailing whitespace.
- Only `<Request>` and `<TransID>` are read; extra fields are ignored.

| Device `<Event>` | Server replies `<Request>` |
|---|---|
| `TimeLog` / `AdminLog` / `Alarm` | `UploadedLog` |
| `KeepAlive` | `KeptAlive` |

Four ack shapes were tried before the protocol was identified and all failed for
the same two reasons (wrong tag, missing NUL): `<Return>1</Return>` with and
without the XML declaration, with and without `<TransID>`, and with `<Event>`
echoed back. Don't re-derive these.

### The listener

`~/biomax-mbio/mbio_listener.py` on `.180` — repo copy `biomax-console/mbio_listener.py`.

- Listens on `0.0.0.0:9099` (ufw allows 9099/tcp).
- **Stores the punch in `biomax.db` before acking.** Acking first would let a
  failed insert lose a punch permanently; staying silent makes the device retry.
- Writes `device_id='9'`, `log_date` as `MM/DD/YY HH:MM:SS`.
- `direction` comes from `<AttendStat>` (`...On` → `in`, `...Off` → `out`), and is
  left blank when the device sends nothing rather than guessing.
- Idle connections and KeepAlive are handled silently to keep the log readable.
- Log `~/biomax-mbio/mbio.log`, pidfile `~/biomax-mbio/mbio.pid`.

**Do not put this back in `/tmp`** — the first version lived there and was wiped by
a reboot, which is how the device ended up with a two-month backlog.

---

## SDK channel (`SBXPCDLL.dll` under Wine)

Runs on the Mac Mini `.101` in `~/mbio-push/`, reusing the Wine prefix the FK623
bridge already uses (`/Users/admin/biomax-push/wineprefix`). Same pattern as
`fk_push.exe` / `fk_delete.exe`, different vendor SDK.

### Required files, all in `~/mbio-push/`
`SBXPCDLL.dll`, `SBPCCOMM.dll`, **`GEN_FONT.dll`** — missing `GEN_FONT.dll` gives
`LOADFAIL 126` (ERROR_MOD_NOT_FOUND) with no other clue.

### Calling convention gotchas
- Exports are undecorated **with a leading underscore**: `_ConnectTcpip`,
  `_GetAllUserID`, `_SetUserName1`, … (86 exports total). All `__stdcall`.
- `_ConnectTcpip` takes the IP as a **`BSTR*`**, not `char*`.
- **Every user/enroll/log/status call must be wrapped in
  `_EnableDevice(machine, 0)` … `_EnableDevice(machine, 1)`.** Without the
  disable, calls block forever inside the DLL. The vendor GUI does this around
  every operation.
- Connect with password `0`: `ConnectTcpip(1, "192.168.126.10", 5005, 0)`.

### Our tools (sources in `biomax-console/`, built on `.180`)

| exe | Source | Purpose |
|---|---|---|
| `sbxpc_probe.exe` | `sbxpc_probe.c` | connect, serial, dump the user list |
| `sbxpc_user.exe` | `sbxpc_user.c` | `push` (create/rename) and `delete` a user |
| `sbxpc_getlogs.exe` | `sbxpc_getlogs.c` | bulk-pull every attendance log |
| `sbxpc_clearlogs.exe` | `sbxpc_clearlogs.c` | **destructive**: wipe log memory |
| `sbxpc_try.exe` | `sbxpc_try.c` | one-call-at-a-time diagnostic (`status`, `time`, `name`, `enroll`, `enroll1`) |
| `sbxpc_dumpenroll.exe` | `sbxpc_dumpenroll.c` | template dump attempt (see Fingerprints) |

Build (on `.180`, sources in `~/mbio-build/`):

```bash
i686-w64-mingw32-gcc -O2 -static -o NAME.exe NAME.c -lole32 -loleaut32
```

Run (on `.101`):

```bash
cd ~/mbio-push && WINEPREFIX=/Users/admin/biomax-push/wineprefix WINEDEBUG=-all \
  "/Users/admin/wine-setup/Wine Devel.app/Contents/Resources/wine/bin/wine" \
  sbxpc_probe.exe 192.168.126.10 5005 0 1
```

### Useful calls
| Need | Function |
|---|---|
| create / rename user | `_SetUserName1(machine, enrollNo, BSTR* name)` |
| delete user | `_DeleteEnrollData(machine, enrollNo, eMachineNo, backupNo)` per slot |
| list users | `_ReadAllUserID` then loop `_GetAllUserID` |
| bulk log pull | `_ReadAllGLogData` then loop `_GetAllGLogData` |
| counters | `_GetDeviceStatus(machine, index, uint*)` |
| clock | `_GetDeviceTime` / `_SetDeviceTime` |
| wipe logs | `_EmptyGeneralLogData` — **destructive** |

`_GetDeviceStatus` indices: 1 manager, 2 user, 3 fp, 4 password, 5 slog, **6 glog**,
7 card, 8 alarm, 9 face, 10 slog-unread, 11 glog-unread.

`_EmptyEnrollData` would wipe **every enrolled user**. It is deliberately not
referenced anywhere in this codebase.

### Slot numbering
`_GetAllUserID` returns one row per credential: `enroll|eMachineNo|backupNo|privilege|enabled`.

- `0`–`9` = fingerprint slots
- `11` = card, `15` = password
- **`50` = the user record itself**, not a credential

So a name-only user is `USER|<id>|1|50|0|1`, and a user with two fingers is
`0,1,50`. This is also why `_GetEnrollData(id, backup=50)` returns error 4 —
there is no template there to read. Delete returns `0` for slots that were never
populated; that is normal, not a failure.

---

## Fingerprints cannot be copied onto 604

Asked whether a new user's fingerprint could be sourced from one of the three
FK623 devices instead of re-enrolling. **No.**

| Family | FP template size |
|---|---|
| FK623 (606 / 605 / 502) | **1680 bytes** |
| EBKN A30C (604) | **1416 bytes** (`1404 + 12`, from the vendor sample's `DATASIZE`) |

Different vendors, different matching algorithms — the blobs are not
interchangeable even ignoring the size difference. Confirmed on the hardware:
604 will not hand back its own templates either.

| Call | Result |
|---|---|
| `_GetEnrollData1(1, 227, 0, …)` | hangs forever inside the DLL |
| `_GetEnrollData(1, 227, 1, 0, …)` | returns 1 but transfers **0 bytes** |
| `_GetEnrollData(1, 227, 1, 50, …)` | returns 0, `GetLastError` = 4 |

**Operational consequence:** for 604 the console creates the user record (ID,
name), and the person must present their finger **on 604 itself** once. There is
no `fk_copyenroll` shortcut here.

---

## Console integration

- `devices` row 9: `serial_number='M2023081315'`, `device_type='mbio'`.
- `device_push.py`
  - `mbio_push_user(ip, enroll, name)` → `sbxpc_user.exe push`
  - `mbio_delete_user(ip, enroll)` → `sbxpc_user.exe delete`
  - `mbio_list_logs(ip)` → `sbxpc_getlogs.exe`, returns rows already in
    `MM/DD/YY` form, drops pre-2015 junk and reports the count
- `console.py` — Create User and Delete User pick the bridge by device type;
  templates unchanged (`success` / `error` / `raw_output` already cover it).

Verified end-to-end on the live device: creating `9999`/`test` took the device
from 79 → 80 users, deleting it put it back to 79, and the device was left clean.

`_device_type` still understands `'adms'` (the iclock command queue built when 604
was misidentified). That path is now unreachable for 604 but was left in place —
it is still correct for a genuine iclock device.

---

## Logs pipeline

### Live
Punch → push → listener → `attendance`. Confirmed: user `1003` punched at
`09/03/26 17:00:26` and the row appeared within seconds.

### Bulk pull (history, one-off or recovery)
`_ReadAllGLogData` + `_GetAllGLogData` returned **all 81,032 records in under 60
seconds**. Notes:

- `_ReadGLogWithPos(1, 0, 99)` fails with error 5 (invalid parameter) — positions
  are probably not 0-based. Not needed while the full read works.
- This SDK's log record has **no in/out field**, so pulled rows store
  `direction = ''`. Direction only exists in the push XML's `<AttendStat>`.
- Verify-mode values seen: `1` (36,234), `257` (44,665), `3`, `259`, `279`. The
  `0x100` bit looked like a direction flag, but the hour-of-day distributions of
  `1` and `257` overlap too much to conclude that — left undecoded on purpose.
- 47 records were dated year 2000 (an old device-clock reset) and are skipped.

### Why the push channel could not carry history
81,032 stored logs arriving at **one record per ~66 s** is about **62 days**. The
device sends strictly in TransID order, so a punch made today sat behind the
entire backlog. Emptying the device's log memory was what made live punches
arrive in seconds.

---

## Retention: 30 days

Decision (2026-09-03): keep only the last 30 days across **all** devices.

`biomax_retention.py` — dry-run by default, `--apply` to delete, `--days N` to
change the window. Every `--apply` first writes a CSV of the rows it is about to
remove into `~/biomax-sync/retention-backups/`.

```
cutoff 2026-08-04   total 82,985 → kept 3,038, deleted 79,947
  device 6 (606) 1,457 · device 8 (605) 746 · device 9 (604) 77,744
```

Two deliberate behaviours:

- **Dates are parsed in Python and rows deleted by rowid.** `log_date` is TEXT in
  `MM/DD/YY` form, so a SQL comparison would be lexicographic — `'01/01/25'`
  sorts before `'12/31/24'`. (Same reason `min()`/`max()` on that column are
  meaningless; count by `substr(log_date,7,2)` instead.)
- **A row whose date cannot be parsed is never deleted** — it is counted and
  reported instead.

Nightly cron (user `saleshandy`, no sudo needed):

```
30 2 * * * cd /home/saleshandy/biomax-sync && ./venv/bin/python3 biomax_retention.py \
           --days 30 --apply >> /home/saleshandy/biomax-sync/retention.log 2>&1
```

### Ordering matters
Wipe the **device's** log memory *before* pruning the DB, or the next SDK pull
re-imports everything retention just deleted. The sequence used was: final
incremental pull → import → wipe device → prune DB.

### The wipe tool
`sbxpc_clearlogs.exe` calls `_EmptyGeneralLogData` and prints the glog count
before and after. It **refuses to run without the literal argument
`I-HAVE-A-BACKUP`**, so it cannot fire from a mistyped command, and it touches
attendance logs only — users and fingerprints live in a different store.

```bash
cd ~/mbio-push && WINEPREFIX=/Users/admin/biomax-push/wineprefix WINEDEBUG=-all \
  "/Users/admin/wine-setup/Wine Devel.app/Contents/Resources/wine/bin/wine" \
  sbxpc_clearlogs.exe 192.168.126.10 I-HAVE-A-BACKUP
# GLOG_BEFORE 81041 / EMPTY 1 / GLOG_AFTER 0
```

Backups kept from the one-off wipe:
`~/biomax-sync/retention-backups/device9-full-before-clear.csv` (80,230 rows),
`attendance-pruned-20260903-110903.csv` (79,947 rows), and the raw SDK dump
`.101:~/mbio-push/glogs-backup-2026-09-03.txt`.

---

## Runbook

```bash
# listener status / recent punches
ssh saleshandy@192.168.126.180
kill -0 "$(cat ~/biomax-mbio/mbio.pid)" && echo alive
grep -a "RX TimeLog" ~/biomax-mbio/mbio.log | tail

# restart the listener (while it is still a manual daemon)
kill "$(cat ~/biomax-mbio/mbio.pid)"; ~/biomax-sync/venv/bin/python3 ~/biomax-mbio/mbio_listener.py

# what the device itself thinks (user count, log count, clock)
ssh admin@192.168.126.101
cd ~/mbio-push && WINEPREFIX=/Users/admin/biomax-push/wineprefix WINEDEBUG=-all \
  "/Users/admin/wine-setup/Wine Devel.app/Contents/Resources/wine/bin/wine" \
  sbxpc_try.exe 192.168.126.10 status 1 0

# retention dry run
cd ~/biomax-sync && ./venv/bin/python3 biomax_retention.py --days 30
```

### Environment gotchas
- **sudo on `.180` is not passwordless** — service installs/restarts and ufw
  changes have to be run by a human.
- **No `sqlite3` CLI on `.180`** — use `~/biomax-sync/venv/bin/python3`.
- **macOS has no `timeout`** — `timeout 30 cmd` silently produces nothing on
  `.101`. Use a background PID + poll + `kill` instead.
- **`.101`'s shell is zsh, which does not word-split unquoted variables** —
  `set -- $spec` inside a loop does not do what it does in bash.
- **Every Wine invocation costs ~5s of cold start**, so batch work into one call.
- **Never `pkill -f mbio_...` over SSH** — the pattern matches the SSH command
  line itself and kills the shell. Kill by pidfile.
- The repo is a mirror of the live hosts; verify with `md5sum` on both sides.

---

## Known issues / open items

1. **Listener is not a systemd service yet.** `biomax-mbio.service` is staged at
   `~/biomax-mbio/biomax-mbio.service`; installing it needs sudo:
   ```bash
   sudo cp ~/biomax-mbio/biomax-mbio.service /etc/systemd/system/
   sudo systemctl daemon-reload
   kill "$(cat ~/biomax-mbio/mbio.pid)"
   sudo systemctl enable --now biomax-mbio
   ```
   Until then a reboot silently stops attendance collection for 604.
2. **Device clock is ~8 minutes fast** (device `15:47:36` vs host `15:39:44` IST on
   2026-09-03). Date and day-of-week are correct. `_SetDeviceTime` would fix it.
3. **`TransID` came back as `0`** on the first punch after the log wipe. The ack
   was accepted and there was no retry storm, so it works — but if duplicate or
   stuck punches ever appear, look here first.
4. **`direction` is blank** for 604 rows — the device is not populating
   `<AttendStat>` on these punches.
5. **`verification_mode` differs by path** — push writes the device's text
   (`FP`), the SDK pull writes a packed number (`1`, `257`). Both are the
   device's own value; nothing is translated. 604's pulled rows age out in 30 days.
6. **The FK623 devices' log sync is dead, and this is a separate pre-existing
   problem.** `biomax-sync` runs every ~6 min and reports `synced 0 new
   record(s)`; a direct pull from 606 returns `LOAD 1 / ITER_END -7 / TOTAL 0` —
   the devices have no stored logs, so something else (likely SmartOffice) is
   pulling and clearing them. Untouched here.
7. `biomax_sync.py`'s FK path inserts ISO `YYYY-MM-DD` dates while every other
   path writes `MM/DD/YY`. Latent inconsistency, currently invisible because that
   path returns no rows. Left alone.
8. Nothing in this work is committed to git yet.

---

## Provenance

The protocol was not documented by the vendor; it was pieced together from:

- `Vibhav-Aggarwal/ebkn-m61-protocol` (Apache-2.0) — reverse-engineered LogClient
  spec incl. the `UploadedLog` + NUL ack, and a zero-dependency Python listener.
- `akmalfadli/ebkn7-websocket-cloud-dashboard` (MIT) — working PHP implementation
  of the EBKN WebSocket dialect, including `SetUserData` create/delete XML.
- `staffinnsolutionsllp-commits/staffinn-main` — public mirror of the vendor SDK
  (`SDK_BIOTIME_4_5_5N_BIOFACE/`) containing `SBXPCDLL.dll`, `GEN_FONT.dll`, the
  C# wrapper `SBXPCDLL.cs` (all 86 signatures) and the sample forms that revealed
  the `EnableDevice(0)` requirement and the template sizes.
- A Microsoft Q&A thread on an M50 terminal that first showed the same XML shape.

Local copies of the specs are in `biomax-console/mbio-refs/`.
