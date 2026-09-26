# Reasonably secure air-gapped data transfer

This guide copies one small secret file, such as a key, from one Qubes OS
computer to another without a network cable or USB stick between them. The
sending computer shows the encrypted file as a QR code on its screen, and a
webcam on the receiving computer reads it. The encrypted file must fit in a
single QR code; larger files, which would need several codes, are not
supported.

## How the transfer works

The secret travels in two separate pieces, and every later step exists to keep
them apart:

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
   random one-time passphrase, which you write on paper.
2. A display qube on the sending computer shows the encrypted file as a QR code.
3. On the receiving computer, a webcam and a camera qube read the QR code and
   pass the encrypted file to the target key qube.
4. The webcam is removed. You compare a short fingerprint (a code calculated
   from the encrypted file) on both screens to check that the file arrived
   unchanged.
5. You type the paper passphrase into the target key qube, which decrypts the
   file.

The webcam side only ever handles encrypted data, and the passphrase is typed
only after the webcam side is shut down. As long as those two conditions hold,
and the trusted parts listed below are not compromised, an attacker needs to
control both the webcam side and the keyboard side to read the secret.

## What you must trust

The procedure protects the secret only if these parts behave correctly:

- the source and target key qubes;
- dom0 (the Qubes administrative domain that controls all other qubes) on both
  computers;
- Qubes OS itself; and
- you, following the steps in order.

The webcam, the QR data, and the display, camera, staging, and USB qubes that
handle them are treated as possibly hostile. So is the other side: normal
`sys-usb`, a USB keyboard, its firmware, and their controller see the
passphrase as you type it, and Qubes does not trust them either. The secret
stays safe only while at most one of the two sides is hostile. If both are,
the passphrase and the encrypted file meet, the secret is lost, and nothing in
this procedure will tell you. The two sides are not independent: they share
the USB attack surface, the room, and possibly the attacker, and any USB
device ever plugged into `sys-usb` could have compromised it. The two-piece
split is a rule about the order of the steps, not extra cryptography.

The best way to shrink this risk is to keep `sys-usb` out of the passphrase
path: type the passphrase on a keyboard that does not go through a USB qube,
such as a built-in laptop keyboard that is not internally USB, or a PS/2
keyboard. Then the keyboard side is dom0, which you already trust.

Deleting a file afterwards also does not guarantee that it is gone from
snapshots, swap, backups, or SSD storage.

## What each computer needs

The two computers need different parts of SEQS. To send in both directions, set
up both roles on each computer.

The **sending computer** needs:

- a trusted **source key qube** containing the file, called `master.key` in the
  commands below; and
- SEQS installed with the `qr-display` qube selected. This creates
  `D-qr-display`, the offline qube that shows the QR code and only ever handles
  encrypted data.

`D-qr-display` is a disposable: a qube whose changes are thrown away when it
shuts down. It starts from the template `A-qr-display`, which SEQS creates at
the same time.

No webcam or hardware check is needed on the sending computer.

The **receiving computer** needs:

- a trusted **target key qube** that does not yet contain a `master.key`;
- a USB webcam that can read a QR code from the sending computer's screen;
- the hardware check in the next three sections; and
- SEQS installed with the `qr-camera` qube selected, plus `qr-staging` on the
  sequential path described below. This creates `A-qr-camera`, the offline
  template for the camera disposables that run `zbarcam` (the QR scanner
  program), and `sys-usb-webcam`, which handles only the webcam.

`sys-usb-webcam` is a USB qube: a qube that owns USB hardware and passes
individual devices to other qubes.

SEQS does not create the key qubes, because their names and contents differ for
every user.

## Why the webcam must not share a USB controller with the keyboard

Qubes cannot give a single USB socket to a qube. It can only give away a whole
USB controller (the chip that drives a group of sockets), and every device on
that controller then goes through the same USB qube. If the webcam and a USB
keyboard share a controller, a malicious webcam that takes over that USB qube
could also watch what you type, either immediately or the next time the
keyboard is connected. The passphrase would then no longer travel separately.

