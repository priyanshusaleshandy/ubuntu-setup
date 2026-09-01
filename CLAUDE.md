# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

`core-labs` is an **IT-operations repo, not a normal application codebase**. Most
directories are the working copy of code that actually runs on on-prem servers.
There is no unified build, no CI, and no test suite for the repo as a whole.

The consequence that matters: for most components, **the live server is the real
deployment and this repo is the mirror**. Edits often happen over SSH on the host
first and get copied back here (`biomax-console/README.md` says this explicitly).
Before assuming a file here is current, check the live host.

Git remote is `priyanshusaleshandy/ubuntu-setup` — the repo name does not match
the folder name.

## Physical topology (verified 2026-08-26)

Everything on-prem is **one physical machine**, not several:

**Mac Mini 101** — `192.168.126.101`, SSH alias `IKI-MAC-27`, user `admin`, Apple M4 / arm64 / macOS 26.1 / 16GB.
- Native (launchd): **Hermes** — Telegram bot, `~/hermes-native/hermes_bot.js`, runs `claude -p` per message.
- Docker: `it-billing-console` (:3000), `ntfy` (:8080), `onprem-telegram-bot`, WhatsApp Console stack (`chatwoot` :3010, `waha` :3011, `bridge`, workers, postgres, redis), Finance Docs Stack (`nextcloud` :8090, `stirling-pdf` :8091, `onlyoffice` :8092 on isolated `finance-net`).

**`192.168.126.180`** — **a UTM VM on that same Mac Mini** (Ubuntu arm64, bridged NIC so it holds a real LAN IP for Omada device discovery). SSH user `saleshandy`, key auth works, sudo is **not** passwordless.
- Omada Controller (native Java, `/opt/tplink/EAPController`)
- Full BioMax suite as native systemd services under `/home/saleshandy/biomax-*` — **not Docker**
- `omada-ntfy` watcher, `cloudflared-biomax` tunnel

**TrueNAS** — `192.168.126.21`, user `truenas_admin`. Serves setup scripts over HTTP (:8000) and a local app-installer cache (:8001).

Implications worth remembering: no Proxmox/second hypervisor exists or is needed
(Proxmox VE has no ARM support). New Docker tools go on the macOS host; anything
needing bridged/L2 LAN access goes in the existing UTM VM. **Buzz does not run on
this Mac Mini** — its location is undocumented.

## Working rules

**Check the branch before touching setup-cli files.** Run `git branch --show-current`
first. The two branches diverge in *contents*, not just history: `main` has the
`Nas/` script mirror but no `biomax-console/`; the `biomax-console` branch has the
opposite. So a file can be genuinely absent from disk simply because you are on the
other branch — this has caused a wrong-branch mistake twice. Do **not** fix it by
checking out the other branch (each carries uncommitted work that must survive).
Instead read the file with `git show main:<path> > <path>`, then commit onto `main`
without checking it out, via plumbing: `git hash-object -w` → `read-tree`/`update-index`
against a scratch `GIT_INDEX_FILE` → `write-tree` → `commit-tree -p main` → `update-ref`.

**Most components in this working directory are untracked by git.** Only `alerts/`,
`biomax-console/`, `it-billing-console/`, `linux/`, `windows/`, the two
`setup-center-cli.*` scripts, `tailscale-cli.sh` and `README.md` are committed on this
branch. (`it-billing-console/` was added 01-09-2026 — source, `n8n/README.md`,
`n8n/workflows.json` and `HANDOVER.md`; `node_modules/`, `data.sqlite*` and `uploads/`
are gitignored.)
`whatsapp-console/`, `finance-docs-stack/`, `buzz-docker/`, `basecamp-mcp-server/`,
`Mac-Mini-M2-Setup/` and `scripts/` exist **only on this disk** — no branch contains
them, so there is no version history or off-machine copy to fall back on. Treat edits
there as unrecoverable if lost, and do not assume `git checkout`/`git stash` can undo them.

**Deploy the IT console by rebuilding its image, never `docker cp`.** Its code used to be
copied straight into the running container and never into the image, so a routine
`docker compose up -d` recreated it from a stale image and silently wiped every change
(01-09-2026). `data.sqlite` is a bind mount, so data survived — the code did not. The
build needs Docker Desktop's credential helper, which an SSH session lacks:

```bash
ssh IKI-MAC-27
export PATH=/Applications/Docker.app/Contents/Resources/bin:/usr/local/bin:$PATH
cd ~/it-billing-console && docker compose up -d --build
```

Without that `PATH`: `error getting credentials - docker-credential-desktop: not found`.

