#!/usr/bin/env bash
#
# Shared GPG verification helpers for SEQS install scripts.
#
# Sourced, not executed: this file only defines functions and has no side
# effects at source time. The seqs.qube Salt state copies every shared
# library next to each component's install scripts inside the target qube,
# so install scripts load it with:
#
#     . "$(dirname "$0")/verify-gpg.sh"
#
# The sourcing script is expected to have run `set -Eeuo pipefail` itself.

# Qubes update proxy: the only way out of a template, which has no NetVM.
UPDATES_PROXY="127.0.0.1:8082"

# -----------------------------------------------------------------------------
# Why these helpers exist
# -----------------------------------------------------------------------------
# Every component that trusts a third-party signing key (brave, signal, element,
# docker, vscode, bitbox, keepass, openoffice, gnosisvpn) runs the same
# checks; keeping them here stops the call sites from drifting. The subtle
# part is gpg's --status-fd protocol: it is multi-line and emits several
# positive AND several negative keywords, so "the signature verified to the
# pinned key" needs the right positive signal present AND no negative one.
#
# Negative keywords explicitly rejected (--status-fd 1 protocol):
#   * BADSIG       -- signature math failed
#   * ERRSIG       -- couldn't verify (e.g., missing pubkey, broken sig packet)
#   * EXPSIG       -- otherwise-good sig past its self-imposed expiry
#   * EXPKEYSIG    -- otherwise-good sig from an EXPIRED key
#   * REVKEYSIG    -- otherwise-good sig from a REVOKED key
#   * KEYEXPIRED   -- key used has an expiration timestamp in the past
#   * KEYREVOKED   -- key used was revoked by its owner
#   * NO_PUBKEY    -- gpg lacks the public key entirely
#
# Positive keywords required:
#   * GOODSIG      -- a valid sig from a non-expired, non-revoked key.
#                     GPG emits this XOR one of EXP*SIG / REVKEYSIG, so
#                     requiring GOODSIG gives us "good and not expired and
#                     not revoked" in a single check.
#   * VALIDSIG <... primary_fpr=PINNED> -- chain-to-pinned-primary check.
#                     VALIDSIG fires whenever the cryptographic math works,
#                     including for expired/revoked keys, so it alone is
#                     insufficient -- but the LAST field of the VALIDSIG
#                     line is the primary-key fingerprint, which is what we
#                     pin against.
#
# Any negative GPG status is fatal; GOODSIG and VALIDSIG must both match.
# -----------------------------------------------------------------------------

# verify_detached_sig SIGFILE DATAFILE PIN_FPR LABEL
# Verify that DATAFILE has a detached signature SIGFILE that chains to the
# pinned primary-key fingerprint PIN_FPR, with no negative status keyword
# emitted along the way. LABEL is the human-readable artifact name used in
# log/error messages (e.g. "bitbox_4.51.0_amd64.deb").
#
# Aborts the calling script with exit 1 on any verification failure --
# including gpg's own non-zero exit. Echoes "signature OK -- LABEL ..." on
# success and returns 0.
verify_detached_sig() {
	local sigfile="${1}"
	local datafile="${2}"
	local pin_fpr="${3}"
	local label="${4}"

	local status rc=0
	# Capture STATUS even if gpg failed: we want to dump it on error.
	# Note: NO `|| true` here -- we keep gpg's exit code in $rc and act on
	# it explicitly below.
	status="$(gpg --status-fd 1 --verify "${sigfile}" "${datafile}" 2>/dev/null)" || rc=$?

	if [ "${rc}" -ne 0 ]; then
		echo "ERROR: gpg --verify exited ${rc} for ${label} -- not installing." >&2
		echo "${status}" >&2
		exit 1
	fi

	if ! awk -v fpr="${pin_fpr}" '
		# Positive signals: must see BOTH for a pass.
		$1=="[GNUPG:]" && $2=="GOODSIG"  { goodsig=1; next }
		$1=="[GNUPG:]" && $2=="VALIDSIG" && $NF==fpr { validsig=1; next }
		# Negative signals: any one of these on any line of the gpg
		# --status-fd output is enough to reject.
		$1=="[GNUPG:]" && ($2=="BADSIG"   || $2=="ERRSIG"    || \
		                    $2=="EXPSIG"   || $2=="EXPKEYSIG" || \
		                    $2=="REVKEYSIG" || $2=="KEYEXPIRED" || \
		                    $2=="KEYREVOKED" || $2=="NO_PUBKEY") { bad=$2; next }
		END {
			if (bad)         { printf "  rejected: gpg emitted %s\n", bad > "/dev/stderr"; exit 1 }
			if (!goodsig)    { print  "  rejected: no GOODSIG in gpg output (expired/revoked key, or no signature)" > "/dev/stderr"; exit 1 }
			if (!validsig)   { printf "  rejected: no VALIDSIG with primary-key fingerprint %s\n", fpr > "/dev/stderr"; exit 1 }
			exit 0
		}
	' <<< "${status}"; then
		echo "ERROR: ${label} signature verification FAILED (pin: ${pin_fpr}) -- not installing." >&2
		echo "${status}" >&2
		exit 1
	fi

	echo "signature OK -- ${label} signed by ${pin_fpr}"
}

