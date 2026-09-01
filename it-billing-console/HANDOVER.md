# IT Console — session handover

State as of **01-09-2026**. Written so a fresh session can pick this up without
re-discovering any of it.

Deep detail lives in [`n8n/README.md`](n8n/README.md) — this file is the map and the
things that will bite you.

---

## What runs where

| Piece | Address | Notes |
|---|---|---|
| IT console | `192.168.126.101:3000` | Node/Express + SQLite, container `it-billing-console` |
| n8n | `192.168.126.101:5678` | v2.36.7, **12 workflows, all active** |
| Invoice parser | `192.168.126.101:4321` | native launchd service, `~/invoice-parser/server.js` |
| ntfy | `192.168.126.101:8080` | topic `it-billing-console` — **the only alert channel that works** |

SSH alias `IKI-MAC-27` → `192.168.126.101`, user `admin`.
`docker` is **not on PATH over SSH** — use `/usr/local/bin/docker`.

---

## Read this before deploying anything

> **The console deploys by rebuilding the image, not `docker cp`.**
> Every change used to be copied into the *running* container and never into the image.
> A routine `docker compose up -d` on 01-09-2026 recreated the container from the old
> image and **wiped every change** — the rentals tables, the RAC tab, `paid_amount`.
> `data.sqlite` is a bind mount so no data was lost, but the app served pre-RAC code
> until it was restored.
>
> ```bash
> scp <changed files> IKI-MAC-27:/Users/admin/it-billing-console/...
> ssh IKI-MAC-27
> export PATH=/Applications/Docker.app/Contents/Resources/bin:/usr/local/bin:$PATH
> cd ~/it-billing-console && docker compose up -d --build
> ```
>
> That `PATH` line is required: without it the build fails with
> `error getting credentials - docker-credential-desktop: not found`.

> **n8n `import:workflow` deactivates the workflow it overwrites**, and DB changes do not
> take effect while n8n is running. Always follow with
> `n8n update:workflow --id=<ID> --active=true` then `docker restart n8n`, and
> **verify the import actually landed** — one silently did not during this session and
> the old code kept running.

---

## Traps that have already cost real time

**Gmail returns `from` / `to` / `cc` as objects**, not strings —
`{ value:[{address,name}], html, text }`. `String(...)` gives `"[object Object]"`, so any
`.includes('@domain')` test is silently false and the workflow processes nothing while
reporting success. This had killed **both** RAC workflows outright. Always normalise
through the `addr()` helper. `subject`, `text` and `html` *are* strings.

**A fixture that does not mirror the real payload is worse than no fixture.** The manual
fixtures passed strings for `from`, so every test was green while production could not
have worked. Fixtures now emit the object shape.

**Never derive "today" from UTC.** n8n's timezone is Asia/Kolkata and schedules fire on
local time, but `new Date()` / `getUTCDate()` inside a Code node ignore that. 00:00 IST
is 18:30 UTC *the previous day* — which made the exit sync remove **every** leaver a day
late. Use:
```js
const istNow = new Date(Date.now() + 5.5 * 3600000);
const today = new Date(Date.UTC(istNow.getUTCFullYear(), istNow.getUTCMonth(), istNow.getUTCDate(), 12, 0, 0));
```
The console container now sets `TZ=Asia/Kolkata` (needs `apk add tzdata` — alpine ships
no timezone database, so a bare `TZ` does nothing).

**Never hardcode a sheet tab name that carries a count.** HR rename them as the count
moves (`G Suite Main 89` → `G Suite Main 111`), which killed the master-sheet sync for
days. Resolve the title from the numeric `sheetId`, which survives a rename.

**`PUT` is a full-record replace everywhere in this API.** Echo every field back or it is
written as NULL.

**HTTP header values must be ASCII.** An emoji in an ntfy `Title` makes node's `fetch`
throw outright.

---

## The 12 workflows

| ID | Name | Trigger |
|---|---|---|
| `Ncx7r0VcoxUfO6hF` | Weekly IT Spend Summary | Mon 09:00 |
| `t4Pui7NwhNkRoabs` | Gmail Invoice Auto-Capture | Gmail |
| `qZ3Gn6zzCACqfweL` | Auto-Delete Basecamp Notification Emails | Gmail |
| `newJoinersAuto` | New Joiners Auto Add (SH / HA / TI) | 30 min |
| `shSheetSync001` | Saleshandy User List → G Suite Sheet | 30 min |
| `krishnaSheetSync` | Krishnabusiness → G Suite Krishna | 30 min |
| `tiSheetSync001` | TrulyInbox → TrulyInbox GW | 30 min |
| `solSheetSync01` | Saleshandy Solutions ↔ SaleshandySolutions | 30 min |
| `exitSync00001` | Exit Sync — Remove Leavers | 30 min |
| `racBillCapture` | RAC Laptop Bill Auto-Capture | Gmail |
| `racProofCapture` | RAC Payment Proof Auto-Capture | Gmail (SENT) |
| `syncFailAlert01` | **Sync Failure Alert** | error trigger |

