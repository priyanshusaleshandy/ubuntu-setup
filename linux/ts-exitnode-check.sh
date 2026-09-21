#!/usr/bin/env bash
# Tailscale exit-node check — safe to run over a remote session.
#
# It turns an exit node on, measures exactly what breaks, and ALWAYS puts the
# machine back. Two independent guarantees, because losing your session while
# an exit node is half-applied is how people get locked out:
#   1. the script restores the original prefs when it finishes
#   2. a detached root watchdog restores them anyway if the script, the SSH
#      session or the remote desktop dies mid-test
# It also re-execs itself detached, so a dropped connection cannot interrupt it.
#
# It changes nothing permanently and never touches login state: no `up`,
# no --reset, no --force-reauth, no --operator.
#
# Usage:  sudo bash ts-check.sh [exit-node-ip] [expected-egress-ip]
# Default: 100.64.0.1 (ikigai-office-network-node-1) / 44.229.234.59

set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo:  sudo bash $0"; exit 1; }

EXIT_NODE="${1:-100.64.0.1}"
EXPECT_IP="${2:-44.229.234.59}"
LOG=/var/log/ts-exitnode-check.log
HOLD=8            # seconds to let the exit node settle before measuring
WATCHDOG=150      # hard deadline: state is restored by then no matter what

command -v tailscale >/dev/null || { echo "tailscale is not installed."; exit 1; }

# ── Original state, so the revert restores what was there, not some default ──
prefs_val() { tailscale debug prefs | sed -n "s/.*\"$1\": \(.*\),/\1/p" | tr -d '"'; }
ORIG_ID="$(prefs_val ExitNodeID)"
ORIG_LAN="$(prefs_val ExitNodeAllowLANAccess)"
[ -n "$ORIG_LAN" ] || ORIG_LAN=false

# An exit node is stored by ID, but --exit-node takes an IP, so map it back.
ORIG_ARG=""
if [ -n "$ORIG_ID" ]; then
    ORIG_ARG="$(tailscale status --json 2>/dev/null | python3 -c '
import json,sys
want=sys.argv[1]
d=json.load(sys.stdin)
for p in (d.get("Peer") or {}).values():
    if str(p.get("ID"))==want:
        ips=p.get("TailscaleIPs") or []
        print(ips[0] if ips else "")
        break
' "$ORIG_ID" 2>/dev/null)"
fi

restore() {
    tailscale set --exit-node="$ORIG_ARG" >/dev/null 2>&1
    tailscale set --exit-node-allow-lan-access="$ORIG_LAN" >/dev/null 2>&1
}

# ── Self-detach: a dropped session must not be able to interrupt the revert ──
if [ -z "${TS_CHECK_DETACHED:-}" ]; then
    export TS_CHECK_DETACHED=1
    setsid nohup bash "$0" "$EXIT_NODE" "$EXPECT_IP" >/dev/null 2>&1 &
    echo "Started detached — nothing here depends on your session staying up."
    echo "Original state recorded: exit-node='${ORIG_ARG:-none}' allow-lan=$ORIG_LAN"
    echo
    echo "Read the result in about $((HOLD + 30)) seconds:"
    echo "    sudo cat $LOG"
    echo
    echo "The exit node is removed automatically when the test ends, and a"
    echo "watchdog removes it within ${WATCHDOG}s even if this run dies."
    exit 0
fi

exec > "$LOG" 2>&1

# Watchdog: only acts if the run below never reached the end.
setsid nohup bash -c "sleep $WATCHDOG
  grep -q 'CHECK COMPLETE' '$LOG' 2>/dev/null && exit 0
  tailscale set --exit-node='$ORIG_ARG' >/dev/null 2>&1
  tailscale set --exit-node-allow-lan-access=$ORIG_LAN >/dev/null 2>&1
  echo '[watchdog] run did not finish — original state restored' >> '$LOG'" >/dev/null 2>&1 &

echo "### tailscale exit-node check"
echo "host        : $(hostname)"
echo "date        : $(date)"
echo "exit node   : $EXIT_NODE   (expected egress $EXPECT_IP)"
echo "original    : exit-node='${ORIG_ARG:-none}'  allow-lan=$ORIG_LAN"
echo

echo "═══ 1. traffic-filtering agents present ═══"
echo "  eea service      : $(systemctl is-active eea 2>/dev/null || echo not-installed)"
REDIR=$(nft list ruleset 2>/dev/null | grep -c 38521 || echo 0)
echo "  ESET TCP redirect: $REDIR rule(s) to :38521"
echo "  eset modules     : $(lsmod | grep -ci eset || echo 0)"
echo "  warp             : $(systemctl is-active warp-svc 2>/dev/null || echo not-installed)"
echo

