#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
AOO_VERSION="4.1.16"
APT_PROXY="127.0.0.1:8082"
TARBALL="Apache_OpenOffice_${AOO_VERSION}_Linux_x86-64_install-deb_en-US.tar.gz"
BASE_URL="https://downloads.apache.org/openoffice/${AOO_VERSION}/binaries/en-US"

# Apache OpenOffice release signing key (Jim Jagielski).
#
# Verified on 2026-05-19 against three independent sources, all agreeing on
# this fingerprint:
#   * the Apache OpenOffice KEYS file: https://downloads.apache.org/openoffice/KEYS
#   * the Apache committer keyring:    https://people.apache.org/keys/committer/jim.asc
#   * keyserver.ubuntu.com  (by fingerprint)
# uid: "Jim Jagielski (Release Signing Key) <jim@apache.org>".
#
# The key is embedded below so nothing is fetched over the network to
# establish trust. Re-verify the fingerprint if you ever replace it.
AOO_KEY_FPR="A93D62ECC3C8EA12DB220EC934EA76E6791485A8"

echo "Installing Apache OpenOffice ${AOO_VERSION}"

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
L6WGGssH
=Kkij
-----END PGP PUBLIC KEY BLOCK-----
EOF

IMPORTED_FPR="$(gpg --with-colons --fingerprint | awk -F: '$1=="fpr"{print $10; exit}')"
if [[ "${IMPORTED_FPR}" != "${AOO_KEY_FPR}" ]]; then
	echo "ERROR: embedded Apache OpenOffice key fingerprint mismatch -- aborting." >&2
	echo "  expected: ${AOO_KEY_FPR}" >&2
	echo "  got     : ${IMPORTED_FPR:-<none>}" >&2
	exit 1
fi

# ─── Download the tarball and its detached signature ─────────────────────────
echo "downloading ${TARBALL}..."
curl --proxy "${APT_PROXY}" -fLso "${WORKDIR}/${TARBALL}"     "${BASE_URL}/${TARBALL}"
curl --proxy "${APT_PROXY}" -fLso "${WORKDIR}/${TARBALL}.asc" "${BASE_URL}/${TARBALL}.asc"

# ─── Verify the signature chains to the pinned key ───────────────────────────
echo "verifying signature..."
STATUS="$(gpg --status-fd 1 --verify "${WORKDIR}/${TARBALL}.asc" "${WORKDIR}/${TARBALL}" 2>/dev/null)" || true
if ! awk -v fpr="${AOO_KEY_FPR}" \
        '$2=="VALIDSIG" && $NF==fpr {ok=1} END {exit !ok}' <<<"${STATUS}"; then
	echo "ERROR: Apache OpenOffice signature verification FAILED -- not installing." >&2
	echo "${STATUS}" >&2
	exit 1
fi
echo "signature OK -- ${TARBALL} signed by ${AOO_KEY_FPR}"

# ─── Unpack and install (apt resolves the local .debs' dependencies) ─────────
echo "unpacking..."
tar -xzf "${WORKDIR}/${TARBALL}" -C "${WORKDIR}"

echo "installing packages..."
sudo apt-get install -y "${WORKDIR}"/en-US/DEBS/*.deb
sudo apt-get install -y "${WORKDIR}"/en-US/DEBS/desktop-integration/*.deb