The same applies to cameras that already sit on the keyboard's USB qube. A
laptop's built-in webcam is usually a USB device on the same controller as
the keyboard, handled by normal `sys-usb`. If that qube is compromised, it can
film the QR code on the sending computer's screen and the paper as you write
or type the passphrase, and it has both halves on its own. Cover or disable
built-in cameras on both computers for the whole transfer, for example with
the hardware switch or by detaching them from `sys-usb` in the Devices widget,
and treat any camera on `sys-usb` as you would the hostile webcam.

<a id="start-here-determine-which-path-the-machine-qualifies-for"></a>

## Choose the hardware-isolation path

The receiving computer qualifies for one of two paths. Only the first separates
the webcam and keyboard in hardware.

The **dedicated-controller path** is available if a webcam socket is on a
controller that carries none of these:

- a keyboard or mouse;
- the disk or USB device Qubes boots from or stores data on;
- a USB anti-evil-maid (AEM, a Qubes boot-integrity check) or boot device;
- a hardware wallet, security key, phone, or backup drive; or
- any other device you need to operate or recover the computer.

`sys-usb-webcam` then owns that controller permanently, so anything plugged
into any of that controller's sockets from then on is handled by the qube this
guide treats as hostile, or is unusable while that qube is stopped. The
separation also relies on the IOMMU (the VT-d or AMD-Vi feature Qubes needs to
assign PCI devices); leave it enabled in the firmware settings.

A built-in keyboard that is genuinely not connected over USB does not count,
because it uses no USB controller. Some built-in keyboards are wired internally
over USB and do count. Before relying on a built-in keyboard, check that it
keeps working while `sys-usb` is stopped.

The **sequential path** is a weaker fallback for computers where every webcam
socket shares a controller with required devices. It does not separate the
devices in hardware. Instead, a dom0 script stops normal `sys-usb`, lends the
controller to the webcam for one scan, and powers the computer off before the
keyboard is used again. It relies on an assumption that the dedicated path does
not need: that cutting power clears anything the webcam could have left behind
in the controller or other hardware. A restart does not qualify, and malicious
firmware that survives power loss defeats it. The path also requires that every
other device on that controller can be unplugged: a built-in keyboard that is
internally wired to the shared controller cannot, and the script then refuses
to scan.

Before choosing the sequential path, check whether you can remove all power
from the receiving computer after the scan. A normal power-off can leave parts
of the computer on standby power, so the sequential path expects you to
unplug the power cable and take out the battery. This guide does not specify a
tested minimum time without power. If the battery is built in, the assumption
is weaker still, and this guide cannot say how much.

Even with all power removed, the sequential path remains exposed to malicious
state that survives in controller firmware, a webcam attack that escapes
through Qubes itself or qrexec, a compromised dom0, a webcam left plugged in at
the next boot, and malicious keyboard or controller firmware. A dedicated
controller avoids reusing hardware the webcam has touched.

If the computer only qualifies for the sequential path and these limits are not
acceptable for your secret, add a PCIe USB card to get a dedicated controller
instead.

## Find the webcam's USB controller

To apply the rule above, you need to know which controller each webcam socket
and each required device uses. Linux, `sys-usb`, and dom0 each name the same
hardware differently, so this takes four short lookups.

### Record the device paths

Linux names each USB device by its position, called the USB device path:

```text
PCI USB controller 00_14.0             <- Qubes assigns this whole unit
|-- root USB bus 4 (USB 2)
|   |-- port 2 -> device                <- device path 4-2
|   `-- port 3 -> hub -> port 1 -> device
|                                        <- device path 4-3.1
`-- root USB bus 5 (USB 3)
    `-- port 1 -> device                <- device path 5-1
