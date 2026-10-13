# Recipes & helpers

Optional, mostly one-off tweaks that are not part of the automated SEQS install.
Apply the ones you want by hand.

## Contents

- [Sync clock in the base template](#sync-clock-in-the-base-template)
- [CPU pinning for `A-gnosisvpn`](#cpu-pinning-for-a-gnosisvpn)
- [Firewall between app VMs](#firewall-between-app-vms)
- [Get rid of lags in LibreOffice](#get-rid-of-lags-in-libreoffice)
- [Reliably copy large files from/to an Android phone](#reliably-copy-large-files-fromto-an-android-phone)
- [Mount a USB drive](#mount-a-usb-drive)
- [Minimal templates](#minimal-templates)

## Sync clock in the base template

Some apps, such as 2FA authenticator apps, fail when the clock drifts. To keep
it synchronised, install the following package in your base template (e.g.
`debian-13-xfce`) before SEQS clones it, or in each `Z-` template:
```
sudo apt install systemd-timesyncd
```

## CPU pinning for `A-gnosisvpn`

The mixnet is CPU-intensive. On a CPU with both performance and efficiency
cores, pin the qube to performance cores with the `cpu_pinning` catalogue key
(see [configuration](configuration.md)). Pinning gives the qube one vCPU per
listed core and replaces the entry's `'vcpus': 4`, so remove that key. For
example on the i7-1265U, whose Xen CPUs 0 and 2 lie on its two performance
cores:

```python
{'name': 'gnosisvpn', ..., 'cpu_pinning': {'cpus': [0, 2], 'weight': 512}},
```

That leaves the qube 2 vCPUs, which on a four-core test machine without
pinning was about 12% slower than 4; measure both before keeping the pinning.

Commit the edit and rebuild as in [upgrading](upgrading.md); the build leaves
the qube shut down. Start it, then check in a dom0 terminal:

```bash
xl vcpu-list A-gnosisvpn
```

The affinity column should show `0 / all` and `2 / all`.

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
unreliable. Selecting `usb-data-transfer` builds a dedicated `A-usb-data-transfer` qube (red label)
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

## Mount a USB drive

Mount an attached FAT, exFAT or NTFS USB drive so that its files belong to the
qube's user and are not executable (ext4 rejects these options):
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
