#!/usr/bin/env bash
set -Eeuo pipefail

echo "Installing pinned GnosisVPN stable release..."

ASSET_DIR="$(dirname "$0")"
. "${ASSET_DIR}/verify-gpg.sh"
# This is the stable-channel package listed on 2026-10-10 in the APT index of
# https://download.vpn.gnosis.eth.limo/linux/apt, whose InRelease file is
# signed by the key below; the hash matches that signed index. Fetch the
# reviewed package directly instead of piping upstream's mutable install.sh to
# root. This preserves SEQS's version/hash pin and detached-signature check.
GNOSISVPN_URL="https://download.vpn.gnosis.eth.limo/linux/apt/pool/main/g/gnosisvpn/gnosisvpn_0.95.2_amd64.deb"
GNOSISVPN_SHA256="87294d45d382d22181089c2f7f0a25330c75b77ef22b3989d399abf4027d3bdb"
GNOSISVPN_KEY_FPR="9A308031FD3BFE8EDBF5076D84F73FEA46D10972"
DEB="${GNOSISVPN_URL##*/}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fetch_signed "${GNOSISVPN_KEY_FPR}" "${GNOSISVPN_URL}" .asc "${tmp}" "${GNOSISVPN_SHA256}" \
	< "${ASSET_DIR}/gnosisvpn-public-key.asc"

# The package installs upstream's APT repository (two mirrors) and its
# keyring. Like every other third-party repository, it may supply only its
# own package; the pin is in place before the repository is.
sudo tee /etc/apt/preferences.d/gnosisvpn.pref > /dev/null <<'EOF'
Package: *
Pin: origin "download.vpn.gnosis.eth.limo"
Pin-Priority: -1

Package: gnosisvpn
Pin: origin "download.vpn.gnosis.eth.limo"
Pin-Priority: 500

Package: *
Pin: origin "download.gnosisvpn.io"
Pin-Priority: -1

Package: gnosisvpn
Pin: origin "download.gnosisvpn.io"
Pin-Priority: 500
EOF

# A rerun finds the package's keyring locked by lock_keyring below; the
# package rewrites it, so unlock it first.
KEYRING="/etc/apt/keyrings/gnosisvpn-archive-keyring.gpg"
sudo chattr -i "${KEYRING}" 2>/dev/null || true
sudo apt-mark unhold gnosisvpn >/dev/null 2>&1 || true
sudo env GNOSISVPN_NETWORK=jura-prod apt-get install -y "${tmp}/${DEB}"

# The package wrote its keyring; it must hold exactly the pinned key, and is
# locked against rewrite by later maintainer scripts.
lock_keyring "${KEYRING}" "${GNOSISVPN_KEY_FPR}"
# Every upgrade rewrites that keyring, which the lock makes fail in dpkg and
# then block every update of the template. Held, GnosisVPN changes only when a
# reviewed SEQS pin installs a new release; the release above lifts the hold.
sudo apt-mark hold gnosisvpn >/dev/null

sudo install -m 0755 "${ASSET_DIR}/seqs-gnosisvpn-dns" /usr/sbin/seqs-gnosisvpn-dns
sudo install -m 0755 "${ASSET_DIR}/seqs-gnosisvpn-firewall" /usr/sbin/seqs-gnosisvpn-firewall
sudo install -m 0755 "${ASSET_DIR}/seqs-gnosisvpn-prepare-app" /usr/sbin/seqs-gnosisvpn-prepare-app
sudo install -m 0755 "${ASSET_DIR}/seqs-gnosisvpn-rates" /usr/bin/seqs-gnosisvpn-rates
sudo install -m 0755 "${ASSET_DIR}/seqs-gnosisvpn-autoconnect" /usr/sbin/seqs-gnosisvpn-autoconnect
sudo install -m 0644 "${ASSET_DIR}/seqs-gnosisvpn-autoconnect.service" /etc/systemd/system/seqs-gnosisvpn-autoconnect.service
sudo install -m 0644 "${ASSET_DIR}/seqs-gnosisvpn-dns.service" /etc/systemd/system/seqs-gnosisvpn-dns.service
sudo install -m 0644 "${ASSET_DIR}/seqs-gnosisvpn-dns.path" /etc/systemd/system/seqs-gnosisvpn-dns.path
sudo install -m 0644 "${ASSET_DIR}/seqs-gnosisvpn-dns.timer" /etc/systemd/system/seqs-gnosisvpn-dns.timer
sudo install -m 0644 "${ASSET_DIR}/99-seqs-gnosisvpn-rmem.conf" /etc/sysctl.d/99-seqs-gnosisvpn-rmem.conf
sudo systemctl daemon-reload
sudo systemctl enable seqs-gnosisvpn-dns.path
sudo systemctl enable seqs-gnosisvpn-dns.timer
sudo systemctl enable seqs-gnosisvpn-autoconnect.service

echo "GnosisVPN ${GNOSISVPN_URL##*/} installed for network jura-prod."
