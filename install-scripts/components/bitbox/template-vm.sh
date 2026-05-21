#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

# Shared gpg detached-sig verification helper; setup-qubes.sh moves
# verify-gpg.sh in next to this script via the LIB_FILES mechanism.
. "$(dirname "$0")/verify-gpg.sh"

# ─── Configuration ───────────────────────────────────────────────────────────
BITBOX_VERSION="4.51.0"
APT_PROXY="127.0.0.1:8082"
DEB="bitbox_${BITBOX_VERSION}_amd64.deb"
BASE_URL="https://github.com/BitBoxSwiss/bitbox-wallet-app/releases/download/v${BITBOX_VERSION}"

# BitBoxApp (Shift Crypto) release signing key.
#
# Verified on 2026-05-19 against three independent sources, all agreeing on
# this fingerprint:
#   * BitBox's own docs -- support.bitbox.swiss/.../verify-bitboxapp-signature-linux
#     publish this fingerprint and the key at
#     https://bitbox.swiss/download/shiftcryptosec-509249B068D215AE.gpg.asc
#   * keyserver.ubuntu.com  (by key id)
#   * keys.openpgp.org      (by key id)
# uid: "ShiftCrypto Security <security@shiftcrypto.ch>".
# (An earlier key, 1AA6 2C17 ... 0AD5 161E, was revoked and replaced by this one.)
#
# The key is embedded below so nothing is fetched over the network to
# establish trust. Re-verify the fingerprint if you ever replace it.
BITBOX_KEY_FPR="DD09E41309750EBFAE0DEF63509249B068D215AE"

echo "Installing BitBoxApp ${BITBOX_VERSION}"

# ─── Dependencies ────────────────────────────────────────────────────────────
sudo apt-get update
command -v gpg >/dev/null 2>&1 || sudo apt-get install -y gnupg

# ─── Throwaway working directories ───────────────────────────────────────────
GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${GNUPGHOME}" "${WORKDIR}"' EXIT

# ─── Verify the embedded signing key ─────────────────────────────────────────
gpg --import <<'EOF'
-----BEGIN PGP PUBLIC KEY BLOCK-----

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
jLZugv6bMuMLjA==
=0krM
-----END PGP PUBLIC KEY BLOCK-----
EOF

# Require the embedded key block to contain EXACTLY the pinned fingerprint
# and no other keys (see verify_imported_keyring_matches header).
verify_imported_keyring_matches "${BITBOX_KEY_FPR}"

# ─── Download the .deb and its detached signature ────────────────────────────
echo "downloading ${DEB}..."
curl --proxy "${APT_PROXY}" -fLso "${WORKDIR}/${DEB}"     "${BASE_URL}/${DEB}"
curl --proxy "${APT_PROXY}" -fLso "${WORKDIR}/${DEB}.asc" "${BASE_URL}/${DEB}.asc"

# ─── Verify the signature chains to the pinned key ───────────────────────────
echo "verifying signature..."
verify_detached_sig \
	"${WORKDIR}/${DEB}.asc" \
	"${WORKDIR}/${DEB}" \
	"${BITBOX_KEY_FPR}" \
	"${DEB}"

# Bind the verified bytes to what apt actually installs. `apt-get install`
# below opens the .deb a second time and does NOT re-verify the gpg
# signature for a local file path; without binding, there is a TOCTOU
# window between the check above and that second read. Two cheap defenses:
#   (a) pin the SHA-256 of the just-verified file and re-check it right
#       before the apt-get install call -- catches any in-place tampering
#       (or filesystem corruption) during the window;
#   (b) drop the file to mode 0400 so a tamper attempt has to chmod first
#       and is therefore louder.
SHA_VERIFIED="$(sha256sum "${WORKDIR}/${DEB}" | awk '{print $1}')"
chmod 0400 "${WORKDIR}/${DEB}"

# ─── Install (apt resolves the .deb's dependencies) ──────────────────────────
SHA_PREINSTALL="$(sha256sum "${WORKDIR}/${DEB}" | awk '{print $1}')"
if [ "${SHA_VERIFIED}" != "${SHA_PREINSTALL}" ]; then
	echo "ERROR: .deb hash changed between gpg --verify and install -- aborting." >&2
	echo "  at verify:  ${SHA_VERIFIED}" >&2
	echo "  at install: ${SHA_PREINSTALL}" >&2
	exit 1
fi
# --no-install-recommends: defense-in-depth against the BitBox .deb pulling
# in unexpected optional packages from whatever third-party repos may be
# configured in this template later. The per-repo Pin-Priority: -1 + named
# allowlist pattern (signal/element/docker/vscode/brave) already blocks
# at the origin level, but Recommends is the next-narrowest knob and is
# free here -- BitBox declares its own hard deps.
sudo apt-get install -y --no-install-recommends "${WORKDIR}/${DEB}"
