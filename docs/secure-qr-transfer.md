# Secure air-gapped data transfer with QR codes

This process aims to move a secret file between two offline Qubes machines
without connecting them by a network or removable drive: the source encrypts
the file with a one-time paper-recorded passphrase, shows only the ciphertext
as a QR code, and the target scans and authenticates that ciphertext before the
passphrase is entered to decrypt it. Under this document's trust assumptions
(in particular, trusted source and target key qubes and dom0 installations,
working isolation, and correct execution of the ceremony), this gives a
conditional **2-of-2 confidentiality property**: compromise of the webcam/QR
channel alone reveals only ciphertext, while compromise of the keyboard/input
channel alone reveals only the passphrase; recovering the plaintext from those
two channels requires both. This is a protocol-level property under the stated
assumptions, not a cryptographic threshold scheme: an escape that compromises
dom0 or a key qube defeats it.

The preferred **dedicated-controller path** permanently assigns the webcam to
its own USB controller and isolated disposable qubes, so camera-exposed
hardware is never reused for trusted keyboard input. The reduced-assurance
**sequential path** is for machines where the webcam and keyboard must share a
controller: an automated ceremony uses them at different times, copies only
scanned ciphertext into offline staging, physically removes the webcam, and
completely powers the machine off before keyboard use resumes. Assuming the
operator follows that ceremony and dom0 and the isolation mechanisms work as
expected, its additional trust assumption relative to the dedicated path is
that the complete cold-power boundary clears all camera-influenced transient
state in the reused controller and other still-powered hardware, including
controller RAM and device state. An ordinary restart is not that boundary, and
state that persists across complete power removal (for example compromised
firmware) remains outside this guarantee.

SEQS provisions two offline DisposableVM templates for one-way QR transfers:

- `A-qr-display` supplies `qrencode` and is used only to display ciphertext.
- `A-qr-camera` supplies `zbarcam` and `qubes-usb-proxy` and is used only to
  scan ciphertext.

The webcam backend, `sys-usb-webcam`, is also disposable. SEQS creates it and
assigns its controller only when an active `webcam_usb_mode` and
`webcam_usb_controller` are configured in `salt/pillar/seqs/config.sls`.
Leaving the mode disabled and controller empty is intentional: no software can
safely infer which physical ports share a controller with a keyboard, boot
disk, or other critical device.

## Start here: determine which path the machine qualifies for

Make this determination before installing or configuring a webcam controller.

The **resilient dedicated-controller path** qualifies only if the physical port
used by the webcam reaches a PCI USB controller that carries none of these:

- keyboard or mouse;
- Qubes boot/storage device;
- USB AEM or boot device; or
- any device required to operate the machine.

