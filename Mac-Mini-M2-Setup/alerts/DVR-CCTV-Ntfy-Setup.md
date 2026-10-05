# CCTV NVR Infrastructure Monitoring

**Total NVRs:** 4  
**Monitored Ports:** ICMP Ping, RTSP (Port 554), HTTP (Port 80)

---

## NVR IP Catalog

1. **Office #606 NVR**: `192.168.126.168` (16 Channels)
2. **Office #502 NVR**: `192.168.126.6` (16 Channels)
3. **Office #601 NVR**: `192.168.126.3` (16 Channels)
4. **Office #604 NVR**: `192.168.126.8` (16 Channels)

---

## 60-Second Outage Threshold Policy

To avoid false alarms caused by 15-20 second NVR stream buffering or temporary network blips, the background monitor waits for **10 consecutive failed retries over 60 seconds** before triggering a `🚨 CRITICAL OUTAGE ALERT` to Telegram.
