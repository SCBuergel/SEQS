#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
KEYRING="/usr/share/keyrings/element-io-archive-keyring.gpg"

# Element (element.io) apt signing key.
#
# Element Desktop is NOT in the Debian repositories (verified 2026-05-20 against
# https://packages.debian.org/trixie/element-desktop -> "No such package"), so
# the install relies on element.io's own apt repository. The signing key
# fingerprint below was cross-checked on 2026-05-20 against three independent
# sources, all agreeing:
#   * the key served by Element's install source:
#       https://packages.element.io/debian/element-io-archive-keyring.gpg
#   * keyserver.ubuntu.com  (by fingerprint)
#   * keys.openpgp.org      (by fingerprint)
# A Wayback Machine snapshot of the install-source key from 2023 carries the
# same fingerprint -- multi-year longevity confirms it is not a recent swap.
# uid: "riot.im packages <packages@riot.im>" (the key dates from Element's
# previous name and still carries that uid).
#
# The key is embedded below so nothing is fetched over the network to
# establish trust. Re-verify the fingerprint if you ever replace it.
ELEMENT_KEY_FPR="12D4CD600C2240A9F4A82071D7B0B66941D01538"

echo "Installing Element Desktop"

# ─── Dependencies ────────────────────────────────────────────────────────────
if ! command -v gpg >/dev/null 2>&1; then
	sudo apt-get update
	sudo apt-get install -y gnupg
fi

# ─── Verify the embedded signing key ─────────────────────────────────────────
GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
trap 'rm -rf "${GNUPGHOME}"' EXIT

gpg --import <<'EOF'
-----BEGIN PGP PUBLIC KEY BLOCK-----

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
=euoM
-----END PGP PUBLIC KEY BLOCK-----
EOF

# Fail unless the embedded key really is the pinned one (guards against an
# accidentally edited or corrupted key block above).
IMPORTED_FPR="$(gpg --with-colons --fingerprint | awk -F: '$1=="pub"{w=1} $1=="fpr"&&w{print $10; exit}')"
if [[ "${IMPORTED_FPR}" != "${ELEMENT_KEY_FPR}" ]]; then
	echo "ERROR: embedded Element key fingerprint mismatch -- aborting." >&2
	echo "  expected: ${ELEMENT_KEY_FPR}" >&2
	echo "  got     : ${IMPORTED_FPR:-<none>}" >&2
	exit 1
fi
echo "Element signing key verified: ${ELEMENT_KEY_FPR}"

# ─── Install the keyring (binary form apt expects) and the repository ────────
gpg --export "${ELEMENT_KEY_FPR}" | sudo tee "${KEYRING}" > /dev/null

echo "deb [signed-by=${KEYRING}] https://packages.element.io/debian/ default main" \
	| sudo tee /etc/apt/sources.list.d/element-io.list > /dev/null

# ─── Install ─────────────────────────────────────────────────────────────────
sudo apt-get update
sudo apt-get install -y element-desktop
