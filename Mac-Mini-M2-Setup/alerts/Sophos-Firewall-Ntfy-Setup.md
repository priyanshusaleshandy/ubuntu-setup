# Sophos Firewall (XG/XGS) Integration

**Firewall LAN IP:** `192.168.126.1`  
**Web Admin Port:** `4444`  
**Dual WAN Line:** Reliance Jio Fiber (Primary) + Airtel Xstream Fiber (Failover Backup)

---

## Sophos Health Monitoring

The Sophos Firewall is monitored via:
1. **ICMP Ping**: Real-time packet response.
2. **TCP Socket Check (Port 4444)**: Fallback port check if ping is restricted by firewall security rules.
3. **Dual WAN Failover Detection**: Cloudflare CDN speedtest queries active outbound route (`ipinfo.io`) to report whether Jio or Airtel is currently routing traffic.
