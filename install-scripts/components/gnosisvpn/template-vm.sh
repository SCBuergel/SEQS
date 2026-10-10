#!/usr/bin/env bash
set -Eeuo pipefail

echo "Installing pinned GnosisVPN stable release..."

ASSET_DIR="$(dirname "$0")"
# This is the stable-channel package listed on 2026-10-10 in the APT index of
# https://download.vpn.gnosis.eth.limo/linux/apt, whose InRelease file is
# signed by the key below; the hash matches that signed index. Fetch the
# reviewed package directly instead of piping upstream's mutable install.sh to
# root. This preserves SEQS's version/hash pin and detached-signature check.
GNOSISVPN_URL="https://download.vpn.gnosis.eth.limo/linux/apt/pool/main/g/gnosisvpn/gnosisvpn_0.95.2_amd64.deb"
GNOSISVPN_SHA256="87294d45d382d22181089c2f7f0a25330c75b77ef22b3989d399abf4027d3bdb"
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
# The package installs upstream's APT repository (two mirrors) and its
# keyring. A rerun finds that keyring locked by the chattr +i below; the
# package rewrites it, so unlock it first.
KEYRING="/etc/apt/keyrings/gnosisvpn-archive-keyring.gpg"
sudo chattr -i "${KEYRING}" 2>/dev/null || true
sudo env GNOSISVPN_NETWORK=jura-prod apt install ./g.deb -y

# Treat that repository like every other third-party one: its keyring must
# hold exactly the pinned key, only the gnosisvpn package may come from it,
# and the keyring is locked against rewrite by later maintainer scripts.
repo_fpr="$(
	gpg --show-keys --with-colons "${KEYRING}" 2>/dev/null |
		awk -F: '$1 == "pub" { p = 1; n++ } $1 == "fpr" && p { print $10; p = 0 } END { if (n != 1) print "count:" n }'
)"
[[ "${repo_fpr}" = "${GNOSISVPN_KEY_FPR}" ]] || {
	echo "ERROR: ${KEYRING} does not hold exactly the pinned GnosisVPN key (got: ${repo_fpr:-none})" >&2
	exit 1
}
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
sudo chattr +i "${KEYRING}"

sudo install -m 0755 "${ASSET_DIR}/seqs-gnosisvpn-dns" /usr/sbin/seqs-gnosisvpn-dns
sudo install -m 0755 "${ASSET_DIR}/seqs-gnosisvpn-firewall" /usr/sbin/seqs-gnosisvpn-firewall
sudo install -m 0755 "${ASSET_DIR}/seqs-gnosisvpn-prepare-app" /usr/sbin/seqs-gnosisvpn-prepare-app
sudo install -m 0644 "${ASSET_DIR}/seqs-gnosisvpn-dns.service" /etc/systemd/system/seqs-gnosisvpn-dns.service
sudo install -m 0644 "${ASSET_DIR}/seqs-gnosisvpn-dns.path" /etc/systemd/system/seqs-gnosisvpn-dns.path
sudo install -m 0644 "${ASSET_DIR}/seqs-gnosisvpn-dns.timer" /etc/systemd/system/seqs-gnosisvpn-dns.timer
sudo systemctl daemon-reload
sudo systemctl enable seqs-gnosisvpn-dns.path
sudo systemctl enable seqs-gnosisvpn-dns.timer

echo "GnosisVPN ${GNOSISVPN_URL##*/} installed for network jura-prod."
