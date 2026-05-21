#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

# Shared gpg detached-sig verification helper; setup-qubes.sh moves
# verify-gpg.sh in next to this script via the LIB_FILES mechanism.
. "$(dirname "$0")/verify-gpg.sh"

# ─── Configuration ───────────────────────────────────────────────────────────
KEEPASSXC_VERSION="2.7.12"
APT_PROXY="127.0.0.1:8082"
APPIMAGE="KeePassXC-${KEEPASSXC_VERSION}-x86_64.AppImage"
BASE_URL="https://github.com/keepassxreboot/keepassxc/releases/download/${KEEPASSXC_VERSION}"

# KeePassXC release signing key.
#
# The downloaded AppImage's detached signature must chain to this primary key.
# The fingerprint was verified on 2026-05-18 against three independent sources:
#   * https://keepassxc.org/verifying-signatures/
#   * keys.openpgp.org by-fingerprint lookup -> "KeePassXC Release
#     <release@keepassxc.org>"
#   * the Arch Linux `keepassxc` PKGBUILD `validpgpkeys` array
# A live `gpg --verify` of the 2.7.12 signature with this key succeeded
# (VALIDSIG ... BF5A669F2272CF4324C1FDA8CFB4C2166397D0D2).
#
# The key block is embedded below so nothing is fetched over the network to
# establish trust. If you ever replace it, re-verify the fingerprint.
KEEPASSXC_KEY_FPR="BF5A669F2272CF4324C1FDA8CFB4C2166397D0D2"

echo "Installing KeePassXC ${KEEPASSXC_VERSION} from AppImage"

# ─── Dependencies ────────────────────────────────────────────────────────────
sudo apt-get update
# gpg: needed to verify the release signature below
command -v gpg >/dev/null 2>&1 || sudo apt-get install -y gnupg
# AppImage runtime needs FUSE 2 (libfuse2t64 on Debian 13, libfuse2 on Debian 12)
sudo apt-get install -y libfuse2t64 2>/dev/null || sudo apt-get install -y libfuse2

# ─── Throwaway working directories ───────────────────────────────────────────
GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${GNUPGHOME}" "${WORKDIR}"' EXIT

# ─── Import the pinned KeePassXC release signing key ─────────────────────────
gpg --import <<'EOF'
-----BEGIN PGP PUBLIC KEY BLOCK-----

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
=7yqw
-----END PGP PUBLIC KEY BLOCK-----
EOF

# Fail unless the embedded key really is the pinned one (guards against an
# accidentally edited or corrupted key block above).
IMPORTED_FPR="$(gpg --with-colons --fingerprint | awk -F: '$1=="pub"{w=1} $1=="fpr"&&w{print $10; exit}')"
if [[ "${IMPORTED_FPR}" != "${KEEPASSXC_KEY_FPR}" ]]; then
	echo "ERROR: embedded KeePassXC key fingerprint mismatch -- aborting." >&2
	echo "  expected: ${KEEPASSXC_KEY_FPR}" >&2
	echo "  got     : ${IMPORTED_FPR:-<none>}" >&2
	exit 1
fi

# ─── Download the AppImage and its detached signature ────────────────────────
# -f makes curl fail on HTTP errors instead of saving an error page as the binary.
echo "downloading ${APPIMAGE} ..."
curl --proxy "${APT_PROXY}" -fLso "${WORKDIR}/${APPIMAGE}"     "${BASE_URL}/${APPIMAGE}"
curl --proxy "${APT_PROXY}" -fLso "${WORKDIR}/${APPIMAGE}.sig" "${BASE_URL}/${APPIMAGE}.sig"

# ─── Verify the signature chains to the pinned KeePassXC release key ─────────
echo "verifying signature ..."
verify_detached_sig \
	"${WORKDIR}/${APPIMAGE}.sig" \
	"${WORKDIR}/${APPIMAGE}" \
	"${KEEPASSXC_KEY_FPR}" \
	"${APPIMAGE}"

# ─── Bind the verified bytes to what gets installed ──────────────────────────
# Close the TOCTOU window between gpg --verify and `sudo install`: the AppImage
# sits in a user-owned mktemp dir while it waits to be copied to /usr/bin/.
# Hash the just-verified file, drop it to 0400 so a tamper attempt has to
# chmod first (louder), then re-hash immediately before the install and bail
# on drift. Same pattern as bitbox/template-vm.sh.
SHA_VERIFIED="$(sha256sum "${WORKDIR}/${APPIMAGE}" | awk '{print $1}')"
chmod 0400 "${WORKDIR}/${APPIMAGE}"

SHA_PREINSTALL="$(sha256sum "${WORKDIR}/${APPIMAGE}" | awk '{print $1}')"
if [ "${SHA_VERIFIED}" != "${SHA_PREINSTALL}" ]; then
	echo "ERROR: AppImage hash changed between gpg --verify and install -- aborting." >&2
	echo "  at verify:  ${SHA_VERIFIED}" >&2
	echo "  at install: ${SHA_PREINSTALL}" >&2
	exit 1
fi

# ─── Install ─────────────────────────────────────────────────────────────────
sudo install -m 0755 "${WORKDIR}/${APPIMAGE}" /usr/bin/keepassxc.AppImage
echo "installed /usr/bin/keepassxc.AppImage (KeePassXC ${KEEPASSXC_VERSION})"