# require_exact_keys LABEL FPR... < GPG_COLONS_OUTPUT
# Read a `gpg --with-colons` key listing on stdin and exit 1 unless its
# primary keys are EXACTLY the pinned fingerprints FPR... (order does not
# matter). Callers pipe gpg into it, so it runs in a subshell: the pipeline
# fails (also on a gpg failure), and the caller must stop on that.
#
# Checking only the first key is the wrong shape: a key block that holds a
# second key after the pinned one would still pass, and any flow that uses
# the keyring directly would then trust the stowaway key.
require_exact_keys() {
	local label="${1}" got expected
	shift
	got="$(awk -F: '$1=="pub"{w=1} $1=="fpr"&&w{print $10; w=0}' | sort)"
	expected="$(printf '%s\n' "$@" | sort)"
	if [[ "${got}" != "${expected}" ]]; then
		echo "ERROR: ${label} must hold exactly the pinned key(s) -- aborting." >&2
		echo "  expected:" >&2
		printf '    %s\n' ${expected} >&2
		echo "  got     :" >&2
		printf '    %s\n' ${got:-<none>} >&2
		exit 1
	fi
	echo "key verified: $*"
}

# import_pinned_key DIR FPR < KEY_BLOCK
# Import the ASCII-armoured key block on stdin into a new GNUPGHOME at DIR
# (exported for the calling script) and abort unless it holds exactly the key
# FPR. Installs gnupg first if gpg is missing.
import_pinned_key() {
	local key
	key="$(cat)"
	if ! command -v gpg >/dev/null 2>&1; then
		sudo apt-get update
		sudo apt-get install -y gnupg
	fi
	install -d -m 0700 "${1}"
	export GNUPGHOME="${1}"
	gpg --batch --import <<< "${key}"
	gpg --with-colons --fingerprint 2>/dev/null | require_exact_keys "the key block" "${2}" || exit 1
}

# fetch_signed FPR URL SIG_SUFFIX DIR < KEY_BLOCK
# Import the key block on stdin (import_pinned_key, GNUPGHOME=DIR/gnupg),
# download URL and URL+SIG_SUFFIX into DIR through the update proxy, and
# abort unless the detached signature chains to FPR. The verified file is
# DIR/<last path element of URL>. DIR must be a mktemp directory of the
# calling user (who has passwordless sudo), so nothing less privileged can
# swap the file between this check and its installation.
fetch_signed() {
	local fpr="${1}" url="${2}" sig="${3}" dir="${4}" file="${2##*/}"
	import_pinned_key "${dir}/gnupg" "${fpr}"
	echo "downloading ${file}..."
	# -f makes curl fail on an HTTP error instead of saving the error page.
	curl --proxy "${UPDATES_PROXY}" -fsSL -o "${dir}/${file}" "${url}"
	curl --proxy "${UPDATES_PROXY}" -fsSL -o "${dir}/${file}${sig}" "${url}${sig}"
	verify_detached_sig "${dir}/${file}${sig}" "${dir}/${file}" "${fpr}" "${file}"
}

# add_pinned_apt_repo NAME KEYRING FPR ARCH REPO ORIGIN ALLOWED < KEY_BLOCK
# Add a third-party apt repository that apt trusts only through the key FPR
# and only for the packages ALLOWED:
#   * the key block on stdin must hold exactly FPR (import_pinned_key);
#   * KEYRING receives gpg's export of FPR alone -- apt never sees the raw
#     key block, which another OpenPGP parser might read differently;
#   * /etc/apt/sources.list.d/NAME.list gets
#     "deb [arch=ARCH signed-by=KEYRING] REPO" (REPO = "URI SUITE COMPONENT");
#   * /etc/apt/preferences.d/NAME.pref default-denies the whole ORIGIN
#     (Pin-Priority -1) and re-allows only the space-separated ALLOWED
#     packages. signed-by= proves only that a package carries the vendor's
#     signature; without the pin a compromise of the vendor's signing
#     infrastructure could ship a higher-version bash / libc6 / systemd and
#     apt would prefer it over Debian's.
# The caller unlocks KEYRING before (a rerun finds it locked) and, after
# installing, locks it with `sudo chattr +i`: the pin bounds which packages
# the repo can ship, not what their root-run maintainer scripts do, and one
# that rewrote KEYRING would silently rotate the trust anchor. Locked, such
# a write fails loudly; a genuine key rotation needs the pinned fingerprint
# re-verified and updated.
add_pinned_apt_repo() (
	local name="${1}" keyring="${2}" fpr="${3}" arch="${4}" repo="${5}" origin="${6}" allowed="${7}"
	local gh
	gh="$(mktemp -d)"
	trap 'rm -rf "${gh}"' EXIT
	import_pinned_key "${gh}" "${fpr}"
	gpg --export "${fpr}" | sudo tee "${keyring}" > /dev/null
	echo "deb [arch=${arch} signed-by=${keyring}] ${repo}" \
		| sudo tee "/etc/apt/sources.list.d/${name}.list" > /dev/null
	printf 'Package: *\nPin: origin "%s"\nPin-Priority: -1\n\nPackage: %s\nPin: origin "%s"\nPin-Priority: 500\n' \
		"${origin}" "${allowed}" "${origin}" | sudo tee "/etc/apt/preferences.d/${name}.pref" > /dev/null
)
