#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

# ─── Microsoft (packages.microsoft.com) signing key ──────────────────────────
# Verified on 2026-05-19 against three independent sources, all agreeing on
# this fingerprint:
#   * https://packages.microsoft.com/keys/microsoft.asc
#   * https://keyserver.ubuntu.com  (by fingerprint)
#   * https://keys.openpgp.org      (by fingerprint)
# uid: "Microsoft (Release signing) <gpgsecurity@microsoft.com>".
#
# The key is embedded below so nothing is fetched over the network to
# establish trust. Re-verify the fingerprint if you ever replace it.
MS_KEY_FPR="BC528686B50D79E339D3721CEB3E94ADBE1229CF"
KEYRING="/etc/apt/keyrings/packages.microsoft.gpg"

echo "Installing VS Code"

# ─── Dependencies ────────────────────────────────────────────────────────────
sudo apt-get update
command -v gpg >/dev/null 2>&1 || sudo apt-get install -y gnupg
sudo install -m 0755 -d /etc/apt/keyrings

# ─── Verify the embedded signing key ─────────────────────────────────────────
GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
trap 'rm -rf "${GNUPGHOME}"' EXIT

gpg --import <<'EOF'
-----BEGIN PGP PUBLIC KEY BLOCK-----
Version: GnuPG v1.4.7 (GNU/Linux)

mQENBFYxWIwBCADAKoZhZlJxGNGWzqV+1OG1xiQeoowKhssGAKvd+buXCGISZJwT
LXZqIcIiLP7pqdcZWtE9bSc7yBY2MalDp9Liu0KekywQ6VVX1T72NPf5Ev6x6DLV
7aVWsCzUAF+eb7DC9fPuFLEdxmOEYoPjzrQ7cCnSV4JQxAqhU4T6OjbvRazGl3ag
OeizPXmRljMtUUttHQZnRhtlzkmwIrUivbfFPD+fEoHJ1+uIdfOzZX8/oKHKLe2j
H632kvsNzJFlROVvGLYAk2WRcLu+RjjggixhwiB+Mu/A8Tf4V6b+YppS44q8EvVr
M+QvY7LNSOffSO6Slsy9oisGTdfE39nC7pVRABEBAAG0N01pY3Jvc29mdCAoUmVs
ZWFzZSBzaWduaW5nKSA8Z3Bnc2VjdXJpdHlAbWljcm9zb2Z0LmNvbT6JATUEEwEC
AB8FAlYxWIwCGwMGCwkIBwMCBBUCCAMDFgIBAh4BAheAAAoJEOs+lK2+EinPGpsH
/32vKy29Hg51H9dfFJMx0/a/F+5vKeCeVqimvyTM04C+XENNuSbYZ3eRPHGHFLqe
MNGxsfb7C7ZxEeW7J/vSzRgHxm7ZvESisUYRFq2sgkJ+HFERNrqfci45bdhmrUsy
7SWw9ybxdFOkuQoyKD3tBmiGfONQMlBaOMWdAsic965rvJsd5zYaZZFI1UwTkFXV
KJt3bp3Ngn1vEYXwijGTa+FXz6GLHueJwF0I7ug34DgUkAFvAs8Hacr2DRYxL5RJ
XdNgj4Jd2/g6T9InmWT0hASljur+dJnzNiNCkbn9KbX7J/qK1IbR8y560yRmFsU+
NdCFTW7wY0Fb1fWJ+/KTsC4=
=J6gs
-----END PGP PUBLIC KEY BLOCK-----
EOF

IMPORTED_FPR="$(gpg --with-colons --fingerprint | awk -F: '$1=="pub"{w=1} $1=="fpr"&&w{print $10; exit}')"
if [[ "${IMPORTED_FPR}" != "${MS_KEY_FPR}" ]]; then
	echo "ERROR: embedded Microsoft key fingerprint mismatch -- aborting." >&2
	echo "  expected: ${MS_KEY_FPR}" >&2
	echo "  got     : ${IMPORTED_FPR:-<none>}" >&2
	exit 1
fi
echo "Microsoft signing key verified: ${MS_KEY_FPR}"

# ─── Install the keyring and the repository ──────────────────────────────────
gpg --export "${MS_KEY_FPR}" | sudo tee "${KEYRING}" > /dev/null

echo "deb [arch=amd64,arm64,armhf signed-by=${KEYRING}] https://packages.microsoft.com/repos/code stable main" \
	| sudo tee /etc/apt/sources.list.d/vscode.list > /dev/null

# ─── Install VS Code ─────────────────────────────────────────────────────────
sudo apt-get update
sudo apt-get install -y code
