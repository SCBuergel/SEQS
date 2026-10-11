#!/usr/bin/env bash
#
# Shared Brave helpers for SEQS install scripts.
#
# Sourced, not executed: this file only defines functions and has no side
# effects at source time. The seqs.qube Salt state copies it next to each
# component's install scripts inside the target qube, so install scripts load
# it with:
#
#     . "$(dirname "$0")/brave.sh"
#
# The sourcing script is expected to have run `set -Eeuo pipefail` itself.
#
# -----------------------------------------------------------------------------
# Brave apt signing keys -- how BRAVE_KEY_FPRS below was verified (2026-05-18)
# -----------------------------------------------------------------------------
# install_brave() downloads Brave's apt keyring and aborts unless it contains
# EXACTLY the pinned key fingerprints. Those fingerprints were cross-checked
# against three independent sources -- to forge them an attacker would have to
# compromise all three at once:
#
#   1. The keyring served from the actual install source (S3 apt bucket):
#        curl -fsSL https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg \
#          | gpg --show-keys --with-colons | awk -F: '$1=="fpr"{print $10}'
#
#   2. The same keys published as ASCII-armored PGP blocks on Brave's
#      signing-keys page (different host), under the heading
#      "Linux Package Repositories - Release Channel":
#        https://brave.com/signing-keys/
#      Saving each block and running `gpg --show-keys` on it yields the same
#      three fingerprints.
#
#   3. Key DBF1A116...20038257 is independently hard-coded in an unrelated
#      public project: github.com/fphammerle/docker-brave-browser (Dockerfile,
#      `apt-key adv --recv-keys`).
#
# The three keys all carry uid "Brave Linux Release"
# (brave-linux-release@brave.com / linux-release@brave.com), rsa4096, created
# 2022-12-27, 2025-03-17 and 2025-07-29 respectively.
#
# Brave rotates these keys over time. When they do, this check fails BY DESIGN
# -- re-run the commands above, confirm the new set, and update BRAVE_KEY_FPRS.
# -----------------------------------------------------------------------------

# Shared key checks and UPDATES_PROXY; the libraries are staged together.
. "$(dirname "${BASH_SOURCE[0]}")/verify-gpg.sh"

# Brave apt release-channel keyring download URL.
BRAVE_KEYRING_URL="https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg"

# Fingerprints the downloaded keyring must contain -- exactly these, no more,
# no fewer. (Order does not matter; the check sorts both sides.)
BRAVE_KEY_FPRS="47D32A74E9A9E013A4B4926C68D513D36A73CD96
B2A3DCA350E67256740DF904DE4EC67BE4B0DCA0
DBF1A116C220B8C7164F98230686B78420038257"

