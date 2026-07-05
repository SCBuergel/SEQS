#!/usr/bin/env bash

# ════════════════════════════════════════════════════════════════════════════
# SEQS -- Qubes Salt based setup (dom0 entry point).
# ════════════════════════════════════════════════════════════════════════════
#
# This replaces the old imperative installer (a ~1400-line dom0 bash script
# that repeatedly pulled files from a live app qube and piped VM output
# through the dom0 terminal) with the Qubes-native Salt management stack.
# The old script is preserved in git history.
#
# What this script does, and why the trust story is better:
#
#   1. FETCH (once): a single `tar` transfer of salt/ + install-scripts/ from
#      REPO_VM into dom0, with every archive entry validated (regular
#      files/dirs only, safe charset, no '..', no absolute paths) before
#      extraction. This is the ONLY VM->dom0 data flow in the whole system;
#      the old installer re-fetched scripts, libs, assets and directory
#      listings from the (untrusted) repo qube throughout the entire build
#      and interpolated its listings into remote shell commands.
#
#   2. REVIEW GATE: before the fetched tree becomes root-owned salt code, a
#      re-fetch is diffed against the tree already installed in /srv and an
#      explicit CONTINUE confirmation is required (first fetch: hash display
#      + confirmation; use --fetch-only for a full pre-apply audit).
#
#   3. INSTALL: the verified tree is copied to /srv/salt/seqs and
#      /srv/pillar/seqs. From here on the build has NO dependency on
#      REPO_VM. Re-runs with --skip-fetch never contact it at all.
#
#   4. APPLY dom0: `qubesctl state.apply seqs.dom0` validates the pillar
#      config, installs the qrexec policies, clones templates and creates
#      app qubes -- declaratively and idempotently. Re-runs converge instead
#      of refusing; pre-existing qubes NOT created by SEQS are refused via
#      the 'seqs-managed' feature guard (with intent markers so an
#      interrupted run can be resumed, not locked out). Air-gapped qubes are
#      re-verified here in the runner before anything is provisioned.
#
#   5. APPLY qubes: `qubesctl --skip-dom0 --targets=... state.apply
#      seqs.qube` provisions each template, then each app qube. Qubes salt
#      runs this through a DISPOSABLE management VM over qrexec: dom0 pushes
#      states and files down; dom0 never executes, parses, or interpolates
#      anything a target qube produces. The entire fetchFromVm / vmRun /
#      listing-validation machinery of the old installer is gone because the
#      dataflow it defended no longer exists. (qubesctl's own summary output
#      is still routed through the terminal sanitizer below -- see sanitize().)
#
# All configuration (which qubes, colors, components, wallet extensions,
# cleanup dirs, prefixes, base template) now lives in ONE place:
#   salt/pillar/seqs/config.sls   (installed to /srv/pillar/seqs/config.sls)
# Edit it in the repo qube and re-run this script, or edit the installed
# copy in dom0 and re-run with --skip-fetch.
#
# Usage:
#   ./setup-qubes.sh                fetch + install + apply everything
#   ./setup-qubes.sh --fetch-only   fetch + install to /srv, then stop so the
#                                   operator can review before applying
#   ./setup-qubes.sh --skip-fetch   apply from the tree already in /srv
#                                   (no contact with REPO_VM at all)

set -uo pipefail

# ════════════════════════════════════════════════════════════════════════════
# Config -- usually set once when first installing SEQS.
# ════════════════════════════════════════════════════════════════════════════

# Qube that holds the SEQS repo. Only contacted during the fetch step.
# See README: do not use an in-use daily-driver qube for this.
REPO_VM="personal"
REPO_PATH="/home/user/SEQS"

SALT_TREE="/srv/salt/seqs"
PILLAR_TREE="/srv/pillar/seqs"
# Written by the seqs.dom0 state; lists the qubes to provision, in order.
TARGETS_FILE="/var/lib/seqs/targets"

