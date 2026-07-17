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

## Adding this to an existing SEQS installation

The installer is convergent: after updating the repository, rerun it to create
the missing QR qubes while preserving existing qubes marked `seqs-managed`.
Configure and verify the controller as described in the next section **before**
applying the update. Leaving `webcam_usb_controller` empty still installs the
two QR DisposableVM templates, but deliberately does not create or attach the
webcam USB backend.

If the updated repository is in an existing trusted repo qube, rerun the normal
README installation command. If it is downloaded into a temporary networked
DisposableVM, keep that disposable running during the fetch and note its name
(for example `disp1234`). In dom0, copy the updated runner while suppressing
untrusted stderr:

```bash
DOWNLOAD_QUBE=disp1234
qvm-run -p "$DOWNLOAD_QUBE" \
  'cat /home/user/SEQS/setup-qubes.sh' \
  2>/dev/null > ~/seqs-update.sh
chmod 700 ~/seqs-update.sh
```

Fetch and install the new Salt tree without applying it yet:

```bash
SEQS_REPO_VM="$DOWNLOAD_QUBE" \
SEQS_REPO_PATH=/home/user/SEQS \
~/seqs-update.sh --fetch-only
```

Review the displayed diff and the resulting `/srv/salt/seqs` and
`/srv/pillar/seqs` trees. The download qube is a source of dom0 configuration
and therefore part of the build's trust path; verify the repository revision
independently before accepting it. After the fetch completes, the disposable
may be shut down. Apply only the reviewed local tree:

```bash
~/seqs-update.sh --skip-fetch
```

The expected new persistent objects are `Z-qr-display`, `A-qr-display`,
`Z-qr-camera`, and `A-qr-camera`; the two `A-*` qubes are templates from which
fresh transfer disposables are launched. `sys-usb-webcam` is additionally
created only when a verified controller BDF is configured.

## One-time hardware identification

Do not put a value in `webcam_usb_controller` until completing this section.
There are three different identifiers involved, and they are easy to confuse:

| Example | Meaning | Where it appears |
|---|---|---|
| `dom0:00_14.0` | Physical PCI USB-controller BDF; this is the value SEQS ultimately needs, without the `dom0:` prefix | `qvm-pci` in dom0 |
| `sys-usb:4-3` | USB backend (`sys-usb`) plus USB device path (`4-3`); the leading `4` is the root USB bus | `qvm-usb` in dom0 |
| `0000:00:09.0` | Virtual PCI address assigned to the passed-through controller inside `sys-usb` | `readlink`/`lspci` inside `sys-usb` |

These numbering systems do **not** have to match. In particular, a virtual
`00:09.0` inside `sys-usb` will normally not appear in dom0's `qvm-pci` list and
must not be entered as `webcam_usb_controller`.

### 1. List physical controllers and current USB devices

In dom0:

```bash
qvm-pci
qvm-usb
```

`qvm-pci` lists controllers but does not say which socket feeds which
controller. `qvm-usb` lists devices but normally does not print their physical
PCI BDF. The two commands answer different questions.

Example `qvm-usb` output:

```text
sys-usb:4-1.1  Mouse
sys-usb:4-1.4  Keyboard
sys-usb:4-3    Camera
```

All three paths start with root bus `4-`. Therefore they share one USB
controller, even though the suffixes differ. A path such as `4-1.4` means the
device is behind a hub; it is still on root bus 4. Seeing the same backend name
(`sys-usb`) alone is not proof of sharing because one USB qube may own several
controllers—the shared root-bus number is the useful observation here.

### 2. Test every physical camera port

Leave the keyboard and mouse connected. Move only a harmless test device (the
webcam is suitable) to each physical socket and run `qvm-usb` after every move.
Record its complete device path.

- `4-3`, then `4-2`, then `4-7`: all sockets tested still lead to root bus 4
  and the same controller.
- `4-3`, then `2-1`: the second socket reaches a different root bus and may be
  a candidate for isolation.

Test every socket intended for camera use. Never choose a controller serving
the keyboard, mouse, Qubes boot disk, AEM/boot device, or another device needed
to operate the machine.

### 3. Resolve a candidate bus to its controller

For a camera shown as `sys-usb:2-1`, inspect it inside its backend:

```bash
qvm-run -p sys-usb 'readlink -f /sys/bus/usb/devices/2-1'
```

An output path may include something like:

```text
/sys/devices/pci0000:00/0000:00:09.0/usb2/2-1
```

Here `00:09.0` is the controller's **virtual** address inside `sys-usb`, not
the physical dom0 BDF. Obtain its device identity inside `sys-usb`:

```bash
qvm-run -p sys-usb 'lspci -nn -s 00:09.0'
```

Compare the controller description and `[vendor:device]` ID with candidate
physical USB controllers in dom0, for example:

```bash
lspci -nn -s 00:14.0
```

Use the matching physical address in Qubes underscore notation: physical
`00:14.0` becomes `00_14.0`. If multiple physical controllers have identical
IDs and cannot be distinguished confidently, do not guess—test by assigning
hardware only with a recovery plan, or use a different/add-in controller.

### 4. Decide whether this machine qualifies

The preferred arrangement qualifies only when the webcam port reaches a
physical controller that does not carry any keyboard, mouse, boot/AEM device,
or other required device.

If every available port leaves the camera on the same root bus as a USB
keyboard, the existing hardware does not provide the preferred isolation.
Stop and leave `webcam_usb_controller` empty. This is a normal and important
result of the test, not a software problem.

A plain USB hub, USB extension cable, USB-to-PS/2 adapter, or Bluetooth dongle
does not add a controller; it remains downstream of the existing one. On a
desktop, the usual solution is a separately assignable PCIe USB controller
card dedicated to the webcam. On suitable hardware a Thunderbolt dock may
expose a distinct controller, but this must be confirmed in `qvm-pci` and with
the bus test above. Otherwise use a different machine.

The procedure also permits an internal, genuinely non-USB keyboard: disconnect
all external USB input devices, confirm the internal keyboard still works with
`sys-usb` shut down, and shut down/destroy the webcam-exposed USB backend before
typing any paper value. This fallback does not help a desktop whose only input
devices use the shared USB controller.

### 5. Configure only a verified controller

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

Also run `qvm-usb`: the webcam must be under `sys-usb-webcam`, while every USB
keyboard and mouse must remain under another backend. If an input device moved
with the camera controller, stop—the selected controller was not dedicated.

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
