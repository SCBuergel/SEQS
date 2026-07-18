#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

echo "Adding Ledger udev rules..."

cat << EOF | sudo tee /etc/udev/rules.d/20-hw1.rules
# HW.1, Nano
# MODE 0660 on the usb nodes too (not just hidraw below): without it the
# node keeps the udev default mode and only the ACL layer restricts access
# -- same tightening the Trezor rules already carry on their usb lines.
SUBSYSTEMS=="usb", ATTRS{idVendor}=="2581", ATTRS{idProduct}=="1b7c|2b7c|3b7c|4b7c", MODE="0660", TAG+="uaccess", TAG+="udev-acl"

# Blue, NanoS, Aramis, HW.2, Nano X, NanoSP, Stax, Ledger Test,
SUBSYSTEMS=="usb", ATTRS{idVendor}=="2c97", MODE="0660", TAG+="uaccess", TAG+="udev-acl"

# Same, but with hidraw-based library (instead of libusb).
# MODE 0660 + uaccess/udev-acl tags: only root+group can rw via raw perms,
# and systemd-logind grants the seated user a dynamic ACL via uaccess --
# tighter than the upstream 0666 which gave any process on the system rw.
KERNEL=="hidraw*", ATTRS{idVendor}=="2c97", MODE="0660", TAG+="uaccess", TAG+="udev-acl"
EOF

echo "triggering udevadm..."
sudo udevadm trigger

echo "reloading rules..."
sudo udevadm control --reload-rules

# Ledger Live AppImage needs FUSE 2 at runtime.
# Pick the available FUSE 2 package instead of suppressing installation errors;
# that pattern hid the real apt error when the actual install failed for
# an unrelated reason (proxy down, dpkg lock, ...).
echo "installing FUSE 2 runtime for the Ledger Live AppImage..."
sudo apt-get update
if apt-cache show libfuse2t64 >/dev/null 2>&1; then
	sudo apt-get install -y libfuse2t64
else
	sudo apt-get install -y libfuse2
fi

# curl is needed for the download below.
sudo apt-get install -y curl

# ─── Ledger Live AppImage ────────────────────────────────────────────────────
# Ledger publishes no GPG signature for the Linux AppImage and the URL is
# unversioned ("latest"), so the download cannot be cryptographically
# verified or version-pinned -- see TRUST.md, "Ledger Live ❌".
#
# Install system-wide and root-owned so qube-user processes cannot replace the
# AppImage between sessions.
#
# Templates have no direct network; route the curl through the Qubes
# apt proxy. -f makes curl fail on an HTTP error instead of saving an
# error page as the AppImage.
echo "downloading Ledger Live..."
TMP=$(mktemp)
trap 'rm -f "${TMP}"' EXIT
curl --proxy 127.0.0.1:8082 -fsSL https://download.live.ledger.com/latest/linux -o "${TMP}"
sudo install -m 0755 -o root -g root "${TMP}" /usr/bin/LedgerLive.AppImage
echo "installed /usr/bin/LedgerLive.AppImage (root-owned, immutable to qube user)"