echo "═══ 2. baseline, no exit node ═══"
BASE_IP=$(curl -4 -s --max-time 12 https://ifconfig.me || echo FAIL)
echo "  egress v4  : $BASE_IP"
echo "  google     : $(curl -s -o /dev/null -w '%{http_code}' --max-time 12 https://www.google.com/)"
echo "  rp_filter  : all=$(cat /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null)"
echo "  tailscale0 : $(ip link show tailscale0 2>/dev/null | head -1 | grep -o 'mtu [0-9]*')"
echo

echo "═══ 3. exit node ON ═══"
tailscale set --exit-node-allow-lan-access=true; echo "  allow-lan rc=$?  (keeps LAN/SSH direct so your session survives)"
tailscale set --exit-node="$EXIT_NODE";          echo "  exit-node rc=$?"
sleep "$HOLD"
PEER=$(tailscale status 2>/dev/null | grep "^$EXIT_NODE " | sed 's/  */ /g')
echo "  applied    : $(tailscale debug prefs | grep ExitNodeID | tr -d ' \t,\"')"
echo "  peer       : $PEER"
echo "  route      : $(ip route get 8.8.8.8 2>/dev/null | head -1)"
echo

echo "═══ 4. measurements through the exit node ═══"
ICMP=$(ping -c 3 -W 3 8.8.8.8 2>&1 | grep -oE '[0-9]+% packet loss' || echo "no reply")
echo "  ICMP 8.8.8.8    : $ICMP"
DNSR=$(getent hosts www.google.com | head -1 || echo FAIL)
echo "  DNS             : ${DNSR:-FAIL}"
P443=$(curl -4 -s -o /dev/null -w '%{http_code}' --max-time 10 https://portquiz.net:443/ 2>/dev/null || echo 000)
P8080=$(curl -4 -s -o /dev/null -w '%{http_code}' --max-time 10 http://portquiz.net:8080/ 2>/dev/null || echo 000)
echo "  TCP :443        : $P443"
echo "  TCP :8080       : $P8080     (ACL allows 8000-9000 but not 443)"
EG=$(curl -4 -s --max-time 15 https://ifconfig.me || echo FAIL)
echo "  egress v4       : $EG   (want $EXPECT_IP)"
G=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 https://www.google.com/)
I=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 https://app.intercom.com/)
echo "  google          : $G"
echo "  intercom        : $I"
MTU=""
for s in 1200 1300 1400 1460; do
    ping -c 1 -W 2 -M do -s $s 8.8.8.8 >/dev/null 2>&1 && MTU="$MTU ${s}:ok" || MTU="$MTU ${s}:fail"
done
echo "  MTU probe       :$MTU"
echo

echo "═══ 5. restoring original state ═══"
restore
sleep 3
echo "  exit node now : $(tailscale debug prefs | grep ExitNodeID | tr -d ' \t,\"')"
echo "  allow-lan now : $(prefs_val ExitNodeAllowLANAccess)"
echo "  egress v4     : $(curl -4 -s --max-time 12 https://ifconfig.me || echo FAIL)"
echo "  internet      : $(curl -s -o /dev/null -w '%{http_code}' --max-time 12 https://www.google.com/)"
echo

echo "═══ VERDICT ═══"
if [ "$EG" = "$EXPECT_IP" ] && [ "$G" = "200" ]; then
    echo "  PASS — traffic egressed via $EXIT_NODE and the web worked."
    case "$PEER" in
        *direct*) echo "         Path was direct. This is the healthy state." ;;
        *relay*)  echo "         Path was relayed, so it works but with extra latency." ;;
    esac
elif [ "$REDIR" -gt 0 ] && [ "$G" != "200" ]; then
    echo "  FAIL — and ESET's Web Access Protection redirect is active ($REDIR rule)."
    echo "         That redirect sends every outbound TCP SYN to :38521, which"
    echo "         collides with Tailscale's fwmark/table-52 policy routing."
    echo "         This is the known root cause. Fix it on the ESET side:"
    echo "         exclude /usr/sbin/tailscaled and /usr/bin/tailscale, or force"
    echo "         Web access protection off by policy on this endpoint."
elif echo "$PEER" | grep -q relay && echo "$PEER" | grep -qE 'rx 0(,|$| )'; then
    echo "  FAIL — no usable path to $EXIT_NODE: relayed with nothing coming back."
    echo "         Look at UDP 41641 reachability and whether anything is"
    echo "         proxying tailscaled's own TCP 443 to the DERP servers."
elif [ "$P8080" = "200" ] && [ "$P443" = "000" ]; then
    echo "  FAIL — port-selective: 8080 passed, 443 did not."
    echo "         That matches the tailnet ACL, which permits TCP only on"
    echo "         53 and 8000-9000. Fix is in the Headscale policy, not here."
elif [ "$ICMP" = "0% packet loss" ] && [ "$G" != "200" ]; then
    echo "  FAIL — ICMP passes but TCP does not, with no ESET redirect present."
    echo "         Either $EXIT_NODE is not forwarding TCP/UDP (the Windows node"
    echo "         100.64.0.7 behaves exactly like this), or the ACL is blocking."
else
    echo "  FAIL — pattern does not match a known cause. Sections 3 and 4 above"
    echo "         have the raw evidence."
fi
echo
echo "Original state has been restored. Nothing here persists."
echo "CHECK COMPLETE"