# Policy files owned by the seqs.dom0 state. A file that exists WITHOUT the
# managed marker was written by the operator or another tool -- never
# overwrite it without explicit confirmation.
MANAGED_MARKER="Managed by SEQS"
POLICY_FILES=(
	"/etc/qubes/policy.d/28-browser-suppress.policy"
	"/etc/qubes/policy.d/29-browser.policy"
	"/etc/qubes/policy.d/30-user-input.policy"
)

# ════════════════════════════════════════════════════════════════════════════
# Helpers
# ════════════════════════════════════════════════════════════════════════════

# sanitize -- strip terminal-control bytes from anything that reaches the
# dom0 terminal. Same three-stage defense as the old vmRun (C0 controls
# except TAB/LF, raw 8-bit C1 bytes via iconv, UTF-8-encoded C1 codepoints
# via sed). qubesctl output embeds strings produced inside target qubes
# (installer stdout captured by salt), so this stays load-bearing even
# though no VM output is *executed* in dom0 any more.
sanitize() {
	LC_ALL=C tr -d '\000-\010\013-\037\177' \
		| iconv -f UTF-8 -t UTF-8 -c \
		| LC_ALL=C sed -E $'s/\xc2[\x80-\x9f]//g'
}

# die MESSAGE -- error messages can embed attacker-influenced strings (tar
# entry names), so they are sanitized too.
die() {
	printf 'ERROR: %s\n' "$*" | sanitize >&2
	exit 1
}

# confirm PROMPT WORD -- require the operator to type WORD on the terminal.
# Reads from /dev/tty so a piped or empty stdin cannot be misread as
# approval; EOF or anything else aborts.
confirm() {
	local answer
	if ! read -rp "$1" answer </dev/tty; then
		die "no terminal available to confirm -- aborting."
	fi
	[ "${answer}" = "$2" ] || die "not confirmed -- aborting."
}

# runQubesctl ARGS... -- qubesctl with sanitized output and reliable failure
# detection. The exit code alone is not trusted: qubesctl/salt-call versions
# differ in whether a failed state propagates non-zero, so the (sanitized)
# output is also scanned for salt's own failure markers. False negatives
# provision a broken system; a false positive merely makes you re-run.
runQubesctl() {
	local out rc
	out=$(mktemp /tmp/seqs-qubesctl.XXXXXX) || die "mktemp failed"
	sudo qubesctl "$@" 2>&1 | sanitize | tee "${out}"
	rc="${PIPESTATUS[0]}"
	# 'Result: False' is printed per failed state; the summary 'Failed: N'
	# is only interesting when N > 0. Salt colorizes the VALUE, so after
	# sanitize() strips the ESC bytes these lines read e.g.
	# 'Result: [0;31mFalse' / 'Failed:   [0;31m1[0;39m' -- allow any mix of
	# whitespace and color residue between the key and the value, but never
	# skip over a real character (a '0' count cannot false-positive).
	if [ "${rc}" -eq 0 ] \
			&& grep -qE 'Result:([[:space:]]|\[[0-9;]*m)*False|Failed:([[:space:]]|\[[0-9;]*m)*[1-9]' "${out}"; then
		echo "NOTE: qubesctl exited 0 but its output reports failed states -- treating as failure." >&2
		rc=1
	fi
	rm -f "${out}"
	return "${rc}"
}

joinCsv() {
	local IFS=,
	echo "$*"
}

# ════════════════════════════════════════════════════════════════════════════
# Phase 1 -- fetch the salt tree from REPO_VM (single verified tar transfer)
# ════════════════════════════════════════════════════════════════════════════

