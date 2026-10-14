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

1. The source key qube (the trusted qube that holds the file) encrypts it with
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

## What you must trust

The procedure protects the secret only if these parts behave correctly:

- the source and target key qubes;
- dom0 (the Qubes administrative domain that controls all other qubes) on both
  computers;
- Qubes OS itself;
- on a computer where you type on a USB keyboard, `sys-usb` (the qube that
  Qubes creates to own the computer's USB controllers) and that keyboard,
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
  `sys-usb`. It may watch what you type.

The secret stays safe only while at most one side is hostile. If both are, the
passphrase and the encrypted file meet, the secret is lost, and nothing in this
procedure will tell you. No second layer of encryption protects against this:
the split holds only because you perform the steps in the order given, so that
nothing on the camera side is running when the passphrase is typed.

A keyboard side that goes through a USB qube can do more than watch. With a USB
keyboard, `sys-usb` passes each key press to dom0, and dom0 cannot tell a real
key press from one that `sys-usb` invents. A compromised `sys-usb`, or a
malicious USB keyboard, can therefore type into dom0 or a key qube on either
computer, for example a command that copies `master.key` to a qube with network
access, without the camera side or the passphrase. A USB mouse lets it click,
for example on dialogs. The QR transfer does not create this risk, which exists
whenever you use a USB keyboard on Qubes, but it makes `sys-usb` a single point
of failure rather than an independent second side.

The two-side protection therefore holds in full only if you type on a keyboard
that does not go through a USB qube, such as a built-in laptop keyboard that is
not internally USB ([check this](#check-whether-the-built-in-keyboard-uses-usb));
its key presses reach dom0 directly. With a USB keyboard, the split still
protects against parts that can only watch, such as a camera that sees the
paper but never the encrypted file.

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
shuts down. It starts from `A-qr-display`, its disposable template (the app
qube it is copied from), which SEQS creates at the same time. The sending
computer needs no webcam and no USB controller check.

The **receiving computer** needs:

- Qubes OS 4.3, because the setup uses device commands that Qubes 4.2 does
  not have;
- a trusted **target key qube** that does not yet contain a `master.key`;
- a USB webcam that can read a QR code from the sending computer's screen and
  shows up as a single USB device, which the dedicated-path check or the
  sequential scan script confirms;
- the hardware lookups described below; and
- SEQS installed with the `qr-camera` qube selected, plus `qr-staging` on the
  weaker of the two hardware setups described below. This creates
  `A-qr-camera`, an offline disposable template. Once you configure the
  webcam mode, as described later, the build also creates `seqs-qr-scanner`,
  the disposable started from it that runs `zbarcam` (the QR scanner program),
  and `sys-usb-webcam`, a USB qube (a qube that owns USB hardware and passes
  individual devices to other qubes) that handles only the webcam.

Both key qubes should be offline: a key qube with a NetVM (the qube that gives
it network access) keeps the plaintext `master.key` one software bug away from
the network. The `vault` qube that the Qubes installer creates by default has
no NetVM and is a suitable choice on either computer.

SEQS does not create the key qubes.

## Why the webcam must not share a USB controller with the keyboard

Qubes cannot give a single USB socket to a qube. It can only give away a whole
USB controller (the chip that drives a group of sockets), and every device on
that controller then goes through the same USB qube. If the webcam and a USB
keyboard share a controller, a malicious webcam that takes over that USB qube
could also watch what you type, either immediately or the next time the
keyboard is connected. The passphrase would then no longer travel separately.

The same applies to cameras that already sit on the keyboard's USB qube, such
as a laptop's built-in webcam: a compromised `sys-usb` could film both the QR
code and the passphrase. For the whole transfer, no camera on either computer
other than the QR webcam may be able to see the sending computer's screen, the
paper, or your hands on the keyboard. Cover the lens of every built-in camera with tape or its slider,
or switch it off with a hardware switch that cuts its power. Detaching the
camera in the Devices widget (the Qubes tray icon that attaches devices to
qubes) or disabling it in software is not enough: the
camera stays in `sys-usb`, which is the qube you are guarding against.

## Choose the hardware-isolation path

The receiving computer can keep the webcam away from the keyboard's
controller in two ways. Most laptops and NUCs can use only the second.

The **dedicated-controller path** gives the webcam a USB controller of its own
that `sys-usb-webcam` owns permanently. It is the only path that separates the
webcam and the keyboard in hardware. It needs a controller that carries no
device you need, and a webcam socket whose wires lead to no other controller.
On Intel laptops and NUCs, one controller usually serves the USB-A sockets, the
internal USB devices, and any USB keyboard. This path then needs an added
controller: a PCIe USB card in a desktop, or an M.2 USB controller card in a
free M.2 slot of a NUC; most laptops have no slot for one. AMD laptops often
have two or three USB controllers in the processor and sometimes offer a
dedicated controller without extra hardware.
[Look for a dedicated controller](#look-for-a-dedicated-controller) describes
its requirements.

The **sequential path** lends the controller that `sys-usb` normally owns to
the webcam for a single scan. A dom0 script stops `sys-usb`, gives the
controller to `sys-usb-webcam`, scans, and powers the computer off before the
keyboard is used again. You then remove all power, which is assumed to clear
anything the webcam left in the controller, and `sys-usb` gets the controller
back only at the next cold boot. The path has three requirements:

- **`sys-usb` must own the controller.** The build checks this.
- **During the scan, the webcam must be the only device on the controller.**
  You unplug external devices. Internal USB devices, such as a built-in webcam,
  Bluetooth, a fingerprint reader, or a card reader, must be switched off in
  the firmware settings (the BIOS or UEFI setup) and stay off. Switching a
  device off in Qubes or Linux, for example with `rfkill`, is not enough,
  because the device stays on the controller. If a device remains, the script
  finds more than one USB device only after it has shared a qube with the
  webcam; it then refuses to scan and powers off.
- **You must be able to remove all power after the scan.** A normal power-off
  leaves parts of the computer on standby power, so you unplug the power cable
  and take out the battery. On a laptop with a built-in battery, this is the
  weakest point of the sequential path, and this guide cannot say how much it
  weakens it; it also does not specify a tested minimum time without power.
  Two firmware settings may help, although this guide has not tested whether
  they cut all power: switch off every option that keeps USB powered while
  the computer is off, often called "Always On USB" or "USB charging", and use
  a battery-disconnect setting where the firmware offers one, such as "Disable
  built-in battery" on Lenovo ThinkPads, which disconnects the battery until a
  charger is connected.

The sequential path accepts two things that the dedicated-controller path
does not. A socket may be split, because `sys-usb` is stopped during the scan,
so no qube drives the other controller. And the controller need not support a
strict reset (a reset that clears its state when it moves between qubes),
which the chipset controller of Intel computers often does not. Without it,
state that `sys-usb` left in the controller, possibly traces of earlier
keyboard input, reaches the camera side.

The sequential path cannot protect against malicious state that survives power
removal in the controller, keyboard, or webcam firmware, a webcam attack that
escapes through Qubes itself or
[qrexec](https://doc.qubes-os.org/en/latest/developer/services/qrexec.html)
(the Qubes service through which qubes copy files, open links, and send input
to each other), a compromised dom0, or a webcam left
plugged in at the next boot. Anything the webcam leaves behind that survives
the power-off reaches `sys-usb`, which with a USB keyboard can type into dom0,
as described under [What you must trust](#what-you-must-trust). The worst case
is therefore control of the whole receiving computer, not only a leaked
passphrase.

If the computer qualifies for neither path, or the sequential path's limits
are not acceptable for your secret, add a USB controller card and use the
dedicated-controller path.

## Find the webcam's USB controller

The lookups in this section find the controller of the socket you will use for
the webcam, make sure nothing else will share it during the scan, and show
whether your built-in keyboard bypasses `sys-usb`. They are all the sequential
path needs. If you want a dedicated controller, run them too;
[Look for a dedicated controller](#look-for-a-dedicated-controller) adds the
checks that path needs.

Do not use the webcam for these lookups: it would be handled by `sys-usb`, the
keyboard's qube, which is what the whole setup avoids. Use a small USB device
you already trust instead, such as a USB mouse, as the test device.

### List the USB controllers

In a dom0 terminal of the receiving computer (Qubes menu, gear icon, then
Terminal), run `qvm-pci`
([PCI devices](https://doc.qubes-os.org/en/latest/user/how-to-guides/how-to-use-pci-devices.html)):

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
qube uses the controller; `no-strict-reset=True` there is how the Qubes
installer assigns USB controllers to `sys-usb`.

Lines whose description contains `NHI` are Thunderbolt host interfaces, not
USB controllers with sockets of their own; leave them out when you count
controllers. The example therefore shows two USB controllers: a Thunderbolt
USB controller and the chipset (PCH) controller. Keep this output for the
lookups below.

### Check whether the built-in keyboard uses USB

Skip this check if the receiving computer has no built-in keyboard. Otherwise,
its result decides how much the transfer protects on this computer, as
explained under [What you must trust](#what-you-must-trust). A built-in
keyboard that uses USB counts as an internal device in the next check.

The check stops `sys-usb`, so your USB keyboard and mouse stop working; save
your work first. In a dom0 terminal, run:

```bash
qvm-shutdown --wait sys-usb
```

When the command returns, type a few characters into the same terminal with
the built-in keyboard, and move the pointer with the built-in touchpad. If the
characters appear, the keyboard does not use USB; write that down, and restart
the USB qube with:

```bash
qvm-start sys-usb
```

The same applies to the touchpad: if the pointer moved, it does not use USB
either. If no characters appear, the built-in keyboard goes through
`sys-usb`; write that down. You now have no way to type. Press the power
button briefly to shut the computer down, or hold it if that does nothing.
`sys-usb` starts automatically at the next boot.

### Find the internal USB devices

Internal USB devices cannot be unplugged. The sequential path needs every
one on the webcam's controller switched off; the dedicated-controller path
needs the radios among them switched off, as
[Look for a dedicated controller](#look-for-a-dedicated-controller) explains.
In a dom0 terminal, run `qvm-usb`
([USB devices](https://doc.qubes-os.org/en/latest/user/how-to-guides/how-to-use-usb-devices.html)):

```bash
sleep 20; qvm-usb
```

During the 20 seconds, unplug every external USB device, including the
keyboard and mouse. Every device that is still listed when the output appears
is internal. Its identifier, such as `sys-usb:3-10`, names its position in
`sys-usb`; write it down with the device's name. Then reconnect the keyboard
and mouse.

On the sequential path, switch off every listed device in the firmware
settings, then repeat the check. If the repeated check lists nothing, you are
done here. Any device that remains, such as a built-in keyboard that uses USB,
must be on a different controller from the webcam's, which the next subsection
checks; if it is on the same controller, the sequential path is not possible
with that socket. If a built-in camera that cannot be switched off shares the
controller of the USB-A sockets, a USB 3 webcam in a USB-C socket may still
work: on many Intel laptops, the USB 3 wires of the USB-C sockets lead to the
other controller, which the next subsection shows with a USB 3 test device.

The devices must stay switched off for every later transfer.

### Find the controller of the webcam's socket

If the controller list showed only one USB controller, skip this subsection:
that controller is the webcam's. If an internal device remained switched on
there as well, the sequential path is not possible on this computer without a
USB controller card.

Choose the socket you will always use for the webcam. Most webcams are USB 2,
which their packaging or specifications state; if yours is USB 3, use a USB 3
test device, such as a recent USB stick, in this subsection. With the keyboard
and mouse plugged in, plug the test device into that socket, and in a dom0
terminal run:

```bash
qvm-usb
```

Find the test device by its name. Its identifier, such as `sys-usb:3-1`,
starts with its root USB bus number (`3`), the number before the dash: one
controller has one or more such buses, each serving its sockets. Note this
number, and the bus number of every internal device that remained switched on.

Then open a terminal in `sys-usb` (in a dom0 terminal:
`qvm-run sys-usb xterm`) and run this, which prints one line for each bus:

```bash
for u in /sys/bus/usb/devices/usb*; do p=$(readlink -f "$u/.."); echo "${u##*/} $(cat "$u/speed") $(cat "$p/vendor" "$p/device" | tr '\n' ' ')$(lspci -s "${p##*/}" 2>/dev/null)"; done
```

The output looks like this (example values, with the descriptions shortened):

```text
usb1 480 0x8086 0x51ed 00:09.0 USB controller: Intel Corporation ... PCH USB 3.2 xHCI Host Controller
usb2 10000 0x8086 0x51ed 00:09.0 USB controller: Intel Corporation ... PCH USB 3.2 xHCI Host Controller
usb3 480 0x8086 0x461e 00:0a.0 USB controller: Intel Corporation ... Thunderbolt 4 USB Controller
usb4 10000 0x8086 0x461e 00:0a.0 USB controller: Intel Corporation ... Thunderbolt 4 USB Controller
```

Each line shows the bus, its speed in Mbit/s (`480` is USB 2, and `5000` or
more is USB 3), the controller's hardware ID, and its description. The
addresses such as `00:09.0` exist only inside `sys-usb`; never put them into
the SEQS configuration. Find the line of the test device's bus, and match its
description to a line of the dom0 controller list: that line's BDF is the
webcam's controller. In the example, a test device listed as `sys-usb:1-2` is
on bus 1; the `usb1` line names the PCH xHCI Host Controller, which the dom0
list shows as `dom0:00_14.0`, so the BDF is `00_14.0`. Internal devices that
remained switched on must lead to a different description.

A line with the hardware ID `0x8086 0x24cd` belongs to the virtual USB
controller that Qubes gives the `sys-usb` qube itself, not to a controller of
the computer; no test device appears on its bus, so ignore it.

If the lines end after the hardware ID, `lspci` is not installed in `sys-usb`.
In that case, or if no line of the dom0 list has the same description, which
can happen because `sys-usb` and dom0 may use different versions of the
device database, or if two controllers in the dom0 list have the same
description, match by hardware ID instead. In a dom0 terminal, run:

```bash
lspci -nn | grep -i usb
```

Each line starts with a BDF, written with a colon in place of the underscore,
and ends with a hardware ID in square brackets, such as `[8086:51ed]`. Find
the ID that the test device's bus showed, written without `0x`. If two
controllers have the same ID as well, which happens on some AMD laptops, do
not guess; use the test in the next subsection.

### Tell identical controllers apart

Skip this subsection unless two controllers showed the same hardware ID. This
test takes one of them away from `sys-usb` for 30 seconds and shows which
devices disappear.

In the dom0 controller list, check whether the line of the controller you will
test shows `no-strict-reset` next to `sys-usb`. Plug the test device into
the socket you are checking. First remove the controller from the devices
assigned to `sys-usb`, with your BDF; `sys-usb` keeps the controller until it
restarts, so your keyboard still works. In a dom0 terminal, run:

```bash
qvm-pci unassign sys-usb dom0:00_14.0
```

The output starts with `Unassigned`, or is empty if `sys-usb` was not running.
If it says instead that the device is not assigned, the assignment dates from
before an upgrade to Qubes 4.3 and records no device identity; run the command
again with `--port` after `unassign`. Then run this as a single line, with your
BDF, and add `--option no-strict-reset=true` after `--persistent` if the
controller line showed that option:

```bash
qvm-shutdown --wait sys-usb; qvm-start sys-usb; sleep 30; qvm-usb; qvm-shutdown --wait sys-usb; qvm-pci attach --persistent sys-usb dom0:00_14.0; qvm-start sys-usb
```

Your USB keyboard and mouse may stop working while the line runs, because the
controller you took away may carry them; the line gives the controller back by
itself. The `qvm-usb` output in the middle lists only devices that are not on
the tested controller. It must still list at least one device that you know is
on the other controller, such as a keyboard or internal device. If it lists
nothing at all, `sys-usb` did not start and the test proves nothing.
Otherwise, if the test device is missing from it, the socket belongs to that
BDF.

This test has not been tried on every Qubes version. If `sys-usb` fails to
start at the end and your keyboard stays dead, use the recovery steps under
[Before you build on the dedicated-controller path](#before-you-build-on-the-dedicated-controller-path):
skip the `sys-usb-webcam` command there, and run only the `sys-usb` commands.

### Check whether the controller supports a strict reset

This check decides one setting in the configuration. In a dom0 terminal, run
this with the webcam's controller address from the second column of the
controller list:

```bash
cat /sys/bus/pci/devices/0000:00:14.0/reset_method
```

If it prints one or more reset methods, such as `flr` or `pm`, the controller
supports a strict reset. If it reports `No such file or directory` or prints
nothing, it does not. Write down the result.

You now have everything the sequential path needs: the controller's BDF, which
`sys-usb` must own in the controller list, and the reset result. Continue with
[Configure and build the QR qubes](#configure-and-build-the-qr-qubes), unless
you want to look for a dedicated controller.

## Look for a dedicated controller

Skip this section on the sequential path. The dedicated-controller path needs
a controller and socket with these properties, which the lookups below check.

The controller must carry none of these:

- a keyboard or mouse;
- the disk or USB device Qubes boots from or stores data on;
- a USB anti-evil-maid (AEM, a Qubes boot-integrity check) or boot device;
- a hardware wallet, security key, phone, or backup drive; or
- any other device you need to operate or recover the computer.

A built-in keyboard that does not use USB, as the earlier check showed, does
not count, because it uses no USB controller. Other internal devices on the
controller are handled by the camera side. Radios among them, such as
Bluetooth, must be switched off in the firmware settings: they would give the
camera side a way to send data out without a network.

The socket must lead only to that controller. A USB 3 socket has separate
wires for USB 2 and USB 3, and on some computers they lead to different
controllers; the USB-C sockets of recent Intel computers typically send USB 3
to one controller and USB 2 to the controller that also serves the keyboard.
On such a split socket the webcam, not you, chooses which wires it uses. A
hostile webcam can connect over the USB 2 wires as well, and that connection
lands in `sys-usb`. The check after the build does not reveal this, because it
shows only the connection the webcam chooses to present; only the split check
below can find such a socket. A USB-C socket with Thunderbolt can also reach
the Thunderbolt host interface (`NHI`) that `sys-usb` owns. A split or
Thunderbolt socket therefore never qualifies.

The controller must support a strict reset, as checked under
[Check whether the controller supports a strict reset](#check-whether-the-controller-supports-a-strict-reset).
Transfers on this path are not separated by a power-off; with a strict reset,
Qubes resets the controller each time `sys-usb-webcam` starts, so state a
hostile webcam left in it does not carry into the next transfer.

`sys-usb-webcam` then owns the controller permanently, so anything plugged
into any of that controller's sockets from then on is handled by the camera
side, or is unusable while `sys-usb-webcam` is stopped. The separation also
relies on the IOMMU (the VT-d or AMD-Vi feature Qubes needs to assign PCI
devices); leave it enabled in the firmware settings.

### Find a candidate socket

A socket is a candidate if its controller carries none of the devices listed
above. To place them, plug in every required USB device, such as the keyboard,
mouse, and boot drive, plug the USB 2 test device into the socket, and repeat
the `qvm-usb` and `sys-usb` lookups from
[Find the controller of the webcam's socket](#find-the-controller-of-the-webcams-socket).
The test device's bus must lead to a controller that no required device's bus
leads to. Try each socket you might use.

### Check a candidate socket for a split

Plug a USB 3 test device, such as a recent USB stick, into the candidate
socket, and repeat the same lookups. If it leads to a different controller
than the USB 2 test device in the same socket, the socket is split and does
not qualify.

The split check works only if the USB 3 test device really connects at USB 3:
its bus must show a speed of `5000` or more, in this socket or another socket
of the same kind (USB-A or USB-C) with the same adapter. If it never does, the
device or adapter is USB 2 only, and its results cannot show whether a socket
is split; repeat the check with a real USB 3 device.

If a candidate socket is not split and its controller supports a strict reset,
use the dedicated-controller path with that controller. From now on, plug the
webcam only into that socket, and nothing else into that controller's sockets.
Otherwise, use the sequential path if its requirements hold, and continue
with [Configure and build the QR qubes](#configure-and-build-the-qr-qubes); or
add a controller card.

### Before you build on the dedicated-controller path

Arrange a second way to type in dom0, such as a built-in keyboard that does not
use USB or a keyboard on another controller. The build stops `sys-usb`, takes
the controller away from it, and starts `sys-usb` again without it, so USB
devices on its other controllers return after a short pause. The assignment
survives reboots; setting the mode back to `disabled` does not undo it. If you
chose the wrong BDF and it carries your only keyboard, the keyboard stops
working until you undo the assignment as follows:

1. Unplug every USB device except the keyboard, then restart the computer by
   pressing the power button, or holding it if a short press does nothing.
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
   qvm-pci unassign sys-usb-webcam dom0:<BDF>
   qvm-pci attach --persistent --option no-strict-reset=true sys-usb dom0:<BDF>
   ```

   The last command gives the controller back to `sys-usb` the way the Qubes
   installer assigns USB controllers.
4. Restart the computer normally. The GRUB edit applied only to one boot, and
   `sys-usb` owns the controller again.

Then correct `webcam_usb_controller` in the configuration, or set
`webcam_usb_mode` to `disabled` and clear the controller, and commit before the
next SEQS run.

## Configure and build the QR qubes

SEQS builds qubes from a Git checkout in the repository qube (the qube holding
your SEQS clone, such as the disposable used in the
[README](../README.md) install). Never edit SEQS files in dom0.

On the sending computer, no configuration change is needed: select
`qr-display` when you run SEQS, as described at the end of this section.

On the receiving computer, edit `salt/pillar/seqs/config.sls` in the repository
qube. For the sequential path:

```jinja
{%- set webcam_usb_mode = 'sequential' %}
{%- set webcam_usb_controller = '00_14.0' %}
{%- set webcam_usb_no_strict_reset = False %}
```

For the dedicated-controller path:

```jinja
{%- set webcam_usb_mode = 'dedicated' %}
{%- set webcam_usb_controller = '03_00.0' %}
{%- set webcam_usb_no_strict_reset = False %}
```

Replace the example BDF with your own, exactly as the controller list shows
it, without the `dom0:` prefix.
`webcam_usb_no_strict_reset = True` lets Qubes hand the controller to
`sys-usb-webcam` without a strict reset. On the sequential path, set it to
`True` only if the
[strict-reset check](#check-whether-the-controller-supports-a-strict-reset)
found no reset method, and to `False` otherwise. The dedicated-controller path
requires `False`.

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

Selecting `qr-staging` creates `A-qr-staging` (a persistent offline qube
that keeps the encrypted file while the computer is off).

On the sequential path, every build also installs the dom0 script
`/usr/local/sbin/seqs-qr-sequential` that runs the scan, and stops with
`Configured controller is not attached to sys-usb` if the configured BDF is
not a controller that the running `sys-usb` holds; recheck the BDF, and that
`sys-usb` is running. Every later SEQS run on this computer repeats that
check, whichever qubes it builds.

The build assigns the controller without resetting it. If `sys-usb-webcam`
later fails to start because the controller cannot be reset, the reset check
was wrong for this controller. On the dedicated-controller path, the
controller is then unsuitable; give it back to `sys-usb` with steps 3 and 4 of
the recovery under
[Before you build on the dedicated-controller path](#before-you-build-on-the-dedicated-controller-path).
On the sequential path, the scan script says so and powers off after 60
seconds without scanning; set `webcam_usb_no_strict_reset` to `True`, commit,
build again, and repeat the transfer from
[Step 2: Copy the encrypted file to the display qube](#step-2-copy-the-encrypted-file-to-the-display-qube-sending-computer).

## Check the setup

Run these checks once after building and before you use any secret.

### Sending computer: check that the display qubes are offline

A qube is offline if it has no NetVM and no default disposable (the
disposable it opens files in by default, normally a networked one). Both must
be set to none explicitly: a none inherited from a global default becomes
networked when that default changes. The SEQS run that builds an offline qube
checks this itself and stops otherwise; its output then contains a line
starting with `Air gap verified:` that names `A-qr-display` and
`D-qr-display`. If you no longer have that output, run in a dom0 terminal of
the sending computer:

```bash
for q in A-qr-display D-qr-display; do qvm-prefs $q | grep -E '^(netvm|default_dispvm) '; done
```

Each of the four output lines must show `-` and then `None`; a `D` instead of
`-` means the value is only inherited.

Having no network does not stop qrexec, so SEQS also installs qrexec policies (dom0 rules deciding which
qube may use which service). Check that the display qubes may neither hand
links to the browser qube nor start a program in another qube or a
disposable, as a second layer behind the unset default disposable. In a dom0 terminal of the sending computer, run:

```bash
qvm-tags A-qr-display list; qvm-tags D-qr-display list
cat /etc/qubes/policy.d/28-browser-suppress.policy
```

Both tag lists must include `seqs-no-handoff`; a disposable started from
`A-qr-display` inherits it. The policy file must deny, from
`@tag:seqs-no-handoff` to `@anyvm` (every qube and disposable), these eight
services: `qubes.OpenURL`, `qubes.OpenInVM`, `qubes.StartApp`,
`qubes.GetImageRGBA`, `qubes.VMShell`, `qubes.VMExec`, `qubes.VMExecGUI`, and
`qubes.PdfConvert`.

### Receiving computer: check that the camera qubes are offline

The `Air gap verified:` line of the SEQS run covers `A-qr-camera` and, on the
sequential path, `A-qr-staging`, in the same way. If you no longer have that
output, check them with the `qvm-prefs` loop of the sending computer. On the
dedicated-controller path, no scan script checks `sys-usb-webcam` and
`seqs-qr-scanner` at each transfer, so check them yourself; in a dom0 terminal
of the receiving computer, run:

```bash
for q in sys-usb-webcam seqs-qr-scanner; do qvm-prefs $q | grep -E '^(netvm|default_dispvm) '; done
```

Each of the four output lines must show `-` and then `None`.

### Receiving computer: check the controller assignment

In a dom0 terminal of the receiving computer, run:

```bash
qvm-pci list --assignments
```

The controller can appear on two lines: one with the qubes that hold it right
now, if any, and one with the assigned qubes, marked with `*`. On both paths,
no other controller may be assigned to `sys-usb-webcam`: a build with a
different BDF leaves that controller assigned to it.

On the dedicated-controller path, your controller must be assigned only to
`sys-usb-webcam`. Give a wrongly assigned controller back to `sys-usb` with
steps 3 and 4 of the recovery under
[Before you build on the dedicated-controller path](#before-you-build-on-the-dedicated-controller-path).

On the sequential path, the controller is assigned to both `sys-usb` and
`sys-usb-webcam`. Qubes refuses to start a qube whose controller another
running qube holds, and the script stops `sys-usb` before starting
`sys-usb-webcam`. A wrongly assigned controller keeps its `sys-usb`
assignment, so only remove it from `sys-usb-webcam`, with `<BDF>` replaced:

```bash
qvm-pci unassign sys-usb-webcam dom0:<BDF>
```

### Receiving computer: check the qrexec policies

The qrexec policies on this side limit the webcam qubes. In a dom0 terminal
of the receiving computer, run:

```bash
cat /etc/qubes/policy.d/00-seqs-qr-input-deny.policy
qvm-tags A-qr-camera list
```

The first file must deny the input services (`qubes.InputKeyboard`,
`qubes.InputMouse`, `qubes.InputTablet`) and the eight services listed for
the sending computer from `sys-usb-webcam` and `seqs-qr-scanner`, and `qubes.Filecopy` from `sys-usb-webcam`. The tag list must
include `seqs-no-handoff`, which applies the `28-browser-suppress.policy`
denies checked on the sending computer to `A-qr-camera` and to disposables
started from it; on the sequential path, `qvm-tags A-qr-staging list` must
include it too.

On the sequential path, also run:

```bash
cat /etc/qubes/policy.d/01-seqs-qr-filecopy.policy
```

You should see one `allow` from `seqs-qr-scanner` to `A-qr-staging`, followed
by a `deny` for every other destination.

### Receiving computer: check the dedicated controller with the webcam

On the dedicated-controller path only. This is the first time the webcam is
plugged into the receiving computer. Start `sys-usb-webcam` in the Qube
Manager, plug the webcam into its socket, and in a dom0 terminal run:

```bash
qvm-usb
```

The webcam must be listed under `sys-usb-webcam`, as a single device. Apart
from it, only internal devices of this controller may appear there. If any
other device appears under `sys-usb-webcam`, unplug the webcam and stop.
Either the controller carries something you did not place, in which case
repeat the lookups, or the webcam itself shows up as several devices. Some
webcams contain a small hub and do this legitimately, but you cannot tell
their extra devices from an attack; use a webcam that shows up as a single
device. Every keyboard, mouse, and other required device must still be listed
under another USB qube. If any of them moved to `sys-usb-webcam`, stop: the
controller is not dedicated. Shut down `sys-usb-webcam` and unplug the webcam
when you are done.

If the webcam is instead listed under `sys-usb`, it is in a socket of the
keyboard's controller and the keyboard side has now been exposed to it. Unplug
it, shut the receiving computer down, and remove all power as described for
the sequential path under
[Choose the hardware-isolation path](#choose-the-hardware-isolation-path); a
restart is not enough. Then start the computer with only the keyboard
attached. If `sys-usb` is a disposable (in dom0, `qvm-prefs sys-usb klass`
prints `DispVM`), this discards its state, and what remains is the residual
risk the sequential path accepts. Continue only if you accept that; otherwise
replace the keyboard. If `sys-usb` is not a disposable, treat it, and with a
USB keyboard the whole receiving computer, as compromised, and do not
continue. The same rule applies whenever this happens during a transfer.

### Rehearse with a throwaway file

Run the whole transfer once with a throwaway file before you transfer a real
secret. Parts of this procedure, including the sequential scan script, have not
yet been tested on Qubes 4.3, and a failure costs nothing when no secret is
involved. In a terminal in the source key qube, run:

```bash
mkdir ~/qr-rehearsal && cd ~/qr-rehearsal && head -c 1000 /dev/urandom > master.key
```

This creates a random 1,000-byte `master.key` in a new directory. In a terminal
in the target key qube, run `mkdir ~/qr-rehearsal`, and use `~/qr-rehearsal`
as `<target-dir>` in step 5. Then follow [Transfer a file](#transfer-a-file)
from step 1, working in `~/qr-rehearsal` on both computers, with a fresh sheet
of paper that you destroy as in step 7. Afterwards, run
`rm -rf ~/qr-rehearsal` in both key qubes.

The rehearsal succeeds only if each of these happens as described:

- on the sequential path, the script lists only the devices you expect in
  `sys-usb`, starts `sys-usb-webcam`, and powers off after the scan;
- on the receiving computer, exactly one copy dialog appears, and the
  received folder holds only `key.asc`;
- all four fingerprint groups match in step 5; and
- step 6 ends with `600 master.key`.

If anything else happens, find the cause before you use a real secret. If the
fingerprints differ at every attempt but the scan works, stop: the scan
commands need changing.

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

Qubes asks in a dom0 dialog before a qube copies files to another qube.
`D-qr-display` and the camera-side qubes can open such a dialog on their own,
for example to copy `key.asc` to a qube with network access. Accept only the
copy dialogs that the steps below tell you to expect. Cancel any other dialog
from these qubes, and treat it like a fingerprint mismatch in step 5.

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

The terminal prints the passphrase and creates the encrypted file `key.asc`.
Write the passphrase on the paper. If the last line starts with `ERROR`,
discard that passphrase: check that you are in the directory containing
`master.key` and that no `key.asc` from an earlier attempt is there, then run
the block again.

Then close this terminal window completely. Its scrollback still contains the
passphrase, and running `clear` does not remove it.

### Step 2: Copy the encrypted file to the display qube (sending computer)

Start `D-qr-display` before copying, so that its start-up cleanup cannot delete
the copy. Open a terminal in it: choose `Display QR (offline)` under
`D-qr-display` in the Qubes menu, or, if the menu does not offer it, run
`qvm-run D-qr-display x-terminal-emulator` in a dom0 terminal. If you used the
dom0 command, that dom0 terminal stays busy until the new terminal is closed;
leave it open, because closing it also closes the terminal in `D-qr-display`.

Open a new terminal in the source key qube, go to the directory containing
`key.asc`, and run:

```bash
qvm-copy key.asc
```

In the dialog, choose the running `D-qr-display`. Keep the source copy of
`key.asc`, because step 5 compares against it. You may shut down the source key
qube now; its files are kept.

### Step 3: Show the QR code (sending computer)

Put away the paper and close every window that shows a secret. In the
`D-qr-display` terminal from step 2, run this, replacing `<source-key-qube>`
with the name of your source key qube:

```bash
cd ~/QubesIncoming/<source-key-qube>
qrencode -l M -t ansiutf8 < key.asc
```

The terminal should show one complete QR code: a square with a light border on
all sides and no wrapped lines. Maximize the terminal and make the font
smaller (in most terminals with `Ctrl+-`) until the whole code fits. If
`qrencode` instead reports that it failed to encode the input data, stop: the
file is too big for this procedure. Keep `D-qr-display` running only until the
receiving computer has scanned the code, then shut it down.

`D-qr-display` never needs to open a dialog: cancel any that names it as the
source, and treat it like a fingerprint mismatch.

### Step 4a: Scan on the dedicated-controller path (receiving computer)

Use this step only on the dedicated-controller path; on the sequential path,
use step 4b.

1. Start the target key qube, so that it can be chosen as a copy destination.
2. Start `sys-usb-webcam` in the Qube Manager and plug the webcam into its
   socket.
3. Open the Qubes Devices widget. The webcam
   must be listed as `sys-usb-webcam:...`, as a single device. If it is listed
   as `sys-usb:...`, it is in a socket of the keyboard's controller: unplug it
   and stop. If any device appears under `sys-usb-webcam` other than the webcam
   and the internal devices you recorded for this controller, unplug the webcam
   and stop, as described under
   [check the dedicated controller with the webcam](#receiving-computer-check-the-dedicated-controller-with-the-webcam).
4. Open a terminal in `seqs-qr-scanner`, the camera disposable: choose a
   terminal under `seqs-qr-scanner` in the Qubes menu, or, if the menu offers
   none, run `qvm-run seqs-qr-scanner x-terminal-emulator` in a dom0
   terminal and leave that dom0 terminal open while you scan.
5. Attach only the webcam to `seqs-qr-scanner` with the Devices widget.
6. In the `seqs-qr-scanner` terminal, run:

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

   Accept only the copy dialog that appears right after the scan; cancel any
   other from `seqs-qr-scanner`, and treat it like a fingerprint mismatch.
7. After the copy succeeds, unplug the webcam and shut down `seqs-qr-scanner`
   and `sys-usb-webcam`. Check in the Qube Manager or the Qubes
   Domains widget (the tray icon that lists running qubes) that both have stopped before you take out the paper.

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
4. Be ready to unplug every USB keyboard and mouse quickly. A built-in keyboard
   or touchpad that does not use USB, as the setup check showed, can stay as it
   is.

In a dom0 terminal of the receiving computer, run:

```bash
sudo /usr/local/sbin/seqs-qr-sequential
```

The script checks that the required qubes exist, that the camera-side qubes
have no NetVM and no default disposable, and that `A-qr-staging` holds no old
`key.asc`. It then lists the USB devices now in `sys-usb`. Only your USB
keyboard and mouse, and internal devices you found on another controller, may
be listed. If anything else is listed, an internal device may have been
switched back on, for example by a firmware update: do not type `START`; press
`Enter` to end the script, switch the device off as described under
[Find the internal USB devices](#find-the-internal-usb-devices), and run the
script again. If the script reports that `A-qr-staging` already holds an
incoming `key.asc`, left by an earlier scan or rehearsal, delete
`~/QubesIncoming/seqs-qr-scanner` in `A-qr-staging` once you no longer need
it, shut `A-qr-staging` down, and run the script again. If it reports that
`sys-usb-webcam` is already running, that qube has had the shared controller,
so the script powers the computer off; run it again after the restart.
Otherwise, type `START` in capital letters. After that:

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
2. When the screen says `NORMAL USB BACKEND STOPPED`, plug in only the webcam,
   into the socket you chose for it during setup. You have 30 seconds.
3. The script starts `sys-usb-webcam` and `seqs-qr-scanner`, checks that exactly
   one USB device is present, and scans for up to 3 minutes. If
   `sys-usb-webcam` does not start, the script shows an error and powers off
   after 60 seconds without scanning; see the end of
   [Configure and build the QR qubes](#configure-and-build-the-qr-qubes).
   Point the webcam at the QR code.
4. Unplug the webcam when the script reports that the copy completed, or
   when it reports an error. Do not reconnect the keyboard or mouse.
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
```

If `cd` reports a missing directory, or `ls` lists nothing, the scan failed.
Shut down `D-qr-display` if it is still running, then repeat from
[Step 2: Copy the encrypted file to the display qube](#step-2-copy-the-encrypted-file-to-the-display-qube-sending-computer);
the source `key.asc` can be reused. If `ls` lists anything other than
`key.asc`, the scanner sent files on its own: do not open them, delete them
all with `rm -rf -- ~/QubesIncoming/seqs-qr-scanner`, shut down
`A-qr-staging` in the Qubes Domains widget, and treat it like a fingerprint
mismatch in step 5.

If `ls` lists only `key.asc`, copy it in the same terminal, without opening or
decrypting it here:

```bash
qvm-copy key.asc
```

In the dialog, choose the target key qube. Accept only this one copy dialog;
cancel any other from `A-qr-staging`, and treat it like a fingerprint
mismatch.

The camera side must be shut down before you type the passphrase. When the
copy has finished, delete the staging copy in the same terminal:

```bash
rm -f -- key.asc
```

Then shut down `A-qr-staging` in the Qubes Domains widget.

### Step 5: Compare fingerprints (both computers)

The fingerprint check detects whether the file the target received differs
from the source's `key.asc`, before GnuPG reads it.

First check that the webcam is unplugged and that every camera and webcam qube
on the receiving computer, including `A-qr-staging`, has stopped. Qubes puts
received files in `~/QubesIncoming/<sender>`, where the sender is
`seqs-qr-scanner` on the dedicated-controller path and `A-qr-staging` on the
sequential path. In a terminal in the target key qube, replace `<sender>` with
that name and `<target-dir>` with the directory where
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

If any character differs, do not run GnuPG. A bad scan is an unlikely
explanation: QR codes carry error correction, so `zbarcam` almost always
either reads a code correctly or reads nothing. Assume instead that something
on the camera side changed the file on purpose. That side is then hostile, and
the secret depends entirely on the keyboard side staying clean.

Without opening anything, delete the received `key.asc`, and any unexpected
files, in the target key qube. Retry only after you have found the cause, or if
you will type the passphrase on a keyboard that does not go through a USB qube.
To retry, shut down `D-qr-display` if it is still running, then repeat from
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
and must not receive the passphrase. Then type the passphrase from the paper.
If the [built-in keyboard check](#check-whether-the-built-in-keyboard-uses-usb)
showed that the built-in keyboard does not use USB, type it there rather than
on a USB keyboard.

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

The command prints nothing. Check that the file is gone. Destroy the paper
only after step 6 showed `600 master.key`: burn it, or cut it with a cross-cut
shredder, so that the passphrase cannot be read from the pieces.
