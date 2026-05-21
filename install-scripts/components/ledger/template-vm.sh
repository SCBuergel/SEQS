#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

echo "Adding Ledger udev rules..."

cat << EOF | sudo tee /etc/udev/rules.d/20-hw1.rules
# HW.1, Nano
SUBSYSTEMS=="usb", ATTRS{idVendor}=="2581", ATTRS{idProduct}=="1b7c|2b7c|3b7c|4b7c", TAG+="uaccess", TAG+="udev-acl"

# Blue, NanoS, Aramis, HW.2, Nano X, NanoSP, Stax, Ledger Test,
SUBSYSTEMS=="usb", ATTRS{idVendor}=="2c97", TAG+="uaccess", TAG+="udev-acl"

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
# Debian 13 ships it as libfuse2t64; Debian 12 as libfuse2.
echo "installing FUSE 2 runtime for the Ledger Live AppImage..."
sudo apt-get update
sudo apt-get install -y libfuse2t64 2>/dev/null || sudo apt-get install -y libfuse2

# curl is needed for the download below.
sudo apt-get install -y curl

# ─── Ledger Live AppImage ────────────────────────────────────────────────────
# Ledger publishes no GPG signature for the Linux AppImage and the URL is
# unversioned ("latest"), so the download cannot be cryptographically
# verified or version-pinned -- see TRUST.md, "Ledger Live ❌".
#
# We install it system-wide in the TEMPLATE phase (not the app-vm phase, as
# previously) so the final artifact is owned root:root at /usr/bin/.
# Reason: the app-vm phase previously placed it at ~/LedgerLive.AppImage
# owned user:user, where anything running as the qube user account could
# overwrite the AppImage between sessions. That makes a one-time-clean
# install only good until the first piece of user-account code execution
# in the wallet qube. KeePass already installs its AppImage this way
# (/usr/bin/keepassxc.AppImage, root-owned) -- this brings Ledger in line.
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
