# On-Prem 2-Way Interactive Telegram Bot — Command Center

**Goal:** Complete remote management, live status monitoring, system health checks, dual-direction speedtest (Download & Upload), Tailscale VPN status, Dual WAN ISP failover identification (Jio + Airtel), Sophos Firewall monitoring, and instant push alerts for all Office NVRs, Omada Wi-Fi Routers, and Mac Mini — accessible anywhere in the world on 4G/5G mobile data without VPN.

---

## 1. Features & Architecture

```
📱 TELEGRAM APP (Mobile Phone — Anywhere in World on 4G/5G)
   │
   ├──► 1. Menu Buttons:
   │    ├── [📹 Check NVR Status]      ➔ Live latency & online status of all 4 NVRs
   │    ├── [🌐 Routers & Sophos FW]   ➔ Sophos Firewall, Jio/Airtel Hub #502, Omada Wi-Fi APs & Controller VM
   │    ├── [🔒 Tailscale VPN]         ➔ Tailscale Mesh Network & Control Server status
   │    ├── [🚀 Dual WAN Speedtest]    ➔ Download & Upload Mbps + Active WAN (Jio/Airtel) & Standby Line
   │    ├── [🖥️ Mac Health]            ➔ Mac Mini CPU, RAM, Disk & Uptime
   │    └── [📊 Master Summary]        ➔ Infrastructure health overview (10 Devices)
   │
   ▼ (Telegram Long Polling — 0 Open Firewall Ports Required!)
   │
🖥️ MAC MINI ON-PREM (192.168.126.101 — Docker Container)
   │
   ├──► 2-Way Interactive Reply: Returns status/health in <1s.
   └──► 24/7 Push Alerts: Auto Ntfy-style push alerts (60s threshold) when ANY device fails.
```

---

## 2. Bot Credentials

| Field | Value |
| :--- | :--- |
| **Bot Handle** | [@Ikigai_Alerts_bot](https://t.me/Ikigai_Alerts_bot) |
| **Bot Token** | `8607599767:AAEOO6ZhYc3ccl1OfFgi6-jAqhneWB6u01I` |
| **Host** | Mac Mini M2 (`192.168.126.101`) |
| **Container** | `onprem-telegram-bot` (Docker, `--restart always`) |
| **Alert Threshold** | 60 seconds (10 retries × 5s) |

---

## 3. Menu Commands Reference

| Button / Command | Function |
| :--- | :--- |
| `📹 Check NVR Status` / `/nvr` | Live status of all 4 CCTV NVRs |
| `🌐 Routers & Sophos FW` / `/network` | Sophos Firewall + Routers + TP-Link APs |
| `🔒 Tailscale VPN` / `/vpn` | Tailscale VPN mesh & control server |
| `🚀 Dual WAN Speedtest` / `/speedtest` | DL+UL Mbps + Active WAN (Jio/Airtel) |
| `🖥️ Mac Health` / `/mac` | Mac Mini CPU, RAM, Disk, Uptime |
| `📊 Master Summary` / `/status` | All 10 devices comprehensive report |
| `/test` | Test alert push notification |
| `/demo` | Demo Airtel outage + recovery alert |

---

## 4. 24/7 Outage & Recovery Alerting

- Background thread monitors all **10 network devices** every 5 seconds.
- If a device is unreachable for **>60 seconds** → sends `🚨 CRITICAL OUTAGE ALERT` to all connected Telegram clients.
- When device comes back online → sends `🟢 RECOVERY NOTICE`.
- Chat IDs are persisted in `/tmp/telegram_chats.json` — survives container restarts.

---

## 5. Production Deployment (Mac Mini Terminal)

```bash
mkdir -p ~/telegram-bot
# Copy alerts/bot.py content to ~/telegram-bot/bot.py on Mac Mini, then:

docker rm -f onprem-telegram-bot 2>/dev/null || true

docker run -d \
  --name onprem-telegram-bot \
  --restart always \
  -v $HOME/telegram-bot/bot.py:/bot.py \
  python:3.11-alpine sh -c 'apk add --no-cache bash iputils curl && python3 /bot.py'
```

---

## 6. Logs & Troubleshooting

```bash
# Live logs
docker logs -f --tail 50 onprem-telegram-bot

# Restart bot
docker restart onprem-telegram-bot

# Check container status
docker ps | grep telegram
```
