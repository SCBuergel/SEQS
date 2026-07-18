#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

# Shared helper verifies the embedded key and pinned fingerprint.
. "$(dirname "$0")/verify-gpg.sh"

# ─── Configuration ───────────────────────────────────────────────────────────
KEYRING="/usr/share/keyrings/signal-desktop-keyring.gpg"

# Signal Desktop apt signing key.
#
# Signal does NOT publish this fingerprint anywhere on signal.org -- their
# documented procedure simply trusts whatever keys.asc is served over HTTPS.
# The fingerprint below was therefore cross-checked on 2026-05-18 against:
#   * the key served at https://updates.signal.org/desktop/apt/keys.asc
#   * a keys.openpgp.org by-fingerprint lookup -> "Open Whisper Systems
#     <support@whispersystems.org>"
#   * Wayback Machine snapshots of keys.asc from 2018, 2020 and 2022 -- the
#     same fingerprint has been served for 8+ years (no recent substitution)
#
# The key is embedded below so nothing is fetched over the network to
# establish trust. Re-verify the fingerprint if you ever replace it.
SIGNAL_KEY_FPR="DBA36B5181D0C816F630E889D980A17457F6FB06"

echo "Installing Signal Desktop"

# ─── Dependencies ────────────────────────────────────────────────────────────
# gpg is needed to inspect and export the signing key
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
N+O606NOXLwcmq5KZL0g
=zyVo
-----END PGP PUBLIC KEY BLOCK-----
EOF

# Require the embedded key block to contain EXACTLY the pinned fingerprint
# and no other keys (see verify_imported_keyring_matches header).
verify_imported_keyring_matches "${SIGNAL_KEY_FPR}"

# ─── Install the keyring (binary form apt expects) and the repository ────────
gpg --export "${SIGNAL_KEY_FPR}" | sudo tee "${KEYRING}" > /dev/null

echo "deb [arch=amd64 signed-by=${KEYRING}] https://updates.signal.org/desktop/apt xenial main" \
	| sudo tee /etc/apt/sources.list.d/signal-xenial.list > /dev/null

# ─── Lock the Signal repo to its own packages ────────────────────────────────
# Signal's Release file uses a generic "xenial" suite label and a placeholder
# Origin (literally ". xenial"), so by default this third-party repo has the
# same apt priority (500) as Debian's main repos -- it could in principle
# satisfy any package name. The pin file below blocks anything from
# updates.signal.org by default (Pin-Priority -1), then re-allows only
# signal-desktop and signal-desktop-beta at normal priority. Defense-in-depth
# against this repo being repurposed to ship anything other than Signal.
sudo tee /etc/apt/preferences.d/signal-xenial.pref > /dev/null <<'EOF'
Package: *
Pin: origin "updates.signal.org"
Pin-Priority: -1

Package: signal-desktop signal-desktop-beta
Pin: origin "updates.signal.org"
Pin-Priority: 500
EOF

# ─── Install ─────────────────────────────────────────────────────────────────
sudo apt-get update
sudo apt-get install -y signal-desktop

# ─── Lock the keyring file against in-place rewrite ──────────────────────────
# See vscode/template-vm.sh for the rationale. The Pin-Priority allowlist
# bounds which package names this repo can ship; chattr +i additionally
# bounds what root-running maintainer scripts inside an allowlisted
# package can do to the trust anchor at ${KEYRING}. Key rotation must
# then go through `sudo chattr -i ${KEYRING}` + manual re-verify.
sudo chattr +i "${KEYRING}"
