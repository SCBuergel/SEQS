# Secure QR transfer, short form

This is the short form of [Reasonably secure air-gapped data transfer](secure-qr-transfer.md)
for the common hardware case: a receiving computer whose USB sockets all
belong to one USB controller, on the sequential path. It copies one small
secret file, such as a key, from one Qubes OS computer to another with no
network or USB stick between them: the sending computer shows the encrypted
file as a QR code, and a webcam on the receiving computer reads it. The
original file must be at most about 1,600 bytes. The full guide covers the
reasoning, computers with several USB controllers, and the
dedicated-controller path.

## What happens, and what you accept

The secret travels in two pieces that must never meet on the camera side:

- The **encrypted file** goes from the source key qube to an offline display
  qube, as a QR code to the webcam, through offline camera qubes on the
  receiving computer, and into the target key qube.
- The **passphrase** goes from the source key qube's screen onto paper, and
  from the paper through your keyboard into the target key qube.

The webcam, the QR data, and every qube that handles them are treated as
possibly hostile. The procedure holds only while you do the steps in order,
so that nothing on the camera side runs when you type the passphrase. If the
camera side is hostile and the passphrase reaches it anyway, the secret is
lost and nothing in this procedure will tell you.

On the sequential path the webcam borrows the USB controller that normally
belongs to `sys-usb` (the qube that owns the computer's USB hardware, through
which a USB keyboard and mouse reach dom0). A dom0 script stops `sys-usb`,
gives the controller to a webcam-only USB qube, scans, and powers the
computer off; you then remove all power, and `sys-usb` gets the controller
back at the next boot. Accept these limits before you set anything up:

- **A USB keyboard or mouse makes `sys-usb` part of what you trust.**
  Whatever the webcam leaves in the controller and survives the power removal
  reaches `sys-usb` at the next boot, and `sys-usb` can type or click in dom0
  as your USB keyboard or mouse would. The worst case is control of the whole
  receiving computer, not only a lost passphrase. A built-in laptop keyboard
  at least keeps the passphrase away from `sys-usb`; one that is itself USB
  would fail setup step 1.
- **Internal USB devices stay switched off in the firmware**, for every
  later transfer: a built-in webcam, Bluetooth, a fingerprint or card reader.
  Only the webcam may be on the controller during the scan.
- **You must be able to remove all power** after the scan: unplug the power
  cable and take out the battery. A laptop with a built-in battery is the
  weakest point of this path, and this guide cannot say how much it weakens
  it.

