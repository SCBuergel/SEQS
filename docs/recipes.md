# Recipes & helpers

Optional, mostly one-off tweaks that are not part of the automated SEQS install.
Apply the ones you want by hand.

## Contents

- [`delete-vms.sh` — rebuild a qube from scratch](#delete-vmssh)
- [Sync clock in the base template](#sync-clock-in-the-base-template)
- [WireGuard bandwidth monitor in the tray](#wireguard-bandwidth-monitor-in-the-tray)
- [CPU pinning for `A-gnosisvpn`](#cpu-pinning-for-a-gnosisvpn)
- [Firewall between app VMs](#firewall-between-app-vms)
- [Get rid of lags in LibreOffice](#get-rid-of-lags-in-libreoffice)
- [Reliably copy large files from/to an Android phone](#reliably-copy-large-files-fromto-an-android-phone)
- [vim mappings](#vim-mappings)
- [Mount a USB drive](#mount-a-usb-drive)
- [Minimal templates](#minimal-templates)

## `delete-vms.sh`

Re-running `setup-qubes.sh` converges on its own; you need `delete-vms.sh`
only to rebuild a qube from scratch. See [Deleting SEQS qubes](deleting-vms.md).

## Sync clock in the base template

Several apps have issues with exactly synced time (e.g. 2FA authenticator apps).
To mitigate that, install the following package in your base template (e.g.
`debian-13-xfce`):
```
sudo apt install systemd-timesyncd
```

## WireGuard bandwidth monitor in the tray

![Qubes tray showing download and upload stats](https://github.com/SCBuergel/SEQS/blob/main/tray.png?raw=true)

To show the bandwidth consumed by a WireGuard interface (e.g. of a VPN qube) in
the system tray:

1. Create a script `~/wg.sh` on the VPN app qube that has the WireGuard
   interface (by default assumes interface name `wg0_gnosisvpn`):
   ```bash
   #!/usr/bin/env bash
   set -euo pipefail

   IFACE="${1:-wg0_gnosisvpn}"

   get_bytes() {
     sudo wg show "$IFACE" transfer 2>/dev/null \
       | awk '{rx+=$2; tx+=$3} END {print rx+0, tx+0}'
   }

   human() {
     local bytes="$1"
     awk -v b="$bytes" 'BEGIN {
       split("B KB MB GB TB", u, " ")
       i=1
       while (b>=1024 && i<5) { b/=1024; i++ }

       # Always exactly 2 decimals to keep fixed width
       val=sprintf("%.2f", b)

       # 6 chars for number (incl. dot), 2 chars for unit
       printf "%6s %-2s", val, u[i]
     }'
   }

   read -r rx1 tx1 < <(get_bytes)
   sleep 1
   read -r rx2 tx2 < <(get_bytes)

   delta_rx=$((rx2 - rx1))
   delta_tx=$((tx2 - tx1))

   printf " ↑ %s (+ %s), ↓ %s (+ %s)\n" \
     "$(human "$tx2")" "$(human "$delta_tx")" \
     "$(human "$rx2")" "$(human "$delta_rx")"
   ```
2. Create a `vpn_monitor.sh` script in dom0 which calls the bandwidth monitor on
   the VPN app VM (assumes `A-gnosisvpn`):
   ```
   qvm-run --pass-io "A-gnosisvpn" "bash ~/wg.sh"
   ```
3. Add a generic monitor to the tray which runs the `vpn_monitor.sh` script
   above. Set the interval to **2s and not 1s**, otherwise the window manager
   might freeze!

## CPU pinning for `A-gnosisvpn`

The mixnet is CPU-intensive. This pins the qube to the two P-cores (physical
cores 0 and 2) on the i7-1265U.

**One-time setup (dom0)**

Create the pin script:
```bash
cat > ~/pimpmyvpn.sh << 'EOF'
#!/bin/bash
xl vcpu-pin A-gnosisvpn 0 0
xl vcpu-pin A-gnosisvpn 1 2
xl sched-credit2 -d A-gnosisvpn -w 512
EOF
chmod +x ~/pimpmyvpn.sh
```

Set vCPU count:
```bash
qvm-prefs A-gnosisvpn vcpus 2
```

Create the xenstore watcher:
```bash
sudo vim /usr/local/bin/watch-gnosisvpn.sh
```
```bash
#!/bin/bash
xenstore-watch /local/domain | while read event; do
    if xl list A-gnosisvpn &>/dev/null; then
        xl vcpu-pin A-gnosisvpn 0 0
        xl vcpu-pin A-gnosisvpn 1 2
        xl sched-credit2 -d A-gnosisvpn -w 512
    fi
done
```
```bash
sudo chmod +x /usr/local/bin/watch-gnosisvpn.sh
```

Create and enable the systemd service:
```bash
sudo vim /etc/systemd/system/watch-gnosisvpn.service
```
```ini
[Unit]
Description=Watch and pin A-gnosisvpn CPUs
After=xenstored.service

[Service]
Type=simple
ExecStart=/usr/local/bin/watch-gnosisvpn.sh
Restart=always

[Install]
WantedBy=multi-user.target
```
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now watch-gnosisvpn.service
```

**Verify**
```bash
xl vcpu-list A-gnosisvpn
# Affinity should show: 0 / all and 2 / all
```

## Firewall between app VMs

Qubes blocks connections between qubes. This recipe opens one TCP port from a
source qube to a target qube, for example a local RPC server (port 45750) that
a wallet qube should reach. Both qubes get a dedicated firewall qube, so the
rule does not affect other qubes. Tested on Qubes 4.3, where `sys-firewall` is
a disposable: its own files are reset at every start, so the rule lives in a
dedicated disposable template instead.

1. In dom0, create the firewall qube from clones of the stock ones, and find
   the two qubes' addresses:
   ```bash
   qvm-clone default-dvm app-sys-firewall
   qvm-clone sys-firewall sys-firewall-lab
   qvm-prefs sys-firewall-lab template app-sys-firewall
   qvm-prefs <source> ip
   qvm-prefs <target> ip
   ```
2. In a terminal of `app-sys-firewall` (not of `sys-firewall-lab`), allow the
   connection through the firewall qube, then shut `app-sys-firewall` down:
   ```bash
   echo 'nft add rule ip qubes custom-forward ip saddr SOURCE_IP ip daddr TARGET_IP tcp dport 45750 ct state new accept' | sudo tee -a /rw/config/qubes-firewall-user-script
   sudo chmod 755 /rw/config/qubes-firewall-user-script
   ```
3. In a terminal of the target qube, accept the connection there as well;
   without this step the target still refuses it:
   ```bash
   echo 'nft add rule ip qubes custom-input ip saddr SOURCE_IP tcp dport 45750 accept' | sudo tee -a /rw/config/rc.local
   sudo chmod 755 /rw/config/rc.local
   ```
4. In dom0, connect both qubes to the firewall qube, then restart them:
   ```bash
   qvm-prefs <source> netvm sys-firewall-lab
   qvm-prefs <target> netvm sys-firewall-lab
   ```

The source qube can now reach port 45750 of the target, and nothing else of it.
If either qube is re-created, its address changes; update both rules.

## Get rid of lags in LibreOffice

```
echo 'export SAL_USE_VCLPLUGIN=gen' >> ~/.bashrc
```

## Reliably copy large files from/to an Android phone

Default Qubes methods for copying large files to/from Android phones are
unreliable. The setup builds a dedicated `A-usb-data-transfer` qube (red label)
with `adb` and `pv` pre-installed from the Debian repos — `sys-usb` stays
untouched.

When the phone is plugged in, attach it to `A-usb-data-transfer` from the Qubes
Devices widget (or `qvm-usb attach A-usb-data-transfer sys-usb:<id>` from dom0).
Then in a terminal in the qube:
```
adb pull /sdcard/Documents/somefile.txt /tmp
adb push /tmp/somefile.txt /sdcard/Documents
```

For large files where the transfer can stall mid-way, use the bundled
chunked/resumable wrapper installed at `/usr/bin/adb-pull`:
```
adb-pull -c 10 /sdcard/big-file.zip /home/user/big-file.zip
```
It chunks the transfer, retries on adb timeout, resumes on re-invoke, and
SHA-256 checksums at the end. Wireless ADB also works: with the phone in pairing
mode you'll be prompted for the IP:port and pairing code on first connect; the
IP:port is then saved for next time. Note the SHA-256 check catches transport
corruption only — both hashes flow through the same ADB channel, so it doesn't
certify peer authenticity; prefer USB-attached ADB on untrusted networks.

## vim mappings

*(TODO: script this)*

Move screen lines in vim instead of wrapped physical lines — put this in
`~/.vimrc`:
```
noremap <up> gk
noremap <down> gj
inoremap <up> <C-o>gk
inoremap <down> <C-o>gj
```

## Mount a USB drive

Mount an attached USB drive without having all files be default executable and
root-owned, even if it's FAT formatted:
```
sudo mount -o uid=1000,gid=1000,fmask=177,dmask=077 /dev/xvdi /mnt
```

## Minimal templates

Install in dom0 via:
```
qvm-template install debian-13-minimal
```

These templates are [passwordless](https://www.qubes-os.org/doc/templates/minimal/#passwordless-root),
which means all `sudo` commands can only happen via a special terminal opened
from dom0 (for both template or app VM):
```
qvm-run -u root <qube> xterm
```

To give the app-VM user access to e.g. the webcam, run the following in the sudo
terminal of the template VM of the app VM:
```
sudo usermod -a -G video user
```