```

The number before the dash is the root USB bus (one tree of sockets inside a
controller), and each number after it is a port. A controller usually has a USB
2 bus and a USB 3 bus sharing the same sockets, so a different bus number does
not mean a different controller. Hubs, extension cables, Bluetooth dongles, and
USB-to-PS/2 adapters never add a controller. Port numbers do not match the
labels printed on the case.

Leave the keyboard, mouse, boot drive, and other required USB devices plugged
in. Plug the webcam into one socket you might use, and in a dom0 terminal of the
receiving computer run:

```bash
qvm-usb
```

The output lists each device with an identifier such as `sys-usb:4-3`, meaning
device path `4-3` in `sys-usb`. Write down the path of the webcam and of every
required device. Move only the webcam to the next socket and run `qvm-usb`
again, until you have tried every candidate socket.

### Find which controller each bus uses inside `sys-usb`

Open a terminal in `sys-usb`. For each different bus number you recorded, run
this with one device path from that bus, for example `4-2`:

```bash
readlink -f /sys/bus/usb/devices/4-2
```

The output looks like this:

```text
/sys/devices/pci0000:00/0000:00:09.0/usb4/4-2
```

The address just before `/usb4`, here `0000:00:09.0`, is the controller as
`sys-usb` sees it. This is a virtual address that exists only inside `sys-usb`;
never put it into the SEQS configuration. Write down which bus numbers lead to
which virtual address. Several buses often lead to the same one.

### Read each controller's hardware ID

The hardware ID lets you find the same controller in dom0. In the same
`sys-usb` terminal, run this for each virtual address, replacing
`0000:00:09.0`:

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

dom0 names each controller by its BDF (bus-device-function), the controller's
real PCI address, such as `00:14.0`. Qubes commands write it with an
underscore, `00_14.0`, and that form is what SEQS needs. In a dom0 terminal,
run:

```bash
qvm-pci list --with-sbdf | grep -i usb
```

The output lists controllers such as `dom0:00_14.0`. For each one, run `lspci`
with the underscore changed to a colon:

```bash
lspci -nn -s 00:14.0
```

Look for a recorded hardware ID in square brackets at the end:

```text
00:14.0 USB controller: Intel Corporation ... [8086:a36d]
```

You now know which BDF serves each socket and each required device. If two
controllers show the same ID and you cannot tell them apart, do not guess.
Everything you read inside `sys-usb` came from a qube that Qubes does not
trust, so the check that counts is the one after the build, where dom0 shows
which qube actually receives the webcam.

Apply the rule from
[Choose the hardware-isolation path](#choose-the-hardware-isolation-path). If a
webcam socket's controller carries none of the listed devices, use the
dedicated-controller path with that controller, always plug the webcam into
that socket, and plug nothing else into that controller's sockets. Otherwise,
use the sequential path with the controller of the socket you will use for the
webcam.

Finally, confirm that `sys-usb` currently owns the chosen controller. In a dom0
terminal, run:

```bash
qvm-pci list sys-usb
```

The chosen controller should appear as `dom0:<BDF>` in the first column. The
sequential path requires this before you build. Do not use
`qvm-prefs sys-usb pcidevs` instead; PCI devices are managed with `qvm-pci`,
and `pcidevs` is not a `qvm-prefs` setting.

## Configure and build the QR qubes

SEQS builds qubes from a Git checkout in the repository qube (the qube holding
your SEQS clone, such as the disposable used in the
[README](../README.md) install). Never edit SEQS files in dom0.

On the sending computer, no configuration change is needed: select
`qr-display` when you run SEQS, as described at the end of this section.

On the receiving computer, edit `salt/pillar/seqs/config.sls` in the repository
qube. For the dedicated-controller path:

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
`webcam_usb_no_strict_reset` at `False`: `True` lets Qubes hand over a
controller that cannot be fully reset, which can carry hostile state from one
qube to the next. Sequential mode refuses `True`.

The SEQS runner builds only the committed state of the checkout, so an
uncommitted edit is silently ignored. In a terminal in the repository qube,
review and commit the change:

```bash
cd ~/SEQS
git diff salt/pillar/seqs/config.sls
git commit -m 'Configure QR webcam controller' salt/pillar/seqs/config.sls
```

The diff should show only the lines you changed. If Git refuses to commit
because it does not know your name and email, set them with `git config
user.name` and `git config user.email` and commit again. If the repository qube
is a disposable, the commit disappears when it shuts down, and you must repeat
the edit before any later SEQS run on this computer.

Then run SEQS from dom0 as usual, choosing the qubes with `--qubes`:

- For a first SEQS install, follow the [README](../README.md).
- For an existing installation, follow [the upgrade procedure](upgrading.md).

Select `qr-display` on the sending computer. On the receiving computer, select
`qr-camera,qr-staging` for the sequential path or `qr-camera` for the
dedicated-controller path. Add the other role's qubes too if the computer will
send in both directions.

On the receiving computer, the build creates `sys-usb-webcam`. On the
sequential path it also creates `seqs-qr-scanner` (a disposable that scans the
QR code), `A-qr-staging` (a persistent offline qube that keeps the encrypted
file while the computer is off), and the dom0 script
`/usr/local/sbin/seqs-qr-sequential` that runs the scan.

On the dedicated-controller path, the build takes the controller away from
`sys-usb` immediately, and the assignment survives reboots; setting the mode
back to `disabled` does not undo it. If you chose the wrong BDF and it carries
your keyboard, the keyboard stops working and stays that way. Before building,
make sure you have a second way to type in dom0, such as a built-in non-USB
keyboard or a keyboard on another controller.

If the build fails with a strict PCI attachment error, the controller cannot be
reset safely and is unsuitable. Do not enable `no-strict-reset` to get past it.

## Check the setup

Run these checks once after building and before you use any secret.

### Sending computer: check that the display qubes are offline

A qube without a NetVM (the qube that gives it network access) is offline. In a
dom0 terminal of the sending computer, run:

```bash
qvm-prefs A-qr-display netvm
qvm-prefs D-qr-display netvm
```

Both commands must print nothing, `None`, or `none`.

Having no network does not stop
[qrexec](https://doc.qubes-os.org/en/latest/developer/services/qrexec.html)
(the Qubes service that lets qubes copy files, open links, and send input to
each other), so SEQS also installs qrexec policies (dom0 rules deciding which
qube may use which service). Check that the display qubes may not hand links
to the browser qube:

```bash
sudo grep qr-display /etc/qubes/policy.d/28-browser-suppress.policy
```

You should see `deny` lines for `A-qr-display`, `@dispvm:A-qr-display`, and
`D-qr-display`.

### Receiving computer: check that the camera qubes are offline

In a dom0 terminal of the receiving computer, run:

```bash
qvm-prefs A-qr-camera netvm
qvm-prefs sys-usb-webcam netvm
```

On the sequential path, also run:

```bash
qvm-prefs seqs-qr-scanner netvm
qvm-prefs A-qr-staging netvm
```

Every command must print nothing, `None`, or `none`.

### Receiving computer: check the controller assignment

In a dom0 terminal of the receiving computer, run:

```bash
qvm-pci list --assignments
```

On the dedicated-controller path, your controller must be assigned only to
`sys-usb-webcam`. On the sequential path, it is assigned to both `sys-usb` and
`sys-usb-webcam`. Qubes refuses to start a qube whose controller another
running qube holds, and the script stops `sys-usb` before starting
`sys-usb-webcam`.

### Receiving computer: check the qrexec policies

The qrexec policies on this side limit the webcam qubes. In a dom0 terminal
of the receiving computer, run:

```bash
sudo cat /etc/qubes/policy.d/00-seqs-qr-input-deny.policy
```

You should see `deny` lines for `qubes.InputKeyboard`, `qubes.InputMouse`,
`qubes.InputTablet`, `qubes.Filecopy`, and `qubes.OpenURL` from
`sys-usb-webcam`, and for the input services and `qubes.OpenURL` from
`@dispvm:A-qr-camera`.

On the sequential path, also run:

```bash
sudo cat /etc/qubes/policy.d/01-seqs-qr-filecopy.policy
```

You should see one `allow` from `seqs-qr-scanner` to `A-qr-staging`, followed
by a `deny` for every other destination.

### Receiving computer: check the dedicated controller with the webcam

On the dedicated-controller path only, start `sys-usb-webcam` from the Qubes
menu, plug the webcam into its socket, and in a dom0 terminal run:

```bash
qvm-usb
```

The webcam must be listed under `sys-usb-webcam`. Every keyboard, mouse, and
other required device must still be listed under another USB qube. If any of
them moved to `sys-usb-webcam`, stop: the controller is not dedicated. Shut
down `sys-usb-webcam` and unplug the webcam when you are done.

## Transfer a file

Repeat this procedure for every transfer. Before starting, take a fresh sheet
of paper for the passphrase, which will look like this:

```text
PASSPHRASE: <26 letters and digits>
```

Keep the webcam unplugged, and its lens covered or facing away, until step 4
tells you to plug it in. A hostile webcam may record whenever it has power,
even while no qube uses it. Cover the built-in cameras of both computers.
From step 1 until the end, keep the paper, and any screen showing the
passphrase, out of every camera's view.

### Step 1: Encrypt the file (sending computer)

Open a terminal in the source key qube, go to the directory containing
`master.key`, and run:

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

The terminal prints the passphrase and creates the encrypted file `key.asc`.
Write the passphrase on the paper.

Then close this terminal window completely. Its scrollback still contains the
passphrase, and running `clear` does not remove it.

### Step 2: Copy the encrypted file to the display qube (sending computer)

Start `D-qr-display` from the Qubes menu before copying. A copy made before it
starts could be deleted by its startup cleanup.

Open a new terminal in the source key qube, go to the directory containing
`key.asc`, and run:

```bash
qvm-copy key.asc
```

In the dialog, choose the running `D-qr-display`. Keep the source copy of
`key.asc`, because step 5 compares against it. You may shut down the source key
qube now; its files are kept.

### Step 3: Show the QR code (sending computer)

Put away the paper and close every window that shows a secret. In a
`D-qr-display` terminal, run this, replacing `<source-key-qube>` with the name
of your source key qube:

```bash
cd ~/QubesIncoming/<source-key-qube>
qrencode -l M -t ansiutf8 < key.asc
```

The terminal should show one complete QR code. If `qrencode` reports that the
data is too large, stop: the file is too big for this procedure. Keep
`D-qr-display` running only until the receiving computer has scanned the code,
then shut it down.

### Step 4a: Scan on the dedicated-controller path (receiving computer)

Use this step only on the dedicated-controller path; on the sequential path,
use step 4b.

1. Start the target key qube, so that it can be chosen as a copy destination.
2. Start `sys-usb-webcam` and plug the webcam into its socket.
3. Open the Qubes Devices widget (the USB icon in the system tray). The webcam
   must be listed as `sys-usb-webcam:...`. If it is listed as `sys-usb:...`,
   it is in a socket of the keyboard's controller: unplug it and stop.
4. From the Qubes menu, open a terminal in a new disposable based on
   `A-qr-camera`.
5. Attach only the webcam to that disposable with the Devices widget.
6. In the disposable's terminal, run:

   ```bash
   set -euo pipefail
   umask 077
   zbarcam -q --raw --oneshot -Sdisable -Sqrcode.enable > key.asc
   qvm-copy key.asc
   ```

   Point the webcam at the QR code. `zbarcam` exits after one successful read.
   In the copy dialog, choose the target key qube.
7. After the copy succeeds, unplug the webcam and shut down the camera
   disposable and `sys-usb-webcam`. Check in the Qube Manager or the Qubes
   Domains widget that both have stopped before you take out the paper.

If `sys-usb` ever handled the webcam, or `sys-usb-webcam` ever handled your
keyboard, stop and do not type the passphrase. Otherwise, continue with step 5.

### Step 4b: Scan on the sequential path (receiving computer)

On the sequential path, a dom0 script scans the code and then powers off the
receiving computer. Never use the manual scan from step 4a here; the script
has to stay in control until the power-off.

Prepare:

1. Put away the paper and close every window that shows a secret.
2. Unplug the webcam.
3. Save and close all unrelated work.
4. Be ready to unplug the keyboard and mouse quickly.

In a dom0 terminal of the receiving computer, run:

```bash
sudo /usr/local/sbin/seqs-qr-sequential
```

The script checks that the required qubes exist and that `A-qr-staging` holds
no old `key.asc`, then shows the controller and qube names. Check them, then
type `START` in capital letters. After that:

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

Once the computer is off, remove every power source you can: unplug the power
cable, and take out the battery if it is removable. The limits of this step are
described under
[Choose the hardware-isolation path](#choose-the-hardware-isolation-path).
Then, with the webcam still unplugged, reconnect power, keyboard, and mouse,
and start the computer.

After boot, start the target key qube, then open a terminal in `A-qr-staging`
and run:

```bash
cd ~/QubesIncoming/seqs-qr-scanner
qvm-copy key.asc
```

If `cd` or `qvm-copy` reports a missing directory or file, the scan failed;
repeat from
[Step 3: Show the QR code](#step-3-show-the-qr-code-sending-computer).
Otherwise, choose the target key qube in the dialog. Do not open or decrypt the
file in `A-qr-staging`.

### Step 5: Compare fingerprints (both computers)

The fingerprint check detects whether the file the target received differs
from the source's `key.asc`, before GnuPG reads it. It compares a shortened
hash, so a match makes an undetected change very unlikely rather than
impossible; the numbers follow the commands.

First check that the webcam is unplugged and that every camera and webcam qube
on the receiving computer has stopped. In the target key qube, move the
received `key.asc` into the directory where `master.key` should end up. Qubes
puts received files in `~/QubesIncoming/<sender>`, where the sender is the
camera disposable (a name like `disp1234`) or `A-qr-staging`.

On the sending computer, open a new terminal in the source key qube. Do not
reuse the terminal from step 1. Go to the directory containing the kept
`key.asc` and run:

```bash
test -f key.asc
printf 'SOURCE: '
sha256sum -- key.asc | cut -c1-20 | sed 's/...../&-/g; s/-$//' | tr '[:lower:]' '[:upper:]'
```

The output is four groups of five characters, for example:

```text
SOURCE: 7A91C-24D8E-6F032-B5A10
```

On the receiving computer, in a terminal in the target key qube, in the
directory holding the received `key.asc`, run:

```bash
test -f key.asc
printf 'TARGET: '
sha256sum -- key.asc | cut -c1-20 | sed 's/...../&-/g; s/-$//' | tr '[:lower:]' '[:upper:]'
```

Place the two screens side by side, use a large font, and compare all four
groups character by character. Do not copy, paste, retype, or photograph the
code.

The code is the first 20 characters (80 bits) of the file's SHA-256 hash. For a
given source code, producing a different file with the same code would take
about 2^80 attempts.

If any character differs, do not run GnuPG. Delete the received `key.asc` in
the target key qube, and on the sequential path also in `A-qr-staging`, then
repeat from
[Step 3: Show the QR code](#step-3-show-the-qr-code-sending-computer).
The source `key.asc` can be reused.

### Step 6: Decrypt (receiving computer)

The commands decrypt into a temporary directory and create `master.key` only
if GnuPG succeeds. In the target key qube terminal, run:

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

When GnuPG asks for the passphrase, check that the prompt window has the
target key qube's colour border, then type the passphrase from the paper,
using a keyboard that does not go through a USB qube if the computer has one. If
the passphrase is wrong or the file fails GnuPG's integrity check, GnuPG exits
with an error,
and the temporary output is removed without creating `master.key`. On success,
the last line shows `600 master.key`.

### Step 7: Clean up

Before deleting anything, check that all display, scanner, and webcam qubes
have stopped, the webcam is unplugged, and the target key qube no longer
contains `key.asc`.

On the sending computer, in the source key qube directory containing `key.asc`,
run:

```bash
rm -f -- key.asc
```

On the sequential path, also run this on the receiving computer in an
`A-qr-staging` terminal:

```bash
rm -f -- ~/QubesIncoming/seqs-qr-scanner/key.asc
```

Both commands print nothing. Check that the files are gone. Destroy the paper
only after step 6 showed `600 master.key`.

## Further reading

The official Qubes documentation covers the underlying concepts in more depth:
[USB qubes](https://doc.qubes-os.org/en/latest/user/advanced-topics/usb-qubes.html),
[USB devices](https://doc.qubes-os.org/en/latest/user/how-to-guides/how-to-use-usb-devices.html),
[PCI devices](https://doc.qubes-os.org/en/latest/user/how-to-guides/how-to-use-pci-devices.html),
and [disposable customization](https://doc.qubes-os.org/en/development/user/advanced-topics/disposable-customization.html).
