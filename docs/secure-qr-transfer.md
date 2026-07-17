# Secure air-gapped data transfer with QR codes

SEQS provisions two offline DisposableVM templates for one-way QR transfers:

- `A-qr-display` supplies `qrencode` and is used only to display ciphertext.
- `A-qr-camera` supplies `zbarcam` and `qubes-usb-proxy` and is used only to
  scan ciphertext.

The webcam backend, `sys-usb-webcam`, is also disposable. SEQS creates it and
assigns its controller only when `webcam_usb_controller` is configured in
`salt/pillar/seqs/config.sls`. Leaving that value empty is intentional: no
software can safely infer which physical ports share a controller with a
keyboard, boot disk, or other critical device.

## One-time hardware identification

In dom0, list controllers with `qvm-pci`. Map physical ports by plugging a
harmless test device into each port and observing `qvm-usb`. Choose a controller
used only for the webcam. Never choose one serving the keyboard, mouse, Qubes
boot disk, AEM/boot device, or another device needed to operate the machine.
If the webcam and USB keyboard share a controller, use an add-in USB controller,
a different computer, or an internal non-USB keyboard; software cannot provide
the required isolation.

Set the identified BDF (using Qubes' underscore notation) and rerun setup:

```jinja
{%- set webcam_usb_controller = '03_00.0' %}
```

SEQS then creates `sys-usb-webcam` as a named DispVM, sets HVM mode, disables
networking, memory balancing and autostart, removes its app menu, detaches the
controller from its prior backend, and persistently attaches it to the new
backend. This can make input devices unavailable if the BDF is wrong; verify
the port/controller map first. `webcam_usb_no_strict_reset` stays `False`.
Change it only when attachment fails for lack of a reset mechanism and after
accepting the weaker reset isolation.

After setup, start `sys-usb-webcam`, connect the webcam, and check `qvm-usb`.
The camera must appear below `sys-usb-webcam`; keyboard and mouse must remain on
another backend. Check the air gap with:

```bash
qvm-prefs sys-usb-webcam netvm
```

## Transfer ceremony

The following procedure copies a `master.key` while treating the webcam, its
firmware, both visual disposables, the USB backend, and QR bytes as untrusted.
The source and target key qubes and both dom0 installations are trusted.

Use fresh paper for three labeled values: a one-time `PASSPHRASE`, `PLAINTEXT
SHA256`, and `CIPHERTEXT SHA256`. The paper and any screen containing these
values must never enter the webcam field of view. A USB backend exposed to the
webcam must be shut down before entering any paper value.

### Source machine

In the trusted source key qube:

```bash
set -euo pipefail
umask 077
head -c 16 /dev/urandom | base32 | tr -d '=\n'; echo
sha256sum -- master.key
gpg --no-symkey-cache --symmetric --armor --cipher-algo AES256 \
  --s2k-mode 3 --s2k-count 65011712 --compress-algo none \
  --set-filename '' --output key.asc -- master.key
sha256sum -- key.asc
qvm-copy key.asc
rm -f -- key.asc
```

Write the generated passphrase and both complete hashes on paper. Enter the
passphrase twice at GPG's prompt. Clear the terminal and its scrollback, close
it, and preferably shut down the source key qube before aiming the webcam.
No notification, clipboard tool, terminal, paper, or secret-bearing surface
may be visible.

Start a fresh display disposable from `A-qr-display`, enter its incoming
directory, and display only the ciphertext full-screen:

```bash
qvm-run --dispvm=A-qr-display --service qubes.StartApp+qubes-run-terminal
cd ~/QubesIncoming/<source-key-qube>
qrencode -l M -t ansiutf8 < key.asc
```

If it does not fit in one QR code, stop; this setup does not implement a
multi-frame protocol. Shut down the disposable after scanning.

### Target machine: scan

Put the paper away first. Start `sys-usb-webcam`, then a fresh scanner:

```bash
qvm-run --dispvm=A-qr-camera --service qubes.StartApp+qubes-run-terminal
```

Use the Devices widget to attach only the webcam, or in dom0:

```bash
qvm-usb
qvm-usb attach <camera-disposable> sys-usb-webcam:<device-id>
```

In the scanner disposable:

```bash
set -euo pipefail
umask 077
zbarcam -q --raw --oneshot -Sdisable -Sqrcode.enable > key.asc
qvm-copy key.asc
```

Then physically unplug the webcam, detach it, and shut down the scanner and
`sys-usb-webcam`. Verify both are stopped. If the webcam backend also handled
the keyboard, stop and do not enter the passphrase.

### Target machine: authenticate and decrypt

Only after the webcam is unplugged and its backend stopped, retrieve the paper.
In the trusted target key qube, move the incoming `key.asc` into the intended
directory and run:

```bash
set -euo pipefail
umask 077
test ! -e master.key

IFS= read -r -s -p 'CIPHERTEXT SHA256: ' expected; echo
[[ "$expected" =~ ^[0-9A-Fa-f]{64}$ ]]
actual=$(sha256sum -- key.asc); actual=${actual%% *}
test "${actual,,}" = "${expected,,}" || { rm -f -- key.asc; exit 1; }
unset expected actual

tmpdir=$(mktemp -d .master-key-import.XXXXXX)
trap 'rm -rf -- "$tmpdir"' EXIT HUP INT QUIT TERM
gpg --no-symkey-cache --decrypt --output "$tmpdir/master.key" -- key.asc

IFS= read -r -s -p 'PLAINTEXT SHA256: ' expected; echo
[[ "$expected" =~ ^[0-9A-Fa-f]{64}$ ]]
actual=$(sha256sum -- "$tmpdir/master.key"); actual=${actual%% *}
test "${actual,,}" = "${expected,,}"
unset expected actual

test ! -e master.key
mv -T -- "$tmpdir/master.key" master.key
rmdir -- "$tmpdir"
trap - EXIT HUP INT QUIT TERM
chmod 600 master.key
rm -f -- key.asc
stat --format='%a %n' master.key
sha256sum -- master.key
```

Enter the paper passphrase only at GPG's trusted prompt. Any hash mismatch is a
hard stop. The final mode must be `600`; compare the final displayed hash to the
paper again.

Finally confirm all three disposables/backends are stopped, the webcam is
unplugged, no `key.asc` remains, and destroy the complete paper record.
Ordinary deletion and disposable teardown do not guarantee forensic erasure
from snapshots, CoW storage, backups, swap, or SSD media.

For Qubes background and warnings, see the official documentation for
[USB qubes](https://doc.qubes-os.org/en/latest/user/advanced-topics/usb-qubes.html),
[USB devices](https://doc.qubes-os.org/en/latest/user/how-to-guides/how-to-use-usb-devices.html),
[PCI devices](https://doc.qubes-os.org/en/latest/user/how-to-guides/how-to-use-pci-devices.html),
and [disposable customization](https://doc.qubes-os.org/en/development/user/advanced-topics/disposable-customization.html).

