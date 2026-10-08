# Reasonably secure air-gapped data transfer

This guide copies one small secret file, such as a key, from one Qubes OS
computer to another without a network cable or USB stick between them. The
sending computer shows the encrypted file as a QR code on its screen, and a
webcam on the receiving computer reads it. The encrypted file must fit in a
single QR code, which limits the original file to about 1,600 bytes; larger
files, which would need several codes, are not supported.

## How the transfer works

The secret travels in two separate pieces. Most of the later steps exist to
keep them apart; the rest check that the file arrived unchanged and clean up.
The numbers in the list below match the steps of the transfer procedure:

```text
                 sending computer                 receiving computer
Encrypted file:  source key qube -> D-qr-display  --QR code-->  webcam
                                                                -> camera qube
                                                                (-> staging qube,
                                                                 on one setup)
                                                                -> target key qube

Passphrase:      source key qube -> written on paper -> typed on the
                 keyboard into the target key qube
```

1. The source key qube encrypts the file with
   [GnuPG](https://www.gnupg.org/) (a standard encryption program) using a
   random one-time passphrase, which you write on paper.
2. You copy the encrypted file to a display qube on the sending computer.
3. The display qube shows the encrypted file as a QR code.
4. On the receiving computer, a webcam and a camera qube read the QR code and
   pass the encrypted file to the target key qube. Then you unplug the webcam
   and shut down the camera qubes.
5. You compare a short fingerprint (a code calculated from the encrypted file)
   on both screens to check that the file arrived unchanged.
6. You type the paper passphrase into the target key qube, which decrypts the
   file.
7. You delete the leftover encrypted copies and destroy the paper.

The camera side only ever handles encrypted data, and the passphrase is typed
only after the camera side is shut down. As long as those two conditions hold,
and the trusted parts listed below are not compromised, an attacker who can
only watch needs to control both the camera side and the keyboard side to read
the secret. The next section says what those two sides are, and why a USB
keyboard weakens this protection.

## What you must trust

The procedure protects the secret only if these parts behave correctly:

- the source and target key qubes;
- dom0 (the Qubes administrative domain that controls all other qubes) on both
  computers;
- Qubes OS itself;
- on a computer where you type on a USB keyboard, `sys-usb` and that keyboard,
  and likewise a USB mouse, because they can type or click in dom0, as
  explained below; and
- you, following the steps in order.

Everything else is treated as possibly hostile, and it falls into two sides:

- The **camera side** sees the encrypted file: the webcam, the QR data, and
  every qube that handles them. These are the qube that displays the QR code,
  the qube that owns the webcam's USB hardware, the qubes that scan the code,
  and, on one of the two hardware setups described later, a qube that stores
  the encrypted file while the receiving computer is switched off.
- The **keyboard side** sees the passphrase: normal `sys-usb`, the USB
  keyboard, its firmware, their controller, and any camera attached to
  `sys-usb`. This side is treated as possibly hostile in the sense that it may
  watch what you type; a USB keyboard path that types on its own is covered by
  the trust list above, as explained below.

The secret stays safe only while at most one side is hostile. If both are, the
passphrase and the encrypted file meet, the secret is lost, and nothing in this
procedure will tell you. No second layer of encryption protects against this:
the split holds only because you perform the steps in the order given, so that
nothing on the camera side is running when the passphrase is typed.

A keyboard side that goes through a USB qube can do more than watch. With a USB
keyboard, `sys-usb` reads the physical keys and passes each key press to dom0,
and dom0 cannot tell a real key press from one that `sys-usb` invents. A
compromised `sys-usb` can therefore type into dom0 or a key qube, for example a
command that copies `master.key` to a qube with network access. It needs
neither the camera side nor the passphrase. A malicious USB keyboard can do the
same through `sys-usb`. A USB mouse gives `sys-usb` the weaker power to click,
for example on dialogs, which is still more than watching. This applies on both
computers: on the sending computer, `sys-usb` can type into the source key
qube, and on the receiving computer into the target key qube. The QR transfer
does not create this risk; with a USB keyboard, `sys-usb` can take over the
whole Qubes system at any time. But it means that `sys-usb` is then a single
point of failure, not an independent second side.

The two-side protection therefore holds in full only if you type on keyboards
that do not go through a USB qube, such as a built-in laptop keyboard that is
not internally USB. Its key presses reach dom0 directly, so the keyboard side
becomes dom0, which you already trust. With a USB keyboard, the split still
protects against parts that can only watch: for example, a camera that sees the
paper but never the encrypted file, or a camera-side qube that gets the
encrypted file but never the passphrase. The secret, like the rest of your
Qubes system, then also depends on `sys-usb` not being compromised.

Even against parts that only watch, the two sides can fail together more
easily than it seems. They share the USB attack surface, the room, and possibly
the attacker, and any USB device ever plugged into `sys-usb` could have
compromised it.

The transfer leaves copies of the encrypted file in several qubes. Deleting
them at the end does not guarantee that they are gone from snapshots, swap,
backups, or SSD storage. Any leftover copy can be decrypted with the passphrase
on the paper, which is why the procedure ends by destroying the paper.

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
shuts down. It starts from `A-qr-display`, an app qube that SEQS creates at the
same time and that serves as its disposable template (the qube a disposable is
copied from). It is not a TemplateVM.

The sending computer needs no webcam and no USB controller check. Its built-in
cameras must still be covered during each transfer, as the transfer procedure
says.

The **receiving computer** needs:

- a trusted **target key qube** that does not yet contain a `master.key`;
- a USB webcam that can read a QR code from the sending computer's screen and
  shows up as a single USB device, which the setup checks confirm;
- the hardware check in the next three sections; and
- SEQS installed with the `qr-camera` qube selected, plus `qr-staging` if the
  hardware check leads you to the weaker of its two setups. This creates
  `A-qr-camera`, the offline disposable template for the camera disposables
  that run `zbarcam` (the QR scanner program), and `sys-usb-webcam`, which
  handles only the webcam.

Both key qubes should be offline: a key qube with a NetVM (the qube that gives
it network access) keeps the plaintext `master.key` one software bug away from
the network. The `vault` qube that the Qubes installer creates by default has
no NetVM and is a suitable choice on either computer.

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
or type the passphrase, and it has both halves on its own.

For the whole transfer, no camera on either computer other than the QR webcam
may be able to see the sending computer's screen, the paper, or your hands on
the keyboard. Cover the lens of every built-in camera with tape or its slider,
or switch it off with a hardware switch that cuts its power. Detaching the
camera in the Devices widget or disabling it in software is not enough: the
camera stays in `sys-usb`, which is the qube you are guarding against.

<a id="start-here-determine-which-path-the-machine-qualifies-for"></a>

## Choose the hardware-isolation path

This section has three possible outcomes for the receiving computer: the
dedicated-controller path, the sequential path if its extra requirements hold,
or neither, in which case you change the hardware before going on. Only the
dedicated-controller path separates the webcam and keyboard in hardware.

The **dedicated-controller path** is available if a webcam socket is on a
controller that carries none of these:

- a keyboard or mouse;
- the disk or USB device Qubes boots from or stores data on;
- a USB anti-evil-maid (AEM, a Qubes boot-integrity check) or boot device;
- a hardware wallet, security key, phone, or backup drive; or
- any other device you need to operate or recover the computer.

The socket must also lead only to that controller. A USB 3 socket has separate
wires for USB 2 and USB 3, and on some computers they lead to different
controllers; the USB-C sockets of recent Intel computers typically send USB 3
to one controller and USB 2 to the controller that also serves the keyboard.
On such a split socket the webcam, not you, chooses which wires it uses. A
hostile webcam can connect over the USB 2 wires as well, and that connection
lands in `sys-usb`. The check after the build does not reveal this, because
it shows only the connection the webcam chooses to present. A split socket
therefore never qualifies for this path.

`sys-usb-webcam` then owns that controller permanently, so anything plugged
into any of that controller's sockets from then on, and any internal device on
it, is handled by the qube this guide treats as hostile, or is unusable while
that qube is stopped. The separation also relies on the IOMMU (the VT-d or
AMD-Vi feature Qubes needs to assign PCI devices); leave it enabled in the
firmware settings. The controller must also support a strict reset, which
clears its state when it moves between qubes; the lookups check this first.

A built-in keyboard that is genuinely not connected over USB does not rule out a
controller, because it uses no USB controller. Some built-in keyboards are
wired internally over USB and do rule it out. Before relying on a built-in
keyboard, check that it does not use USB, as described in
[Check whether a built-in keyboard uses USB](#check-whether-a-built-in-keyboard-uses-usb).

The **sequential path** is a weaker fallback for computers where no socket
qualifies for the dedicated-controller path. It has requirements of its own,
explained below. It does not separate the devices in hardware. Instead, a dom0
script stops normal `sys-usb`, lends the controller to the webcam for one scan,
and powers the computer off before the keyboard is used again. It relies on an
assumption that the dedicated path does not need: that cutting power clears
anything the webcam could have left behind in the controller or other
hardware. A restart does not qualify, and malicious firmware that survives
power loss defeats it. A split socket is acceptable on this path if `sys-usb`
owns both of its controllers, which the lookups below show: `sys-usb` is
stopped during the scan, so no qube drives the other controller.

Unlike the dedicated path, it can use a controller that does not support a
strict reset, which is common for the chipset controller of Intel computers.
Without a strict reset, the controller reaches `sys-usb-webcam` still holding
state that `sys-usb` left in it, possibly traces of earlier keyboard input.
The camera side has no network; it could pass such traces on only through the
scanned file, which stays in offline qubes, or to the webcam itself. The
reverse direction needs no reset, because the controller returns to `sys-usb`
only after the power-off.

The path also requires that every device on that controller other than the
webcam can be unplugged or switched off in the firmware settings (the BIOS or
UEFI setup). This includes internal USB devices such as a built-in webcam,
Bluetooth, a fingerprint reader, or a card reader, and a built-in keyboard that
is internally wired over USB. Switching a device off in Qubes or Linux, for
example with `rfkill`, is not enough, because the device stays on the
controller. If such a device remains, the script finds more than one USB device
only after the device has shared a qube with the webcam; it then refuses to
scan and powers off. The next section shows how to find these devices before
you build.

Before choosing the sequential path, check whether you can remove all power
from the receiving computer after the scan. A normal power-off can leave parts
of the computer on standby power, so the sequential path expects you to
unplug the power cable and take out the battery. This guide does not specify a
tested minimum time without power. If the battery is built in, the assumption
is weaker still, and this guide cannot say how much. Some laptops have a
firmware setting that disconnects the built-in battery until a charger is
connected, such as "Disable built-in battery" on Lenovo ThinkPads. Such a
setting may allow full power removal, but this guide has not tested whether it
cuts all power.

Even with all power removed, the sequential path remains exposed to malicious
state that survives in controller firmware, a webcam attack that escapes
through Qubes itself or qrexec, a compromised dom0, a webcam left plugged in at
the next boot, and malicious keyboard or controller firmware. Because the
webcam uses a controller that `sys-usb` owns at all other times, anything it
leaves behind that survives the power-off reaches `sys-usb`, which with a USB
keyboard can type into dom0.
The worst case is therefore control of the whole receiving computer, not only
a leaked passphrase. A dedicated controller avoids reusing hardware the webcam
has touched.

The lookups in the next section decide for each computer, but some layouts are
typical. On Intel laptops and NUCs, one controller usually serves the USB-A
sockets, the internal USB devices such as a built-in webcam, Bluetooth, or a
fingerprint reader, and often your USB keyboard, while the USB-C sockets are
split. The dedicated-controller path then needs an added controller: a PCIe
USB card in a desktop, or an M.2 USB controller card in a free M.2 slot of a
NUC; most laptops have no slot for one. AMD laptops often have two or three USB
controllers in the processor and sometimes offer a dedicated controller without
extra hardware. The sequential path is usually possible on a NUC, which has no
battery, if its internal USB devices can be switched off; on a laptop, the
built-in battery weakens it. Whether a controller supports a strict reset
varies, and the chipset controller of Intel computers often does not; such a
controller cannot serve the dedicated-controller path but can still serve the
sequential path.

If the computer qualifies for neither path, or the sequential path's limits
are not acceptable for your secret, stop here and add a USB controller card to
get a dedicated controller.

## Find the webcam's USB controller

To apply the rules above, you need to know which controller the webcam's
socket uses, whether that controller supports a strict reset, which
controllers carry required and internal devices, and, for the
dedicated-controller path, whether a socket is split. Do not use the webcam
for this: it would be handled by `sys-usb`, the keyboard's qube, which is what
the whole setup avoids. Instead, use small USB devices you already trust as
test devices: a USB 2 device, such as most mice, and, for one check, a USB 3
device, such as most recent USB sticks. For USB-C sockets, use USB-C devices or
simple USB-C adapters.

### List the USB controllers

In a dom0 terminal of the receiving computer, run:

```bash
qvm-pci list --with-sbdf | grep -i usb
```

On a typical Intel laptop, the output looks like this (example values, with
the descriptions shortened):

```text
dom0:00_0e.0  0000:00:0e.0  PCI_USB: Intel ... Thunderbolt 4 USB Controller  sys-usb (attached: no-strict-reset=True)
dom0:00_0e.2  0000:00:0e.2  PCI_USB: Intel ... Thunderbolt 4 NHI #0          sys-usb (attached: no-strict-reset=True)
dom0:00_0e.3  0000:00:0e.3  PCI_USB: Intel ... Thunderbolt 4 NHI #1          sys-usb (attached: no-strict-reset=True)
dom0:00_14.0  0000:00:14.0  PCI_USB: Intel ... PCH USB 3.2 xHCI Host Controller  sys-usb (attached: no-strict-reset=True)
```

The first column is the controller's BDF (bus-device-function), its real PCI
address. SEQS needs it without `dom0:`, such as `00_14.0`. The second column
is the same address in the form Linux uses in dom0. The last column shows which
qube uses the controller. `no-strict-reset=True` there is how the Qubes
installer assigns USB controllers to `sys-usb`; it says nothing about whether
a controller supports a strict reset, which the next subsection checks.

Lines whose description contains `NHI` are Thunderbolt host interfaces, not
USB controllers with sockets of their own; leave them out when you count
controllers. A USB-C socket with Thunderbolt can also reach the NHI, which is
one more reason such a socket never qualifies for the dedicated-controller
path. On the sequential path it does not matter, because `sys-usb`, which owns
the NHI, is stopped during the scan. The example therefore shows two USB
controllers: a Thunderbolt USB controller and the chipset (PCH) controller.

If every line shows `sys-usb`, a split socket is acceptable on the sequential
path, as explained above, without further checks.

### Check which controllers support a strict reset

The dedicated-controller path needs a controller that supports a strict
reset. The sequential path does not, but the configuration must say whether to
use one, because a controller that cannot be reset fails only when
`sys-usb-webcam` starts. Check every USB controller now, before you invest in
the other lookups. For each USB controller in the list, not the NHI lines, run
this in dom0 with the address from the second column:

```bash
cat /sys/bus/pci/devices/0000:00:14.0/reset_method
```

If it prints one or more reset methods, such as `flr` or `pm`, the controller
probably supports a strict reset. If it reports `No such file or directory` or
prints nothing, it does not, and that controller cannot serve the
dedicated-controller path. Write down the result for each controller; on the
sequential path, the configuration uses it. This file is a good indication but
not a guarantee; a check after the build confirms the hand-over before you use
a secret.

### Choose how far to look

How many of the following lookups you need depends on the list:

- **One USB controller.** If the list shows exactly one USB controller, used by
  `sys-usb`, and you need at least one USB device for normal use, such as a USB
  keyboard, mouse, security key, or drive, the dedicated-controller path is
  impossible without adding a controller card. If the sequential path's limits
  are acceptable for your secret, it is your path, and its controller is that
  BDF. Run only
  [Find the internal USB devices](#find-the-internal-usb-devices), then
  [Decide which path applies](#decide-which-path-applies).
- **Several USB controllers, all used by `sys-usb`.** You can either look for
  a dedicated controller with the full route, or take the short route straight
  to the sequential path. On laptops like the example, a dedicated controller
  is rare: the USB-C sockets are usually split, and the chipset controller
  usually carries the internal devices and any USB keyboard or mouse. The
  short route accepts the sequential path's weaker protection without checking
  whether this computer could do better, so take the full route if you would
  do without USB devices on a controller, or add a controller card, to get a
  dedicated one. On the short route, run
  [Find the internal USB devices](#find-the-internal-usb-devices); then run
  [Record the device paths](#record-the-device-paths) and the three lookups
  after it for the one socket you will use for the webcam only; skip
  [Check candidate sockets for a split](#check-candidate-sockets-for-a-split);
  and finish with [Decide which path applies](#decide-which-path-applies).
- **Otherwise,** take the full route: run every subsection below.

On the short and full routes, record the results in a table like the
following, on paper or in a text file; none of it is secret. The lookups fill
in the columns from left to right: the device path (where a device sits on a
controller), the bus speed, the virtual address (the name `sys-usb` uses for
the controller), and the BDF. Each is explained where you look it up. In this
full-route example, the rear USB-A socket shares controller `00_14.0` with the
USB keyboard and the internal Bluetooth, while the socket on an added PCIe card
has controller `03_00.0` to itself and is not split:

| Socket or device                    | Device path | Bus speed | Virtual address | BDF       |
|-------------------------------------|-------------|-----------|-----------------|-----------|
| Rear USB-A, USB 2 test device       | `4-1`       | `480`     | `0000:00:09.0`  | `00_14.0` |
| USB keyboard                        | `4-2`       | `480`     | `0000:00:09.0`  | `00_14.0` |
| Internal: Bluetooth                 | `4-10`      | `480`     | `0000:00:09.0`  | `00_14.0` |
| PCIe card socket, USB 2 test device | `8-1`       | `480`     | `0000:00:0b.0`  | `03_00.0` |
| PCIe card socket, USB 3 test device | `9-1`       | `5000`    | `0000:00:0b.0`  | `03_00.0` |

### Find the internal USB devices

Internal USB devices, such as a built-in webcam, Bluetooth, a fingerprint
reader, or a card reader, cannot be unplugged. Find them first with all
external USB devices removed. In a dom0 terminal, run:

```bash
sleep 20; qvm-usb
```

During the 20 seconds, unplug every external USB device, including the
keyboard and mouse. Every device that is still listed when the output appears
is internal. Its identifier, such as `sys-usb:4-10`, contains its device path
`4-10`, explained under
[Record the device paths](#record-the-device-paths). Write down its path and
name, then reconnect the keyboard and mouse.

On the sequential path, every internal device on the controller you will use
must be switched off in the firmware settings, and must stay switched off for
every later transfer: the script counts the devices at each scan, but only
after they have shared a qube with the webcam. Switch off every internal USB
device that you can do without, then repeat the check. If the repeated check
lists nothing at all, you do not need to place any internal device on a
controller. Otherwise, the remaining devices must be on a controller other
than the one you will use; on the short route, include their bus numbers in
the bus lookups.

### Check whether a built-in keyboard uses USB

This check decides whether a built-in keyboard rules out a controller for the
dedicated-controller path, and whether the keyboard bypasses `sys-usb`, which
[What you must trust](#what-you-must-trust) explains. Skip it if the receiving
computer has no built-in keyboard. On the short route it is optional: a
built-in keyboard that uses USB stays listed by the internal-device check and
rules out its controller there.

To check, confirm that the built-in keyboard keeps working while `sys-usb` is
stopped. Your USB mouse and keyboard stop working during this check, so save
your work first. In a dom0 terminal, run:

```bash
qvm-shutdown --wait sys-usb
```

When the command returns, type a few characters into the same terminal with
the built-in keyboard. If they appear, the keyboard does not use USB and does
not rule out any controller; restart the USB qube with:

```bash
qvm-start sys-usb
```

If nothing appears, the built-in keyboard goes through `sys-usb`. It is one of
the internal devices you recorded; treat it as a required device on its
controller. You now have no way to type. Press the power button briefly to
shut the computer down, or hold it if that does nothing. `sys-usb` starts
automatically at the next boot.

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

Leave the keyboard, boot drive, and other required USB devices plugged in.
Plug the USB 2 test device into one socket you might use for the webcam, and in
a dom0 terminal of the receiving computer run:

```bash
qvm-usb
```

The output lists each device with an identifier such as `sys-usb:4-1`, meaning
device path `4-1` in `sys-usb`. Write down the path of the test device and of
every required device. Move the test device to the next candidate socket and
run `qvm-usb` again, until you have tried every candidate socket. On the short
route, try only the socket you will use for the webcam, with the USB 3 test
device instead if your webcam is USB 3. On the full route, you need the USB 3
test device only later, for sockets that turn out to be candidates for the
dedicated-controller path.

### Find which controller each bus uses inside `sys-usb`

Open a terminal in `sys-usb`. For each different bus number you recorded, run
this with that number, for example bus `4`:

```bash
readlink -f /sys/bus/usb/devices/usb4
cat /sys/bus/usb/devices/usb4/speed
```

The output looks like this:

```text
/sys/devices/pci0000:00/0000:00:09.0/usb4
480
```

The address just before `/usb4`, here `0000:00:09.0`, is the controller as
`sys-usb` sees it. This is a virtual address that exists only inside `sys-usb`;
never put it into the SEQS configuration. Write down which bus numbers lead to
which virtual address. Several buses often lead to the same one. The second
line is the bus speed in Mbit/s: `480` is a USB 2 bus, and `5000` or more is a
USB 3 bus.

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

Write the pair as `8086:a36d`, without `0x`.

### Find the real controller address in dom0

For each controller from
[List the USB controllers](#list-the-usb-controllers), run `lspci` in a dom0
terminal with the BDF's underscore changed to a colon:

```bash
lspci -nn -s 00:14.0
```

Look for a recorded hardware ID in square brackets at the end:

```text
00:14.0 USB controller: Intel Corporation ... [8086:a36d]
```

You now know which BDF serves each socket, each required device, and each
internal device, unless two controllers show the same hardware ID. Some
computers, AMD laptops in particular, have two identical controllers. Do not
guess between them; use the test in the next subsection instead.

Everything you read inside `sys-usb` came from a qube that Qubes does not
trust. The check after the build, where dom0 shows which qube actually
receives the webcam, confirms the controller, but it cannot detect a split
socket. For that you rely on the two test devices, whose results also come
from `sys-usb`.

### Tell identical controllers apart

Skip this subsection unless two controllers showed the same hardware ID. This
test takes one of them away from `sys-usb` for 30 seconds and shows which
devices disappear. It relies only on dom0, so it is also more trustworthy than
the lookups inside `sys-usb`.

First, in a dom0 terminal, check how `sys-usb` holds the controller you will
test, replacing `00_14.0` with one of the two BDFs:

```bash
qvm-pci list | grep 00_14.0
```

Note whether the line shows `no-strict-reset=True` next to `sys-usb`. Plug a
test device into the socket you are checking. Then run this as a single line,
with your BDF in both places, and add `--option no-strict-reset=true` after
`--persistent` in the second `qvm-pci` command if the line showed that option:

```bash
qvm-shutdown --wait sys-usb; qvm-pci detach --persistent sys-usb dom0:00_14.0; qvm-start sys-usb; sleep 30; qvm-usb; qvm-shutdown --wait sys-usb; qvm-pci attach --persistent sys-usb dom0:00_14.0; qvm-start sys-usb
```

Your USB keyboard and mouse may stop working while the line runs, because the
controller you took away may carry them; the line gives the controller back by
itself. The `qvm-usb` output in the middle lists only devices that are not on
the tested controller. It must still list at least one device that you know is
on another controller, for example a keyboard or internal device that the
lookups placed there. If it lists nothing at all, `sys-usb` did not start and
the test proves nothing. Otherwise, if the test device is missing from it, the
socket belongs to that BDF. Repeat for each socket you need to place.

This test has not been tried on every Qubes version. If `sys-usb` fails to
start at the end and your keyboard stays dead, use the recovery steps under
[Configure and build the QR qubes](#configure-and-build-the-qr-qubes): skip the
`sys-usb-webcam` command there, and run only the `sys-usb` commands.

### Check candidate sockets for a split

A socket is a candidate for the dedicated-controller path if its USB 2 test
device reached a controller that carries none of the devices listed under
[Choose the hardware-isolation path](#choose-the-hardware-isolation-path).
Skip this subsection if no socket is a candidate. Otherwise, plug the USB 3
test device into each candidate socket, run `qvm-usb` in dom0, and look up any
new bus number inside `sys-usb` as described above. If the USB 3 test device
leads to a different virtual address than the USB 2 test device in the same
socket, that socket is split and does not qualify.

The split check works only if the USB 3 test device really connects at USB 3.
For each kind of socket you checked, USB-A and USB-C, it must have reached a
bus with speed `5000` or more in at least one socket, using the adapter you
used for that kind. If it never did, the device or adapter is USB 2 only, and
its results cannot show whether a socket is split; repeat the check with a
real USB 3 device. If a test device that is known to work at USB 3 landed on a
USB 2 bus in some socket, that socket has no USB 3 connection. Only the
controller of its USB 2 bus then matters.

On the sequential path, you need this check only in two cases. If some USB
controller in the list is not used by `sys-usb`, check the socket you will use
and make sure both test devices appear under `sys-usb`. If your webcam is USB
3, use the controller that the USB 3 test device reaches in that socket.

### Decide which path applies

Decide, using the full conditions in
[Choose the hardware-isolation path](#choose-the-hardware-isolation-path):

- If a candidate socket is not split and its controller supports a strict
  reset, use the dedicated-controller path with that controller. From now on,
  plug the webcam only into that socket, and nothing else into that
  controller's sockets.
- Otherwise, the sequential path's controller is the only USB controller, or
  the controller that the USB 2 test device reached in the socket you will use
  for the webcam (the USB 3 test device, if your webcam is USB 3; most webcams
  are USB 2, which their packaging or specifications state). Use the
  sequential path with that controller if three conditions hold: `sys-usb`
  uses it; every device on it other than the webcam can be unplugged or is
  switched off, so that the repeated internal-device check lists nothing on
  it; and the power-removal requirement holds. If you picked the wrong
  controller of a split socket, the script finds no device during the scan and
  powers off without scanning.
- Otherwise, stop and change the hardware, as that section describes.

On the sequential path, skip the parts of this guide written only for the
dedicated-controller path: the keyboard-lockout recovery under
[Configure and build the QR qubes](#configure-and-build-the-qr-qubes), the
check
[Receiving computer: check the dedicated controller with the webcam](#receiving-computer-check-the-dedicated-controller-with-the-webcam),
and
[Step 4a](#step-4a-scan-on-the-dedicated-controller-path-receiving-computer).

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

Replace the example BDF with your own, without the `dom0:` prefix.
`webcam_usb_no_strict_reset = True` lets Qubes hand the controller to
`sys-usb-webcam` without a strict reset, so the controller can carry state from
one qube to the next. On the dedicated-controller path, leave it at `False`,
because that path needs a strict reset. On the sequential path, leave it at
`False` if the
[strict-reset check](#check-which-controllers-support-a-strict-reset) found a
reset method for the controller, and set it to `True` only if it found none;
the risk this leaves is described under
[Choose the hardware-isolation path](#choose-the-hardware-isolation-path).

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

Before you build on the dedicated-controller path, arrange a second way to
type in dom0, such as a built-in non-USB keyboard or a keyboard on another
controller. The build takes the controller away from `sys-usb` immediately,
and the assignment survives reboots; setting the mode back to `disabled` does
not undo it. If you chose the wrong BDF and it carries your only keyboard, the
keyboard stops working until you undo the assignment as follows:

1. Unplug every USB device except the keyboard, then restart the computer by
   pressing the power button.
2. In the GRUB boot menu, select the Qubes entry and press `e`. In the line
   that contains `rd.qubes.hide_all_usb`, delete that word, then press
   `Ctrl+X` or `F10` to boot. For this one boot, dom0 itself drives the USB
   controllers that no running qube holds, so the keyboard works in dom0.
   The Qubes
   [USB qubes](https://doc.qubes-os.org/en/latest/user/advanced-topics/usb-qubes.html)
   documentation describes this option.
3. In a dom0 terminal, replace `<BDF>` with the wrongly chosen controller and
   run:

   ```bash
   qvm-shutdown --wait sys-usb
   qvm-pci detach --persistent sys-usb-webcam dom0:<BDF>
   qvm-pci attach --persistent sys-usb dom0:<BDF>
   ```

   If the last command fails because the controller does not support a strict
   reset, repeat it with `--option no-strict-reset=true` after `--persistent`.
   The default Qubes setup assigns USB controllers to `sys-usb` this way.
4. Restart the computer normally. The GRUB edit applied only to one boot, and
   `sys-usb` owns the controller again.

Then correct `webcam_usb_controller` in the configuration, or set
`webcam_usb_mode` to `disabled` and clear the controller, and commit before the
next SEQS run.

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

If the build, or the first start of `sys-usb-webcam` in the checks below,
fails because the controller cannot be reset, the controller is unsuitable for
the dedicated-controller path; do not set `webcam_usb_no_strict_reset` to get
past it. On the sequential path, set it to `True`, commit, and run the build
again.
On the sequential path, the build also stops with `Configured controller is not
assigned to sys-usb` if the configured BDF is not a controller `sys-usb`
currently owns; recheck the BDF you recorded.

## Check the setup

Run these checks once after building and before you use any secret.

### Sending computer: check that the display qubes are offline

A qube without a NetVM is offline. The SEQS run that builds an offline qube
checks this itself and stops if the qube still has a NetVM; its output then
contains a line starting with `Air gap verified:` that names `A-qr-display`
and `D-qr-display`. If you no longer have that output, run
`qvm-prefs A-qr-display netvm` and `qvm-prefs D-qr-display netvm` in a dom0
terminal of the sending computer; both must print nothing, `None`, or `none`.

Having no network does not stop
[qrexec](https://doc.qubes-os.org/en/latest/developer/services/qrexec.html)
(the Qubes service that lets qubes copy files, open links, and send input to
each other), so SEQS also installs qrexec policies (dom0 rules deciding which
qube may use which service). Check that the display qubes may not hand links
to the browser qube. In a dom0 terminal of the sending computer, run:

```bash
sudo grep qr-display /etc/qubes/policy.d/28-browser-suppress.policy
```

You should see `deny` lines for `A-qr-display`, `@dispvm:A-qr-display`, and
`D-qr-display`.

### Receiving computer: check that the camera qubes are offline

The `Air gap verified:` line of the SEQS run covers `A-qr-camera` and, on the
sequential path, `A-qr-staging`, in the same way. If you no longer have that
output, check them with `qvm-prefs <qube> netvm` as on the sending computer.
The line does not cover `sys-usb-webcam` and `seqs-qr-scanner`, which SEQS
creates separately. In a dom0 terminal of the receiving computer, run:

```bash
qvm-prefs sys-usb-webcam netvm
```

On the sequential path, also run:

```bash
qvm-prefs seqs-qr-scanner netvm
```

Each command must print nothing, `None`, or `none`.

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

### Receiving computer: check the hand-over on the sequential path

On the sequential path only. This check confirms, with no webcam involved,
that `sys-usb-webcam` can take the controller as configured: with a strict
reset, which the earlier `reset_method` check could only indicate, or without
one if you set `webcam_usb_no_strict_reset` to `True`. Nothing hostile touches the
controller during the check, so it exposes nothing. Make sure the webcam is
unplugged. A USB keyboard and mouse on that controller stop working while the
check runs; it gives the controller back by itself. In a dom0 terminal of the
receiving computer, run this as a single line:

```bash
qvm-shutdown --wait sys-usb; qvm-start sys-usb-webcam && echo HAND-OVER-OK; qvm-shutdown --wait sys-usb-webcam; qvm-start sys-usb
```

The output must contain `HAND-OVER-OK`. If `qvm-start` instead reports that
the device cannot be reset, set `webcam_usb_no_strict_reset` to `True`, commit,
build again as described under
[Configure and build the QR qubes](#configure-and-build-the-qr-qubes), and
repeat this check.

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

On the dedicated-controller path only. This is the first time the webcam is
plugged into the receiving computer. Start `sys-usb-webcam` from the Qubes
menu, plug the webcam into its socket, and in a dom0 terminal run:

```bash
qvm-usb
```

The webcam must be listed under `sys-usb-webcam`, as a single device. Apart
from it, only the internal devices you recorded for this controller may appear
there. If any other device appears under `sys-usb-webcam`, unplug the webcam
and stop. Either the controller carries something you did not record, in which
case repeat the lookups, or the webcam itself shows up as several devices.
Some webcams contain a small hub and do this legitimately, but you cannot tell
their extra devices from an attack, and the sequential script refuses them
too; use a webcam that shows up as a single device. Every keyboard, mouse, and
other required device must still be listed under another USB qube. If any of
them moved to `sys-usb-webcam`, stop: the controller is not dedicated. Shut
down `sys-usb-webcam` and unplug the webcam when you are done.

If the webcam is instead listed under `sys-usb`, it is in a socket of the
keyboard's controller and the keyboard side has now been exposed to it. Unplug
it, shut the receiving computer down, and remove all power as described for
the sequential path under
[Choose the hardware-isolation path](#choose-the-hardware-isolation-path); a
restart is not enough. Then start the computer with only the keyboard
attached. If `sys-usb` is a disposable (in dom0, `qvm-prefs sys-usb klass`
prints `DispVM`), this discards its state, and what remains is the residual
risk the sequential path accepts: hostile state that survives power removal in
the keyboard or controller. With a USB keyboard, its worst case is control of
the whole receiving computer. Continue only if you accept that; otherwise
replace the keyboard. If `sys-usb` is not a disposable, treat it as
compromised, and with a USB keyboard the whole receiving computer as well, and
do not continue. The same rule applies whenever this happens during a
transfer.

## Transfer a file

Repeat this procedure for every transfer. Once you have done it before, the
[transfer checklist](secure-qr-transfer-checklist.md) lists the steps with
links back to this section. Before starting, take a fresh sheet of paper for
the passphrase, which will look like this:

```text
PASSPHRASE: <26 characters, each A-Z or 2-7>
```

The passphrase contains no 0, 1, 8, or 9, so O and 0 or I and 1 cannot be
confused when you read it back.

Keep the webcam unplugged, and its lens covered or facing away, until step 4
tells you to plug it in. A hostile webcam may record whenever it has power,
even while no qube uses it. Cover the lens of every built-in camera on both
computers, as described under
[Why the webcam must not share a USB controller with the keyboard](#why-the-webcam-must-not-share-a-usb-controller-with-the-keyboard).
From step 1 until the end, keep the paper, and any screen showing the
passphrase, out of every camera's view.

### Step 1: Encrypt the file (sending computer)

Open a terminal in the source key qube, go to the directory containing
`master.key`, and run:

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

The parentheses run the commands in a subshell, so that a failing command
stops the block and prints an `ERROR` line instead of closing the terminal.

The terminal prints the passphrase and creates the encrypted file `key.asc`.
Write the passphrase on the paper. If the last line starts with `ERROR`,
discard that passphrase: check that you are in the directory containing
`master.key` and that no `key.asc` from an earlier attempt is there, then run
the block again.

Then close this terminal window completely. Its scrollback still contains the
passphrase, and running `clear` does not remove it.

### Step 2: Copy the encrypted file to the display qube (sending computer)

Start `D-qr-display` from the Qubes menu before copying. SEQS qubes delete
`~/QubesIncoming` when they start, so a copy that itself starts `D-qr-display`
could be deleted by that cleanup.

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

The terminal should show one complete QR code: a square with a light border on
all sides and no wrapped lines. A code for a file near the size limit is about
185 characters wide, so maximize the terminal and make the font smaller (in
most terminals with `Ctrl+-`) until the whole code fits. If `qrencode` instead
reports that it failed to encode the input data, stop: the file is too big for
this procedure. Keep `D-qr-display` running only until the receiving computer
has scanned the code, then shut it down.

### Step 4a: Scan on the dedicated-controller path (receiving computer)

Use this step only on the dedicated-controller path; on the sequential path,
use step 4b.

1. Start the target key qube, so that it can be chosen as a copy destination.
2. Start `sys-usb-webcam` and plug the webcam into its socket.
3. Open the Qubes Devices widget (the USB icon in the system tray). The webcam
   must be listed as `sys-usb-webcam:...`, as a single device. If it is listed
   as `sys-usb:...`, it is in a socket of the keyboard's controller: unplug it
   and stop. If any device appears under `sys-usb-webcam` other than the webcam
   and the internal devices you recorded for this controller, unplug the webcam
   and stop, as described under
   [check the dedicated controller with the webcam](#receiving-computer-check-the-dedicated-controller-with-the-webcam).
4. From the Qubes menu, open a terminal in a new disposable based on
   `A-qr-camera`.
5. Attach only the webcam to that disposable with the Devices widget.
6. In the disposable's terminal, run:

   ```bash
   (
   set -euo pipefail
   trap 'echo "ERROR: scan or copy failed" >&2' ERR
   umask 077
   zbarcam -q --raw --oneshot -Sdisable -Sqrcode.enable > key.asc
   qvm-copy key.asc
   )
   ```

   Point the webcam at the QR code. `zbarcam` exits after one successful read.
   In the copy dialog, choose the target key qube. If the last line starts with
   `ERROR`, run the block again.

   Accept exactly one copy dialog: the one that appears right after the scan.
   The camera disposable can open copy dialogs on its own, so cancel any other
   dialog from it, and treat such a dialog like a fingerprint mismatch in
   step 5.
7. After the copy succeeds, unplug the webcam and shut down the camera
   disposable and `sys-usb-webcam`. Check in the Qube Manager or the Qubes
   Domains widget that both have stopped before you take out the paper.

If `sys-usb` handled the webcam at any point since the receiving computer last
booted, or `sys-usb-webcam` handled your keyboard, stop and do not type the
passphrase; follow the recovery in
[check the dedicated controller with the webcam](#receiving-computer-check-the-dedicated-controller-with-the-webcam).
Otherwise, continue with step 5.

### Step 4b: Scan on the sequential path (receiving computer)

On the sequential path, a dom0 script scans the code and then powers off the
receiving computer. Never use the manual scan from step 4a here; the script
has to stay in control until the power-off.

Prepare:

1. Put away the paper and close every window that shows a secret.
2. Unplug the webcam.
3. Save and close all unrelated work.
4. Check that the internal USB devices you switched off are still off. In a
   dom0 terminal, run `sleep 20; qvm-usb`, unplug every external USB device
   during the 20 seconds, as under
   [Find the internal USB devices](#find-the-internal-usb-devices), and check
   that nothing is listed on the controller the script uses. Then reconnect
   the keyboard and mouse.
5. Be ready to unplug every USB keyboard and mouse quickly. A built-in keyboard
   or touchpad that does not use USB can stay as it is.

In a dom0 terminal of the receiving computer, run:

```bash
sudo /usr/local/sbin/seqs-qr-sequential
```

The script checks that the required qubes exist and that `A-qr-staging` holds
no old `key.asc`, then shows the controller and qube names. Check them, then
type `START` in capital letters. After that:

1. Unplug every USB keyboard and mouse right away. After 10 seconds the
   script stops normal `sys-usb`. If you cannot unplug them in time, press
   `Ctrl+C` before the 10 seconds end; nothing has changed yet, and you can run
   the script again. If a keyboard or mouse on the shared controller is still
   plugged in when the script starts `sys-usb-webcam`, it ends up in that qube
   together with the webcam. The script then finds more than one USB device,
   refuses to scan, and powers off. Treat that keyboard or mouse as exposed to
   the webcam: use it again only if you accept that its firmware may have been
   compromised, the same residual risk this path already accepts for the
   controller; otherwise replace it.
2. When the screen says `NORMAL USB BACKEND STOPPED`, plug in only the webcam.
   You have 30 seconds.
3. The script starts `sys-usb-webcam` and `seqs-qr-scanner`, checks that exactly
   one USB device is present, and scans for up to 3 minutes. Point the webcam at
   the QR code. The received file may be at most 16 KiB and is copied only to
   `A-qr-staging`. A webcam that itself shows up as several USB devices is
   refused every time; use a webcam that shows up as a single device.
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
ls -A
qvm-copy key.asc
```

`ls` must list only `key.asc`. If it lists anything else, the scanner sent
files on its own: do not open them, cancel the copy dialog, and treat it like
a fingerprint mismatch in step 5.

If `cd` or `qvm-copy` reports a missing directory or file, the scan failed.
Shut down `D-qr-display` if it is still running, then repeat from
[Step 2: Copy the encrypted file to the display qube](#step-2-copy-the-encrypted-file-to-the-display-qube-sending-computer);
the source `key.asc` can be reused. Otherwise, choose the target key qube in
the dialog. Do not open or decrypt the file in `A-qr-staging`.

### Step 5: Compare fingerprints (both computers)

The fingerprint check detects whether the file the target received differs
from the source's `key.asc`, before GnuPG reads it. It compares a shortened
hash, so a match makes an undetected change very unlikely rather than
impossible; the numbers follow the commands.

First check that the webcam is unplugged and that every camera and webcam qube
on the receiving computer has stopped. Qubes puts received files in
`~/QubesIncoming/<sender>`, where the sender is the camera disposable (a name
like `disp1234`) or `A-qr-staging`. In a terminal in the target key qube,
replace `<sender>` with that name and `<target-dir>` with the directory where
`master.key` should end up, and run:

```bash
ls -A ~/QubesIncoming/<sender>
mv -- ~/QubesIncoming/<sender>/key.asc <target-dir>/
cd <target-dir>
```

`ls` must list only `key.asc`. If it lists anything else, the camera side sent
files you did not ask for: do not open them, and handle it like a mismatch
below.

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

On the receiving computer, in the same target key qube terminal, run:

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

If any character differs, do not run GnuPG. A bad scan is an unlikely
explanation: QR codes carry error correction, so `zbarcam` almost always
either reads a code correctly or reads nothing. Assume instead that something
on the camera side changed the file on purpose. That side is then hostile, and
the secret depends entirely on the keyboard side staying clean.

Without opening anything, delete the received `key.asc`, and any unexpected
files, in the target key qube, and on the sequential path also in
`A-qr-staging`. Retry only after you have found the cause, or if you will type
the passphrase on a keyboard that does not go through a USB qube. To retry,
shut down `D-qr-display` if it is still running, then repeat from
[Step 2: Copy the encrypted file to the display qube](#step-2-copy-the-encrypted-file-to-the-display-qube-sending-computer);
the source `key.asc` can be reused.

### Step 6: Decrypt (receiving computer)

The commands decrypt into a temporary directory and create `master.key` only
if GnuPG succeeds. In the target key qube terminal, run:

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
target key qube's colour border. Qubes draws that border in dom0, so another
qube cannot fake it; a prompt with a different colour belongs to another qube
and must not receive the passphrase. Then type the passphrase from the paper,
using a keyboard that does not go through a USB qube if the computer has one.

On success, the last line shows `600 master.key`. If the passphrase is wrong
or the file fails GnuPG's integrity check, GnuPG prints an error, the
temporary output is removed without creating `master.key`, and the last line
starts with `ERROR`. Run the block again to retype the passphrase.

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
only after step 6 showed `600 master.key`: burn it, or cut it with a cross-cut
shredder, so that the passphrase cannot be read from the pieces.

## Further reading

The official Qubes documentation covers the underlying concepts in more depth:
[USB qubes](https://doc.qubes-os.org/en/latest/user/advanced-topics/usb-qubes.html),
[USB devices](https://doc.qubes-os.org/en/latest/user/how-to-guides/how-to-use-usb-devices.html),
[PCI devices](https://doc.qubes-os.org/en/latest/user/how-to-guides/how-to-use-pci-devices.html),
and [disposable customization](https://doc.qubes-os.org/en/development/user/advanced-topics/disposable-customization.html).
