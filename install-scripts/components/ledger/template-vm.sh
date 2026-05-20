#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

echo "Adding Ledger udev rules..."

cat << EOF | sudo tee /etc/udev/rules.d/20-hw1.rules
# HW.1, Nano
SUBSYSTEMS=="usb", ATTRS{idVendor}=="2581", ATTRS{idProduct}=="1b7c|2b7c|3b7c|4b7c", TAG+="uaccess", TAG+="udev-acl"

# Blue, NanoS, Aramis, HW.2, Nano X, NanoSP, Stax, Ledger Test,
SUBSYSTEMS=="usb", ATTRS{idVendor}=="2c97", TAG+="uaccess", TAG+="udev-acl"

# Same, but with hidraw-based library (instead of libusb)
KERNEL=="hidraw*", ATTRS{idVendor}=="2c97", MODE="0666"
EOF

echo "triggering udevadm..."
sudo udevadm trigger

echo "reloading rules..."
sudo udevadm control --reload-rules

# Ledger Live AppImage (installed by the app-vm phase) needs FUSE 2 at runtime.
# Debian 13 ships it as libfuse2t64; Debian 12 as libfuse2.
echo "installing FUSE 2 runtime for the Ledger Live AppImage..."
sudo apt-get update
sudo apt-get install -y libfuse2t64 2>/dev/null || sudo apt-get install -y libfuse2