`syncFailAlert01` is every other workflow's `settings.errorWorkflow`. Before it existed,
`shSheetSync001` failed 46 times over two days and nobody knew — the console kept working
and the only symptom was a sheet that had quietly gone stale. All 20 `googleapis.com`
nodes also carry `retryOnFail / maxTries 3`, which absorbs Google's frequent 503s.
**Retry first, alert second** — without the retry the alert fires on every blip and gets
tuned out.

---

## RAC laptops — the newest piece

RAC IT Solutions Pvt Ltd, domain **`racwg.com`**, bill from several mailboxes on it
(`accounts@`, `accountsahmd@`, `receivables3@`, `hobilling@`, `salesahmd4@`,
`billing@`). Payment advices go to **`accountsahmd@racwg.com`**.

Two workflows close the loop:

```
RAC mails a bill   → racBillCapture  → payment row (status Pending) + PDF on the NAS + ntfy
we mail the proof  → racProofCapture → marks it Paid + screenshot on the NAS + ntfy
```

Both land on the same console row under **RAC Laptops**.

| Field | Meaning |
|---|---|
| `amount` | what was invoiced |
| `paid_amount` | what actually left the bank — **lower**, RAC deduct 2% TDS u/s 194I |
| `payment_date` | the bill's own date |
| `paid_on` | when the money went out |
| `due_date` | off the PDF; overdue unpaid rows go red |

Current state: 2 Lenovo V14 G3 laptops (`RAC-02370004` / SN `PF4WGJAW`,
`RAC-02384381` / SN `PF52JT2R`), ₹1,600/month each, on rent since 18-08-2026.
Invoice `AMD/26-27/00669` — ₹3,776 billed, **₹3,712 paid** on 24-08-2026 by IMPS
(₹64 = the TDS). Bills are raised on **IKIGAI INFOTECH LLP**, not Saleshandy.
Their cycle runs **18th → 17th**, not calendar months.

Who holds which laptop is tracked in **Keka** — the "Assigned To" column was
deliberately removed from this UI.

---

## The parser (`:4321`)

Not in this repo — `~/invoice-parser/server.js` on the Mac Mini, run by launchd
(`com.invoiceparser`). Shells out to a coding agent and returns JSON.

| Endpoint | For |
|---|---|
| `POST /parse-invoice` | vendor invoices → service contracts |
| `POST /parse-rental-bill` | RAC bills → `invoices[]` + `laptops[]` |
| `POST /parse-payment-proof` | bank screenshots → amount / date / refs |
| `GET /health` | `{ok, engine, codexInstalled, codexAuthed}` |

**Two engines.** Codex (`~/.codex/packages/standalone/current/codex exec`, logged in with
a ChatGPT account) is preferred; claude (`claude -p`) is the fallback. They are separate
quotas, which is the whole point — sharing one with Hermes meant a busy Telegram day took
invoice capture down. On a quota/auth failure codex automatically retries on claude, and
the reply records `_engine` / `_fellBackFrom`.

> Both engines **do** run out. Seen on 31-08: claude's session limit at midday, codex's
> usage limit the same evening. The fallback covers one being down, not both.

> Log in codex over SSH with `codex login --device-auth` — plain `codex login` wants a
> browser on the same machine.

---

## Where things are written down

- **`n8n/README.md`** — the deep reference: every workflow, sheet layouts, API contracts,
  credentials map, deploy steps, gotchas.
- **`n8n/workflows.json`** — export of all 12 live workflows. A **mirror, not the
  source**; re-export before trusting it. Verified to contain credential *references*
  only, never secrets.
- **Obsidian** → `Projects/IT Billing Console - Invoice Automation.md` — narrative
  history, incidents, decisions and the reasoning behind them.

---

## Open items

| Item | Detail |
|---|---|
| Console email alerts | Gmail rejects the stored password (12 chars; needs a 16-char **App Password**). Channel disabled; alerts go to ntfy instead. Re-enable from Alert Settings once a real App Password exists. |
| O365 costs | Service id 4 holds a seeded ₹44,781 that matches neither the 7- nor the 34-user product; id 5 is 0. Needs the Redington invoices. |
| TrulyInbox contract | id 7 expired 09-06-2026 covering 8 users; Google shows 11 licences. Needs the DigiSoft renewal invoice. |
| ₹127 DigiSoft invoice | `GSTNW/1205/2627`, unpaid, due 08-09-2026. |
| DigiSoft ₹3140+GST rate | Confirm whether it applies to saleshandy.com (renewal 12-09-2026, ₹13,098 difference). |
| Product Team batches | `Batch-1`…`Batch-5` exist and are empty. 31 domains still to be assigned — the user will dictate the mapping. |
| HR sheet data errors | `sneh@` / `dhruvam@` listed under the wrong domain; `karan.g` / `jiten` exist in no tenant. |
| Unsynced tabs | `G Suite Team 07`, `O365 Truly Inbox 33`, `Zoho 04`, `Billing` have no sync. |
| `trytrulyinbox.com` | Shows "Possible service issues" — DNS check pending. |
| Technofirm contracts | ids 9–15 don't reconcile with the Product Team tab (Batch 1–5 vs 3 batches; 100 O365 vs 60). |
| Seat-note date | `Gmail Invoice Auto-Capture` → `Update Domain Seats` still stamps a UTC date in its note text. Cosmetic; left alone deliberately. |