fetchSaltTree() {
	local tarball stage
	tarball=$(mktemp /tmp/seqs-fetch.XXXXXX.tar) || die "mktemp failed"
	stage=$(mktemp -d /tmp/seqs-stage.XXXXXX) || die "mktemp -d failed"

	echo "Fetching salt tree from ${REPO_VM}:${REPO_PATH} (single tar transfer)..."
	# 2>/dev/null: same bootstrap-window defense as the README one-liner --
	# the source qube's stderr must never reach the dom0 terminal raw.
	if ! qvm-run -p "${REPO_VM}" "tar -C ${REPO_PATH} -cf - salt install-scripts" 2>/dev/null > "${tarball}"; then
		rm -rf "${tarball}" "${stage}"
		die "could not fetch salt/ + install-scripts/ from ${REPO_VM}:${REPO_PATH} -- does the repo exist there? (see REPO_VM at the top of this script)"
	fi

	echo ""
	echo "Transfer SHA256 (verify against a copy you trust -- e.g. run"
	echo "  tar -C ${REPO_PATH} -cf - salt install-scripts | sha256sum"
	echo "on a SECOND, independent machine holding the same git commit; hashing"
	echo "inside ${REPO_VM} itself proves nothing if that qube is compromised):"
	sha256sum "${tarball}"
	echo ""

	tar -tf "${tarball}" > /dev/null 2>&1 || die "fetched data is not a valid tar archive"

	# Validate EVERY entry before extraction: regular files and directories
	# only (no symlinks/hardlinks/devices), paths rooted at salt/ or
	# install-scripts/, safe charset, no '..', no spaces. A hostile REPO_VM
	# controls this archive; tar extraction in dom0 is the attack surface.
	# tvf lines are '<perms> <owner> <size> <date> <time> <path>' -- a
	# seventh field means the path contains whitespace: reject, since no
	# legitimate SEQS file does and the charset check below couldn't see
	# the full name after field splitting.
	local perms f_owner f_size f_date f_time path extra
	while read -r perms f_owner f_size f_date f_time path extra; do
		[ -n "${extra}" ] && die "refusing tar entry with whitespace in its name: ${path} ${extra}"
		case "${perms:0:1}" in
			d|-) ;;
			*) die "refusing non-regular tar entry (type '${perms:0:1}'): ${path}" ;;
		esac
		[[ "${path}" == *..* ]] && die "refusing tar path containing '..': ${path}"
		[[ "${path}" =~ ^(salt|install-scripts)(/[A-Za-z0-9._-]+)*/?$ ]] \
			|| die "refusing unsafe tar path: ${path}"
	done < <(tar -tvf "${tarball}")

	tar -xf "${tarball}" -C "${stage}" --no-same-owner --no-same-permissions \
		|| die "tar extraction failed"

	# Sanity: the tree must carry the pieces the apply phases rely on.
	local f
	for f in salt/seqs/dom0.sls salt/seqs/dom0.top salt/seqs/qube.sls salt/seqs/qube.top \
	         salt/pillar/seqs/config.sls salt/pillar/seqs/config.top; do
		[ -f "${stage}/${f}" ] || die "fetched tree is missing ${f}"
	done
	[ -d "${stage}/install-scripts/components" ] || die "fetched tree is missing install-scripts/components/"
	[ -d "${stage}/install-scripts/lib" ] || die "fetched tree is missing install-scripts/lib/"

	# Assemble the exact layout that will land in /srv, so it can be diffed
	# against what is already installed there before anything is replaced.
	local newsalt="${stage}/_install-salt" newpillar="${stage}/_install-pillar"
	mkdir -p "${newsalt}/files" "${newpillar}" || die "staging mkdir failed"
	cp -r "${stage}/salt/seqs/." "${newsalt}/" || die "staging of salt states failed"
	cp -r "${stage}/salt/pillar/seqs/." "${newpillar}/" || die "staging of pillar failed"
	# Component scripts + shared libs become salt fileserver payload,
	# referenced as salt://seqs/files/... by the seqs.qube state.
	cp -r "${stage}/install-scripts/lib" "${stage}/install-scripts/components" \
		"${newsalt}/files/" || die "staging of component payload failed"
	touch "${newsalt}/.seqs-managed" "${newpillar}/.seqs-managed"

	# Refuse to wipe /srv trees we did not create (marker file written above
	# for our own trees).
	local d
	for d in "${SALT_TREE}" "${PILLAR_TREE}"; do
		if [ -e "${d}" ] && [ ! -e "${d}/.seqs-managed" ]; then
			rm -rf "${tarball}" "${stage}"
			die "${d} exists but was not installed by SEQS -- refusing to replace it. Remove it manually if it is stale."
		fi
	done

	# Review gate. The fetched tree comes from a qube this setup deliberately
	# does not trust, and once installed it runs as root -- so nothing is
	# installed without an explicit go-ahead. On a re-fetch the operator sees
	# exactly what changed vs the tree already reviewed; an identical
	# re-fetch skips the prompt (nothing new is being trusted).
	local diffout
	if [ -d "${SALT_TREE}" ] || [ -d "${PILLAR_TREE}" ]; then
		diffout="$( { diff -r "${SALT_TREE}" "${newsalt}" 2>&1; \
		              diff -r "${PILLAR_TREE}" "${newpillar}" 2>&1; } || true )"
		if [ -z "${diffout}" ]; then
			echo "Fetched tree is identical to the tree already installed in /srv."
		else
			echo "Changes vs the tree currently installed in /srv ($(printf '%s\n' "${diffout}" | wc -l) diff lines):"
			echo "--------------------------------------------------------------------------------"
			printf '%s\n' "${diffout}" | sanitize | head -n 200
			[ "$(printf '%s\n' "${diffout}" | wc -l)" -gt 200 ] && echo "[... truncated -- re-run with --fetch-only to review the full tree ...]"
			echo "--------------------------------------------------------------------------------"
			confirm "Install this tree into /srv? type CONTINUE to confirm (anything else aborts): " "CONTINUE"
		fi
	else
		echo "First install -- no tree in /srv to diff against. To audit everything"
		echo "before any state is applied, abort now and re-run with --fetch-only."
		confirm "Install the fetched tree into /srv? type CONTINUE to confirm (anything else aborts): " "CONTINUE"
	fi

	echo "Installing salt tree into ${SALT_TREE} and ${PILLAR_TREE}..."
	sudo rm -rf "${SALT_TREE}" "${PILLAR_TREE}" || die "could not clear old trees"
	# Marker first: .seqs-managed means "SEQS owns this path", NOT "tree is
	# complete" -- if the copy below is interrupted, the next run must wipe
	# and reinstall its own half-written tree, not refuse it (same lockout
	# class the qube intent markers in seqs.dom0 prevent).
	sudo mkdir -p "${SALT_TREE}" "${PILLAR_TREE}" || die "mkdir failed"
	sudo touch "${SALT_TREE}/.seqs-managed" "${PILLAR_TREE}/.seqs-managed" || die "marker write failed"
	sudo cp -r "${newsalt}/." "${SALT_TREE}/" || die "install of ${SALT_TREE} failed"
	sudo cp -r "${newpillar}/." "${PILLAR_TREE}/" || die "install of ${PILLAR_TREE} failed"
	sudo chown -R root:root "${SALT_TREE}" "${PILLAR_TREE}"
	sudo chmod -R go-w "${SALT_TREE}" "${PILLAR_TREE}"

	rm -rf "${tarball}" "${stage}"
	echo "Salt tree installed."
}

