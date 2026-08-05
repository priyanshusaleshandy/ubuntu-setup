# On-Prem Alerting Stack — Master Reference

Single source of truth for both 24/7 alerting bots running on the office
network: the **Telegram 2-Way Command Bot** and the **Omada Ntfy Log
Watcher**. Live-verified against the running systems as of 2026-08-05.

---

## 1. Telegram 2-Way Command & Auto-Alert Bot

**Goal:** Complete remote management, live status monitoring, system health
checks, dual-direction speedtest (Download & Upload), Tailscale VPN status,
Dual WAN ISP failover identification (Jio + Airtel), Sophos Firewall
monitoring, and instant push alerts for all Office NVRs, Omada Wi-Fi
Routers, and the Mac Mini host — accessible anywhere in the world on 4G/5G
mobile data without VPN.

### 1.1 Infrastructure & Credentials

| Field | Value |
| :--- | :--- |
| **Bot Handle** | [@Ikigai_Alerts_bot](https://t.me/Ikigai_Alerts_bot) |
| **Bot Token** | `8607599767:AAEOO6ZhYc3ccl1OfFgi6-jAqhneWB6u01I` |
| **Host** | Mac Mini M2 — `192.168.126.101` (macOS/Darwin) |
| **SSH Access** | `ssh IKI-MAC-27` (alias, key-based) or `ssh admin@192.168.126.101` |
| **Source File (host)** | `~/telegram-bot/bot.py` (i.e. `/Users/admin/telegram-bot/bot.py`) |
| **Repo Copy** | `alerts/bot.py` (kept in sync with the host — this is the deploy source) |
| **Container** | `onprem-telegram-bot` (`python:3.11-alpine`, `--restart always`) |
| **Docker Path** | `docker` is not on PATH over SSH — use full path `/usr/local/bin/docker` |
| **Chats Cache File** | `/tmp/telegram_chats.json` (inside container, persists across restarts) |
| **Incidents Log File** | `/tmp/telegram_outage_logs.json` (inside container, last 50 events) |
| **Alert Threshold** | 60 seconds (10 retries × 5s) per device |

### 1.2 Architecture

```
📱 TELEGRAM APP (anywhere in the world, 4G/5G — no VPN needed)
   │
   ├──► Menu Buttons / Commands → 2-way reply in <1s
   ▼ (Telegram Long Polling — 0 open firewall ports required)
🖥️ MAC MINI M2 (192.168.126.101 — Docker Container)
   │
   ├──► Thread 1 (poll_updates): handles incoming commands/button taps
   └──► Thread 2 (bg_monitor):   pings all 10 devices every 5s, auto push
        alert on >60s downtime, auto recovery notice on reconnect
```

### 1.3 Monitored Devices (`DEVICES` map)

| IP Address | Device Name | Category |
| :--- | :--- | :--- |
| `192.168.126.1` | Sophos Firewall (XG/XGS Main Gateway) | FW |
| `192.168.126.5` | Office #502 Main Router (Jio & Airtel Dual WAN) | NET |
| `192.168.126.180` | TP-Link Omada Controller VM | NET |
| `192.168.126.125` | Office #606 TP-Link Wi-Fi AP | NET |
| `192.168.126.4` | Office #601 TP-Link Wi-Fi AP / Router | NET |
| `192.168.126.12` | Office #604 TP-Link Wi-Fi AP | NET |
| `192.168.126.168` | Office #606 NVR | CCTV |
| `192.168.126.6` | Office #502 NVR | CCTV |
| `192.168.126.3` | **Office #601 NVR** | CCTV |
| `192.168.126.8` | Office #604 NVR | CCTV |

### 1.4 Menu Commands Reference

| Button / Command | Function |
| :--- | :--- |
| `📹 Check NVR Status` / `/nvr` / `/cctv` | Live status of all 4 CCTV NVRs |
| `🌐 Routers & Sophos FW` / `/network` / `/omada` / `/sophos` | Sophos Firewall + Routers + TP-Link APs |
| `🔒 Tailscale VPN` / `/vpn` / `/tailscale` | Tailscale VPN mesh & control server |
| `🚀 Dual WAN Speedtest` / `/speedtest` | DL+UL Mbps + Active WAN (Jio/Airtel) via Cloudflare |
| `🖥️ System Health` / `/sys` / `/mac` | Mac Mini CPU/RAM/Disk, Uptime |
| `📊 Master Summary` / `/status` | All 10 devices comprehensive report |
| `📋 Incident Logs` / `/logs` / `/history` / `/incidents` | Last 10 outage/recovery events (all devices) |
| `📅 601 DVR Log` / `/601log` / `/dvr601` | **NEW** — Full outage/recovery history *just for Office #601 NVR* (`192.168.126.3`) with exact timestamps, plus a "most outages happen around HH:00" pattern hint — added to diagnose the recurring night-time internet drop at Office #601 |
| `/test` / `/testalert` | Test alert push notification |
| `/demo` / `/demoairtel` | Demo Airtel outage + recovery alert |
| `/start` / `/help` | Welcome message + registers the chat for push alerts |

### 1.5 Known Issue — Fixed 2026-08-05

`poll_updates()` called `getUpdates` telling Telegram to hold the connection
open for **30s** (`{"timeout": 30}`), but the local `urlopen()` call itself
only allowed **15s** before giving up — so every single poll cycle
self-timed-out and spammed `TG HTTP Error [getUpdates]: The read operation
timed out` in the logs, forever, in a tight retry loop.

**Effect:** 24/7 push alerts (outage/recovery) still worked fine (`send_msg`
is a separate, fast call), but 2-way commands (you texting the bot) never
got a reply — the bot could never actually receive your messages.

**Fix:** `tg_call()` now takes an `http_timeout` param; `getUpdates` passes
`http_timeout=40` (must stay comfortably above Telegram's own 30s long-poll
window). Verified clean — zero errors in the logs for 2+ minutes post-deploy.

> Note: while debugging, manual `curl` test calls against `getUpdates` from
> the host can produce `409 Conflict` or hang — that's expected, since only
> one long-poll connection per bot token is allowed and the container's own
> poller is normally holding it. Don't test `getUpdates` manually while the
> container is running; check `docker logs` instead.

### 1.6 Deployment / Redeploy

```bash
ssh IKI-MAC-27   # admin@192.168.126.101

# Edit the bot (or scp a new alerts/bot.py over):
nano ~/telegram-bot/bot.py

# Apply changes:
/usr/local/bin/docker restart onprem-telegram-bot
```

Fresh install (if the container doesn't exist yet):
```bash
mkdir -p ~/telegram-bot
# copy alerts/bot.py to ~/telegram-bot/bot.py, then:
/usr/local/bin/docker rm -f onprem-telegram-bot 2>/dev/null || true
/usr/local/bin/docker run -d \
  --name onprem-telegram-bot \
  --restart always \
  -v $HOME/telegram-bot/bot.py:/bot.py \
  python:3.11-alpine sh -c 'apk add --no-cache bash iputils curl && python3 /bot.py'
```

### 1.7 Logs & Troubleshooting

```bash
# Only see NEW logs since a restart (avoids old noise mixed in):
/usr/local/bin/docker logs --since 2m onprem-telegram-bot

# Live tail
/usr/local/bin/docker logs -f --tail 50 onprem-telegram-bot

# Restart
/usr/local/bin/docker restart onprem-telegram-bot

# Container status
/usr/local/bin/docker ps --filter name=onprem-telegram-bot
```

---

## 2. Omada Ntfy Log Watcher (Ping + Log Monitor)

Separate, independent monitor running on the Ubuntu Omada Controller VM —
watches the Omada controller's own log file for hardware faults/admin
logins, *and* runs its own ping-based outage detector, pushing to Ntfy
(not Telegram).

### 2.1 Infrastructure & Credentials

| Component | Host / Location | Details |
| :--- | :--- | :--- |
| **Watcher Host Server** | `192.168.126.180` (Ubuntu) | SSH User: `saleshandy` (no working key/password on file as of 2026-08-05 — re-auth needed to manage remotely) |
| **Watcher Script** | `/usr/local/bin/omada-ntfy-watcher.sh` | Main Bash monitoring daemon |
| **Systemd Service** | `/etc/systemd/system/omada-ntfy.service` | Auto-start background service — **confirmed active** via `services_audit.txt` (`omada-ntfy.service loaded active running`) |
| **Local Ntfy Server** | `192.168.126.101:8080` (Mac Mini, Docker) | Local Topic: `omada-alerts` |
| **Cloud Ntfy Server** | `https://ntfy.sh` | Cloud Topic: `omada-alerts-priyanshu99` |
| **Target Log File** | `/opt/tplink/EAPController/logs/server.log` | Omada Controller server log (falls back to `docker logs omada-controller` if the file doesn't exist) |

### 2.2 Service Commands (systemd)

```bash
# Status
systemctl status omada-ntfy.service

# Live logs
journalctl -u omada-ntfy -f --no-pager

# Restart
systemctl restart omada-ntfy.service
```

### 2.3 What It Does

Two loops run in parallel inside the one script:

1. **`ping_monitor`** — pings 3 mapped devices every 4s. A device must fail
   2 consecutive pings before it's called a confirmed outage (avoids false
   positives from single dropped packets). On confirmed outage: sends a
   burst of up to 30 push notifications (1.5s apart, stops early if the
   device recovers). On recovery: sends 3 rapid green "back up" alerts.
2. **Log watcher** — tails the Omada controller's `server.log` (or `docker
   logs -f omada-controller` if no log file), filters out noise (session
   IDs, cloud model-info lookups, routine config/temp-file chatter), and
   pushes alerts for admin logins (priority 3) and hardware
   faults/disconnects/reboots (priority 4).

### 2.4 Device → Office Mapping (`IP_TO_OFFICE`)

```bash
declare -A IP_TO_OFFICE=(
  ["192.168.126.125"]="Office #606"
  ["192.168.126.5"]="Office #502"
  ["192.168.126.12"]="Office #604"
  # Office #601 devices (AP 192.168.126.4 / NVR 192.168.126.3) are NOT
  # currently in this map — only monitored by the Telegram bot's
  # bg_monitor, not by this ping_monitor loop.
)
```

### 2.5 Full Script (`/usr/local/bin/omada-ntfy-watcher.sh`)

```bash
#!/bin/bash
LOCAL_NTFY="http://192.168.126.101:8080/omada-alerts"
CLOUD_NTFY="https://ntfy.sh/omada-alerts-priyanshu99"
LOG_FILE="/opt/tplink/EAPController/logs/server.log"

declare -A IP_TO_OFFICE=(
  ["192.168.126.125"]="Office #606"
  ["192.168.126.5"]="Office #502"
  ["192.168.126.12"]="Office #604"
  # ["192.168.126.3"]="DVR Office 601"
)
declare -A STATE_MAP

send_push() {
  local title="$1"
  local priority="$2"
  local tags="$3"
  local body="$4"
  curl -s -H "Title: $title" -H "Priority: $priority" -H "Tags: $tags" -d "$body" "$LOCAL_NTFY" &
  curl -s -H "Title: $title" -H "Priority: $priority" -H "Tags: $tags" -d "$body" "$CLOUD_NTFY" &
}

ping_monitor() {
  while true; do
    for ip in "${!IP_TO_OFFICE[@]}"; do
      office="${IP_TO_OFFICE[$ip]}"
      last_state="${STATE_MAP[$ip]:-UP}"
      if ! ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
        sleep 2
        if ! ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
          if [ "$last_state" = "UP" ]; then
            STATE_MAP["$ip"]="DOWN"
            (
              for i in $(seq 1 30); do
                [ "${STATE_MAP[$ip]}" != "DOWN" ] && break
                body="Location: $office
IP Address: $ip
Status: OFFLINE / UNREACHABLE (Confirmed Outage)
Action Required: Please check router power & network cable."
                send_push "🚨 CRITICAL: Device DOWN - $office ($i/30)" "5" "rotating_light,exclamation,skull" "$body"
                sleep 1.5
              done
            ) &
          fi
        fi
      else
        if [ "$last_state" = "DOWN" ]; then
          STATE_MAP["$ip"]="UP"
          body="Location: $office
IP Address: $ip
Status: Router UP Done (ONLINE & RESPONDING)"
          for j in 1 2 3; do
            send_push "🟢 Router UP Done - $office ($j/3)" "3" "white_check_mark,green_heart" "$body"
            sleep 0.3
          done
        fi
      fi
    done
    sleep 4
  done
}
ping_monitor &

send_log_alert() {
  local raw_log="$1"

  if echo "$raw_log" | grep -qiE "\-90021|no modelInfo from cloud|uiInterface failed|sessionId:|temp-disk|diskMultipartFileAsset|check clear expired|CONFIG|MODIFY|UPDATE"; then
    return
  fi
  if echo "$raw_log" | grep -qiE "SpeedUpLoginController|check login|CheckLoginByTPCloud|LoginController|identityaccess.*Response"; then
    body="Event: Admin User Logged In
Controller: Omada Network Application
Status: Login Successful"
    send_push "🔐 Security: Omada Admin Login" "3" "lock,key,shield" "$body"
    return
  fi
  if echo "$raw_log" | grep -qiE "OFFLINE|DISCONNECTED|REBOOT|DOWN|ERROR|FATAL|ALARM"; then
    local ip=$(echo "$raw_log" | grep -oP "192\.168\.[0-9]+\.[0-9]+" | head -n 1)
    local office="Omada Network Device"
    [ -n "$ip" ] && [ -n "${IP_TO_OFFICE[$ip]}" ] && office="${IP_TO_OFFICE[$ip]}"
    body="Device / Office: $office
Event: Hardware Error / Network Fault
Raw Details: $raw_log"
    send_push "⚠️ Omada Hardware Warning - $office" "4" "warning,warning" "$body"
  fi
}

if [ ! -f "$LOG_FILE" ]; then
    docker logs -f omada-controller 2>/dev/null | while read -r line; do
        send_log_alert "$line"
    done
else
    tail -F "$LOG_FILE" 2>/dev/null | while read -r line; do
        send_log_alert "$line"
    done
fi
```

### 2.6 Editing / Extending

```bash
ssh saleshandy@192.168.126.180
sudo nano /usr/local/bin/omada-ntfy-watcher.sh
# add a line inside IP_TO_OFFICE, e.g.:
#   ["192.168.126.3"]="DVR Office 601"
sudo systemctl restart omada-ntfy.service
```

---

## 3. Diagnosing the Office #601 Night-Time Internet Drop

Two independent data sources now exist for this:

1. **Telegram bot** — `📅 601 DVR Log` button gives exact timestamped
   OUTAGE/RECOVERY history for `192.168.126.3` (Office #601 NVR) straight
   from `/tmp/telegram_outage_logs.json`, plus a computed "most outages
   happen around HH:00" hint.
2. **Omada watcher** — does **not** currently monitor Office #601 devices
   (`192.168.126.4` AP / `192.168.126.3` NVR aren't in its `IP_TO_OFFICE`
   map — see §2.4). Adding that IP there would give a second, independent
   confirmation source and Ntfy-based alerting for that specific office.

Once a few nights of `📅 601 DVR Log` data accumulate, the exact hour the
line drops should be visible — that then points to whether it's an ISP-side
scheduled maintenance window, a router reboot/power-saving schedule, or a
Wi-Fi AP issue specific to that office.
