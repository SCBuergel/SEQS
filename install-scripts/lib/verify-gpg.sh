#!/usr/bin/env bash
#
# Shared GPG detached-signature verification helper for SEQS install scripts.
#
# Sourced, not executed: this file only defines functions and has no side
# effects at source time. setup-qubes.sh discovers every *.sh under LIB_PATH
# (see discoverLibFiles) and ships it next to each install script inside the
# target VM, so install scripts load it with:
#
#     . "$(dirname "$0")/verify-gpg.sh"
#
# The sourcing script is expected to have run `set -Eeuo pipefail` itself.
#
# -----------------------------------------------------------------------------
# Why this helper exists
# -----------------------------------------------------------------------------
# Three components (keepass, bitbox, openoffice) verify a downloaded artifact
# against a pinned signing-key fingerprint. Doing this inline in each script
# triplicated a subtle bit of logic: gpg's --status-fd protocol is multi-line,
# emits several positive AND several negative keywords, and "the signature
# verified to the pinned key" requires checking that BOTH the right positive
# signal is present AND that no negative signal is present, not just the
# former. A single shared helper keeps the three call sites from drifting --
# the same failure mode that motivated the policy-overwrite helper in
# setup-qubes.sh.
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

# verify_imported_keyring_matches PIN_FPR
# Verify that the *current* GNUPGHOME keyring contains EXACTLY one primary
# key whose fingerprint is PIN_FPR. Aborts the calling script if anything
# else is present.
#
# This avoids the parser-shape footgun in a pattern such as
#       gpg --with-colons --fingerprint | awk '... $1=="fpr" ... exit'
# parses only the FIRST pub key in the keyring. If the embedded PGP key
# block in a future commit (accidentally, or maliciously) holds a second
# key concatenated after the first, the first-key fingerprint check still
# passes while the keyring quietly holds both. For the signed-by= apt
# flows (signal/element/docker/vscode) the subsequent `gpg --export
# "${PIN_FPR}"` re-pins to the verified fingerprint and only that key
# reaches /usr/share/keyrings/, so a stowaway second key is dropped. But
# any future flow that omits the re-export step -- or that uses the
# keyring directly -- would silently trust the smuggled key. This helper
# requires the keyring to contain EXACTLY the pinned fingerprint so the
# parser shape can't be the weak link. Same approach lib/brave.sh already
# uses on Brave's three-key set.
verify_imported_keyring_matches() {
	local pin_fpr="${1}"
	local got expected
	got="$(gpg --with-colons --fingerprint 2>/dev/null \
		| awk -F: '$1=="pub"{w=1} $1=="fpr"&&w{print $10; w=0}' | sort)"
	expected="${pin_fpr}"
	if [[ "${got}" != "${expected}" ]]; then
		echo "ERROR: embedded PGP key block must contain exactly one key (${expected}) -- aborting." >&2
		echo "  expected: ${expected}" >&2
		echo "  got     :" >&2
		printf '    %s\n' ${got:-<none>} >&2
		exit 1
	fi
	echo "key verified: ${pin_fpr}"
}