**A GitHub push of `setup-center-cli.sh`/`.ps1` is not done until the NAS copies
match.** The NAS serves these same scripts as the LAN-fast/offline path; drift
silently reintroduces stale-content bugs. Treat both as one unit of work, and
verify with `md5sum` on both sides. Write on the NAS side via a temp file + `cp`
under sudo — direct SFTP into `Script/` and `priyanshu data/` fails on permissions,
and a raw `sudo tee` through a pty has corrupted a file before.

**Update the Obsidian vault when live infra changes** (`.agents/AGENTS.md`).
Vault root `C:\Users\Priyanshu Kumar\Documents\Obsidian Vault\`, hub note
`Project.md`. Keep `[[WikiLinks]]` bidirectional; nothing but `Project.md` in the
vault root. The vault — not this repo — holds the long-form architecture notes,
credentials, and incident history.

**Never write credentials into this repo.** `.gitignore` covers `.env`,
`*credentials*.json`, and installer binaries. Live passwords belong in Obsidian or
the session memory layer, not in tracked files including this one.

**Never run `claude -p` manually on the Mac Mini while Hermes is live.** Concurrent
`claude` calls race on OAuth refresh-token rotation (single-use/rotating) and have
broken Hermes' auth outright. Debug Hermes through its own logs
(`~/hermes-native/hermes.log`, `hermes.error.log`) instead. Restart with
`launchctl kickstart -k gui/$(id -u)/com.hermes.bot`.

**`docker` is not on PATH over SSH** on the Mac Mini — use `/usr/local/bin/docker`.

## Components and how each deploys

| Component | Source here | Runs on | Deploy |
|---|---|---|---|
| BioMax console/sync/ADMS | `biomax-console/` | `.180` native systemd | scp to `~/biomax-sync/`, `~/biomax-adms/`, units to `/etc/systemd/system/` |
| Telegram network bot | `alerts/bot.py` | `.101` Docker | copy to `~/telegram-bot/bot.py`, `docker restart onprem-telegram-bot` |
| WhatsApp Console | `whatsapp-console/` | `.101` Docker | scp compose/`.env`/`bridge/` to `~/whatsapp-console/`, `docker compose up -d --build` |
| Finance Docs Stack | `finance-docs-stack/` | `.101` Docker | compose up on `finance-net` |
| IT Billing Console | `it-billing-console/` | `.101` Docker :3000 | Node/Express + SQLite. scp source, then `docker compose up -d --build` — see the deploy warning above. Start at `it-billing-console/HANDOVER.md` |
| Buzz relay stack | `buzz-docker/` | not on `.101` | `deploy.sh` / `buzz-mac-mini-deploy.sh` |
| Setup Center CLI | `setup-center-cli.{sh,ps1}` | end-user workstations | GitHub raw + NAS mirror (see rules above) |
| Basecamp MCP server | `basecamp-mcp-server/` | local MCP | see commands below |

`biomax-console/fk_*.c` are Wine/DLL bridge sources cross-compiled **on `.180`**
with `i686-w64-mingw32-gcc -static`, and the resulting `.exe` files are deployed to
`.101:~/biomax-push/`. Note `fk_push.c`, `fk_delete.c`, `fk_listusers.c` sources
were never saved — only their compiled `.exe` survives, so those cannot be rebuilt.

## Commands

The only component with a real build/test cycle is the Basecamp MCP server:

```bash
cd basecamp-mcp-server
npm run build          # tsc
npm run dev            # tsx src/index.ts
npm test               # vitest run
npx vitest run src/test/basecamp-client.test.ts    # single test file
npm run config:claude  # generate MCP client config
```

IT Billing Console:

```bash
cd it-billing-console
npm start              # node server.js
npm run dev            # node --watch server.js
```

Workstation setup entry points:

```bash
./setup-center-cli.sh          # Linux/Ubuntu
./tailscale-cli.sh             # Tailscale dashboard
```
```powershell
.\setup-center-cli.ps1         # Windows (or windows\RUN-SETUP.bat)
```

The Python components (`biomax-console/*.py`, `alerts/bot.py`) have no test suite
and no dependency manifest in-repo; they run against venvs that live on the servers.

## Known-stale references

`README.md` lists a `sheets-console/` directory that does not exist in this repo.
`hermes.md` (repo root, and its `Ai cluster/hermes.md` twin in Obsidian) opens with
a LiteLLM-proxy + multi-key-OpenRouter description that is an **abandoned** design —
the corrected live setup is in its `2026-08-06` section further down. Read to the
end of that file before acting on anything in it.

Vendored upstream clones — `buzz-official-repo/` — are not this project's code;
do not treat findings there as issues to fix.
