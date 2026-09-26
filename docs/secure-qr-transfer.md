# Reasonably secure air-gapped data transfer

This guide shows how to copy one small secret file, such as a key, between two
offline Qubes OS computers without connecting them by a network cable or a USB
stick. The file travels as a QR code shown on the sending computer's screen and
read by a webcam on the receiving computer.

The guide works for files small enough to fit in a single QR code. It does not
split larger files across several QR codes.

## How the transfer works

This section gives the whole procedure at a glance so the later steps make
sense. The secret moves in two separate pieces:

```text
                 sending computer                 receiving computer
Encrypted file:  source key qube -> D-qr-display  --QR code-->  webcam
                                                                -> camera qube
                                                                -> target key qube

Passphrase:      source key qube -> written on paper -> typed on the
                 keyboard into the target key qube
```

1. The source key qube encrypts the file with
   [GnuPG](https://www.gnupg.org/) (a standard encryption program) using a
   random one-time passphrase. You write the passphrase on paper.
2. A display qube shows the encrypted file as a QR code.
3. A webcam and a camera qube read the QR code and pass the encrypted file to
   the target key qube.
4. The webcam is removed. You compare a short fingerprint (a code calculated
   from the encrypted file) on the source and target screens to confirm the file
   arrived unchanged.
5. You type the paper passphrase into the target key qube, which decrypts the
   file.

The webcam never sees the passphrase, and the keyboard is only used for the
passphrase after the webcam is gone. An attacker would need to control both to
read the secret.

Most of the guide deals with one hardware problem on the receiving computer:
keeping the untrusted webcam away from the keyboard you type the passphrase on. Read it in order, because the
hardware check near the beginning decides which receive procedure you may use
later.

## Before you start

This section lists what must exist before you set up the QR transfer.

- SEQS is installed as described in the main [README](../README.md), with the
  `qr-display` and `qr-camera` recipes selected. The hardware check below tells
  you whether you also need `qr-staging`.
- A trusted **source key qube** on the sending computer contains the small
  secret file. The commands in
  this guide call it `master.key`.
- A trusted **target key qube** on the receiving computer does not yet contain
  a file with that name.
- A USB webcam for the receiving computer that can read a QR code from the
  sending computer's screen.

SEQS does not create the two key qubes for you, because their names and
contents differ for every user.

## What this protects and what it does not

This section explains which parts you must trust and where the protection ends.

You must trust:

- the source and target key qubes;
- dom0 (the Qubes administrative domain that controls all other qubes) on both
  ends;
- Qubes OS itself; and
- yourself to follow the steps in order.

The webcam, the QR data, the display and camera qubes, and the USB qubes that
handle them are all treated as possibly hostile.

The protection holds only while both of these stay true:

- the webcam side receives the encrypted file but never the passphrase; and
- the keyboard side receives the passphrase only after the webcam side has been
  shut down.

This is a rule about the order of the steps, not extra cryptography. If dom0,
Qubes isolation, or either key qube is compromised, the protection fails.
Deleting a file also does not guarantee it is gone from snapshots, swap,
backups, or SSD storage.

## Qubes used in this guide

This section names the qubes involved so you can recognize them later.

- The **source key qube** holds the original secret and encrypts it.
- The **target key qube** checks and decrypts the received file.
- `A-qr-display` is an offline disposable template (a template for disposables,
  which are qubes whose changes are thrown away when they shut down). SEQS
  creates a named disposable from it, `D-qr-display`, which only ever shows
  encrypted data.
- `A-qr-camera` is an offline disposable template containing `zbarcam` (the QR
  scanner program) and USB webcam support.
- `sys-usb-webcam` is a disposable USB qube (a qube that owns a physical USB
  controller and passes individual USB devices to other qubes). It handles only
  the webcam.

Two more qubes exist only on the sequential path, which is explained below:

- `seqs-qr-scanner` is a disposable that scans the QR code.
- `A-qr-staging` is a persistent offline qube that keeps the encrypted file
  while the computer is powered off.

Having no network does not stop
[qrexec](https://doc.qubes-os.org/en/latest/developer/services/qrexec.html)
(the Qubes service that lets qubes copy files and send input to each other). SEQS
therefore also installs qrexec policies (dom0 rules deciding which qube may use
which service) that stop the webcam side from sending keyboard or mouse input
or copying files where it should not.

## Why the webcam and keyboard must be separated

This section explains the hardware risk that the next steps check for. It
concerns only the receiving computer, where the webcam is plugged in.

Qubes cannot give a single USB socket to a qube. It can only give away a whole
USB controller (the chip that drives a group of USB sockets), and every device
on that controller then goes through the same USB qube. If the webcam and your
USB keyboard share a controller, a malicious webcam that takes over the USB
qube could also watch what you type, either immediately or the next time the
keyboard is connected.

There are two ways to prevent this:

- **Dedicated-controller path (preferred).** The webcam uses its own
  controller, which no keyboard, mouse, or other required device uses.
  `sys-usb-webcam` owns that controller permanently.
- **Sequential path (fallback, weaker).** The webcam must share a controller
  with other devices. A dom0 script hands the controller to the webcam for one
  scan and then powers the whole computer off before the keyboard is used
  again.

<a id="start-here-determine-which-path-the-machine-qualifies-for"></a>

## Choose the hardware-isolation path

This section gives the rule for deciding which path your computer qualifies
for. You apply it after identifying the controllers in the next section.

Use the **dedicated-controller path** only if the webcam socket is on a
controller that carries none of these:

- a keyboard or mouse;
- the disk or USB device Qubes boots from or stores data on;
- a USB anti-evil-maid (AEM, a Qubes boot-integrity check) or boot device; or
- any other device you need to operate or recover the computer.

A built-in laptop keyboard that is not connected over USB does not count,
because it does not use a USB controller. Check that it still works while
`sys-usb` is stopped before relying on it.

Use the **sequential path** if no webcam socket meets that rule, or add a
separate PCIe USB card to get a dedicated controller. On the sequential path:

- normal `sys-usb` is stopped and the webcam gets its controller for one scan;
- you unplug the webcam afterwards; and
- the computer powers off completely before the keyboard is used again.

The sequential path assumes that removing power clears anything the webcam
could have left behind in the controller. A restart is not enough, and
malicious firmware that survives power loss is not covered.

## Find the webcam's USB controller

This section finds out which physical controller each webcam socket on the
receiving computer uses, so you can apply the rule above. It takes several small steps because Qubes and
Linux show the same hardware under different names.

### Understand the USB names you will see

This subsection explains the two kinds of identifiers used in the following
steps. A computer's USB hardware looks like this:

```text
PCI USB controller 00_14.0             <- Qubes assigns this whole unit
|-- root USB bus 4 (USB 2 root hub)
|   |-- port 2 -> device                <- USB device path 4-2
|   `-- port 3 -> hub -> port 1 -> device
|                                        <- USB device path 4-3.1
`-- root USB bus 5 (USB 3 root hub)
    `-- port 1 -> device                <- USB device path 5-1
```

- A **PCI USB controller** is the chip that runs a group of USB sockets. PCI is
  the internal bus that connects it to the rest of the computer. A controller is
  the smallest USB unit Qubes can hand to a qube.
- A controller's address is its **BDF** (bus-device-function), such as
  `00:14.0`. Qubes commands write it with an underscore: `00_14.0`. The word
  "bus" here refers to PCI, not to the USB bus numbers below.
- A **root USB bus**, such as bus 4, is one tree of sockets inside a controller.
  One controller usually has two: a USB 2 bus and a USB 3 bus that share the
  same physical sockets. A slow device in a socket may appear on bus 4 while a
  fast device in the same socket appears on bus 5.
- A **USB device path**, such as `4-2`, is how Linux names a device's position:
  bus 4, port 2. Each hub in between adds a dot and a port number, so `4-3.1`
  means bus 4, port 3, then port 1 on a hub. These numbers do not match the
  labels printed on the case.

The BDF is what matters for isolation. Two devices can only be separated if
their paths lead to different BDFs, for example:

```text
PCI USB controller 03_00.0        PCI USB controller 00_14.0
`-- webcam                         `-- keyboard
    -> sys-usb-webcam                  -> normal sys-usb
```

Different USB bus numbers alone do not mean different controllers.

You will also meet a third kind of address. Inside `sys-usb`, Qubes shows each
controller at a virtual PCI address, such as `0000:00:09.0`, that differs from
the real one in dom0:

| Example | Meaning |
|---|---|
| `dom0:00_14.0` | Real controller address in dom0; this is the value SEQS needs (`00_14.0`) |
| `sys-usb:4-3` | Device path `4-3` as reported by the `sys-usb` qube |
| `0000:00:09.0` | Virtual controller address, visible only inside `sys-usb` |

Never copy the virtual address into the SEQS configuration.

### Record the device paths

This subsection lists where each device sits. Leave the keyboard, mouse, boot
drive, and other required USB devices plugged in. Plug the webcam into one
candidate socket, and in a dom0 terminal run:

```bash
qvm-usb
```

The output lists each USB device with an identifier such as `sys-usb:4-3`.
Write down the path of the webcam and of every required device. Then move only
the webcam to the next socket and run `qvm-usb` again, until you have tried
every socket you might use.

The number before the dash is the root USB bus. Hubs, extension cables,
Bluetooth dongles, and USB-to-PS/2 adapters never add a new controller.

### Find which virtual controller each bus uses

This subsection links each USB bus number to a controller inside `sys-usb`.
Open a terminal in `sys-usb`. For each different bus number you recorded, run
this command with one path from that bus. For a device at `4-2`:

```bash
readlink -f /sys/bus/usb/devices/4-2
```

The output looks like this:

```text
/sys/devices/pci0000:00/0000:00:09.0/usb4/4-2
```

The address just before `/usb4`, here `0000:00:09.0`, is the virtual
controller. Write down which bus numbers lead to which virtual controller.
Several buses often lead to the same one.

### Read each controller's hardware ID

This subsection reads an ID for each virtual controller so you can find the
same chip in dom0. In the same `sys-usb` terminal, run this for each virtual
controller, replacing the address:

```bash
p=/sys/bus/pci/devices/0000:00:09.0
printf 'vendor='; cat "$p/vendor"
printf 'device='; cat "$p/device"
```

The output looks like this:

```text
vendor=0x8086
device=0xa36d
```

Write the pair as `8086:a36d`, without `0x`. These are public model numbers,
not secrets.

### Find the real controller address in dom0

This subsection turns each hardware ID into the real BDF. In a dom0 terminal,
run:

```bash
qvm-pci list --with-sbdf | grep -i usb
```

The output lists USB controllers such as `dom0:00_14.0`. For each one, run
`lspci` with the underscore changed to a colon:

```bash
lspci -nn -s 00:14.0
```

Look for your recorded ID in square brackets at the end:

```text
00:14.0 USB controller: Intel Corporation ... [8086:a36d]
```

Now you know the real BDF behind each virtual controller, and so which sockets
and devices belong to which controller. If two controllers show the same ID and
you cannot tell them apart, do not guess.

Apply the rule from
[Choose the hardware-isolation path](#choose-the-hardware-isolation-path). If a
webcam socket's controller carries none of the listed devices, you may use the
dedicated-controller path with that controller. Otherwise, use the sequential
path with the controller of the socket you will use for the webcam.

### Confirm which controllers `sys-usb` owns

This subsection checks the current assignment before you change anything. In a
dom0 terminal, run:

```bash
qvm-pci list sys-usb
```

Your chosen controller should appear as `dom0:<BDF>` in the first column. The
sequential path requires it to be attached to `sys-usb` before you build.

Do not use `qvm-prefs sys-usb pcidevs` for this. PCI devices are managed with
`qvm-pci`, and `pcidevs` is not a `qvm-prefs` setting.

## Configure and build the QR qubes

This section enters your chosen path and controller into SEQS and builds the
qubes. In the repository qube (never in dom0), edit
`salt/pillar/seqs/config.sls`.

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

Replace the example BDF with your own, without the `dom0:` prefix. Leave
`webcam_usb_no_strict_reset` at `False`. Setting it to `True` lets Qubes hand
over a controller that cannot be fully reset, which can carry hostile state
from one qube to the next. Sequential mode refuses it.

Then follow [the upgrade procedure](upgrading.md) to verify the revision, copy
the runner to dom0, fetch, review, stage, and build. Build
`qr-camera,qr-display,qr-staging` for the sequential path, or
`qr-camera,qr-display` for the dedicated-controller path.

The build creates `sys-usb-webcam`. On the sequential path it also creates
`seqs-qr-scanner`, `A-qr-staging`, and the dom0 script
`/usr/local/sbin/seqs-qr-sequential` that runs the scan.

If the build fails with a strict PCI attachment error, the controller cannot be
reset safely and is unsuitable. Do not turn on `no-strict-reset` to get past
it.

## Check the setup

This section confirms that the qubes and policies are correct before you use
any secret.

### Check that the QR qubes are offline

This subsection checks that none of the QR qubes has a NetVM (the qube that
gives it network access). In a dom0 terminal, run:

```bash
qvm-prefs A-qr-display netvm
qvm-prefs D-qr-display netvm
qvm-prefs A-qr-camera netvm
qvm-prefs sys-usb-webcam netvm
```

On the sequential path, also run:

```bash
qvm-prefs seqs-qr-scanner netvm
qvm-prefs A-qr-staging netvm
```

Every command must print nothing, `None`, or `none`.

### Check the controller assignment

This subsection checks which qubes the controller is assigned to. In a dom0
terminal, run:

```bash
qvm-pci list --assignments
```

On the dedicated-controller path, your controller must be assigned only to
`sys-usb-webcam`. On the sequential path, it is assigned to both `sys-usb` and
`sys-usb-webcam`. That is intended: the script makes sure only one of them runs
at a time.

### Check the qrexec policies

This subsection checks the dom0 rules that limit the webcam side. In a dom0
terminal, run:

```bash
sudo cat /etc/qubes/policy.d/00-seqs-qr-input-deny.policy
```

You should see `deny` lines for `qubes.InputKeyboard`, `qubes.InputMouse`,
`qubes.InputTablet`, and `qubes.Filecopy` from `sys-usb-webcam`.

On the sequential path, also run:

```bash
sudo cat /etc/qubes/policy.d/01-seqs-qr-filecopy.policy
```

You should see one `allow` from `seqs-qr-scanner` to `A-qr-staging`, followed
by a `deny` for every other destination.

### Check the dedicated controller with the webcam

This subsection applies only to the dedicated-controller path. Start
`sys-usb-webcam` from the Qubes menu, plug in the webcam, and in a dom0
terminal run:

```bash
qvm-usb
```

The webcam must be listed under `sys-usb-webcam`. Every keyboard, mouse, and
other required device must still be listed under another USB qube. If any of
them moved to `sys-usb-webcam`, stop: the controller is not dedicated. Shut
down `sys-usb-webcam` and unplug the webcam when you are done.

## Transfer a file

This section is the procedure you repeat for every transfer. It sends one
`master.key` from the source key qube to the target key qube.

You need a fresh sheet of paper for the passphrase, which will look like this:

```text
PASSPHRASE: <26 letters and digits>
```

Keep the paper, and any screen showing the passphrase, out of the webcam's view
at all times.

### Step 1: Encrypt the file (sending computer)

This step creates a random one-time passphrase and an encrypted copy,
`key.asc`. Open a terminal in the source key qube, go to the directory
containing `master.key`, and run:

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

The terminal prints the passphrase. Write it on the paper.

Then close this terminal window completely. Its scrollback still contains the
passphrase and must never be on screen while the webcam is connected. Running
`clear` is not enough.

### Step 2: Copy the encrypted file to the display qube (sending computer)

This step moves `key.asc` into the display qube. Start `D-qr-display` from the
Qubes menu first; if you copied the file before starting it, its startup
cleanup could delete the file.

Open a new terminal in the source key qube, go to the directory containing
`key.asc`, and run:

```bash
qvm-copy key.asc
```

In the dialog, choose the running `D-qr-display`. Keep the source copy of
`key.asc`; you need it for the fingerprint check in step 5. You may shut down
the source key qube now, because its files are kept.

### Step 3: Show the QR code (sending computer)

This step puts the encrypted file on screen. Put away the paper and close every
window that shows a secret. In a `D-qr-display` terminal, run this, replacing
`<source-key-qube>` with the name of your source key qube:

```bash
cd ~/QubesIncoming/<source-key-qube>
qrencode -l M -t ansiutf8 < key.asc
```

The terminal should show one complete QR code. If `qrencode` reports that the
data is too large, stop: the file is too big for this procedure. Leave the QR
code on screen until scanning is finished.

### Step 4a: Scan on the dedicated-controller path (receiving computer)

This step reads the QR code with the webcam. Skip it on the sequential path and
use step 4b instead.

1. Start `sys-usb-webcam` and plug in the webcam.
2. From the Qubes menu, open a terminal in a new disposable based on
   `A-qr-camera`.
3. Attach only the webcam to that disposable with the Qubes Devices widget (the
   USB icon in the system tray).
4. In the disposable's terminal, run:

   ```bash
   set -euo pipefail
   umask 077
   zbarcam -q --raw --oneshot -Sdisable -Sqrcode.enable > key.asc
   qvm-copy key.asc
   ```

   Point the webcam at the QR code. `zbarcam` exits after one successful read.
   In the copy dialog, choose the running target key qube.
5. After the copy succeeds, unplug the webcam and shut down the camera
   disposable and `sys-usb-webcam`. Check in the Qube Manager or Qubes Domains
   widget that both have stopped before you take out the paper.

If `sys-usb-webcam` ever handled your keyboard, stop and do not type the
passphrase.

Continue with step 5.

### Step 4b: Scan on the sequential path (receiving computer)

This step lets a dom0 script lend the shared controller to the webcam for one
scan and then power off the computer. Skip it on the dedicated-controller path.

Never use the manual scan from step 4a on the sequential path. The script has to
stay in control until the power-off.

Get ready:

1. Put away the paper and close every window that shows a secret. The QR code
   from step 3 stays on the sending computer's screen.
2. Unplug the webcam.
3. Save and close all unrelated work, because the receiving computer will
   power off.
4. Be ready to unplug the keyboard and mouse quickly.

In a dom0 terminal, run:

```bash
sudo /usr/local/sbin/seqs-qr-sequential
```

The script first checks that the required qubes exist and that `A-qr-staging`
holds no old `key.asc`. It then shows the controller and qube names. Check
them, then type `START` in capital letters. After that:

1. Unplug the keyboard and mouse right away. After 10 seconds the script stops
   normal `sys-usb`.
2. When the screen says `NORMAL USB BACKEND STOPPED`, plug in only the webcam.
   You have 30 seconds.
3. The script starts `sys-usb-webcam` and `seqs-qr-scanner`, checks that exactly
   one USB device is present, and scans for up to 3 minutes. Point the webcam at
   the QR code. The received file may be at most 16 KiB and is copied only to
   `A-qr-staging`.
4. When told to, unplug the webcam. Do not reconnect the keyboard or mouse.
5. The computer powers off, whether the scan worked or not.

When the computer is completely off, keep the webcam unplugged, reconnect the
keyboard and mouse, and if you can, unplug the power cable or remove standby
power for a moment. Then start the computer.

After boot, check that `A-qr-staging` received the file. If it is missing, the
scan failed. Open a terminal in `A-qr-staging` and run:

```bash
cd ~/QubesIncoming/seqs-qr-scanner
qvm-copy key.asc
```

In the dialog, choose the running target key qube. Do not try to open or decrypt
the file in `A-qr-staging`.

Temporal separation cannot protect against everything. The sequential path is
still exposed to malicious state that survives in controller firmware or in
hardware that stayed powered, an incomplete power-off, a webcam attack that
escapes through Qubes itself or qrexec, a compromised dom0, a webcam left
plugged in at the next boot, and malicious keyboard or controller firmware. A
dedicated controller avoids reusing hardware the webcam has touched.

### Step 5: Compare fingerprints (both computers)

This step confirms that the target received exactly the file the source sent,
before GnuPG reads it. First check that the webcam is unplugged and that every
camera and webcam qube has stopped. In the target key qube, move the received
`key.asc` from `~/QubesIncoming/...` into the directory where `master.key`
should end up.

Open a new terminal in the source key qube. Do not reuse the terminal from
step 1. Go to the directory containing the kept `key.asc` and run:

```bash
test -f key.asc
printf 'SOURCE: '
sha256sum -- key.asc | cut -c1-20 | sed 's/...../&-/g; s/-$//' | tr '[:lower:]' '[:upper:]'
```

The output is four groups of five characters, for example:

```text
SOURCE: 7A91C-24D8E-6F032-B5A10
```

In a terminal in the target key qube, in the directory holding the received
`key.asc`, run:

```bash
test -f key.asc
printf 'TARGET: '
sha256sum -- key.asc | cut -c1-20 | sed 's/...../&-/g; s/-$//' | tr '[:lower:]' '[:upper:]'
```

Place the two screens side by side, use a large font, and compare all four
groups character by character. Do not copy, paste, retype, or photograph the
code.

The code is the first 20 characters of the file's SHA-256 hash. An attacker who
wanted a different file with the same code would need about 2^80 attempts.

If any character differs, do not run GnuPG. Delete the received `key.asc` in
the target key qube (and in `A-qr-staging` on the sequential path), then repeat
from step 3. You can reuse the source `key.asc`.

### Step 6: Decrypt (receiving computer)

This step decrypts the file into a temporary directory and moves it into place
only if GnuPG succeeds. In the target key qube terminal, run:

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

When GnuPG asks for the passphrase, type it from the paper. If the passphrase
is wrong or the file was changed, GnuPG exits with an error and the script
removes the temporary output without creating `master.key`. On success, the
last line shows `600 master.key`.

### Step 7: Clean up

This step removes the leftover encrypted copies. Check that all display,
scanner, and webcam qubes have stopped, the webcam is unplugged, and the target
key qube no longer contains `key.asc`.

On the sending computer, in the source key qube directory containing `key.asc`,
run:

```bash
rm -f -- key.asc
```

On the sequential path, also run this in an `A-qr-staging` terminal:

```bash
rm -f -- ~/QubesIncoming/seqs-qr-scanner/key.asc
```

Both commands print nothing. Check that the files are gone. Destroy the paper
only after step 6 showed `600 master.key`.

## Further reading

This section links the official Qubes documentation behind the concepts used
above:
[USB qubes](https://doc.qubes-os.org/en/latest/user/advanced-topics/usb-qubes.html),
[USB devices](https://doc.qubes-os.org/en/latest/user/how-to-guides/how-to-use-usb-devices.html),
[PCI devices](https://doc.qubes-os.org/en/latest/user/how-to-guides/how-to-use-pci-devices.html),
and [disposable customization](https://doc.qubes-os.org/en/development/user/advanced-topics/disposable-customization.html).
