# Seb's QubesOS Scripts

## Installing QubesOS
1. Start with an empty 8GB USB stick
2. Download the latest [Qubes OS ISO image](https://www.qubes-os.org/downloads/) - warning, [currently, Qubes cannot handle Ventoy-based installer images](https://github.com/QubesOS/qubes-issues/issues/8846), so use a dedicated USB drive for the Qubes installer!
3. **Verify the ISO before flashing it.** A tampered ISO can compromise the entire install (and therefore every qube you later create on it). The full procedure is documented at [Qubes: Verifying signatures](https://www.qubes-os.org/security/verifying-signatures/); summary:
    1. Fetch the Qubes Master Signing Key (QMSK):
        ```
        gpg --fetch-keys https://keys.qubes-os.org/keys/qubes-master-signing-key.asc
        ```
    2. Cross-check the QMSK fingerprint `427F 11FD 0FAA 4B08 0123  F01C DDFA 1A3E 3687 9494` against **three independent sources** — if the same fingerprint shows up across unrelated infrastructure, it is much harder for any single operator (or a MITM on your network) to have substituted a key:
        - Qubes website (primary): https://www.qubes-os.org/security/pack/
        - Qubes `qubes-secpack` repo on GitHub (different infra, separate TLS chain): https://github.com/QubesOS/qubes-secpack
        - `keys.openpgp.org` keyserver (independent operator): https://keys.openpgp.org/search?q=0xDDFA1A3E36879494
    3. Mark the QMSK as trusted and fetch the release signing key (which is itself signed by the QMSK):
        ```
        gpg --edit-key 0x36879494    # then type: trust, 5, y, quit
        gpg --fetch-keys https://keys.qubes-os.org/keys/qubes-release-X-signing-key.asc
        ```
        (replace `X` with the major release number of the ISO you downloaded)
    4. Verify the ISO against its detached signature (download the matching `.asc` file from the same downloads page):
        ```
        gpg --verify Qubes-RX.X-x86_64.iso.asc Qubes-RX.X-x86_64.iso
        ```
        A `Good signature from "Qubes OS Release X Signing Key"` line — and **no warning about the key not being certified** — confirms the ISO is authentic.
4. I create partitions and mount points as follows:
    1. 500 MGB `/boot/efi` (if you do multiboot with other OSs, this partition can be shared)
    2. 1 GB `/boot` (warning: it seems that you cannot share a Qubes and e.g. Ubuntu `/boot` mount point, Qubes will just boot you into a black screen)
    4. whatever is left `/` (encrypted, LUKS2)
4. For convenience, I like window tiling to arrange windows neatly: Qubes menu -> System Tools -> Window Manager -> Keyboard -> scroll down to the Tile settings which I set as follows:

![Screenshot of Qubes Window Manager Keyboard settings](https://github.com/SCBuergel/SEQS/blob/main/WindowManagerTile.png?raw=true)

6. After connecting to wifi, the system update icon should appear in the tray on the top right, run all updates and reboot

## Install software
I set up a template VM for every software that I want to use and then create an app VM that I actually run for using the software. To keep the Qubes menu and Qubes manager clean, all my template VMs are prefixed `Z-[AppName]` and my app VMs are prefixed `A-[AppName]`. This repository contains a range of scripts that set up template VMs and app VMs for several software packages. In order to create them, you are copying files from an app VM to your dom0.

**WARNING: Please note that this is a potential security threat as it exposes your dom0 environment to running a bunch of scripts which I do not guarantee to be safe, so please check all files by yourself and only proceed if you understand everything and consider all actions to be safe!**

In order to set up everything in an automated fashion:
1. Download this repo into the home directory of your `personal` app VM
2. Open dom0 terminal and type the following one-liner (this is a [common hack to copy files from an app VM into dom0](https://www.qubes-os.org/doc/how-to-copy-from-dom0/#copying-to-dom0)):
```
qvm-run -p personal 'cat /home/user/SEQS/setup-qubes.sh' 2>/dev/null > s.sh && chmod +x s.sh && ./s.sh
```
The `2>/dev/null` on the `qvm-run` step is deliberate. The fetch happens BEFORE `setup-qubes.sh` exists in dom0 (and therefore before its `vmRun` sanitizer is available), so any bytes the source qube writes to stderr land directly on the dom0 terminal. A compromised `personal` qube could otherwise emit ANSI / CSI / OSC sequences (window-title smuggling, OSC 52 clipboard write, repaint earlier lines) during the `cat` — the same class of attack `vmRun` later defends against on every VM→dom0 path. Dropping stderr closes that bootstrap window. If the `cat` fails, `s.sh` ends up empty/partial and `./s.sh` fails loudly enough on its own.
3. Some software packages require you to reboot the app VM once to actually work.

The script will download the individual install scripts into dom0 and from there to newly created template VMs. The template VMs are then used to set up app VMs for proper isolation.

Control the actual software packages that are installed at the bottom of the `setup-qubes.sh` file.

### Composing qubes from components
Every qube the setup builds is composed by `installQube` from one or more **components** in `install-scripts/components/<name>/`. Single-tool qubes are 1-component; mix-and-match qubes (wallet, developer) list several. The composer clones the base template, runs each component's `template-vm.sh` (system-wide install) in the template, installs any `menu.desktop` it carries, then runs each `app-vm.sh` (per-app-qube setup) in the app qube, and wires up the browser-link policy and cleanup service.

Available components today:

| Component | What it installs |
|---|---|
| `adb`          | Android Debug Bridge + `pv` (Debian apt) + chunked, resumable `/usr/bin/adb-pull` helper |
| `brave`        | Brave browser (apt repo, embedded verified key) |
| `element`      | Element chat (apt repo) |
| `keepass`      | KeePassXC AppImage (GPG-verified) |
| `signal`       | Signal Desktop (apt repo, embedded verified key) |
| `telegram`     | Telegram via snap (`telegram-desktop`) |
| `openoffice`   | Apache OpenOffice tarball (GPG-verified) |
| `xournalpp`    | Xournal++ (Debian package) |
| `ledger`       | Ledger udev rules + Ledger Live |
| `trezor`       | Trezor udev rules |
| `bitbox`       | BitBoxApp `.deb` (GPG-verified) |
| `docker`       | Docker engine + persistent `/var/lib/docker` bind-dir |
| `python`       | pyenv + Python |
| `node`         | Node.js via nvm |
| `vscode`       | Visual Studio Code |
| `claude-code`  | Claude Code (native installer) |

**Three config blocks at the top of `setup-qubes.sh`:**

`WALLET_QUBES` and `DEV_QUBES` — arrays of qube specs, one per line, format `"NAME COLOR component component ..."`. Add a line to spin up a new combination; edit a line to add/remove components from an existing qube:
```
WALLET_QUBES=(
    "wallets  orange  ledger trezor brave-extension-metamask brave-extension-rabby"
)
DEV_QUBES=(
    "dev-full    gray  docker python node vscode claude-code"
    "dev-backend gray  docker python"
)
```

`BRAVE_EXTENSIONS` — name → Chrome Web Store ID for each Brave wallet extension. Reference them in wallet qube specs as `brave-extension-<name>`; the composer auto-installs Brave on the first such reference in a qube. To **enable** an extension in a qube: add `brave-extension-<name>` to that qube's `WALLET_QUBES` line. To **retire** an extension entirely: remove its line from `BRAVE_EXTENSIONS`. To **add** a new extension (e.g. Ambire): add a `BRAVE_EXTENSIONS` line, then reference it as `brave-extension-ambire` in any wallet qube.

Single-component qubes (Brave, KeePass, Signal, Telegram, Element, OpenOffice, Xournal++) are direct `installQube NAME COLOR component` calls at the bottom of `setup-qubes.sh`. A trailing `offline` flag (used for KeePass) detaches the app qube from netvm.

> **Browser-link handoff requires `A-brave`.** `setup-qubes.sh` configures every non-browser qube to open web links in `BROWSER_VM` (default `A-brave`) via the dom0 qrexec policy `qubes.OpenURL * @anyvm A-brave allow`. If you remove `brave` from `SINGLE_QUBES`, also change `BROWSER_VM` at the top of the script to a browser qube you do have — otherwise links from every other qube will fail to open.

### Adding a new component
Create `install-scripts/components/<name>/` containing an optional `template-vm.sh` (system-wide install in the template), an optional `app-vm.sh` (per-app-VM setup in `$HOME`/`/rw`), and an optional `menu.desktop` (installed as `/usr/share/applications/<name>.desktop`). Reference `<name>` in any qube spec. If the component needs Brave, it can `source "$(dirname "$0")/brave.sh"` and call `install_brave` (or `ensure_brave` for idempotent installation).

## Helpers
### delete-vms.sh
The following script cleans up VMs while debugging and setting up installers:
```
./delete-vms.sh keepass telegram wallets
```

### Wireguard BW monitor in tray
![Screenshot of Qubes tray showing download and upload stats](https://github.com/SCBuergel/SEQS/blob/main/tray.png?raw=true)

To show the bandwidth that got consumed by a wireguard interface (e.g. of a VPN qube) in the system tray, do the following:
1. create a script `~/wg.sh` on the VPN app qube that has the wireguard interface (by default assumes interface name `wg0_gnosisvpn`):
```
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
2. Create a `vpn_monitor.sh` script in dom0 which calls the actual bandwidth monitor on the VPN app VM (assumes `sys-gnosis-vpn`)
```
qvm-run --pass-io "sys-gnosis-vpn" "bash ~/bw.sh"
```
3. Add a generic monitor to the tray which runs the `vpn_monitor.sh` script created above. Make sure to set the interval to 2s and not 1s otherwise the window manager might freeze!



### QubesOS CPU Pinning for sys-gnosisvpn

The mixnet is CPU-intensive. This pins the qube to the two P-cores (physical cores 0 and 2) on the i7-1265U.

**One-time setup (dom0)**

Create the pin script:
```bash
cat > ~/pimpmyvpn.sh << 'EOF'
#!/bin/bash
xl vcpu-pin sys-gnosisvpn 0 0
xl vcpu-pin sys-gnosisvpn 1 2
xl sched-credit2 -d sys-gnosisvpn -w 512
EOF
chmod +x ~/pimpmyvpn.sh
```

Set vCPU count:
```bash
qvm-prefs sys-gnosisvpn vcpus 2
```

Create the xenstore watcher:
```bash
sudo nano /usr/local/bin/watch-gnosisvpn.sh
```
```bash
#!/bin/bash
xenstore-watch /local/domain | while read event; do
    if xl list sys-gnosisvpn &>/dev/null; then
        xl vcpu-pin sys-gnosisvpn 0 0
        xl vcpu-pin sys-gnosisvpn 1 2
        xl sched-credit2 -d sys-gnosisvpn -w 512
    fi
done
```
```bash
sudo chmod +x /usr/local/bin/watch-gnosisvpn.sh
```

Create and enable the systemd service:
```bash
sudo nano /etc/systemd/system/watch-gnosisvpn.service
```
```ini
[Unit]
Description=Watch and pin sys-gnosisvpn CPUs
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
xl vcpu-list sys-gnosisvpn
# Affinity should show: 0 / all and 2 / all
```



### Sync clock in the base template

Several apps will have issues with exactly synced time (e.g. 2FA authenticator apps). To mitigate that, install the following package in your base template (e.g. `debian-13-xfce`):
```
sudo apt install systemd-timesyncd
```

### Firewall setup between app VMs (TODO: script this)
For some use cases, it is useful to allow for selective connections between individual app VMs. This setup limits port 45750 for TCP traffic between two qubes. One example is the [RPCh server](https://access.rpch.net/) running within the `A-docker` app VM that should be accessible from an `A-wallets` app VM. In order to enable that, find the two respective IPs and set the iptables in the net VM. Since the default sys-firewall qube does not persist its `/rw` folder, the following is required to persist the settings between system reboots (as suggested [on the Qubes Forum](https://forum.qubes-os.org/t/help-sys-firewall-has-no-persistence-rc-local-gets-wiped-on-reboot/19184/4)):
1. In dom0 find the IP addresses of both app VMs:
```
qvm-ls -n | grep -E 'A-wallets|A-docker'
```
2. Clone your base disposable-VM template (e.g. `debian-13-xfce-dvm`), rename it as `app-sys-firewall`
3. Clone `sys-firewall`, rename it as `sys-firewall-lab`
4. Change the template of `sys-firewall-lab` from the disposable-VM template (e.g. `debian-13-xfce-dvm`) to `app-sys-firewall`
5. Configure changes on `sys-firewall-lab` by opening a terminal in `sys-firewall-lab`
```
echo "iptables -I FORWARD 2 -s IP_WALLETS -d IP_DOCKER -p tcp --dport 45750 -j ACCEPT" | sudo tee -a /rw/config/qubes-firewall-user-script
```
e.g.
```
echo "iptables -I FORWARD 2 -s 10.137.0.55 -d 10.137.0.51 -p tcp --dport 45750 -j ACCEPT" | sudo tee -a /rw/config/qubes-firewall-user-script
```
6. Restart `sys-firewall-lab`
7. Configure both `A-docker` app VM and `A-wallets` app VM to use `sys-firewall-lab` as their net qube. You can do that from the `dom0` terminal via:
```
qvm-prefs A-docker netvm sys-firewall-lab
qvm-prefs A-wallets netvm sys-firewall-lab
```
9. Now the wallet qube should be able to use the RPCh server on the other app VM. Test e.g. by calling the RPCh app VM via command line:
```
 curl 10.137.0.51:45750/?exit-provider=https://primary.gnosis-chain.rpc.hoprtech.net -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

If you re-install either of the two qubes, remember to update the entry in `/rw/config/qubes-firewall-user-script` with the respective new IPs.

### get rid of lags in libreoffice
```
echo 'export SAL_USE_VCLPLUGIN=gen' >> ~/.bashrc
```

### reliably copy large files from/to Android phone
Default Qubes methods for copying large files to/from Android phones are unreliable. The setup builds a dedicated `A-usb-data-transfer` qube (red label) with `adb` and `pv` pre-installed from the Debian repos — `sys-usb` stays untouched.

When the phone is plugged in, attach it to `A-usb-data-transfer` from the Qubes Devices widget (or `qvm-usb attach A-usb-data-transfer sys-usb:<id>` from dom0). Then in a terminal in the qube:
```
adb pull /sdcard/Documents/somefile.txt /tmp
adb push /tmp/somefile.txt /sdcard/Documents
```

For large files where the transfer can stall mid-way, use the bundled chunked/resumable wrapper installed at `/usr/bin/adb-pull`:
```
adb-pull -c 10 /sdcard/big-file.zip /home/user/big-file.zip
```
It chunks the transfer, retries on adb timeout, resumes on re-invoke, and SHA-256 checksums at the end. Wireless ADB also works: with the phone in pairing mode you'll be prompted for the IP:port and pairing code on first connect; the IP:port is then saved for next time. Note the SHA-256 check catches transport corruption only — both hashes flow through the same ADB channel, so it doesn't certify peer authenticity; prefer USB-attached ADB on untrusted networks.



### vim mappings (TODO: script this)
I like to move screen lines in vim instead of wrapped physical lines so I use the following `~/.vimrc` file:
```
noremap <up> gk
noremap <down> gj
inoremap <up> <C-o>gk
inoremap <down> <C-o>gj
```

### mount USB drive
Use the following to mount an attached USB drive without having all files be default executable and root-owned, even if it's FAT formatted
```
sudo mount -o uid=1000,gid=1000,fmask=177,dmask=077 /dev/xvdi /mnt
```

### minimal templates
Install in `dom0` via
```
sudo qubes-dom0-update qubes-template-debian-13-minimal
```

These templates are [passwordless](https://www.qubes-os.org/doc/templates/minimal/#passwordless-root) which means all `sudo` commands can only happen via a special terminal that has to be opened from `dom0` (for both template or app VM) via:
```
qvm-run -u root A-barcode xterm
```

To give the app-VM user access to e.g. the webcam run the following in the sudo terminal of the template VM of the app VM:
```
sudo usermod -a -G video user
```