# install_brave -- add the *verified* Brave apt repository and install the browser.
install_brave() {
	local keyring="/usr/share/keyrings/brave-browser-archive-keyring.gpg"
	local tmp gh

	echo "Installing brave-browser"

	# gpg is required to inspect the keyring before we trust it
	if ! command -v gpg >/dev/null 2>&1; then
		echo "installing gnupg (needed to verify the Brave keyring)..."
		sudo apt-get update
		sudo apt-get install -y gnupg
	fi

	# -f makes curl fail on HTTP errors instead of writing an error page into
	# the keyring file; without it a proxy/S3 error would be trusted silently.
	echo "downloading Brave apt signing keyring..."
	tmp="$(mktemp)"
	curl --proxy "${UPDATES_PROXY}" -fsSL -o "${tmp}" "${BRAVE_KEYRING_URL}"

	# Verify the keyring contains EXACTLY the pinned Brave signing keys. The
	# check runs on an imported copy, and only gpg's own export of the pinned
	# keys is installed below: apt must not get raw bytes that another OpenPGP
	# parser could read differently from gpg.
	gh="$(mktemp -d)"
	gpg --homedir "${gh}" --batch --quiet --import "${tmp}" 2>/dev/null || true
	# shellcheck disable=SC2086 # one fingerprint per word
	gpg --homedir "${gh}" --with-colons --fingerprint 2>/dev/null \
		| require_exact_keys "Brave keyring ${BRAVE_KEYRING_URL}" ${BRAVE_KEY_FPRS} \
		|| { rm -rf "${tmp}" "${gh}"; exit 1; }
	# shellcheck disable=SC2086 # one fingerprint per word
	gpg --homedir "${gh}" --export ${BRAVE_KEY_FPRS} > "${tmp}"
	rm -rf "${gh}"
	echo "Brave keyring verified -- $(printf '%s ' ${BRAVE_KEY_FPRS})"

	# A rerun finds the keyring locked by the chattr +i below. Unlock it only
	# to write the keyring that was just verified against the pinned
	# fingerprints; it is locked again after the install, as on the first run.
	sudo chattr -i "${keyring}" 2>/dev/null || true
	sudo install -m 0644 "${tmp}" "${keyring}"
	# NB: ${tmp} is kept until after apt completes -- see the re-install
	# step below for why.

	echo "deb [arch=amd64 signed-by=${keyring}] https://brave-browser-apt-release.s3.brave.com/ stable main" \
		| sudo tee /etc/apt/sources.list.d/brave-browser-release.list > /dev/null

	# Lock the Brave repo to its own packages (same pattern as Signal/Element).
	# Without this, a compromise of Brave's signing infrastructure could ship a
	# higher-version bash / libc6 / systemd / etc. and apt would prefer it over
	# Debian's. Default-deny everything from this origin, then re-allow only the
	# brave-browser-* package set plus brave-keyring.
	# brave-keyring MUST be allowlisted: brave-browser hard-depends on it
	# (APT solver 3.0: "brave-browser : Depends: brave-keyring but it is not
	# installable" when brave-keyring is pinned to -1). Allowing it carries
	# the risk that its postinst writes /usr/share/keyrings/...gpg -- the
	# exact path our sources.list.d entry anchors against via signed-by=.
	# Defense is now layered downstream of the pin instead of via it:
	#   (1) After apt completes, we re-install the three-source-verified
	#       keyring on top of whatever brave-keyring's postinst wrote,
	#       restoring the trust anchor to the bytes we just verified.
	#   (2) chattr +i then freezes that file, so any future brave-keyring
	#       upgrade's postinst write fails loudly instead of silently
	#       rotating the trust anchor. A genuine Brave key rotation will
	#       surface as a loud apt failure -- re-run this script after
	#       re-verifying BRAVE_KEY_FPRS against the three independent
	#       sources documented at the top of this file.
	sudo tee /etc/apt/preferences.d/brave-browser.pref > /dev/null <<'EOF'
Package: *
Pin: origin "brave-browser-apt-release.s3.brave.com"
Pin-Priority: -1

Package: brave-browser brave-browser-beta brave-browser-nightly brave-browser-dev brave-keyring
Pin: origin "brave-browser-apt-release.s3.brave.com"
Pin-Priority: 500
EOF

	sudo apt-get update
	sudo apt-mark unhold brave-keyring >/dev/null 2>&1 || true
	sudo apt-get install -y brave-browser

	# Restore the verified trust anchor. brave-keyring's postinst (run as a
	# dependency of brave-browser just above) may have overwritten the
	# keyring file with whatever keys ship in the installed brave-keyring
	# deb. Force the on-disk file back to the bytes we three-source
	# verified before locking it.
	sudo install -m 0644 "${tmp}" "${keyring}"
	rm -f "${tmp}"

	# Lock the keyring file against in-place rewrite. The Pin-Priority
	# allowlist bounds which package names this repo can ship, but cannot
	# exclude brave-keyring (it is a hard dependency of brave-browser).
	# chattr +i is the layer that actually prevents silent trust-anchor
	# rotation: any future package -- brave-keyring upgrade or an
	# allowlisted brave-browser postinst doing
	#     cp /usr/share/brave/something.gpg ${keyring}
	# -- will fail loudly when it tries to overwrite this file. Legitimate
	# key rotation needs BRAVE_KEY_FPRS updated after a re-verify against the
	# three independent sources documented at the top of this file; a rerun
	# then unlocks and rewrites the keyring.
	sudo chattr +i "${keyring}"
	# brave-keyring owns that file, so any later version of it fails in dpkg
	# against the lock and leaves every update of this template failing (seen
	# with the Qubes updater). Held, apt leaves it alone and other updates,
	# Brave's own included, keep working; a rerun of this script after a
	# reviewed key change releases the hold above.
	sudo apt-mark hold brave-keyring >/dev/null
}

# install_brave_extension ID -- force-install one Brave extension by its
# Chrome Web Store ID via an external update manifest.
install_brave_extension() {
	local id="${1}"
	local extensions_path="/opt/brave.com/brave/extensions"

	echo "installing extension ${id}"
	sudo mkdir -p "${extensions_path}"
	echo '{ "external_update_url": "https://clients2.google.com/service/update2/crx" }' \
		| sudo tee "${extensions_path}/${id}.json" > /dev/null
}

# ensure_brave -- idempotent install: installs Brave only if not already present.
# Used by the brave-extension-* states in salt/seqs/qube.sls so that a qube
# containing one or more brave-extension-<name> components auto-installs Brave
# on the first invocation, no-op thereafter.
ensure_brave() {
	dpkg -s brave-browser >/dev/null 2>&1 || install_brave
}