# ════════════════════════════════════════════════════════════════════════════
# Phase 2 -- policy takeover confirmation
# ════════════════════════════════════════════════════════════════════════════

# The seqs.dom0 state owns the qrexec policy files listed in POLICY_FILES and
# will converge them on every apply. Files it wrote carry MANAGED_MARKER. A
# file that exists WITHOUT the marker is the operator's (or another tool's):
# block here, show it, and require a literal OVERWRITE before proceeding --
# same strictness as the old confirmPolicyOverwrite, enforced BEFORE salt
# runs at all.
confirmPolicyTakeover() {
	# 30-user-input.policy is only ever written by seqs.dom0 on Qubes 4.3
	# with sys-usb present (mirrors the gate in salt/seqs/dom0.sls). On any
	# other system a hand-written copy would trigger a recurring takeover
	# prompt for a file salt never touches -- skip it there. Only skip when
	# the release is POSITIVELY known: an unreadable release keeps the
	# prompt (fail safe, worst case one unnecessary confirmation).
	local usb_applies=1 release
	release="$(grep -oE '[0-9]+\.[0-9]+' /etc/qubes-release 2>/dev/null | head -1)" || true
	if [ -n "${release}" ]; then
		if [ "${release}" != "4.3" ] || ! qvm-check -q -- sys-usb >/dev/null 2>&1; then
			usb_applies=0
		fi
	fi

	local p unmanaged=()
	for p in "${POLICY_FILES[@]}"; do
		if [ "${usb_applies}" -eq 0 ] && [ "${p}" = "/etc/qubes/policy.d/30-user-input.policy" ]; then
			continue
		fi
		if [ -e "${p}" ] && ! sudo grep -q "${MANAGED_MARKER}" "${p}"; then
			unmanaged+=("${p}")
		fi
	done
	[ "${#unmanaged[@]}" -eq 0 ] && return 0

	{
		echo ""
		echo "################################################################################"
		echo "##  !!!  WARNING  !!!"
		echo "##"
		echo "##  The following qrexec policy files exist but were NOT written by SEQS."
		echo "##  Applying the SEQS dom0 state will OVERWRITE them (no backup is taken)."
		echo "##  These policies are isolation-affecting dom0 configuration."
		echo "##"
		for p in "${unmanaged[@]}"; do
			echo "##  ${p}:"
			echo "##  ------------------------------------------------------------------"
			sudo sed 's/^/##      /' "${p}"
			echo "##  ------------------------------------------------------------------"
		done
		echo "################################################################################"
		echo ""
	} | sanitize >&2

	confirm "Overwrite the file(s) above? type OVERWRITE to confirm (anything else aborts): " "OVERWRITE"
}

