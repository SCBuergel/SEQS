#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

# ─── Microsoft (packages.microsoft.com) signing key ──────────────────────────
# Verified on 2026-05-21 against three independent sources, all agreeing on
# this fingerprint:
#   * https://packages.microsoft.com/keys/microsoft.asc
#   * https://keyserver.ubuntu.com  (by fingerprint)
#   * https://keys.openpgp.org      (by fingerprint)
# uid: "Microsoft (Release signing) <gpgsecurity@microsoft.com>".
#
# NOTE: this is the SHA-256-rebound version of the same key Microsoft has
# used since 2015. The original key block (which we embedded on 2026-05-18)
# carried a SHA-1 self-signature, which Sequoia/sqv-based apt rejects after
# 2026-02-01 -- breaking `apt-get update` against packages.microsoft.com on
# Debian 13. In late June 2025 Microsoft re-issued the binding signature on
# the same key using SHA-256 and republished it at the same URL (see
# https://github.com/microsoft/linux-package-repositories/issues/47, comment
# from @mbearup on 2025-07-01). The fingerprint is unchanged; only the
# self-sig hash algorithm changed (digest algo 2 -> 8). Confirmed locally
# with `gpg --list-packets` against the freshly-fetched key.
#
# Microsoft has additionally introduced a new key for distro-prod repos
# created after April 2025 (RHEL 10, Debian 13, Ubuntu 25.10):
#   AA86 F75E 427A 19DD 3334  6403 EE4D 7792 F748 182B
# The /repos/code channel SEQS uses is still the legacy standalone repo
# signed with BC528686..., so we keep this key. If/when Microsoft re-homes
# `code` onto a distro-prod repo, this component will need a second pinned
# key for that path.
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
Version: BSN Pgp v1.1.0.0

mQENBFYxWIwBCADAKoZhZlJxGNGWzqV+1OG1xiQeoowKhssGAKvd+buXCGISZJwT
LXZqIcIiLP7pqdcZWtE9bSc7yBY2MalDp9Liu0KekywQ6VVX1T72NPf5Ev6x6DLV
7aVWsCzUAF+eb7DC9fPuFLEdxmOEYoPjzrQ7cCnSV4JQxAqhU4T6OjbvRazGl3ag
OeizPXmRljMtUUttHQZnRhtlzkmwIrUivbfFPD+fEoHJ1+uIdfOzZX8/oKHKLe2j
H632kvsNzJFlROVvGLYAk2WRcLu+RjjggixhwiB+Mu/A8Tf4V6b+YppS44q8EvVr
M+QvY7LNSOffSO6Slsy9oisGTdfE39nC7pVRABEBAAG0N01pY3Jvc29mdCAoUmVs
ZWFzZSBzaWduaW5nKSA8Z3Bnc2VjdXJpdHlAbWljcm9zb2Z0LmNvbT6JATQEEwEI
AB4FAlYxWIwCGwMGCwkIBwMCAxUIAwMWAgECHgECF4AACgkQ6z6Urb4SKc+P9gf/
diY2900wvWEgV7iMgrtGzx79W/PbwWiOkKoD9sdzhARXWiP8Q5teL/t5TUH6TZ3B
ENboDjwr705jLLPwuEDtPI9jz4kvdT86JwwG6N8gnWM8Ldi56SdJEtXrzwtlB/Fe
6tyfMT1E/PrJfgALUG9MWTIJkc0GhRJoyPpGZ6YWSLGXnk4c0HltYKDFR7q4wtI8
4cBu4mjZHZbxIO6r8Cci+xxuJkpOTIpr4pdpQKpECM6x5SaT2gVnscbN0PE19KK9
nPsBxyK4wW0AvAhed2qldBPTipgzPhqB2gu0jSryil95bKrSmlYJd1Y1XfNHno5D
xfn5JwgySBIdWWvtOI05gw==
=zPfd
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

# ─── Lock the VS Code repo to its own packages ───────────────────────────────
# Same pattern as Signal/Element: Microsoft signs many products with this one
# key, so without a pin a compromise of Microsoft's signing infrastructure
# could be used to ship a higher-version bash / libc6 / systemd / etc. into
# /repos/code and apt would prefer it over Debian's. Default-deny everything
# from packages.microsoft.com, then re-allow only the code package set.
sudo tee /etc/apt/preferences.d/vscode.pref > /dev/null <<'EOF'
Package: *
Pin: origin "packages.microsoft.com"
Pin-Priority: -1

Package: code code-insiders code-exploration
Pin: origin "packages.microsoft.com"
Pin-Priority: 500
EOF

# ─── Install VS Code ─────────────────────────────────────────────────────────
sudo apt-get update
sudo apt-get install -y code
