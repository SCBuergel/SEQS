#!/usr/bin/env bash
set -Eeuo pipefail

echo "Installing pinned GnosisVPN stable release..."

ASSET_DIR="$(dirname "$0")"
# This is the package selected by the upstream stable-channel installer at
# https://downloads.vpn.gnosis.eth.limo/linux/install.sh on 2026-07-28.
# Fetch the reviewed package directly instead of piping that mutable script to
# root. This preserves SEQS's version/hash pin and detached-signature check.
GNOSISVPN_URL="https://download.vpn.gnosis.eth.limo/linux/apt/pool/main/g/gnosisvpn/gnosisvpn_0.90.0_amd64.deb"
GNOSISVPN_SHA256="ab91ca3e7824db22bef9e9a27e683714880fc5306b09f99f992a8d57cfa945f1"
GNOSISVPN_KEY_FPR="9A308031FD3BFE8EDBF5076D84F73FEA46D10972"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
cd "${tmp}"

got_fpr="$(
	gpg --show-keys --with-colons "${ASSET_DIR}/gnosisvpn-public-key.asc" 2>/dev/null |
		awk -F: '$1 == "fpr" { print $10; exit }'
)"
[[ "${got_fpr}" = "${GNOSISVPN_KEY_FPR}" ]] || {
	echo "ERROR: embedded GnosisVPN signing key fingerprint mismatch" >&2
	exit 1
}

curl --proxy 127.0.0.1:8082 -fsSL "${GNOSISVPN_URL}" -o g.deb
curl --proxy 127.0.0.1:8082 -fsSL "${GNOSISVPN_URL}.asc" -o g.deb.asc
printf '%s  %s\n' "${GNOSISVPN_SHA256}" g.deb | sha256sum --check --strict
install -d -m 0700 "${tmp}/gnupg"
gpg --batch --homedir "${tmp}/gnupg" \
	--import "${ASSET_DIR}/gnosisvpn-public-key.asc" >/dev/null
gpg --batch --homedir "${tmp}/gnupg" --verify g.deb.asc g.deb
sudo env GNOSISVPN_NETWORK=jura apt install ./g.deb -y

sudo install -m 0755 "${ASSET_DIR}/seqs-gnosisvpn-dns" /usr/sbin/seqs-gnosisvpn-dns
sudo install -m 0755 "${ASSET_DIR}/seqs-gnosisvpn-firewall" /usr/sbin/seqs-gnosisvpn-firewall
sudo install -m 0755 "${ASSET_DIR}/seqs-gnosisvpn-prepare-app" /usr/sbin/seqs-gnosisvpn-prepare-app
sudo install -m 0644 "${ASSET_DIR}/seqs-gnosisvpn-dns.service" /etc/systemd/system/seqs-gnosisvpn-dns.service
sudo install -m 0644 "${ASSET_DIR}/seqs-gnosisvpn-dns.path" /etc/systemd/system/seqs-gnosisvpn-dns.path
sudo install -m 0644 "${ASSET_DIR}/seqs-gnosisvpn-dns.timer" /etc/systemd/system/seqs-gnosisvpn-dns.timer
sudo systemctl daemon-reload
sudo systemctl enable seqs-gnosisvpn-dns.path
sudo systemctl enable seqs-gnosisvpn-dns.timer

echo "GnosisVPN ${GNOSISVPN_URL##*/} installed for network jura."
