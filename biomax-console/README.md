# BioMax Attendance Console

Snapshot of the live code running on `192.168.126.180` (console + sync + ADMS
listener) and the Wine/DLL bridge exe sources from `192.168.126.101`. This
folder exists so the working code isn't only on the servers themselves —
edits still happen live over SSH; copy changes back here when they matter.

Full architecture, history, and the fingerprint-copy reverse-engineering
notes live in Obsidian: **`Projects/BioMax Attendance System.md`**.

**Live deploy locations:**
- `console.py`, `device_push.py`, `biomax_sync.py`, `fk_*.c`, `templates/` → `.180:~/biomax-sync/`
- `biomax-adms/adms_server.py` → `.180:~/biomax-adms/`
- `systemd/*.service` → `.180:/etc/systemd/system/`
- Compiled `fk_*.exe` (built from the `.c` files here via `i686-w64-mingw32-gcc -static` on `.180`) → `.101:~/biomax-push/`

Not included here: `biomax.db` (live SQLite data), `venv/`, logs, and the
`fk_push.c`/`fk_delete.c`/`fk_listusers.c` sources — those three were
compiled directly on `.101` and their source was never saved; only the
compiled `.exe` survives for them.
