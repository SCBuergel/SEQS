#!/usr/bin/env bash
set -Eeuo pipefail
. "$(dirname "$0")/verify-gpg.sh"

echo "Adding Ledger udev rules..."

cat << EOF | sudo tee /etc/udev/rules.d/20-hw1.rules > /dev/null
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

echo "reloading udev rules..."
sudo udevadm control --reload-rules
sudo udevadm trigger

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

# curl downloads, openssl checks Ledger's signature below.
sudo apt-get install -y curl openssl

# ─── Ledger Live AppImage ────────────────────────────────────────────────────
# Ledger signs a SHA-512 list of each release's files with an ECDSA key
# (secp256k1), which Ledger Live's own updater embeds: LEDGER_PUBKEY below is
# apps/ledger-live-desktop/src/main/updater/ledger-pubkey.ts in
# github.com/LedgerHQ/ledger-live, and the Whonix wiki's "Ledger Live
# Installation with Verification" shows the same key. On 2026-10-25 the 4.24.1
# list verified against it and named LEDGER_SHA512, the hash of the AppImage
# then served. The pin fixes the release; the signature lets a reviewer trust
# the key instead of the hash.
#
# Installed root-owned in the template: the app qube then gets it from the
# template's root volume at every start, so a swap takes root and a hook under
# /rw rather than a write to the home directory (see TRUST.md).
LEDGER_VERSION="4.24.1"
LEDGER_SHA512="8563680f38dc59f023f79a1e86037e39fea8b7c2fbf6158987b197f5b04e13b456cf387f55f76ec8b35faddd3fdb4802e1648e0e064285e2c217b81964e096cc"
APPIMAGE="ledger-live-desktop-${LEDGER_VERSION}-linux-x86_64.AppImage"
SUMS="ledger-live-desktop-${LEDGER_VERSION}.sha512sum"
LEDGER_PUBKEY='-----BEGIN PUBLIC KEY-----
MFYwEAYHKoZIzj0CAQYFK4EEAAoDQgAEN7qcsG6bogi1nkD3jnMWS813wWguYEcI
CRcijSvFskSFjHB5la4xUt+Omb2t6iUwop+JRy+EUhy0UQ9p/cPsQA==
-----END PUBLIC KEY-----'

# Templates have no direct network; route the downloads through the Qubes
# update proxy. -f makes curl fail on an HTTP error instead of saving the page.
echo "downloading ${APPIMAGE}..."
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
curl --proxy "${UPDATES_PROXY}" -fsSL -o "${TMP}/${APPIMAGE}" "https://download.live.ledger.com/${APPIMAGE}"
for f in "${SUMS}" "${SUMS}.sig"; do
	curl --proxy "${UPDATES_PROXY}" -fsSL -o "${TMP}/${f}" \
		"https://resources.live.ledger.app/public_resources/signatures/${f}"
done
printf '%s  %s\n' "${LEDGER_SHA512}" "${TMP}/${APPIMAGE}" | sha512sum --check --strict --quiet \
	|| { echo "ERROR: ${APPIMAGE} does not have the pinned SHA-512 -- not installing." >&2; exit 1; }
printf '%s\n' "${LEDGER_PUBKEY}" > "${TMP}/ledger.pem"
openssl dgst -sha256 -verify "${TMP}/ledger.pem" -signature "${TMP}/${SUMS}.sig" "${TMP}/${SUMS}" \
	&& awk -v h="${LEDGER_SHA512}" -v f="${APPIMAGE}" '$1 == h && $2 == f { ok = 1 } END { exit !ok }' "${TMP}/${SUMS}" \
	|| { echo "ERROR: Ledger's signed hash list does not vouch for ${APPIMAGE} -- not installing." >&2; exit 1; }
echo "sha512 and Ledger signature OK -- ${APPIMAGE}"
sudo install -m 0755 -o root -g root "${TMP}/${APPIMAGE}" /usr/bin/LedgerLive.AppImage
echo "installed /usr/bin/LedgerLive.AppImage (Ledger Live ${LEDGER_VERSION}, root-owned)"
