# Using the Bluetooth audio qube

SEQS builds `A-bluetooth`, an offline audio qube (a qube that plays and records
the sound of other qubes; Qubes calls the setting `audiovm`) for Bluetooth
headsets. It holds the computer's Bluetooth adapter, so the Bluetooth radio
and its software stay out of `sys-usb` and out of the qubes you use. Any qube
can send its sound to the headset and use its microphone.

`A-bluetooth` hears everything that a qube using it plays, and while the
microphone is attached, everything that qube records. It has no network
connection, but its radio reaches nearby devices: if it were compromised, it
could send what it hears over the air. Do not point offline qubes, such as
`A-keepass`, at it.

## Build the qube

In dom0, after fetching, reviewing, and staging this revision (see
[first install](first-install.md) or [upgrading](upgrading.md)):

```bash
~/s.sh --build-only --qubes bluetooth
```

This creates `Z-bluetooth` and `A-bluetooth`. The template gets
[BlueZ](https://www.bluez.org/) (the Linux Bluetooth stack), PipeWire's
Bluetooth plugin, the Qubes audio daemon, the
[Blueman](https://github.com/blueman-project/blueman) Bluetooth manager, and
a volume control (`pavucontrol`), all from the Debian and Qubes repositories.
The build makes `A-bluetooth` an audio qube in dom0; see
[TRUST.md](../TRUST.md#bluetooth-audio-qube-audio_provider-catalogue-key-).

## Give it the Bluetooth adapter

The adapter is a USB device that `sys-usb` holds. Bluetooth must be enabled
in the computer's firmware settings, or the adapter does not appear. In a
dom0 terminal:

```bash
qvm-device usb list
```

Find the line that starts with `Bluetooth:`, such as
`sys-usb:4-10  Bluetooth: Intel Corp. AX201 Bluetooth`, and assign that device
to `A-bluetooth`, here `sys-usb:4-10`:

```bash
qvm-device usb assign A-bluetooth sys-usb:4-10
```

Qubes now attaches the adapter whenever `A-bluetooth` starts. Start
`A-bluetooth` from its panel launcher or the Qubes menu.

## Pair a headset

In `A-bluetooth`, start **Bluetooth Manager** from its panel launcher or the
Qubes menu. Put the headset into pairing mode, choose **Search**, then select
the headset and **Pair**. Then mark it **Trusted** so it can reconnect by
itself. The pairing survives restarts of `A-bluetooth`. The Bluetooth icon in
the panel connects and disconnects the headset later.

## Send a qube's sound to the headset

In a dom0 terminal, with the qube's name in place of `A-brave`:

```bash
qvm-prefs A-brave audiovm A-bluetooth
```

This works while the qube runs. The qube's sound now plays on the headset
instead of dom0's speakers. If `A-bluetooth` is not running, the qube is
silent until it starts; starting the qube does not start `A-bluetooth`.
Set the volume of each qube with **Bluetooth volume** in `A-bluetooth`'s
Qubes menu; dom0's volume icon does not change it.

To send the qube's sound to dom0 again:

```bash
qvm-prefs A-brave audiovm --default
```

## Use the headset microphone

Attach the microphone in the Qubes devices menu (the panel icon that lists
USB devices): choose **Microphone** and the qube. Qubes sends the microphone
of the qube's audio qube, here the headset, to that qube. The headset then
switches from stereo music quality (A2DP) to call mode (HFP), which carries
the microphone but plays in lower-quality mono. Detach the microphone after
the call, and the headset returns to stereo.

## Caveats

- Qubes does not shut down `A-bluetooth` while a running qube uses it, and
  `delete-vms.sh` refuses to delete it while any qube uses it. Send those
  qubes' sound back to dom0 first.
- Some headsets with wear sensors end call audio when they are not worn,
  so the microphone sends nothing. On a Poly Voyager, turn the sensors off
  by holding **Call** and **Mute** together for five seconds.
- Each time Bluetooth starts in `A-bluetooth`, every paired device that
  supports both classic Bluetooth and Bluetooth Low Energy is set to connect
  over classic Bluetooth, which carries headset audio. With BlueZ's default, a
  connection started from Bluetooth Manager hung. Devices that support only
  Low Energy are unaffected.