Test every candidate socket as described under [detailed hardware
identification](#detailed-hardware-identification). If the webcam moves between
device paths such as `4-3`, `4-2`, and `4-7` while the keyboard is also `4-*`,
all tested sockets share root bus 4 and the machine does **not** qualify. A USB
hub, extension, Bluetooth dongle, or USB-to-PS/2 adapter does not create another
controller. A separately assignable PCIe USB card normally does.

Choose exactly one configuration:

```jinja
# No webcam controller automation; QR templates are still installed.
{%- set webcam_usb_mode = 'disabled' %}
{%- set webcam_usb_controller = '' %}
```

```jinja
# Preferred: webcam controller never carries keyboard input.
{%- set webcam_usb_mode = 'dedicated' %}
{%- set webcam_usb_controller = '03_00.0' %}
```

```jinja
# Reduced-assurance fallback: one controller is reused sequentially, with a
# mandatory complete power-off before keyboard use resumes.
{%- set webcam_usb_mode = 'sequential' %}
{%- set webcam_usb_controller = '00_14.0' %}
{%- set webcam_usb_no_strict_reset = False %}
```

Use only a verified physical dom0 PCI bus-device-function (BDF) address.
Sequential mode is for a machine whose keyboard and webcam sockets share that
controller. It is rejected by setup if `webcam_usb_no_strict_reset` is enabled.
It reduces risk through temporal isolation and a cold-power boundary, but it is
not equivalent to permanent hardware separation.

## Adding this to an existing SEQS installation

Follow the general [upgrade procedure](upgrading.md): update and configure the
repository source of truth, copy the current runner into dom0, fetch with
`--fetch-only`, review the fetched tree, stage with `--stage-only`, and build
with `--build-only`.
Configure and verify the controller described above **before** applying.
Leaving the mode disabled and controller empty still installs the QR qubes but
deliberately does not create or attach the webcam USB backend.

The expected new persistent objects are `Z-qr-display`, `A-qr-display`,
`Z-qr-camera`, `A-qr-camera`, `Z-qr-staging`, and `A-qr-staging`; the display
and camera `A-*` qubes are templates from which fresh transfer disposables are
launched. `A-qr-staging` is the offline persistent landing zone used by the
sequential path. `sys-usb-webcam` is additionally created only when a verified
controller BDF and active mode are configured.

## Detailed hardware identification

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

#### 3a. Trace the camera path

**Looking for:** the virtual PCI address immediately before `/usbN` in the
camera's sysfs path. For a camera shown by `qvm-usb` as `sys-usb:4-2`, run:

```bash
qvm-run -p sys-usb 'readlink -f /sys/bus/usb/devices/4-2'
```

Example output:

```text
/sys/devices/pci0000:00/0000:00:09.0/usb4/4-2
```

Relevant excerpt:

```text
0000:00:09.0
```

This is the controller's **virtual** address inside `sys-usb`. It is not
necessarily its physical dom0 BDF, so do not convert it to `00_09.0` for the
SEQS configuration.

#### 3b. Read the controller identity

**Looking for:** the controller's vendor and device IDs. Minimal `sys-usb`
templates may not contain `lspci`, so read the IDs directly from sysfs. Replace
`0000:00:09.0` if the preceding command returned a different address:

```bash
qvm-run -p sys-usb \
  'p=/sys/bus/pci/devices/0000:00:09.0; printf "vendor="; cat "$p/vendor"; printf "device="; cat "$p/device"'
```

Example output:

```text
vendor=0x8086
device=0xa36d
```

Relevant excerpt:

```text
8086:a36d
```

Record that combined `vendor:device` ID without the `0x` prefixes.

#### 3c. List the physical candidates

**Looking for:** the physical dom0 BDF of each USB controller. In dom0, run:

```bash
qvm-pci | grep -i usb
```

Example output:

```text
dom0:00_14.0  USB controller: Intel Corporation USB 3.1 xHCI Host Controller
```

Relevant excerpt:

```text
dom0:00_14.0
```

This address is physical, but first confirm that its identity matches the
camera controller.

#### 3d. Match the physical controller

**Looking for:** the same `[vendor:device]` ID recorded in step 3b. Convert a
candidate such as `00_14.0` to the colon form `00:14.0` for `lspci`:

```bash
lspci -nn -s 00:14.0
```

Example output:

```text
00:14.0 USB controller: Intel Corporation USB 3.1 xHCI Host Controller [8086:a36d]
```

Relevant excerpt:

```text
[8086:a36d]
```

When this matches step 3b, the candidate's dom0 address is the physical BDF to
use. In this example, enter it in Qubes underscore notation as `00_14.0`. If
multiple physical controllers have identical IDs and cannot be distinguished
confidently, do not guess—test by assigning hardware only with a recovery plan,
or use a different/add-in controller.

### 4. Confirm whether this machine qualifies for the resilient path

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
{%- set webcam_usb_mode = 'dedicated' %}
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

## Reduced-assurance sequential-controller path

Use this only when hardware testing proves that the webcam and USB input must
share one physical controller and adding a dedicated controller is not
practical. The same PCI controller is assigned persistently to both the normal
USB qube and `sys-usb-webcam`, but the orchestration permits only one owner to
run at a time.

SEQS additionally creates:

- `seqs-qr-scanner`, a named offline scanner DisposableVM;
- `A-qr-staging`, an offline persistent qube that receives only ciphertext;
- `/usr/local/sbin/seqs-qr-sequential`, the fail-closed dom0 ceremony; and
- qrexec rules denying camera-backend input to dom0 and allowing the scanner
  to copy files only to `A-qr-staging`.

The terminal action after any controller exposure—success or failure—is a
physical power-off. The script never starts normal `sys-usb` again in that
boot. This is deliberate: immediate reassignment would rely only on controller
reset and would restore trusted input while the camera-exposed hardware might
retain state.

### Sequential ceremony

Before running it:

1. Finish the source-machine encryption and display setup below.
2. Put the paper passphrase and both hashes completely away.
3. Ensure the webcam is physically unplugged.
4. Ensure `A-qr-staging` has no prior
   `~/QubesIncoming/seqs-qr-scanner/key.asc`.
5. Close unrelated work; the machine will power off without returning to the
   normal keyboard backend.

In dom0, with normal keyboard input still working:

```bash
sudo /usr/local/sbin/seqs-qr-sequential
```

Review the displayed controller/qube names and type `START`. Then follow the
screen literally:

1. Immediately unplug the keyboard and mouse. The script waits ten seconds and
   stops normal `sys-usb`.
2. Only after the screen says `NORMAL USB BACKEND STOPPED`, connect the webcam.
3. The script starts fresh webcam/scanner disposables, requires exactly one USB
   device in the webcam backend, scans one QR code, limits `key.asc` to 16 KiB,
   and copies it to `A-qr-staging`.
4. When told, physically unplug the webcam. Do not reconnect input yet.
5. The computer powers off even if scan, attachment, or copy failed.
6. After power is completely off, leave the webcam unplugged and reconnect the
   keyboard/mouse. For the strongest practical reset, remove AC/standby power
   before booting again.
7. Boot normally with the webcam absent and the normal USB backend restored (a
   named disposable normal backend is preferable, though the normal backend
   was never exposed to the camera in this ceremony). Confirm the incoming
   file exists in `A-qr-staging`; absence means the ceremony failed and must be
   repeated from the beginning.
8. Copy only that `key.asc` to the trusted target key qube, then perform the
   paper-recorded ciphertext-hash check before invoking GPG.

Do not use the ordinary manual camera instructions in the next section for
sequential mode; the dom0 script replaces the entire target scanning phase.

### Sequential-path limitations

This fallback prevents the camera-exposed disposable backend from later seeing
keyboard entry in the same boot, but it does not provide permanent hardware
separation. It remains vulnerable to:

- malicious state persisting in USB-controller firmware or powered hardware;
- an incomplete reset or hardware that remains powered after shutdown;
- a webcam exploit escaping through Xen, IOMMU, PCI, or qrexec vulnerabilities;
- compromise of the dom0 orchestration or its restrictive policy;
- a webcam mistakenly left connected at the next boot; and
- independently malicious keyboard/controller firmware.

Strict PCI reset, working IOMMU isolation, physical webcam removal, cold power
off, a fresh normal USB backend after boot, and hash verification before GPG
are all mandatory. If strict attachment fails, do not enable
`no-strict-reset`; sequential mode is unavailable on that controller. The
dedicated-controller path avoids reusing camera-exposed hardware for trusted
input and is therefore more resilient.

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

### Target machine: scan (dedicated-controller mode only)

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
