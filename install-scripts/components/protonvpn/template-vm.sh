#!/usr/bin/env bash
set -Eeuo pipefail
. "$(dirname "$0")/verify-gpg.sh"

KEYRING="/usr/share/keyrings/protonvpn-stable-archive-keyring.gpg"

# Proton VPN apt signing key. Proton's install guide
# (https://protonvpn.com/support/official-linux-vpn-debian) has users install
# protonvpn-stable-release_1.0.8_all.deb, whose SHA-256 it publishes
# (0b14e715...b03e180). On 2026-10-15 that package matched the hash and held
# exactly this key, which also signed the repository's InRelease file and is
# served by keys.openpgp.org under the same fingerprint. The key is embedded
# instead of installing that package. It expires on 2027-03-03.
PROTON_KEY_FPR="84B0D3492C76C9C6F5873C18EDA3E22630349F1C"

echo "Installing Proton VPN"

# A rerun finds the keyring locked by lock_keyring below.
sudo chattr -i "${KEYRING}" 2>/dev/null || true
# The repository may supply only the app and the Proton libraries it needs.
add_pinned_apt_repo protonvpn-stable "${KEYRING}" "${PROTON_KEY_FPR}" amd64 \
	"https://repo.protonvpn.com/debian stable main" repo.protonvpn.com \
	"proton-vpn-gnome-desktop proton-vpn-gtk-app proton-vpn-cli proton-vpn-daemon python3-proton-vpn-api-core python3-proton-core python3-proton-keyring-linux" <<'KEY'
-----BEGIN PGP PUBLIC KEY BLOCK-----

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
=WVVp
-----END PGP PUBLIC KEY BLOCK-----
KEY

sudo apt-get update
sudo apt-get install -y proton-vpn-gnome-desktop
lock_keyring "${KEYRING}" "${PROTON_KEY_FPR}"