# ════════════════════════════════════════════════════════════════════════════
# Phase 3 -- apply
# ════════════════════════════════════════════════════════════════════════════

readTargets() {
	TEMPLATE_TARGETS=()
	APP_TARGETS=()
	OFFLINE_TARGETS=()
	[ -r "${TARGETS_FILE}" ] || die "${TARGETS_FILE} missing -- did the seqs.dom0 state run?"
	local kind name flags flag
	while read -r kind name flags; do
		case "${kind}" in ''|\#*) continue ;; esac
		# Names are re-validated even though the file is root-written by our
		# own state -- they get interpolated into qubesctl/qvm-* commands.
		[[ "${name}" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] || die "unsafe qube name in ${TARGETS_FILE}: '${name}'"
		case "${kind}" in
			template) TEMPLATE_TARGETS+=("${name}") ;;
			app)      APP_TARGETS+=("${name}") ;;
			*) die "unknown entry kind in ${TARGETS_FILE}: '${kind}'" ;;
		esac
		for flag in ${flags}; do
			case "${flag}" in
				offline) [ "${kind}" = "app" ] && OFFLINE_TARGETS+=("${name}") ;;
				*) die "unknown flag in ${TARGETS_FILE}: '${flag}'" ;;
			esac
		done
	done < "${TARGETS_FILE}"
	[ "${#TEMPLATE_TARGETS[@]}" -gt 0 ] || die "no templates listed in ${TARGETS_FILE}"
}

# verifyAirgap -- independent post-apply check that every 'offline' qube
# really has no netvm. The dom0 state sets this (seqs-offline-*), but the
# exact qvm-prefs semantics are release-dependent and this is the single
# most security-critical pref in the whole setup (wallet/vault air gap) --
# so the runner refuses to provision anything if it is not in effect.
verifyAirgap() {
	local vm nv
	for vm in "${OFFLINE_TARGETS[@]}"; do
		nv="$(qvm-prefs -- "${vm}" netvm 2>/dev/null || true)"
		# qvm-prefs prints an unset netvm as an empty string on current
		# releases; accept 'None'/'none' spellings too. Anything else is a
		# live netvm.
		case "${nv,,}" in
			''|none) ;;
			*) die "offline qube '${vm}' still has netvm '${nv}' after the dom0 apply -- air gap NOT in effect, refusing to provision. (Check the seqs-offline state in salt/seqs/dom0.sls against your Qubes release.)" ;;
		esac
	done
	if [ "${#OFFLINE_TARGETS[@]}" -gt 0 ]; then
		echo "Air gap verified: no netvm on ${OFFLINE_TARGETS[*]}."
	fi
	return 0
}

