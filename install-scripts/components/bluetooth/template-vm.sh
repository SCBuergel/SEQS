#!/usr/bin/env bash
set -Eeuo pipefail

echo "Installing Bluetooth audio..."
# BlueZ and PipeWire's Bluetooth plugin talk to the headset, the Qubes audio
# daemon carries the audio of the qubes that use this one as their audiovm,
# blueman pairs devices, and pavucontrol sets volumes and headset profiles.
sudo apt-get update
sudo apt-get install -y bluez libspa-0.2-bluetooth pipewire-pulse wireplumber \
	qubes-audio-daemon qubes-core-admin-client blueman pavucontrol

ASSET_DIR="$(dirname "$0")"
# /usr and /etc are inherited from the template by A-bluetooth.
sudo install -m 0755 "${ASSET_DIR}/seqs-bluetooth-bredr" /usr/sbin/seqs-bluetooth-bredr
sudo install -d -m 0755 /etc/systemd/system/bluetooth.service.d
printf '[Service]\nExecStartPre=-/usr/sbin/seqs-bluetooth-bredr\n' \
	| sudo tee /etc/systemd/system/bluetooth.service.d/50-seqs-bredr.conf >/dev/null
