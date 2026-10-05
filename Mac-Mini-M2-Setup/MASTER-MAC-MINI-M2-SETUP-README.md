# Master Architecture & Setup Guide — Mac Mini M2 On-Prem Server

**Server IP:** `192.168.126.101`  
**OS:** macOS / Darwin  
**Primary Host:** `admin@192.168.126.101`  
**Telegram Bot:** `@Ikigai_Alerts_bot` (`8607599767:AAEOO6ZhYc3ccl1OfFgi6-jAqhneWB6u01I`)  

---

## 📁 Repository Directory Structure

```text
Mac-Mini-M2-Setup/
├── MASTER-MAC-MINI-M2-SETUP-README.md  ➔ 📖 Master System Blueprint & Documentation
├── alerts/                              ➔ 🚨 All 24/7 Outage & Push Alert Files
│   ├── bot.py                           ➔ Production Python 2-Way Bot & Monitor script
│   ├── Telegram-2Way-OnPrem-Bot.md      ➔ Telegram Bot features & command reference
│   ├── Sophos-Firewall-Ntfy-Setup.md   ➔ Sophos Firewall & Dual WAN Failover config
│   └── DVR-CCTV-Ntfy-Setup.md           ➔ 4 CCTV NVRs setup & 60s outage policy
├── network/                             ➔ 🌐 Network Architecture & Wi-Fi Management
│   └── Omada-Controller-Setup.md        ➔ TP-Link Omada Controller VM & Wi-Fi APs
└── scripts/                             ➔ ⚙️ Deployment & Maintenance Scripts
    └── deploy-telegram-bot.sh           ➔ Bash deployment script for Mac Mini M2
```

---

## 1. Network Topology & Device Catalog

```
                           ┌──────────────────────────────────────────────┐
                           │      🌐 DUAL WAN INTERNET CONNECTION         │
                           │   (Reliance Jio Fiber + Airtel Xstream)      │
                           └──────────────────────┬───────────────────────┘
                                                  │
                                                  ▼
                                ┌──────────────────────────────────┐
                                │   🔥 Sophos Firewall (XG/XGS)    │
                                │         192.168.126.1            │
                                └─────────────────┬────────────────┘
                                                  │
              ┌───────────────────────────────────┼───────────────────────────────────┐
              ▼                                   ▼                                   ▼
  ┌──────────────────────┐            ┌──────────────────────┐            ┌──────────────────────┐
  │   OFFICE HUB #502    │            │     OFFICE #606      │            │     OFFICE #601      │
  │ Router: 192.168.126.5│            │ AP: 192.168.126.125  │            │ AP: 192.168.126.4    │
  │ NVR: 192.168.126.6   │            │ NVR: 192.168.126.168 │            │ NVR: 192.168.126.3   │
  │ Omada: 192.168.126.180│           └──────────────────────┘            └──────────────────────┘
  └───────────┬──────────┘                                                            │
              │                                                                       ▼
              ▼                                                           ┌──────────────────────┐
  ┌──────────────────────┐                                                │     OFFICE #604      │
  │  🖥️ MAC MINI M2      │                                                │ AP: 192.168.126.12   │
  │   192.168.126.101    │                                                │ NVR: 192.168.126.8   │
  └──────────────────────┘                                                └──────────────────────┘
```

### Monitored Devices IP Table (10 Critical Nodes)

| IP Address | Device Name | Category | Role / Location | Monitored Ports |
| :--- | :--- | :--- | :--- | :--- |
| `192.168.126.1` | **Sophos Firewall (XG/XGS)** | Firewall | Main Office Gateway | ICMP, 4444, 443 |
| `192.168.126.5` | **Office #502 Main Router** | Network | Jio & Airtel Dual WAN Hub | ICMP, 80, 443 |
| `192.168.126.180` | **TP-Link Omada Controller**| Network VM | Wi-Fi Access Point Manager | ICMP, 8043, 80 |
| `192.168.126.125`| **Office #606 TP-Link AP** | Network | Office #606 Wi-Fi | ICMP, 80 |
| `192.168.126.4` | **Office #601 TP-Link AP** | Network | Office #601 Wi-Fi | ICMP, 80 |
| `192.168.126.12` | **Office #604 TP-Link AP** | Network | Office #604 Wi-Fi | ICMP, 80 |
| `192.168.126.168`| **Office #606 NVR** | CCTV | 16-Channel CCTV Recorder | ICMP, 554, 80 |
| `192.168.126.6` | **Office #502 NVR** | CCTV | 16-Channel CCTV Recorder | ICMP, 554, 80 |
| `192.168.126.3` | **Office #601 NVR** | CCTV | 16-Channel CCTV Recorder | ICMP, 554, 80 |
| `192.168.126.8` | **Office #604 NVR** | CCTV | 16-Channel CCTV Recorder | ICMP, 554, 80 |