# shutdownAll VM... -- deterministic barrier between provisioning phases.
# qubesctl shuts down qubes it started, but app qubes snapshot their
# template's root volume at start time, so templates must be verifiably
# halted (changes committed) before any app qube boots. Belt and braces.
shutdownAll() {
	local vm
	for vm in "$@"; do
		qvm-shutdown --wait "${vm}" 2>/dev/null || true
	done
}

# ════════════════════════════════════════════════════════════════════════════
# Main
# ════════════════════════════════════════════════════════════════════════════

SKIP_FETCH=0
FETCH_ONLY=0
for arg in "$@"; do
	case "${arg}" in
		--skip-fetch) SKIP_FETCH=1 ;;
		--fetch-only) FETCH_ONLY=1 ;;
		*) die "unknown argument '${arg}' (supported: --skip-fetch, --fetch-only)" ;;
	esac
done
[ "${SKIP_FETCH}" -eq 1 ] && [ "${FETCH_ONLY}" -eq 1 ] && die "--skip-fetch and --fetch-only are mutually exclusive"

if [ "${SKIP_FETCH}" -eq 1 ]; then
	[ -d "${SALT_TREE}" ] && [ -d "${PILLAR_TREE}" ] \
		|| die "--skip-fetch given but ${SALT_TREE} / ${PILLAR_TREE} not installed yet -- run without flags first"
	echo "Skipping fetch -- applying from the tree already in ${SALT_TREE}."
else
	fetchSaltTree
fi

if [ "${FETCH_ONLY}" -eq 1 ]; then
	echo ""
	echo "Fetch-only: salt tree installed but nothing applied."
	echo "Review ${SALT_TREE} and ${PILLAR_TREE}, then re-run with --skip-fetch."
	exit 0
fi

echo ""
echo "Enabling SEQS pillar top (idempotent)..."
runQubesctl top.enable seqs.config pillar=true || die "qubesctl top.enable failed"

confirmPolicyTakeover

echo ""
echo "Applying dom0 state (validation, qrexec policies, qube creation)..."
runQubesctl state.apply seqs.dom0 || die "seqs.dom0 failed -- nothing was provisioned inside any qube. Fix the reported problem and re-run (re-runs converge)."

readTargets
verifyAirgap
FAILED=0

echo ""
echo "Provisioning ${#TEMPLATE_TARGETS[@]} template(s) via the disposable management VM:"
printf '  %s\n' "${TEMPLATE_TARGETS[@]}"
if ! runQubesctl --skip-dom0 --show-output \
		--targets="$(joinCsv "${TEMPLATE_TARGETS[@]}")" state.apply seqs.qube; then
	echo "WARNING: at least one template failed to provision (see output above)." >&2
	echo "Re-running this script converges: finished components are skipped via" >&2
	echo "their /rw/config/seqs markers; only the failed part re-runs." >&2
	FAILED=1
fi

# Commit template root volumes before any app qube snapshots them.
shutdownAll "${TEMPLATE_TARGETS[@]}"

echo ""
echo "Provisioning ${#APP_TARGETS[@]} app qube(s):"
printf '  %s\n' "${APP_TARGETS[@]}"
if ! runQubesctl --skip-dom0 --show-output \
		--targets="$(joinCsv "${APP_TARGETS[@]}")" state.apply seqs.qube; then
	echo "WARNING: at least one app qube failed to provision (see output above)." >&2
	FAILED=1
fi

shutdownAll "${APP_TARGETS[@]}"

echo ""
if [ "${FAILED}" -eq 0 ]; then
	echo "SEQS setup complete. All targets provisioned."
else
	echo "SEQS setup finished WITH FAILURES -- see warnings above. Fix and re-run"
	echo "(the whole flow is convergent; nothing needs manual rollback first)."
	exit 1
fi