If one of these is not acceptable for your secret, use the
[dedicated-controller path](secure-qr-transfer.md#choose-the-hardware-isolation-path)
of the full guide, which needs a USB controller of its own.

## What you need

The **sending computer** needs a trusted offline **source key qube** that
holds the file, called `master.key` below, and SEQS with the `qr-display`
qube selected. That creates `D-qr-display`, an offline disposable (a qube
whose changes are discarded when it shuts down) that only ever shows
encrypted data.

The **receiving computer** needs Qubes OS 4.3, a trusted offline **target key
qube** without a `master.key`, a USB webcam that reads QR codes from a screen
and appears as a single USB device, and SEQS with `qr-camera` and
`qr-staging` selected after the setup below. That creates the offline camera
qubes: `sys-usb-webcam`, which owns the controller during a scan,
`A-qr-camera` and `seqs-qr-scanner`, the disposable template and the
disposable started from it that runs the scanner, and `A-qr-staging`, which
keeps the encrypted file while the computer is off.

A key qube is offline when its NetVM and its default disposable (the qube in
which it opens files, normally a networked one) are both explicitly none. In
a dom0 terminal on each computer, run this with the name of its key qube:

```bash
qvm-prefs <key-qube> | grep -E '^(netvm|default_dispvm) '
```

Both lines must show `-` and then `None`; a `D` means the value is only
inherited and changes with the global default. Set a line that differs with
`qvm-prefs <key-qube> netvm none` or `default_dispvm none`. The `vault` qube
that the Qubes installer creates needs the second: it has no NetVM but
inherits the default disposable. SEQS does not create key qubes.

On both computers, cover the lens of every built-in camera, or switch it off
with a hardware switch, for the whole transfer. Disabling a camera in
software is not enough: it stays in `sys-usb`, the qube you are guarding
against. Use the QR webcam for nothing else, and plug it in only when step 4
of the transfer says so; at any other time it, too, lands in `sys-usb`.

## Set up the receiving computer once

These steps make sure the webcam will be alone on the controller, tell SEQS
which controller that is, build the camera qubes, and test the whole
transfer without a secret.

### 1. Switch off the internal USB devices

In a dom0 terminal (Qubes menu, gear icon, then Terminal), run:

```bash
sleep 20; qvm-usb
```

During the 20 seconds, unplug every external USB device, including the
keyboard and mouse. Everything still listed is internal; reconnect the
keyboard and mouse. Switch each listed device off in the firmware settings
(the BIOS or UEFI setup), then repeat the command. Continue when it lists
nothing. If a device cannot be switched off, this short form does not apply;
the full guide's
[device lookup](secure-qr-transfer.md#find-the-internal-usb-devices) says
when the sequential path still works.

While in the firmware settings of a laptop whose battery you cannot remove,
also switch off every option that keeps USB powered while the computer is
off, often called `Always On USB` or `USB charging`. This guide has not
tested whether that cuts all power.

### 2. Find the USB controller

In a dom0 terminal, run:

```bash
qvm-pci list --with-sbdf | grep -i usb
```

Ignore lines whose description contains `NHI`; they are Thunderbolt host
interfaces. Exactly one line should remain, and its last column should show
`sys-usb`. Its first column, without the `dom0:` prefix, is the controller's
BDF (bus-device-function, its PCI address in the form SEQS expects), for
example `00_14.0`; write it down. If more than one line remains, the
computer has several controllers: find the BDF of the socket you will use
with the full guide's
[socket lookup](secure-qr-transfer.md#find-the-controller-of-the-webcams-socket),
then continue with step 3 here.

### 3. Check the strict reset

In a dom0 terminal, run this with the BDF written with a colon in place of
the underscore:

```bash
cat /sys/bus/pci/devices/0000:00:14.0/reset_method
```

If it prints one or more words, such as `flr` or `pm`, note `False` for the
setting below. If it prints nothing or reports `No such file or directory`,
note `True`: the controller then moves to the webcam qube without a reset,
and whatever `sys-usb` left in it, possibly traces of earlier keyboard input,
reaches the camera side.

### 4. Configure and build

The sending computer needs no configuration change. In a terminal in the
receiving computer's repository qube (the qube holding your SEQS checkout),
edit `salt/pillar/seqs/config.sls` so that these three lines hold your BDF
and the reset result:

```jinja
{%- set webcam_usb_mode = 'sequential' %}
{%- set webcam_usb_controller = '00_14.0' %}
{%- set webcam_usb_no_strict_reset = False %}
```

SEQS builds only committed changes, so commit the edit:

```bash
cd ~/SEQS && git diff salt/pillar/seqs/config.sls && git commit -m 'Configure QR webcam controller' salt/pillar/seqs/config.sls
```

The diff must show only those lines. If the repository qube is a disposable,
repeat the edit before every later SEQS run on this computer.

Then run SEQS from dom0 on each computer as for a
[first install](../README.md) or an [upgrade](upgrading.md), selecting
`qr-camera,qr-staging` on the receiving computer and `qr-display` on the
sending computer. The build stops with
`Configured controller is not attached to sys-usb` if the BDF is wrong, and
it prints a line starting with `Air gap verified:` naming `A-qr-camera` and
`A-qr-staging` on the receiving computer, and `A-qr-display` and
`D-qr-display` on the sending computer, which it checked to have no NetVM
and no default disposable. The scan script repeats that check for all camera
qubes before every scan. To verify the policies and the controller assignment
without relying on the build output, run the checks for both computers under
the full guide's [Check the setup](secure-qr-transfer.md#check-the-setup).

### 5. Rehearse with a throwaway file

The scan script is tested mainly against mocked Qubes commands, and a
failure costs nothing while no secret is involved. In a terminal in the
source key qube, run:

```bash
mkdir ~/qr-rehearsal && cd ~/qr-rehearsal && head -c 1000 /dev/urandom > master.key
```

In a terminal in the target key qube, run `mkdir ~/qr-rehearsal`. Then do
the whole [transfer](#transfer-a-file) in `~/qr-rehearsal` on both
computers, with a sheet of paper that you destroy at the end. It succeeds
only if the script lists nothing unexpected in `sys-usb`, starts the webcam
qube, and powers off after the scan; exactly one copy dialog appears on the
receiving computer and the received folder holds only `key.asc`; all four
fingerprint groups match; and decryption ends with `600 master.key`. Find
the cause of anything else before you transfer a real secret. Afterwards,
run `rm -rf ~/qr-rehearsal` in both key qubes.

## Transfer a file

Four rules hold from the first step to the last:

- Keep the paper, and any screen showing the passphrase, out of every
  camera's view, and keep the webcam unplugged, with its lens covered, until
  step 4 says to plug it in. A hostile webcam may record whenever it has
  power.
- Qubes asks in a dom0 dialog before a qube copies files to another qube.
  Accept only the copy dialogs the steps expect. Cancel any other dialog
  from `D-qr-display` or a camera qube, and treat it as a fingerprint
  mismatch, as step 5 describes.
- If a received folder holds anything but `key.asc`, do not open it; treat
  it as a mismatch too.
- Do not type the passphrase while any camera qube runs or the webcam is
  plugged in.

### Step 1: Encrypt (sending computer)

Take a fresh sheet of paper. In a terminal in the source key qube, go to the
directory containing `master.key` and run:

```bash
(
set -euo pipefail
trap 'echo "ERROR: encryption failed; no key.asc was created" >&2' ERR
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
)
```

It prints `PASSPHRASE:` and 26 characters, each A-Z or 2-7, and creates
`key.asc`. Write the passphrase on the paper. If the last line starts with
`ERROR`, discard that passphrase, check that you are in the right directory
and no old `key.asc` is there, and run the block again. Then close this
terminal window completely; its scrollback keeps the passphrase.

### Step 2: Copy the encrypted file to the display qube (sending computer)

Start `D-qr-display` first, so that its start-up cleanup cannot delete the
copy: choose `Display QR (offline)` under `D-qr-display` in the Qubes menu,
which opens a terminal in it; if the menu lacks it, run
`qvm-run D-qr-display x-terminal-emulator` in a dom0 terminal and leave that
dom0 terminal open. In a new terminal in the source key qube, in the
directory containing `key.asc`, run:

```bash
qvm-copy key.asc
```

In the dialog, choose `D-qr-display`. Keep the source `key.asc`; step 5
compares against it.

### Step 3: Show the QR code (sending computer)

Put the paper away. In the `D-qr-display` terminal, run this with the name of
your source key qube:

```bash
cd ~/QubesIncoming/<source-key-qube>
qrencode -l M -t ansiutf8 < key.asc
```

You should see one complete square with a light border on all sides and no
wrapped lines; maximize the terminal and shrink the font (usually `Ctrl+-`)
until it fits. If `qrencode` reports that it failed to encode the input, the
file is too big; stop. Keep `D-qr-display` running until the scan is done,
then shut it down.

### Step 4: Scan (receiving computer)

Close every window that shows a secret, save all other work, and be ready to
unplug the USB keyboard and mouse quickly. In a dom0 terminal, run:

```bash
sudo /usr/local/sbin/seqs-qr-sequential
```

The script checks the camera qubes and lists the USB devices in `sys-usb`.
Only your keyboard and mouse may be listed. If anything else is, an internal
device has been switched back on, for example by a firmware update: press
`Enter` instead of typing `START`, switch it off as in setup step 1, and run
the script again. If the script reports an old `key.asc` in `A-qr-staging`,
delete `~/QubesIncoming/seqs-qr-scanner` in that qube, shut it down, and run
the script again. If it reports that `sys-usb-webcam` is already running, it
powers off, because that qube has had the shared controller: remove all power
as in item 4 below, start the computer, and run the script again. Otherwise
type `START` in capital letters, then:

1. Unplug the keyboard and mouse at once; the script stops `sys-usb` after
   10 seconds. If you are too slow, press `Ctrl+C` within those seconds and
   start over; nothing has changed yet. A keyboard or mouse still plugged in
   when the webcam qube starts ends up in it with the webcam, the script
   finds more than one device, refuses to scan, and powers off. Use that
   keyboard or mouse again only if you accept that the webcam may have
   altered its firmware; otherwise replace it.
2. When the screen says `NORMAL USB BACKEND STOPPED`, plug in only the
   webcam, within 30 seconds, and point it at the QR code. The script scans
   for up to 3 minutes. If it reports that `sys-usb-webcam` did not start
   because the controller cannot be reset, it powers off after 60 seconds:
   do items 3 and 4, then set `webcam_usb_no_strict_reset = True` (setup
   step 3 says what that gives up), commit, build again, and repeat from
   step 2.
3. Unplug the webcam when the script reports a completed copy or an error.
   Do not reconnect the keyboard or mouse.
4. The computer powers off either way. Unplug the power cable and remove the
   battery if you can. Then, with the webcam still unplugged, reconnect
   power, keyboard, and mouse, and start the computer.

After boot, start the target key qube. In a terminal in `A-qr-staging`, run:

```bash
cd ~/QubesIncoming/seqs-qr-scanner && ls -A
```

If `cd` fails or nothing is listed, the scan failed: shut down `D-qr-display`
and repeat from step 2 with the kept `key.asc`. If only `key.asc` is listed,
copy it, without opening it, in the same terminal:

```bash
qvm-copy key.asc
```

In the dialog, choose the target key qube; accept only this one dialog. When
the copy has finished, run `rm -f -- key.asc` in the same terminal, then shut
down `A-qr-staging` in the Qubes Domains widget.

### Step 5: Compare fingerprints (both computers)

Check that the webcam is unplugged and `A-qr-staging` has stopped. In a
terminal in the target key qube, with `<target-dir>` as the directory where
`master.key` should end up, run:

```bash
ls -A ~/QubesIncoming/A-qr-staging
mv -- ~/QubesIncoming/A-qr-staging/key.asc <target-dir>/
cd <target-dir>
printf 'TARGET: '
sha256sum -- key.asc | cut -c1-20 | sed 's/...../&-/g; s/-$//' | tr '[:lower:]' '[:upper:]'
```

`ls` must list only `key.asc`. On the sending computer, in a new terminal in
the source key qube, in the directory containing the kept `key.asc`, run:

```bash
printf 'SOURCE: '
sha256sum -- key.asc | cut -c1-20 | sed 's/...../&-/g; s/-$//' | tr '[:lower:]' '[:upper:]'
```

Each prints four groups of five characters, such as
`7A91C-24D8E-6F032-B5A10`: the first 80 bits of the file's SHA-256 hash, too
many for anyone to forge a matching file and few enough to compare by eye.
Put the screens side by side and compare every character; do not copy,
retype, or photograph the code.

If any character differs, do not decrypt: the comparison is what keeps GnuPG
in the key qube from reading a file the camera side altered. A bad scan is
unlikely, because QR codes carry error correction; assume that the camera
side changed the file on purpose and is hostile. Delete the received
`key.asc` and any other received file without opening them. Retry only once
you know the cause. The hostile side has also held the controller that
`sys-usb` got back at boot, so with a USB keyboard or mouse the receiving
computer itself is now in doubt. To retry, shut down `D-qr-display` and
repeat from step 2 with the kept `key.asc`.

### Step 6: Decrypt (receiving computer)

In the target key qube terminal, in `<target-dir>`, run:

```bash
(
set -euo pipefail
trap 'echo "ERROR: decryption failed; master.key was not created" >&2' ERR
umask 077
test ! -e master.key

tmpdir=$(mktemp -d .master-key-import.XXXXXX)
trap 'rm -rf -- "$tmpdir"' EXIT HUP INT QUIT TERM
gpg --no-symkey-cache --decrypt --output "$tmpdir/master.key" -- key.asc

test ! -e master.key
mv -T -- "$tmpdir/master.key" master.key
rmdir -- "$tmpdir"
trap - EXIT HUP INT QUIT TERM
trap 'echo "ERROR: master.key was created, but a final step failed" >&2' ERR
chmod 600 master.key
rm -f -- key.asc
stat --format='%a %n' master.key
)
```

When GnuPG asks for the passphrase, check that the prompt window has the
target key qube's colour border; dom0 draws it, so no other qube can fake it.
Type the passphrase from the paper, on the built-in keyboard if the computer
has one. The last line must show `600 master.key`. A wrong passphrase gives
an `ERROR` line and no `master.key`; run the block again.

### Step 7: Clean up

In the source key qube directory containing `key.asc`, run `rm -f -- key.asc`
and check that the file is gone. Then burn the paper, or cut it with a
cross-cut shredder. Leftover encrypted copies cannot be ruled out in
snapshots or on SSDs, and any of them opens with the passphrase, which is
why the paper must go.
