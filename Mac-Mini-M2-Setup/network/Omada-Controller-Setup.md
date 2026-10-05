# Omada SDN Controller — Self-Hosted Setup on Mac Mini (ARM64 VM)

**Goal:** Manage all TP-Link Omada routers, switches, and access points from a single free, self-hosted console — no OC200/OC300 hardware controller, no paid Omada Central cloud subscription.

**Environment:** Mac Mini (Apple Silicon) running a Ubuntu ARM64 VM via UTM, with **Bridged networking** so devices can be auto-discovered on the LAN (autoscan).

---

## 1. Why Docker Was NOT Used

Initially considered Docker Desktop for Mac, but **rejected** because:

- Docker Desktop on macOS runs containers inside a lightweight VM with NAT-style networking.
- Broadcast/multicast traffic (which Omada's autoscan relies on) does not reach containers properly.
- Result: devices never appear in "Pending Devices" automatically — only manual adoption via inform-URL would work.

**Decision:** Run a real Linux VM with **bridged** networking instead, so the VM gets a genuine LAN IP and sits in the same broadcast domain as the routers/APs.

---

## 2. VM Setup (UTM)

1. Installed **UTM** (free): https://mac.getutm.app
2. Created a new VM:
   - OS: **Ubuntu Server** (ARM64 — matches Apple Silicon natively, no emulation needed)
   - CPU/RAM: 1 vCPU / 2GB minimum (used more for headroom)
3. **Critical setting:** Network Mode = **Bridged (Advanced)**, bridged to the Mac's active network interface (Ethernet recommended over Wi-Fi — Wi-Fi bridging is unreliable on macOS/QEMU).
4. Installed Ubuntu normally through the installer.

### Known snag: `systemd-networkd-wait-online` hang on boot
- Symptom: boot hangs waiting for network to come online.
- Cause: bridged adapter not getting a DHCP lease/link (common with Wi-Fi bridging).
- Fix: use wired Ethernet for the Mac's bridged interface, or wait for the timeout (~90s) to pass and let boot continue.

### Known snag: Forgotten root/user password
- Recovered via **GRUB → Advanced options → Recovery mode → root shell**, then:
  ```bash
  mount -o remount,rw /
  passwd your_username
  reboot
  ```
- On ARM64/UEFI (TianoCore) VMs, GRUB's menu can flash by too fast to catch with Shift/Esc. If dropped into a bare `grub>` rescue prompt, typing `normal` will often load the real GRUB menu.
- If GRUB config is broken entirely, easier to just reinstall the VM.

---

## 3. Enabling SSH (recommended — clipboard doesn't work reliably in UTM console)

On the VM console:
```bash
sudo apt update
sudo apt install -y openssh-server
sudo systemctl enable ssh
sudo systemctl start ssh
ip a   # note the LAN IP, e.g. 192.168.126.x
```

From the Mac's Terminal:
```bash
ssh your_username@192.168.126.x
```

This allows normal copy-paste from the Mac into the VM (UTM's own clipboard sharing is unreliable).

---

## 4. Installing Dependencies (ARM64-native)

> **Key insight:** The Omada Controller application itself is Java bytecode — architecture-independent. Only its *dependencies* (Java runtime, MongoDB, jsvc) need to be ARM64-native. This is confirmed by community installs of Omada on Raspberry Pi (ARM64) using the same "x64" TP-Link download.

### Java + jsvc
```bash
sudo apt install -y openjdk-17-jre-headless jsvc libcommons-daemon-java
```

### MongoDB (ARM64)
**Important:** MongoDB does not publish packages for very new Ubuntu codenames right away (e.g. Ubuntu 26.04 "Resolute" at time of this setup). MongoDB 7.0 packages are only published for Ubuntu 22.04 ("**jammy**") — use that codename regardless of your actual Ubuntu version, since the packages are ABI-compatible:

```bash
curl -fsSL https://pgp.mongodb.com/server-7.0.asc | sudo gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg

echo "deb [ arch=arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list

sudo apt update
sudo apt install -y mongodb-org
sudo systemctl enable mongod
sudo systemctl start mongod
```

Verify:
```bash
sudo systemctl status mongod
# Should show: active (running)
```

**Troubleshooting note:** If you see `404 Not Found` on the MongoDB repo, it means your Ubuntu codename isn't published yet — try `jammy` (22.04) first; if that also 404s, try `noble` (24.04), or check MongoDB's docs for currently supported Ubuntu/arch combos.

---

## 5. Installing Omada Controller (called "Omada Network Application" as of v6.2+)

1. Get the current download link from TP-Link's official page:
   https://support.omadanetworks.com/en/product/omada-software-controller/?resourceType=download
   (Copy the `linux_x64.tar.gz` link — this changes with every release, so always get the current one.)

2. Download and extract:
   ```bash
   cd /tmp
   wget -O omada-controller.tar.gz "PASTE_CURRENT_URL_HERE"
   mkdir -p omada-controller
   tar -xzf omada-controller.tar.gz -C omada-controller --strip-components=1
   cd omada-controller
   ls
   # Expect: bin  data  install.sh  lib  logs  properties  uninstall.sh
   ```

3. Install:
   ```bash
   chmod +x install.sh
   sudo ./install.sh
   ```
   On success, it prints:
   ```
   Install Omada Network Application succeeded!
   Started successfully.
   You can visit http://localhost:8088 on this host to manage the wireless network.
   ```

4. Control commands (global, once installed):
   ```bash
   sudo tpeap start
   sudo tpeap stop
   sudo tpeap status
   ```
   (Note: newer versions install `tpeap` globally at `/usr/bin/tpeap`, NOT under the older `/opt/tplink/EAPController/bin/` path — check with `which tpeap` if unsure.)

5. Access the web UI from the **Mac's browser** (not the VM):
   ```
   https://<vm-lan-ip>:8043
   ```

### Upgrade Log (2026-08-17)
Upgraded Omada Network Application from `v6.2.10.17` to **`v6.2.14.11`** (`Omada_Network_Application_v6.2.14.11_linux_x64`).
- Uploaded archive in 50MB chunks to `/tmp/omada_chunks` over Sophos VPN.
- Reassembled & extracted to `/tmp/omada-update-pkg`.
- Executed `printf '123456\ny\n' | sudo -S ./install.sh`.
- Confirmed running status via `sudo /usr/bin/tpeap status`.

> [!warning] 2026-08-18 — this upgrade actually left `lib/` in a mixed-version state, recovery in progress
> The `install.sh` run above did **not** cleanly replace the old JARs: `install.sh` got stuck 25+ min, and `lib/` ended up with both 159 old `*6.2.10.17.jar` files and 160 new `*6.2.14.11.jar` files side by side, causing `BeanDefinitionStoreException` / `IllegalAccessError` on startup. Emergency recovery removed the old-versioned JARs and got the controller running again (backup of the pre-fix `lib/` preserved at `/opt/tplink/EAPController/lib.pre-fix-20260817-1835`), but `startup.log` still showed a `NoSuchMethodError` from other stale JARs that don't carry the version string in their filename — **usable, but not fully clean.** A proper fix (swap in TP-Link's clean `lib/` from the full archive) was staged but not confirmed completed as of the last handover note. Full incident + exact recovery/continuation steps: `OMADA-UPDATE-HANDOVER.md` (repo root). **Verify current status with `sudo tpeap status` + check `startup.log` for fresh errors before assuming this is resolved.**

---

## 6. Device Discovery & Adoption

### Autoscan confirmed working
Because the VM uses bridged networking, all 3 APs (EAP653, EAP660 HD, EAP650) were discovered automatically under **Devices → Add Devices → Auto Find** — no manual inform-URL needed. This confirms the bridged-VM approach solved the original Docker limitation.

### "ADOPT FAILED" issue
Devices that were previously configured (not factory-default) will show `ADOPT FAILED` because they already have local admin credentials set, and the controller doesn't know them.

**Fix:** click the device row → a dialog asks for **Username/Password** — this is the *device's own local admin login* (not your Omada account), i.e. whatever credentials were set when the AP was originally configured.

- Entering wrong credentials is safe — it just fails again, no side effects.
- Entering correct credentials will **briefly reboot that specific AP** to push controller config — anyone connected to its Wi-Fi will briefly disconnect, then reconnect.
- If credentials are unknown, the only fallback is a physical **factory reset** (hold reset button ~5-10 sec) — but this is disruptive on a live office network, so confirm timing with whoever manages the network first.

### Device Management Hostname/IP (Settings)
Found under Settings — should be set to the **VM's own LAN IP** (e.g. `192.168.126.180`), so devices know where to check in with the controller going forward.

---

## 7. Wired vs. Wireless (Mesh) Uplink

- **Router/Gateway** is always wired by design — mesh does not apply to it.
- **Mesh** only applies to **APs** — it's an automatic wireless fallback used only when an AP has no wired uplink available.
- If all 3 APs are properly cabled to the switch/router, Omada will automatically prefer the **wired** uplink — no manual setting needed to "turn off" mesh.
- To confirm: adopt a device, open its details in **Devices**, check the **Uplink Type** field — should show "Wired" if cabling is good.
- If it shows "Wireless" despite a cable being plugged in, check: cable fully seated both ends, correct switch port, port link-light on.

---

## 8. Speed Test & Network Check Tools

- **Speed Test** (ISP bandwidth) — only available for **Omada Gateway/Router** devices, found under **Dashboard → ISP Load**. Not applicable to standalone APs.
- Can also enable **Periodic Speed Test** under **Settings → Sites → Service**, with results later visible in **Speed Test Statistics**.
- **Network Check** (the Ping / Tracert / DNS Lookup / ARP Table tool found on a device's page) is a **diagnostic tool**, not a bandwidth speed test — it runs the command *from that device* to check connectivity/latency to any target IP or domain. Useful for confirming an AP's uplink is healthy (low ping to gateway = good wired connection).

---

## 9. Quick Reference — Key Commands

| Purpose | Command |
|---|---|
| Check controller status | `sudo tpeap status` |
| Start/stop controller | `sudo tpeap start` / `sudo tpeap stop` |
| Check MongoDB status | `sudo systemctl status mongod` |
| Get VM's LAN IP | `ip a \| grep "inet "` |
| SSH into VM from Mac | `ssh username@vm-ip` |
| Reset forgotten password | GRUB → Recovery mode → root shell → `mount -o remount,rw /` → `passwd username` |
| Web UI | `https://<vm-ip>:8043` |

---

## 10. If Setting This Up Again From Scratch — Order of Operations

1. Install UTM → create Ubuntu ARM64 VM with **Bridged** networking (prefer wired Ethernet on the Mac).
2. Install Ubuntu, enable SSH early for easier command entry.
3. Install Java 17 + jsvc (ARM64 packages — straightforward via apt).
4. Install MongoDB 7.0 using the **jammy** repo (not your actual Ubuntu codename, unless MongoDB has since added support for it — check their install docs for current Ubuntu/arch support before assuming).
5. Download the current Omada Controller `linux_x64.tar.gz` from TP-Link's official site, extract, run `install.sh`.
6. Access `https://<vm-ip>:8043`, complete setup wizard.
7. Go to Devices → Add Devices → Auto Find — devices should appear automatically (confirms bridged networking is working).
8. For any device showing "ADOPT FAILED," enter its existing local admin credentials when prompted.
9. Verify each adopted device's **Uplink Type** shows "Wired" if physically cabled.
10. Set **Device Management Hostname/IP** in Settings to the VM's LAN IP.

---

*Document generated as a setup log/reference — TP-Link changes download URLs and package repos periodically, so always re-verify current links (mongodb.com/docs, support.omadanetworks.com) if repeating this setup much later.*
