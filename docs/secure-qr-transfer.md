# Reasonably secure air-gapped data transfer

This guide is for copying a tiny secret file between two offline Qubes OS
machines without connecting them by a network or removable drive. That unusual
constraint rules out the convenient transfer methods and is the reason for the
QR procedure: the source encrypts the file, the target receives only encrypted
QR data through a webcam, and the decryption passphrase travels separately on
paper. This method is suitable only for files small enough to fit in one QR
code; it does not support a sequence of QR frames for larger files.

Before decrypting, the operator visually compares short fingerprints (codes
derived from the encrypted file) calculated independently by the trusted source
and target qubes. [GnuPG](https://www.gnupg.org/) (the encryption program used
by this procedure) then decrypts the file with the one-time paper passphrase.

The elaborate USB separation keeps the untrusted webcam away from the keyboard
used to enter that passphrase. Qubes assigns a complete PCI USB controller to a
USB backend qube; if the webcam and a USB keyboard share that controller, the
same backend can handle both. A malicious webcam that compromises the backend
could then observe keyboard input immediately or after the keyboard is
reconnected. The preferred path uses separate controllers; the fallback path
separates their use in time and powers the machine off before trusted input
returns. See [Understand USB hardware and identifiers](#understand-usb-hardware-and-identifiers)
for the controller, bus, and device-path relationship.

Read the guide in order. Hardware choices made near the beginning determine
which later receive procedure is safe to use.

## Prerequisites

This section lists what must exist before configuring the QR transfer. Install
SEQS by following the main [README](../README.md), and include the `qr-display`
and `qr-camera` recipes in the selected qubes. The hardware assessment later in
this guide determines whether to add `qr-staging` (the offline landing qube
needed when no webcam socket has a controller suitable for dedicated use).

You also need a trusted source key qube containing the small secret file, a
trusted target key qube that does not already contain the destination file, and
a webcam suitable for scanning the displayed QR code. SEQS intentionally does
not create the two trusted key qubes because their identities and contents are
operator-specific.

## Security property and limits

This section explains what the procedure protects and what remains trusted.
The source and target key qubes, both dom0 administrative domains, Qubes OS,
and the operator's execution of the procedure are trusted. The webcam, QR
bytes, display and camera qubes, and their device-handling qubes are treated as
untrusted.

The procedure provides a conditional **2-of-2 confidentiality property**:

- the webcam/QR channel receives encrypted data but never the passphrase;
- the keyboard/input channel receives the passphrase only after the webcam
  channel has been removed; and
- an attacker needs both channels to recover the plaintext.

This is a protocol property, not a cryptographic threshold scheme. A compromise
of dom0, Qubes isolation, or either trusted key qube defeats it. Deleting files
also does not guarantee forensic erasure from snapshots, copy-on-write storage,
swap, backups, or SSD media.

## Qubes used by the procedure

This section identifies the qubes involved in every transfer.

The transfer uses these qubes:

- A trusted **source key qube** holds and encrypts the original secret.
- `A-qr-display` is an offline template for DisposableVMs (fresh qubes whose
  writable state is discarded after a full shutdown). Its named disposable,
  `D-qr-display`, displays only encrypted data.
- `A-qr-camera` is an offline DisposableVM template containing `zbarcam` (the
  QR scanner) and Qubes USB-device support.
- A trusted **target key qube** verifies and decrypts the received file.
- `sys-usb-webcam` is a disposable USB backend (a qube that owns the physical
  webcam controller and exposes individual USB devices to other qubes).

A missing network connection does not block
[qrexec](https://doc.qubes-os.org/en/latest/developer/services/qrexec.html)
(Qubes' controlled communication system between qubes), so SEQS also installs
policies restricting input and file-copy services.

## Understand USB hardware and identifiers

This section explains the USB hierarchy and the two identifiers used later to
find the hardware boundary that Qubes can assign. The general relationship is:

```text
PCI USB controller 00_14.0             <- Qubes assigns this whole unit
|-- root USB bus 4 (USB 2 root hub)
|   |-- port 2 -> device                <- USB device path 4-2
|   `-- port 3 -> hub -> port 1 -> device
|                                        <- USB device path 4-3.1
`-- root USB bus 5 (USB 3 root hub)
    `-- port 1 -> device                <- USB device path 5-1
```

A modern controller commonly provides a USB 2 and a USB 3 side for the same
physical socket. A slower device plugged into that socket might therefore have
path `4-2`, while a faster device in the same socket might have path `5-1`.

The terms in the diagram mean:

- A **Peripheral Component Interconnect (PCI) USB controller** is the hardware
  that drives one or more USB buses and all their ports. PCI is the machine's
  internal bus connecting the controller to the rest of the system. The whole
  controller is the smallest USB unit Qubes can assign to a qube; the controller
  and all its connected devices first belong to that USB backend qube, which
  may then expose individual devices to other qubes.
- A **root USB bus**, such as bus 4, is one tree of ports headed by a root hub
  (the controller-provided starting point of that tree). Qubes cannot assign a
  root USB bus separately from its controller.
- A **USB port** is a socket into which a USB device or hub is plugged. This
  includes sockets on the case and internal USB connectors.
- A **USB device** is anything connected over Universal Serial Bus (USB), such
  as a webcam, keyboard, or mouse.
- A PCI **bus-device-function** (BDF) address, such as `00:14.0`, identifies one
  device on the PCI bus, including a USB controller. The word “bus” here refers
  to PCI and is unrelated to the root USB bus numbers above. Qubes device
  commands write the same address with an underscore: `00_14.0`.
- A **USB device path**, such as `4-2`, is how Linux names one connected
  device's location: root USB bus 4, then port 2. Each downstream hub adds a dot
  and another port number, so `4-2.1.3` continues through ports 1 and 3 on two
  hubs. These numbers describe the internal topology and do not match labels
  printed on the case.

Everything below one controller in the diagram must first be assigned to the
same USB backend qube, even when the devices have different root USB bus
numbers. Hardware isolation is possible only when the devices map to separate
PCI USB controllers, for example:

```text
PCI USB controller 03_00.0        PCI USB controller 00_14.0
`-- webcam                         `-- keyboard
    -> sys-usb-webcam                  -> normal sys-usb
```

The BDF identifies the assignable controller and therefore decides which
hardware Qubes can separate. A USB device path identifies something below that
controller and is not an isolation boundary.

## Choose the hardware-isolation path

This guide offers two hardware-isolation paths. The stronger path assigns the
webcam's PCI USB controller without also assigning any trusted input or other
device needed to operate, boot, or recover the machine. An internal non-USB
keyboard does not occupy a USB controller and therefore does not prevent this
separation. When no webcam socket maps to a controller meeting these conditions,
the fallback path separates webcam and trusted-input use in time and requires a
complete power-off between them.

Use the preferred **dedicated-controller path** only when the webcam socket
reaches a PCI USB controller that carries none of these:

- keyboard or mouse;
- Qubes boot or storage device;
- USB anti-evil-maid (AEM) or boot device; or
- any other device needed to operate or recover the machine.

Use the reduced-assurance **sequential path** when no webcam socket has a
controller meeting those conditions. The sequential ceremony stops normal
`sys-usb`, uses the selected controller for the webcam, physically removes the
webcam, and powers the entire computer off before trusted USB use resumes. Its
additional trust assumption is that complete power removal clears
camera-influenced transient state in the controller and other powered hardware.
A restart is insufficient, and persistent malicious firmware remains outside
the protection. This path additionally uses the disposable `seqs-qr-scanner`
and the persistent, offline `A-qr-staging` qube, which preserves encrypted data
across the required power-off.

## Identify the webcam's physical USB controller

This section maps a physical webcam socket to the BDF that SEQS needs. Three
identifiers appear during the process:

| Example | Meaning |
|---|---|
| `dom0:00_14.0` | Physical PCI controller exposed by dom0; configure `00_14.0` |
| `sys-usb:4-3` | USB device path `4-3` reported by the `sys-usb` backend |
| `0000:00:09.0` | Virtual PCI address visible only inside `sys-usb` |

These numbers do not have to match. Never turn the virtual `00:09.0` address
inside `sys-usb` into the configured dom0 value.

### Record the relevant USB device paths

This subsection records the paths that must be traced to physical controllers.
Leave the keyboard, mouse, boot media, recovery devices, and other required USB
devices connected. Move only the webcam to each candidate socket, and run this
in dom0 after every move:

```bash
qvm-usb
```

The command lists individual devices using identifiers such as
`sys-usb:4-3`. Record the complete path for the webcam at every socket and for
every connected USB device that must remain available. The leading number is a
root USB bus: results `4-3`, `4-2`, and `4-7` are all on bus 4, while `2-1` is
on bus 2. A different bus number is useful for tracing but does not establish a
different controller. The suffix identifies a port or hub path; a hub,
extension, Bluetooth dongle, or USB-to-PS/2 adapter does not add another
controller.

### Trace each root USB bus inside `sys-usb`

This subsection finds the virtual PCI controller serving each recorded root USB
bus. Open a terminal directly in `sys-usb`. Run the command once for each
distinct leading bus number, using any recorded path on that bus. For example,
for a device reported as `4-2`, run:

```bash
readlink -f /sys/bus/usb/devices/4-2
```

Look for the PCI address immediately before `/usbN`. Example output is:

```text
/sys/devices/pci0000:00/0000:00:09.0/usb4/4-2
```

Here the virtual address is `0000:00:09.0`. Record which root buses resolve to
each virtual controller. Multiple root buses may resolve to the same controller.
The virtual address identifies the controller inside `sys-usb`, not the
physical BDF to configure.

### Read the controller identity inside `sys-usb`

This subsection reads each virtual controller's vendor and device IDs so it can
be matched to physical hardware. Continue in the `sys-usb` terminal, replacing
the address for each distinct virtual controller found above:

```bash
p=/sys/bus/pci/devices/0000:00:09.0
printf 'vendor='; cat "$p/vendor"
printf 'device='; cat "$p/device"
```

Example output is:

```text
vendor=0x8086
device=0xa36d
```

For each virtual controller, record a pair such as `8086:a36d`, without the
`0x` prefixes. These are public hardware identifiers, not secret values.

### Match the physical controller in dom0

This subsection matches each recorded hardware identity to a physical BDF.
In dom0, run:

```bash
qvm-pci list --with-sbdf | grep -i usb
```

Look for physical USB-controller candidates such as `dom0:00_14.0`. Then run
`lspci` in dom0 for each candidate, converting the underscore to a colon:

```bash
lspci -nn -s 00:14.0
```

Look for the recorded vendor/device pair in brackets, for example:

```text
00:14.0 USB controller: Intel Corporation ... [8086:a36d]
```

Record the physical BDF matching each virtual controller. If several physical
controllers have identical identities and cannot be distinguished confidently,
do not guess. The webcam qualifies for the dedicated-controller path only if
its physical controller carries none of the prohibited devices listed above;
otherwise, choose the sequential path. When configuring SEQS later, use the
chosen controller's Qubes device identifier without the `dom0:` prefix, such as
`00_14.0`.

### Confirm current ownership

This subsection confirms which PCI controller is actually attached to normal
`sys-usb`. In dom0, run:

```bash
qvm-pci list sys-usb
```

Look for the selected `dom0:<BDF>` in the first column. Do not use
`qvm-prefs sys-usb pcidevs`; PCI devices are managed by `qvm-pci` (an alias for
`qvm-device pci`), and `pcidevs` is not a `qvm-prefs` property.

If the webcam controller also carries trusted USB input or another prohibited
device listed above, the machine does not qualify for the dedicated-controller
path. Use the sequential path or add a separately assignable PCIe USB
controller. A genuinely non-USB internal keyboard is independent of the USB
controller, but verify that it remains usable with `sys-usb` stopped before
relying on it.

## Install or update the QR qubes

This section applies the chosen mode from the reviewed repository. Edit
`salt/pillar/seqs/config.sls` in the repository qube, never in dom0.

For the dedicated-controller path:

```jinja
{%- set webcam_usb_mode = 'dedicated' %}
{%- set webcam_usb_controller = '03_00.0' %}
{%- set webcam_usb_no_strict_reset = False %}
```

For the sequential path:

```jinja
{%- set webcam_usb_mode = 'sequential' %}
{%- set webcam_usb_controller = '00_14.0' %}
{%- set webcam_usb_no_strict_reset = False %}
```

Replace the example BDF. Sequential mode rejects
`webcam_usb_no_strict_reset = True` because switching a controller without a
reliable reset can preserve hostile state.

Follow [the upgrade procedure](upgrading.md) to verify the revision, copy the
commit-bound runner, fetch, review, stage, and build. Build
`qr-camera,qr-display,qr-staging` for sequential mode; omit `qr-staging` for
dedicated mode.

After a sequential build, dom0 contains the fail-closed ceremony at
`/usr/local/sbin/seqs-qr-sequential`. It also creates `sys-usb-webcam`,
`seqs-qr-scanner`, and `A-qr-staging`. A strict PCI-attachment failure means
the controller is unsuitable; do not enable `no-strict-reset` to bypass it.

## Verify the installed isolation

This section checks the generated qubes and policies before any secret is used.

### Verify offline networking

This subsection confirms that the QR qubes have no NetVM, the Qubes setting
that supplies network access. In dom0, run these short commands:

```bash
qvm-prefs A-qr-display netvm
qvm-prefs D-qr-display netvm
qvm-prefs A-qr-camera netvm
qvm-prefs sys-usb-webcam netvm
```

Sequential mode also requires:

```bash
qvm-prefs seqs-qr-scanner netvm
qvm-prefs A-qr-staging netvm
```

Every result must be empty, `None`, or `none`.

### Verify PCI assignment

This subsection confirms the physical controller assignments with the supported
Qubes device command. In dom0, run:

```bash
qvm-pci list --assignments
```

In dedicated mode, the selected `dom0:<BDF>` must be assigned only to
`sys-usb-webcam`. In sequential mode, it is intentionally assigned to both
normal `sys-usb` and `sys-usb-webcam`; the ceremony ensures only one owner runs
at a time.

### Verify qrexec policy

This subsection checks the small dom0 policy files that restrict the untrusted
camera side. In dom0, run:

```bash
sudo cat /etc/qubes/policy.d/00-seqs-qr-input-deny.policy
```

Look for denies on `qubes.InputKeyboard`, `qubes.InputMouse`,
`qubes.InputTablet`, and `qubes.Filecopy` from `sys-usb-webcam`.

In sequential mode, run:

```bash
sudo cat /etc/qubes/policy.d/01-seqs-qr-filecopy.policy
```

Look for one allow from `seqs-qr-scanner` to `A-qr-staging`, followed by a deny
to every other destination.

## Dedicated-controller operation

This section verifies and uses a controller that carries none of the prohibited
devices from the path-selection section.
Start `sys-usb-webcam` from the Qubes menu, connect the webcam, and run this
short command in dom0:

```bash
qvm-usb
```

The webcam must appear under `sys-usb-webcam`, while every keyboard, mouse, and
other required USB device must remain under another backend. If any prohibited
device moves with the webcam, stop: the controller is not dedicated.

During a transfer, start a fresh camera disposable from `A-qr-camera`, attach
only the webcam with the Qubes Devices widget, and follow the dedicated scan
subsection below.

## Sequential-controller operation

This section uses one controller first for its normal USB duties and later for
the untrusted webcam. It is reduced assurance and always ends in complete
power-off after the controller is exposed.

### Prepare the sequential ceremony

This subsection establishes the safe starting state. Finish source encryption
and show its encrypted QR code as described later. Then:

1. Put away the paper passphrase and every secret-bearing screen.
2. Physically unplug the webcam.
3. In `A-qr-staging`, remove any old
   `~/QubesIncoming/seqs-qr-scanner/key.asc` and verify it is absent.
4. Save and close unrelated work.
5. Be ready to unplug keyboard and mouse immediately and to let the computer
   power off without restoring input.

### Run the sequential ceremony

This subsection hands the shared controller to the webcam and scans exactly
one QR code. In dom0, run:

```bash
sudo /usr/local/sbin/seqs-qr-sequential
```

The script prints the configured controller and qube names. Type exact uppercase
`START` only after checking them. Then follow the screen in this order:

1. Immediately unplug keyboard and mouse. The script waits ten seconds and
   stops normal `sys-usb`.
2. Connect only the webcam after the screen says
   `NORMAL USB BACKEND STOPPED`.
3. The script starts fresh webcam and scanner disposables, requires exactly one
   USB device, scans one QR code, limits `key.asc` to 16 KiB, and copies it only
   to `A-qr-staging`.
4. Physically unplug the webcam when instructed. Do not reconnect input.
5. The computer powers off after success or failure.

### Cross the cold-power boundary

This subsection clears transient state before trusted input returns. After the
machine is completely off, leave the webcam unplugged, reconnect keyboard and
mouse, and remove AC or standby power where practical before booting again.

After boot, confirm the incoming `key.asc` exists in `A-qr-staging`. Its absence
means the scan failed. Copy only that encrypted file to the trusted target key
qube, then complete the visual fingerprint comparison before starting GnuPG.

Never use the manual dedicated-camera procedure in sequential mode. The dom0
ceremony replaces the entire scan phase and must retain control through power-off.

### Understand sequential-mode residual risk

This subsection states what temporal separation cannot prevent. Sequential mode
remains vulnerable to malicious state that persists in controller firmware or
still-powered hardware, an incomplete power reset, a webcam escape through the
hypervisor or qrexec, compromised dom0 orchestration, a webcam left connected
at the next boot, and malicious keyboard/controller firmware. A dedicated
controller avoids reusing camera-exposed hardware and is more resilient.

## Transfer ceremony

This section encrypts, displays, receives, authenticates, and decrypts one
`master.key`. Use fresh paper for exactly one value:

```text
PASSPHRASE: <26 letters and digits>
```

The passphrase is the one-time encryption key and must remain outside the
webcam's field of view. Later, each trusted key qube calculates a short
fingerprint from its own copy of `key.asc`. The fingerprint is not secret and
is never carried through the QR channel; comparing the two trusted displays
confirms that the target received the source ciphertext before GnuPG parses it.

### Encrypt in the source key qube

This subsection generates a one-time passphrase and encrypts `master.key`. Open
a terminal in the trusted source key qube and run:

```bash
set -euo pipefail
umask 077
test -f master.key
test ! -e key.asc
PASSPHRASE=$(head -c 16 /dev/urandom | base32 | tr -d '=\n')
printf 'PASSPHRASE: %s\n' "$PASSPHRASE"
printf '%s\n' "$PASSPHRASE" | \
gpg --no-symkey-cache --symmetric --armor --cipher-algo AES256 \
  --s2k-mode 3 --s2k-count 65011712 --compress-algo none \
  --batch --pinentry-mode loopback --passphrase-fd 0 \
  --set-filename '' --output key.asc -- master.key
unset PASSPHRASE
```

Write the passphrase on paper. It was sent to GnuPG through standard input, not
a command-line argument, and the shell variable is now unset. Close this
terminal completely so its passphrase-bearing scrollback cannot later enter the
webcam's field of view. Merely running `clear` is not sufficient. If `key.asc`
is too large for one QR code later, stop; this procedure does not implement
multiple frames.

### Start the display and copy ciphertext into it

This subsection starts a fresh display before Qubes file copy so boot cleanup
cannot remove the incoming file. Start `D-qr-display` from the Qubes menu. Then
open a new terminal in the source key qube, return to the directory containing
`key.asc`, and run:

```bash
qvm-copy key.asc
```

Choose the already-running `D-qr-display` as the destination. Keep the source
copy of `key.asc` until fingerprint comparison is complete; the trusted source
must calculate its code from the exact ciphertext sent through the display.
The source key qube may be shut down because its private storage is persistent.

### Display only the encrypted QR code

This subsection makes the ciphertext visible to the camera. Put the paper and
all secret-bearing screens away. In the `D-qr-display` terminal, run:

```bash
cd ~/QubesIncoming/<source-key-qube>
qrencode -l M -t ansiutf8 < key.asc
```

The terminal should show one complete QR code. If encoding fails because the
data does not fit, stop. Keep this disposable running only until scanning ends.

### Scan in dedicated-controller mode

This subsection receives the QR code when the webcam has a dedicated controller.
It does not apply to sequential mode. Start `sys-usb-webcam`, launch a fresh
disposable from `A-qr-camera`, and attach only the webcam with the Qubes Devices
widget.

In the fresh camera disposable terminal, run:

```bash
set -euo pipefail
umask 077
zbarcam -q --raw --oneshot -Sdisable -Sqrcode.enable > key.asc
qvm-copy key.asc
```

Choose the already-running trusted target key qube. After the copy succeeds,
physically unplug the webcam and shut down the camera disposable and
`sys-usb-webcam`. Confirm both are stopped before retrieving the paper. If the
backend ever handled the keyboard, stop and do not enter the passphrase.

### Receive from sequential staging

This subsection receives the ciphertext after the sequential power-off. In an
`A-qr-staging` terminal, run:

```bash
cd ~/QubesIncoming/seqs-qr-scanner
qvm-copy key.asc
```

Choose the already-running trusted target key qube. Do not decrypt anything in
staging; the target authenticates the received bytes in the next subsection.

### Compare the source and target fingerprints

This subsection authenticates the received ciphertext before GnuPG parses it.
Confirm the webcam is unplugged and every camera-facing qube and backend is
stopped. In sequential mode, complete the cold-power boundary first. Move the
received `key.asc` into the intended directory in the trusted target key qube.

Open a new terminal in the trusted source key qube. Do not reopen or reuse the
terminal that displayed the passphrase. Return to the directory containing the
retained `key.asc`, then run:

```bash
test -f key.asc
printf 'SOURCE: '
sha256sum -- key.asc | cut -c1-20 | sed 's/...../&-/g; s/-$//' | tr '[:lower:]' '[:upper:]'
```

The output is four groups of five uppercase hexadecimal characters, for
example:

```text
SOURCE: 7A91C-24D8E-6F032-B5A10
```

The 20 hexadecimal characters are the first 80 bits of the file's SHA-256
cryptographic hash. For a fixed source fingerprint, producing a different file
with the same code would require about 2^80 attempts. Grouping changes only the
display, not the calculation.

In a terminal in the trusted target key qube, run:

```bash
test -f key.asc
printf 'TARGET: '
sha256sum -- key.asc | cut -c1-20 | sed 's/...../&-/g; s/-$//' | tr '[:lower:]' '[:upper:]'
```

Place the trusted source and target displays where they can be compared. Use a
large monospace font and compare all four groups from left to right. Do not
copy, paste, retype, photograph, or include the expected code in a QR payload.

If any character differs, do not invoke GnuPG. Delete the received target copy,
clear sequential staging if applicable, and repeat the receive procedure from
a clean state. The source `key.asc` may be reused because it remains the trusted
ciphertext being authenticated.

### Decrypt in the target key qube

This subsection decrypts the visually authenticated ciphertext into a temporary
directory and installs `master.key` only after GnuPG succeeds. Continue in the
trusted target key qube terminal:

```bash
set -euo pipefail
umask 077
test ! -e master.key

tmpdir=$(mktemp -d .master-key-import.XXXXXX)
trap 'rm -rf -- "$tmpdir"' EXIT HUP INT QUIT TERM
gpg --no-symkey-cache --decrypt --output "$tmpdir/master.key" -- key.asc

test ! -e master.key
mv -T -- "$tmpdir/master.key" master.key
rmdir -- "$tmpdir"
trap - EXIT HUP INT QUIT TERM
chmod 600 master.key
rm -f -- key.asc
stat --format='%a %n' master.key
```

Enter the paper passphrase only at GnuPG's trusted prompt. A wrong passphrase,
modified ciphertext, or failed encrypted-data integrity check makes GnuPG exit
with an error; `set -e` then prevents installation, and the trap removes the
temporary output. Successful output must show mode `600`.

### Finish the transfer

This subsection removes temporary transfer material after all checks pass.
Confirm all display, scanner, and webcam-backend disposables are stopped, the
webcam is unplugged, and the target no longer contains `key.asc`. After
successful decryption, run this in the trusted source key qube from the
directory containing its ciphertext:

```bash
rm -f -- key.asc
```

For sequential mode, also run this in `A-qr-staging`:

```bash
rm -f -- ~/QubesIncoming/seqs-qr-scanner/key.asc
```

Both commands should finish silently. Confirm the files are absent, then
destroy the paper passphrase only after the final file mode is confirmed.

For additional Qubes background, consult the official documentation for
[USB qubes](https://doc.qubes-os.org/en/latest/user/advanced-topics/usb-qubes.html),
[USB devices](https://doc.qubes-os.org/en/latest/user/how-to-guides/how-to-use-usb-devices.html),
[PCI devices](https://doc.qubes-os.org/en/latest/user/how-to-guides/how-to-use-pci-devices.html),
and [DisposableVM customization](https://doc.qubes-os.org/en/development/user/advanced-topics/disposable-customization.html).
