# Seb's QubesOS Scripts

## Installing QubesOS
1. Start with an empty 8GB USB stick
2. Download the latest [Qubes OS ISO image](https://www.qubes-os.org/downloads/) - warning, [currently, Qubes cannot handle Ventoy-based installer images](https://github.com/QubesOS/qubes-issues/issues/8846), so use a dedicated USB drive for the Qubes installer!
4. I create partitions and mount points as follows:
    1. 500 MGB `/boot/efi` (if you do multiboot with other OSs, this partition can be shared)
    2. 1 GB `/boot` (warning: it seems that you cannot share a Qubes and e.g. Ubuntu `/boot` mount point, Qubes will just boot you into a black screen)
    4. whatever is left `/` (encrypted, LUKS2)
4. For convenience, I like window tiling to arrange windows neatly: Qubes menu -> System Tools -> Window Manager -> Keyboard -> scroll down to the Tile settings which I set as follows:

![Screenshot of Qubes Window Manager Keyboard settings](https://github.com/SCBuergel/SEQS/blob/main/WindowManagerTile.png?raw=true)

6. After connecting to wifi, the system update icon should appear in the tray on the top right, run all updates and reboot

## Install software
I set up a template VM for every software that I want to use and then create an app VM that I actually run for using the software. To keep the Qubes menu and Qubes manager clean, all my template VMs are prefixed `ZZ-[AppName]` and my app VMs are prefixed `AA-[AppName]`. This repository contains a range of scripts that set up template VMs and app VMs for several software packages. In order to create them, you are copying files from an app VM to your dom0.

**WARNING: Please note that this is a potential security threat as it exposes your dom0 environment to running a bunch of scripts which I do not guarantee to be safe, so please check all files by yourself and only proceed if you understand everything and consider all actions to be safe!**

In order to set up everything in an automated fashion:
1. Download this repo into the home directory of your `personal` app VM
2. Open dom0 terminal and type the following one-liner (this is a [common hack to copy files from an app VM into dom0](https://www.qubes-os.org/doc/how-to-copy-from-dom0/#copying-to-dom0)):
```
qvm-run -p personal 'cat /home/user/SEQS/setup-qubes.sh' > s.sh && chmod +x s.sh && ./s.sh
```
3. Some software packages require you to reboot the app VM once to actually work.

The script will download the individual install scripts into dom0 and from there to newly created template VMs. The template VMs are then used to set up app VMs for proper isolation.

Control the actual software packages that are installed at the bottom of the `setup-qubes.sh` file.

### I want to automate installation of [XYZ]
In order to add additional software packages, create corresponding install scripts in the respective folder. If needed (e.g. in case of AppImage downloads) add menu files so that the program can be launched from the Qubes menu.

## Helpers
### delete-vms.sh
The following script cleans up VMs while debugging and setting up installers:
```
./delete-vms.sh keepass telegram wallets
```

### Wireguard BW monitor in tray
![Screenshot of Qubes tray showing download and upload stats](https://github.com/SCBuergel/SEQS/blob/main/tray.png?raw=true)

To show the bandwidth that got consumed by a wireguard interface (e.g. of a VPN qube) in the system tray, do the following:
1. create a script on the VPN app qube that has the wireguard interface (by default assumes interface name `wg0_gnosisvpn`):
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
#!/usr/bin/env bash
set -euo pipefail

QUBE="sys-gnosis-vpn"
qvm-run --pass-io --no-gui "$QUBE" 'bash -lc ~/bw.sh'
```
3. Add a generic monitor to the tray which runs the `vpn_monitor.sh` script created above. Make sure to set the interval to 2s and not 1s otherwise the window manager might freeze!

### Sync clock in Debian-12 template

Several apps will have issues with exactly synced time (e.g. 2FA authenticator apps). To mitigate that, install the following package in the base template (in my case `Debian-12`):
```
sudo apt install systemd-timesyncd
```

### Firewall setup between app VMs (TODO: script this)
For some use cases, it is useful to allow for selective connections between individual app VMs. This setup limits port 45750 for TCP traffic between two qubes. One example is the [RPCh server](https://access.rpch.net/) running within the `A-docker` app VM that should be accessible from an `A-wallets` app VM. In order to enable that, find the two respective IPs and set the iptables in the net VM. Since the default sys-firewall qube does not persist its `/rw` folder, the following is required to persist the settings between system reboots (as suggested [on the Qubes Forum](https://forum.qubes-os.org/t/help-sys-firewall-has-no-persistence-rc-local-gets-wiped-on-reboot/19184/4)):
1. In dom0 find the IP addresses of both app VMs:
```
qvm-ls -n | grep -E 'A-wallets|A-docker'
```
2. Clone `debian-12-dvm`, rename it as `app-sys-firewall`
3. Clone `sys-firewall`, rename it as `sys-firewall-lab`
4. Change the template of `sys-firewall-lab` from `debian-12-dvm` to `app-sys-firewall`
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
sudo qubes-dom0-update qubes-template-debian-12-minimal
```

These templates are [passwordless](https://www.qubes-os.org/doc/templates/minimal/#passwordless-root) which means all `sudo` commands can only happen via a special terminal that has to be opened from `dom0` (for both template or app VM) via:
```
qvm-run -u root A-barcode xterm
```

To give the app-VM user access to e.g. the webcam run the following in the sudo terminal of the template VM of the app VM:
```
sudo usermod -a -G video user
```

### open browser links in separate app qube
For security purposes, it makes sense to open all links in a separate browser as to not endanger another app qube by potentially malicious content in a link. You first have to allow opening links in `dom0` and then set up the link action in a `.desktop` file in the app qube from which you would like to open links in a separate target qube (e.g. `A-brave`).
1. In `dom0` create a file `/etc/qubes/policy.d/29-browser.policy` that allows opening of links, e.g. in my case in `A-brave` with a single line:
```
qubes.OpenURL	*	@anyvm	A-brave	allow
```
2. In your app qube from which you would like to open links (e.g. `A-telegram`), create a file `$HOME/.local/share/applications/mybrowser.desktop` (replace `A-brave` by whatever the name of your target browser qube is called):
```
[Desktop Entry]
Encoding=UTF-8
Name=MyBrowser
Exec=qvm-open-in-vm A-brave %u
Terminal=false
X-MultipleArgs=false
Type=Application
Categories=Network;WebBrowser;
MimeType=x-scheme-handler/unknown;x-scheme-handler/about;text/html;text/xml;application/xhtml+xml;application/xml;application/vnd.mozilla.xul+xml;application/rss+xml;application/rdf+xml;image/gif;image/jpeg;image/png;x-scheme-handler/http;x-scheme-handler/https;
```
3. Activate this in your app qube (replace `mybrowser.desktop` with whatever your `.desktop` file above is called):
```
xdg-settings set default-web-browser mybrowser.desktop
```
**(TODO: script this for all app qubes except for the target)**
