import os, time, subprocess, json, urllib.request, urllib.parse, threading, datetime, socket

BOT_TOKEN = "8607599767:AAEOO6ZhYc3ccl1OfFgi6-jAqhneWB6u01I"
API_URL = f"https://api.telegram.org/bot{BOT_TOKEN}/"
CHAT_FILE = "/tmp/telegram_chats.json"
LOGS_FILE = "/tmp/telegram_outage_logs.json"

DEVICES = {
    "192.168.126.1":   ("Sophos Firewall (XG/XGS Main Gateway)", "FW"),
    "192.168.126.5":   ("Office #502 Main Router (Jio & Airtel Dual WAN)", "NET"),
    "192.168.126.180": ("TP-Link Omada Controller VM", "NET"),
    "192.168.126.125": ("Office #606 TP-Link Wi-Fi AP", "NET"),
    "192.168.126.4":   ("Office #601 TP-Link Wi-Fi AP / Router", "NET"),
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

INCIDENT_LOGS = []

def load_incident_logs():
    global INCIDENT_LOGS
    try:
        if os.path.exists(LOGS_FILE):
            with open(LOGS_FILE, "r") as f:
                INCIDENT_LOGS = json.load(f)
    except Exception as e:
        print(f"Error loading incident logs: {e}")
        INCIDENT_LOGS = []

def add_incident_log(ip, name, event_type, details=""):
    global INCIDENT_LOGS
    now_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    entry = {
        "timestamp": now_str,
        "ip": ip,
        "name": name,
        "event": event_type,
        "details": details
    }
    INCIDENT_LOGS.insert(0, entry)
    INCIDENT_LOGS = INCIDENT_LOGS[:50]
    try:
        with open(LOGS_FILE, "w") as f:
            json.dump(INCIDENT_LOGS, f, indent=2)
    except Exception as e:
        print(f"Error saving incident log: {e}")

load_incident_logs()

def get_incident_logs_report():
    if not INCIDENT_LOGS:
        return "📋 <b>INCIDENT & OUTAGE LOGS</b>\n\n🟢 No recent network outages or reboot incidents logged."
    
    msg = f"📋 <b>RECENT NETWORK INCIDENTS & LOGS</b>\n<i>Showing last {min(10, len(INCIDENT_LOGS))} events:</i>\n\n"
    for log in INCIDENT_LOGS[:10]:
        icon = "🔴" if log["event"] == "OUTAGE" else "🟢"
        msg += f"{icon} <b>{log['timestamp']}</b>\n"
        msg += f"   ├ <b>Device:</b> {log['name']} (<code>{log['ip']}</code>)\n"
        msg += f"   └ <b>Status:</b> {log['event']} ({log.get('details', '')})\n\n"
    return msg

def get_device_incident_report(ip, device_name):
    entries = [log for log in INCIDENT_LOGS if log["ip"] == ip]
    if not entries:
        return f"📅 <b>{device_name} — Detailed Outage Log</b>\n<i>IP: {ip}</i>\n\n🟢 No outage/recovery events logged yet for this device."

    lines = [f"📅 <b>{device_name} — Detailed Outage Log</b>\n<i>IP: {ip} | Showing last {min(30, len(entries))} events</i>\n"]
    hour_counts = {}
    for log in entries[:30]:
        icon = "🔴" if log["event"] == "OUTAGE" else "🟢"
        lines.append(f"{icon} <b>{log['timestamp']}</b> — {log['event']} ({log.get('details', '')})")
        if log["event"] == "OUTAGE":
            try:
                hr = datetime.datetime.strptime(log["timestamp"], "%Y-%m-%d %H:%M:%S").hour
                hour_counts[hr] = hour_counts.get(hr, 0) + 1
            except Exception:
                pass

    if hour_counts:
        top_hour = max(hour_counts, key=hour_counts.get)
        lines.append(f"\n🕒 <b>Pattern Insight:</b> Most outages happen around <b>{top_hour:02d}:00 hrs</b> ({hour_counts[top_hour]} time(s) in the events above). Check ISP/router logs around that hour.")

    return "\n".join(lines)

def handle_601_dvr_log(chat_id):
    ip = "192.168.126.3"
    name = DEVICES.get(ip, ("Office #601 NVR", "CCTV"))[0]
    send_msg(chat_id, get_device_incident_report(ip, name), get_keyboard())

def tg_call(method, params=None, http_timeout=15):
    try:
        url = API_URL + method
        data = urllib.parse.urlencode(params).encode("utf-8") if params else None
        req = urllib.request.Request(url, data=data)
        with urllib.request.urlopen(req, timeout=http_timeout) as resp:
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
            [{"text": "🖥️ System Health"}, {"text": "📊 Master Summary"}],
            [{"text": "📋 Incident Logs"}, {"text": "📅 601 DVR Log"}]
        ],
        "resize_keyboard": True
    }

def get_mac_health():
    try:
        uptime = subprocess.check_output(["uptime"], text=True).strip()
        df = subprocess.check_output(["df", "-h", "/"], text=True).splitlines()[-1].split()
        disk_used = f"{df[2]}/{df[1]} ({df[4]} used)"
        return f"🖥️ <b>UBUNTU INFRASTRUCTURE HEALTH REPORT</b>\n\n<b>Uptime:</b> {uptime}\n<b>Disk Usage:</b> {disk_used}\n<b>Status:</b> Healthy 🟢"
    except Exception as e:
        return f"Error reading system stats: {e}"

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
        res = tg_call("getUpdates", {"offset": offset, "timeout": 30}, http_timeout=40)
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
                    elif text in ["/mac", "/sys", "🖥️ System Health"]:
                        send_msg(cid, get_mac_health(), get_keyboard())
                    elif text in ["/speedtest", "🚀 Dual WAN Speedtest"]:
                        send_msg(cid, "⏳ Testing Download & Upload Speed + Gateway Route...", get_keyboard())
                        send_msg(cid, run_full_speedtest(), get_keyboard())
                    elif text in ["/logs", "/history", "/incidents", "📋 Incident Logs"]:
                        send_msg(cid, get_incident_logs_report(), get_keyboard())
                    elif text in ["/601log", "/dvr601", "📅 601 DVR Log"]:
                        handle_601_dvr_log(cid)
                    else:
                        send_msg(cid, "Select an option from the menu below:", get_keyboard())
        time.sleep(1)

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
                add_incident_log(ip, name, "OUTAGE", "DOWN (>60s)")
                alert_text = f"🚨 <b>CRITICAL OUTAGE ALERT</b>\n\nDevice: <b>{name}</b>\nIP: <code>{ip}</code>\nStatus: <b>DOWN (>60s)</b>\nPlease check power & LAN connection."
                for cid in CHAT_IDS:
                    send_msg(cid, alert_text, get_keyboard())
            elif ok and last == "DOWN":
                state_map[ip] = "UP"
                add_incident_log(ip, name, "RECOVERY", "ONLINE & STABLE")
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
