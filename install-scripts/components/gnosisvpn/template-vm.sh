#!/usr/bin/env bash
set -Eeuo pipefail

echo "Installing GnosisVPN from its stable APT repository..."

ASSET_DIR="$(dirname "$0")"
. "${ASSET_DIR}/verify-gpg.sh"
# Upstream's manual APT setup (download.vpn.gnosis.eth.limo, Linux guide),
# without its mutable install.sh: the stable suite on both mirrors, so that
# the Qubes updater upgrades GnosisVPN like any other package. apt trusts the
# repository only through SEQS's copy of the key below, which is locked.
GNOSISVPN_KEY_FPR="9A308031FD3BFE8EDBF5076D84F73FEA46D10972"
KEYRING="/usr/share/keyrings/seqs-gnosisvpn-archive-keyring.gpg"
# The package's own copy, which its postinst rewrites on every install. SEQS
# releases before the switch to the repository locked it; unlock it so that
# the package can write it. apt does not use it.
PACKAGE_KEYRING="/etc/apt/keyrings/gnosisvpn-archive-keyring.gpg"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# Like every other third-party repository, it may supply only its own
# package; the pin is in place before the repository is.
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

# A rerun finds the keyring locked by lock_keyring below.
sudo chattr -i "${KEYRING}" 2>/dev/null || true
import_pinned_key "${tmp}/gnupg" "${GNOSISVPN_KEY_FPR}" < "${ASSET_DIR}/gnosisvpn-public-key.asc"
gpg --export "${GNOSISVPN_KEY_FPR}" | sudo tee "${KEYRING}" > /dev/null
lock_keyring "${KEYRING}" "${GNOSISVPN_KEY_FPR}"

# The postinst rewrites this file, pointing it at its own keyring copy, only
# when its suite or mirror list differs from the ones below, so they match.
sources() {
	printf 'Types: deb\nURIs: %s\nSuites: stable\nComponents: main\nArchitectures: amd64\nSigned-By: %s\n' "$1" "${KEYRING}"
}
sources "https://download.vpn.gnosis.eth.limo/linux/apt https://download.gnosisvpn.io/linux/apt" \
	| sudo tee /etc/apt/sources.list.d/gnosisvpn.sources > /dev/null

# The build's temporary update proxy reaches only download.gnosisvpn.io, so
# refresh only that mirror and keep Debian's lists, which the runner fetched.
mkdir "${tmp}/sources.d"
sources https://download.gnosisvpn.io/linux/apt > "${tmp}/sources.d/gnosisvpn.sources"
sudo apt-get update -o Dir::Etc::SourceList=/dev/null -o Dir::Etc::SourceParts="${tmp}/sources.d" \
	-o APT::Get::List-Cleanup=0

sudo chattr -i "${PACKAGE_KEYRING}" 2>/dev/null || true
# SEQS releases before the switch held the package.
sudo apt-mark unhold gnosisvpn >/dev/null 2>&1 || true
sudo env GNOSISVPN_NETWORK=jura-prod apt-get install -y gnosisvpn

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

echo "GnosisVPN $(dpkg-query -W -f='${Version}' gnosisvpn) installed for network jura-prod."