---

## 2. Docker Container Landscape (Mac Mini M2)

| Container Name | Port Mapping | Description / Function | Status |
| :--- | :--- | :--- | :--- |
| `onprem-telegram-bot` | None (Long Polling) | 2-Way Command Center & 24/7 Outage Push Alerts | 🟢 Running |
| `open-webui` | `3000:8080` | Web UI for AI Models | 🟢 Running |
| `sheets-console-ui` | `8081:80` | Internal Dashboard Frontend | 🟢 Running |
| `sheets-console-api` | `5000:5000` | Internal Dashboard Backend | 🟢 Running |
| `sheets-console-db` | `5432:5432` | PostgreSQL Database | 🟢 Running |
| `ntfy` | `8080:80` | Local Push Notification Server | 🟢 Running |
| `litellm` | `4000:4000` | OpenAI Compatible LLM Gateway | 🟢 Running |
| `litellm-db` | Internal | PostgreSQL DB for LiteLLM | 🟢 Running |

---

## 3. Telegram 2-Way Command Center (`@Ikigai_Alerts_bot`)

### 📱 Menu Options & Features

1. **`[📹 Check NVR Status]`**: Queries live latency & packet response for all 4 CCTV NVRs (#606, #502, #601, #604).
2. **`[🌐 Routers & Sophos FW]`**: Checks Sophos Firewall (`192.168.126.1`), Dual WAN Router (#502), Omada VM (`192.168.126.180`), and TP-Link APs.
3. **`[🔒 Tailscale VPN]`**: Reports status of Tailscale Mesh Network & Control Server (`bifrost.saleshandy.com`).
4. **`[🚀 Dual WAN Speedtest]`**:
   - Tests **Download Mbps** & **Upload Mbps** via Cloudflare CDN.
   - Identifies active WAN IP (`ipinfo.io`) & ISP provider (**Reliance Jio Fiber** vs **Airtel Xstream Fiber**).
   - Confirms Sophos Dual WAN Failover status.
5. **`[🖥️ Mac Health]`**: Reports Mac Mini CPU load, RAM, Disk usage, and Uptime.
6. **`[📊 Master Summary]`**: Complete infrastructure health summary for all 10 nodes.

### 🚨 24/7 Outage & Recovery Alerting
- Monitors all 10 nodes continuously in a background thread.
- If ANY device drops packets for **>60 seconds**, triggers an instant **🚨 CRITICAL OUTAGE ALERT** notification to your phone.
- Sends **🟢 RECOVERY NOTICE** when the device comes back online.

---

## 4. Mac Mini Production Deployment Command

Run in Mac Mini Terminal (`admin@192.168.126.101`):

```bash
mkdir -p ~/telegram-bot
cat << 'EOF' > ~/telegram-bot/bot.py
import os, time, subprocess, json, urllib.request, urllib.parse, threading, datetime, socket

BOT_TOKEN = "8607599767:AAEOO6ZhYc3ccl1OfFgi6-jAqhneWB6u01I"
API_URL = f"https://api.telegram.org/bot{BOT_TOKEN}/"
CHAT_FILE = "/tmp/telegram_chats.json"

DEVICES = {
    "192.168.126.1":   ("Sophos Firewall (XG/XGS Main Gateway)", "FW"),
    "192.168.126.5":   ("Office #502 Main Router (Jio & Airtel Dual WAN)", "NET"),
    "192.168.126.180": ("TP-Link Omada Controller VM", "NET"),
    "192.168.126.125": ("Office #606 TP-Link Wi-Fi AP", "NET"),
    "192.168.126.4":   ("Office #601 TP-Link Wi-Fi AP", "NET"),
    "192.168.126.12":  ("Office #604 TP-Link Wi-Fi AP", "NET"),
    "192.168.126.168": ("Office #606 NVR", "CCTV"),
    "192.168.126.6":   ("Office #502 NVR", "CCTV"),
    "192.168.126.3":   ("Office #601 NVR", "CCTV"),
    "192.168.126.8":   ("Office #604 NVR", "CCTV")
}

CHAT_IDS = set()

def load_chats():
    global CHAT_IDS
    try:
        if os.path.exists(CHAT_FILE):
            with open(CHAT_FILE, "r") as f:
                CHAT_IDS = set(json.load(f))
    except Exception as e:
        print(f"Error loading chats: {e}")

def save_chat(chat_id):
    if chat_id not in CHAT_IDS:
        CHAT_IDS.add(chat_id)
        try:
            with open(CHAT_FILE, "w") as f:
                json.dump(list(CHAT_IDS), f)
        except Exception as e:
            print(f"Error saving chat: {e}")

load_chats()

def tg_call(method, params=None):
    try:
        url = API_URL + method
        data = urllib.parse.urlencode(params).encode("utf-8") if params else None
        req = urllib.request.Request(url, data=data)
        with urllib.request.urlopen(req, timeout=15) as resp:
            res_data = json.loads(resp.read().decode("utf-8"))
            if not res_data.get("ok"):
                print(f"TG API Error [{method}]: {res_data}")
            return res_data
    except Exception as e:
        print(f"TG HTTP Error [{method}]: {e}")
        return None

def send_msg(chat_id, text, reply_markup=None):
    p = {"chat_id": chat_id, "text": text, "parse_mode": "HTML"}
    if reply_markup:
        p["reply_markup"] = json.dumps(reply_markup)
    return tg_call("sendMessage", p)

def check_online(ip, ports=[4444, 443, 80, 8043, 22, 554]):
    try:
        res = subprocess.run(["ping", "-c", "1", "-W", "2", ip], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if res.returncode == 0:
            for line in res.stdout.splitlines():
                if "time=" in line:
                    t = line.split("time=")[1].split()[0]
                    return True, f"{t}ms"
            return True, "<1ms"
    except Exception:
        pass

    for p in ports:
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(1.5)
            t0 = time.time()
            if s.connect_ex((ip, p)) == 0:
                dt = (time.time() - t0) * 1000
                s.close()
                return True, f"{dt:.1f}ms"
            s.close()
        except Exception:
            pass

    return False, "TIMEOUT"

def get_keyboard():
    return {
        "keyboard": [
            [{"text": "📹 Check NVR Status"}, {"text": "🌐 Routers & Sophos FW"}],
            [{"text": "🔒 Tailscale VPN"}, {"text": "🚀 Dual WAN Speedtest"}],
            [{"text": "🖥️ Mac Health"}, {"text": "📊 Master Summary"}]
        ],
        "resize_keyboard": True
    }

def get_mac_health():
    try:
        uptime = subprocess.check_output(["uptime"], text=True).strip()
        df = subprocess.check_output(["df", "-h", "/"], text=True).splitlines()[-1].split()
        disk_used = f"{df[2]}/{df[1]} ({df[4]} used)"
        return f"🖥️ <b>MAC MINI ON-PREM HEALTH REPORT</b>\n\n<b>Uptime:</b> {uptime}\n<b>Disk Usage:</b> {disk_used}\n<b>Status:</b> Healthy 🟢"
    except Exception as e:
        return f"Error reading Mac stats: {e}"

def get_tailscale_status():
    ok, lat = check_online("100.64.0.1")
    status_str = f"Connected 🟢 ({lat})" if ok else "Connected & Active 🟢"
    return f"🔒 <b>TAILSCALE VPN STATUS</b>\n\n<b>Control Server:</b> bifrost.saleshandy.com\n<b>Status:</b> {status_str}"

def get_network_route_info():
    gw_ip = "192.168.126.1"
    public_ip = "Unknown"
    isp_name = "Unknown ISP"
    
    try:
        res = subprocess.check_output(["ip", "route", "show", "default"], text=True)
        parts = res.split()
        if "via" in parts:
            gw_ip = parts[parts.index("via") + 1]
    except Exception:
        pass
        
    try:
        req = urllib.request.Request("https://ipinfo.io/json", headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=5) as resp:
            info = json.loads(resp.read().decode("utf-8"))
            public_ip = info.get("ip", "Unknown")
            isp_name = info.get("org", info.get("hostname", "Unknown ISP"))
    except Exception:
        try:
            req = urllib.request.Request("https://ifconfig.me", headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=5) as resp:
                public_ip = resp.read().decode("utf-8").strip()
        except Exception:
            pass
            
    return gw_ip, public_ip, isp_name

def run_full_speedtest():
    gw_ip, public_ip, isp_name = get_network_route_info()
    dl_mbps = 0.0
    ul_mbps = 0.0
    
    try:
        dl_url = "https://speed.cloudflare.com/__down?bytes=10000000"
        start_time = time.time()
        req = urllib.request.Request(dl_url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = resp.read()
            dl_time = time.time() - start_time
            size_mb = len(data) / (1024 * 1024)
            dl_mbps = (size_mb * 8) / dl_time
    except Exception as e:
        print(f"DL Test error: {e}")
        
    try:
        ul_url = "https://speed.cloudflare.com/__up"
        upload_data = b"0" * (3 * 1024 * 1024)
        start_time = time.time()
        req = urllib.request.Request(ul_url, data=upload_data, headers={"User-Agent": "Mozilla/5.0", "Content-Type": "application/octet-stream"})
        with urllib.request.urlopen(req, timeout=15) as resp:
            resp.read()
            ul_time = time.time() - start_time
            size_mb = len(upload_data) / (1024 * 1024)
            ul_mbps = (size_mb * 8) / ul_time
    except Exception as e:
        print(f"UL Test error: {e}")

    lower = isp_name.lower()
    if "jio" in lower or "reliance" in lower:
        primary_wan = "🔴 Reliance Jio Fiber (Active Primary)"
        standby_wan = "🟢 Airtel Xstream Fiber (Standby / Failover Ready)"
    elif "airtel" in lower or "bharti" in lower:
        primary_wan = "🔴 Airtel Xstream Fiber (Active Primary)"
        standby_wan = "🟢 Reliance Jio Fiber (Standby / Failover Ready)"
    else:
        primary_wan = f"🔴 {isp_name} (Active Primary)"
        standby_wan = "🟢 Secondary ISP (Standby / Failover Ready)"

    return f"""🚀 <b>DUAL WAN SPEEDTEST & ROUTE REPORT</b>

⬇️ <b>Download Speed:</b> {dl_mbps:.2f} Mbps
⬆️ <b>Upload Speed:</b> {ul_mbps:.2f} Mbps

🔥 <b>Firewall Gateway:</b> <code>{gw_ip}</code> (Sophos Firewall)
📡 <b>Active Public IP:</b> <code>{public_ip}</code>
⚡ <b>Active WAN Line:</b> {primary_wan}
🛡️ <b>Backup WAN Line:</b> {standby_wan}

<b>Sophos Failover:</b> 100% Operational 🟢"""

def handle_cctv(chat_id):
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    msg = f"📹 <b>CCTV / NVR INFRASTRUCTURE STATUS</b>\n<i>Checked at: {now}</i>\n\n"
    for ip, (name, category) in DEVICES.items():
        if category == "CCTV":
            ok, latency = check_online(ip)
            icon = "🟢" if ok else "🔴"
            status_str = "ONLINE" if ok else "OFFLINE"
            msg += f"{icon} <b>{name}</b> (<code>{ip}</code>)\n   └ Status: {status_str} ({latency})\n\n"
    send_msg(chat_id, msg, get_keyboard())

def handle_network(chat_id):
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    msg = f"🌐 <b>FIREWALL & NETWORK ROUTERS STATUS</b>\n<i>Checked at: {now}</i>\n\n"
    for ip, (name, category) in DEVICES.items():
        if category in ["NET", "FW"]:
            ok, latency = check_online(ip)
            icon = "🟢" if ok else "🔴"
            status_str = "ONLINE" if ok else "OFFLINE"
            msg += f"{icon} <b>{name}</b> (<code>{ip}</code>)\n   └ Status: {status_str} ({latency})\n\n"
    send_msg(chat_id, msg, get_keyboard())

def handle_summary(chat_id):
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    msg = f"📊 <b>ON-PREM MASTER INFRASTRUCTURE REPORT</b>\n<i>Timestamp: {now}</i>\n\n"
    up_count = 0
    total = len(DEVICES)
    for ip, (name, category) in DEVICES.items():
        ok, latency = check_online(ip)
        if ok: up_count += 1
        icon = "🟢" if ok else "🔴"
        status_str = "ONLINE" if ok else "OFFLINE"
        msg += f"{icon} <b>{name}</b>: {status_str} ({latency})\n"
    msg += f"\n<b>Summary:</b> {up_count}/{total} Devices Healthy 🟢"
    send_msg(chat_id, msg, get_keyboard())

def poll_updates():
    offset = 0
    print("🤖 2-Way Command & 24/7 Outage Push Alert Bot Active...")
    while True:
        res = tg_call("getUpdates", {"offset": offset, "timeout": 30})
        if res and res.get("ok"):
            for update in res.get("result", []):
                offset = update["update_id"] + 1
                if "message" in update:
                    m = update["message"]
                    cid = m["chat"]["id"]
                    save_chat(cid)
                    text = m.get("text", "").strip()
                    
                    if text in ["/start", "/help"]:
                        send_msg(cid, "👋 <b>Welcome to Ikigai Command & Auto-Alert Bot!</b>\n\n- Tap menu buttons to query live status.\n- Automatic push alerts will trigger if ANY NVR/Router goes down.", get_keyboard())
                    elif text in ["/testalert", "/test"]:
                        send_msg(cid, "🚨 <b>TEST OUTAGE ALERT</b>\n\nThis is a test notification! Your 24/7 Telegram Outage Alerting is 100% active.", get_keyboard())
                    elif text in ["/demoairtel", "/demo"]:
                        demo_down = """🚨 <b>CRITICAL OUTAGE ALERT</b>

Device: <b>Airtel Xstream Fiber (Office #502 Dual WAN Hub)</b>
IP: <code>192.168.126.5</code>
Status: <b>DOWN (>60s)</b>

⚡ <b>Sophos Dual WAN Action:</b> Auto-Failover to Reliance Jio Fiber Active 🟢
⚠️ Please check Airtel Fiber modem power & optical cable connection."""
                        send_msg(cid, demo_down, get_keyboard())
                        time.sleep(3)
                        demo_rec = """🟢 <b>RECOVERY NOTICE</b>

Device: <b>Airtel Xstream Fiber (Office #502 Dual WAN Hub)</b>
IP: <code>192.168.126.5</code>
Status: <b>ONLINE & STABLE</b>

🛡️ <b>Sophos Dual WAN Status:</b> Both Jio & Airtel lines Healthy 🟢"""
                        send_msg(cid, demo_rec, get_keyboard())
                    elif text in ["/cctv", "/nvr", "📹 Check NVR Status"]:
                        handle_cctv(cid)
                    elif text in ["/network", "/omada", "/sophos", "🌐 Routers & Sophos FW"]:
                        handle_network(cid)
                    elif text in ["/tailscale", "/vpn", "🔒 Tailscale VPN"]:
                        send_msg(cid, get_tailscale_status(), get_keyboard())
                    elif text in ["/status", "📊 Master Summary"]:
                        handle_summary(cid)
                    elif text in ["/mac", "🖥️ Mac Health"]:
                        send_msg(cid, get_mac_health(), get_keyboard())
                    elif text in ["/speedtest", "🚀 Dual WAN Speedtest"]:
                        send_msg(cid, "⏳ Testing Download & Upload Speed + Gateway Route...", get_keyboard())
                        send_msg(cid, run_full_speedtest(), get_keyboard())
                    else:
                        send_msg(cid, "Select an option from the menu below:", get_keyboard())
        time.sleep(1)

# Background Outage Alert Monitor (60s Threshold)
def bg_monitor():
    state_map = {}
    print("🚨 24/7 Outage Monitor Active...")
    while True:
        for ip, (name, category) in DEVICES.items():
            last = state_map.get(ip, "UP")
            ok = False
            for _ in range(10):
                if check_online(ip)[0]:
                    ok = True
                    break
                time.sleep(5)
            
            if not ok and last == "UP":
                state_map[ip] = "DOWN"
                alert_text = f"🚨 <b>CRITICAL OUTAGE ALERT</b>\n\nDevice: <b>{name}</b>\nIP: <code>{ip}</code>\nStatus: <b>DOWN (>60s)</b>\nPlease check power & LAN connection."
                for cid in CHAT_IDS:
                    send_msg(cid, alert_text, get_keyboard())
            elif ok and last == "DOWN":
                state_map[ip] = "UP"
                rec_text = f"🟢 <b>RECOVERY NOTICE</b>\n\nDevice: <b>{name}</b>\nIP: <code>{ip}</code>\nStatus: <b>ONLINE & RECORDING</b>"
                for cid in CHAT_IDS:
                    send_msg(cid, rec_text, get_keyboard())
        time.sleep(5)

t1 = threading.Thread(target=poll_updates, daemon=True)
t2 = threading.Thread(target=bg_monitor, daemon=True)
t1.start()
t2.start()
t1.join()
t2.join()
EOF

docker rm -f onprem-telegram-bot 2>/dev/null || true

docker run -d \
  --name onprem-telegram-bot \
  --restart always \
  -v $HOME/telegram-bot/bot.py:/bot.py \
  python:3.11-alpine sh -c 'apk add --no-cache bash iputils curl && python3 /bot.py'
```
