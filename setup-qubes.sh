#!/usr/bin/env bash

# SEQS dom0 runner; see docs/architecture.md and docs/configuration.md.
#
# Usage:
#   ./setup-qubes.sh                fetch, stage, and build (confirm each stage)
#   ./setup-qubes.sh --fetch-only   fetch and validate into /var/lib/seqs/fetched
#   ./setup-qubes.sh --stage-only   copy the fetched tree into /srv
#   ./setup-qubes.sh --build-only   create and provision the configured qubes
#   ./setup-qubes.sh --repo-vm VM   fetch from the named repository qube
#   ./setup-qubes.sh --verbose      show full per-state qubesctl output (debug)

set -uo pipefail

# ---- Config -- usually set once when first installing SEQS. -----------------
# REPO_VM/REPO_PATH identify the fetch source. Use --repo-vm as in README §2.
REPO_VM="${SEQS_REPO_VM:-personal}"
REPO_PATH="${SEQS_REPO_PATH:-/home/user/SEQS}"

# Filesystem roots. The SEQS_* overrides let the test harness run in a scratch
# dir; a normal dom0 install sets none and gets the real /srv + /var/lib paths.
SALT_TREE="${SEQS_SALT_TREE:-/srv/salt/seqs}"
PILLAR_TREE="${SEQS_PILLAR_TREE:-/srv/pillar/seqs}"
TARGETS_FILE="${SEQS_TARGETS_FILE:-/var/lib/seqs/targets}"  # written by seqs.dom0
FETCH_ROOT="${SEQS_FETCH_ROOT:-/var/lib/seqs/fetched}"
FETCH_SALT_TREE="${FETCH_ROOT}/salt"
FETCH_PILLAR_TREE="${FETCH_ROOT}/pillar"

# Policy files owned by seqs.dom0. A file WITHOUT the marker was written by the
# operator or another tool -- never overwrite without confirmation.
MANAGED_MARKER="Managed by SEQS"
POLICY_FILES=(
	"/etc/qubes/policy.d/00-seqs-qr-input-deny.policy"
	"/etc/qubes/policy.d/01-seqs-qr-filecopy.policy"
	"/etc/qubes/policy.d/28-browser-suppress.policy"
	"/etc/qubes/policy.d/29-browser.policy"
	"/etc/qubes/policy.d/30-user-input.policy"
)

# ---- Helpers ----------------------------------------------------------------

# sanitize -- strip terminal-control bytes from anything reaching the dom0
# terminal (C0 controls except TAB/LF, raw 8-bit C1 via iconv, UTF-8-encoded
# C1 via sed). qubesctl output embeds strings produced inside target qubes,
# so this is load-bearing on every display path.
sanitize() {
	LC_ALL=C tr -d '\000-\010\013-\037\177' \
		| iconv -f UTF-8 -t UTF-8 -c \
		| LC_ALL=C sed -E $'s/\xc2[\x80-\x9f]//g'
}

# die MESSAGE -- sanitized because messages can embed tar entry names.
die() {
	printf 'ERROR: %s\n' "$*" | sanitize >&2
	exit 1
}

# confirm PROMPT WORD -- require the operator to type WORD. Reads from /dev/tty
# so a piped or empty stdin cannot be misread as approval; EOF/anything else aborts.
confirm() {
	local answer
	if ! read -rp "$1" answer </dev/tty; then
		die "no terminal available to confirm -- aborting."
	fi
	[ "${answer}" = "$2" ] || die "not confirmed -- aborting."
}

# runQubesctl ARGS... -- qubesctl with sanitized output and reliable failure
# detection. The exit code alone is not trusted (qubesctl/salt-call versions
# differ on whether a failed state exits non-zero), so the output is also
# scanned for salt's own failure markers.
runQubesctl() {
	local out rc
	out=$(mktemp /tmp/seqs-qubesctl.XXXXXX) || die "mktemp failed"
	sudo qubesctl "$@" 2>&1 | sanitize | tee "${out}"
	rc="${PIPESTATUS[0]}"
	# 'Result: False' prints per failed state; 'Failed: N' matters when N > 0.
	# Salt colorizes the value, so allow whitespace/color residue between key
	# and value (sanitize() has already stripped the ESC bytes).
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

# ---- Stage 1 -- fetch and validate -------------------------------------------

fetchSaltTree() {
	local tarball stage
	tarball=$(mktemp /tmp/seqs-fetch.XXXXXX.tar) || die "mktemp failed"
	stage=$(mktemp -d /tmp/seqs-stage.XXXXXX) || die "mktemp -d failed"

	echo "==> Fetching salt tree from ${REPO_VM}:${REPO_PATH}"
	# 2>/dev/null: bootstrap-window defense -- the source qube's stderr must
	# never reach the dom0 terminal raw (docs/architecture.md#bootstrap-window).
	if ! qvm-run -p "${REPO_VM}" "tar -C ${REPO_PATH} -cf - salt install-scripts" 2>/dev/null > "${tarball}"; then
		rm -rf "${tarball}" "${stage}"
		die "could not fetch salt/ + install-scripts/ from ${REPO_VM}:${REPO_PATH} -- does the repo exist there? (see REPO_VM at the top of this script)"
	fi

	echo "    Transfer SHA256 (compare on a second machine at the same commit;"
	echo "    hashing inside ${REPO_VM} proves nothing if that qube is compromised):"
	printf '    '; sha256sum "${tarball}"

	tar -tf "${tarball}" > /dev/null 2>&1 || die "fetched data is not a valid tar archive"

	# Validate EVERY entry before extraction: regular files/dirs only (no
	# symlinks/hardlinks/devices), paths rooted at salt/ or install-scripts/,
	# safe charset, no '..'. A hostile REPO_VM controls this archive; tar
	# extraction in dom0 is the attack surface. tvf lines are
	# '<perms> <owner> <size> <date> <time> <path>' -- a 7th field means
	# whitespace in the name: reject (no legitimate SEQS file has one).
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

	# Refuse to replace a fetched area not owned by SEQS.
	local d
	for d in "${FETCH_SALT_TREE}" "${FETCH_PILLAR_TREE}"; do
		if [ -e "${d}" ] && [ ! -e "${d}/.seqs-managed" ]; then
			rm -rf "${tarball}" "${stage}"
			die "${d} exists but is not managed by SEQS -- refusing to replace it"
		fi
	done

	echo "==> Saving validated fetch under ${FETCH_ROOT}"
	sudo rm -rf "${FETCH_ROOT}" || die "could not clear fetched tree"
	sudo mkdir -p "${FETCH_SALT_TREE}" "${FETCH_PILLAR_TREE}" || die "mkdir failed"
	sudo cp -r "${newsalt}/." "${FETCH_SALT_TREE}/" || die "could not save fetched salt tree"
	sudo cp -r "${newpillar}/." "${FETCH_PILLAR_TREE}/" || die "could not save fetched pillar tree"
	sudo touch "${FETCH_ROOT}/.seqs-complete" || die "could not mark fetch complete"
	sudo chown -R root:root "${FETCH_ROOT}"
	sudo chmod a+rx "$(dirname "${FETCH_ROOT}")" "${FETCH_ROOT}"
	sudo chmod -R a+rX,go-w "${FETCH_ROOT}"

	rm -rf "${tarball}" "${stage}"
	echo "    Fetch complete. Review ${FETCH_SALT_TREE} and ${FETCH_PILLAR_TREE}."
}

# ---- Stage 2 -- stage the reviewed tree in /srv ------------------------------

stageSaltTree() {
	[ -f "${FETCH_ROOT}/.seqs-complete" ] \
		&& [ -f "${FETCH_SALT_TREE}/.seqs-managed" ] \
		&& [ -f "${FETCH_PILLAR_TREE}/.seqs-managed" ] \
		|| die "fetch stage is incomplete -- run --fetch-only first"

	local d diffout
	for d in "${SALT_TREE}" "${PILLAR_TREE}"; do
		if [ -e "${d}" ] && [ ! -e "${d}/.seqs-managed" ]; then
			die "${d} exists but is not managed by SEQS -- refusing to replace it"
		fi
	done

	diffout="$( { diff -r --exclude=.seqs-complete "${SALT_TREE}" "${FETCH_SALT_TREE}" 2>&1; \
	              diff -r --exclude=.seqs-complete "${PILLAR_TREE}" "${FETCH_PILLAR_TREE}" 2>&1; } || true )"
	if [ -z "${diffout}" ]; then
		echo "Fetched tree is identical to the tree already staged in /srv."
	else
		echo "Changes to stage in /srv ($(printf '%s\n' "${diffout}" | wc -l) diff lines):"
		echo "--------------------------------------------------------------------------------"
		printf '%s\n' "${diffout}" | sanitize | head -n 200
		[ "$(printf '%s\n' "${diffout}" | wc -l)" -gt 200 ] && echo "[... truncated ...]"
		echo "--------------------------------------------------------------------------------"
	fi

	echo "==> Staging Salt tree in ${SALT_TREE} and ${PILLAR_TREE}"
	sudo rm -rf "${SALT_TREE}" "${PILLAR_TREE}" || die "could not clear staged trees"
	sudo mkdir -p "${SALT_TREE}" "${PILLAR_TREE}" || die "mkdir failed"
	sudo cp -r "${FETCH_SALT_TREE}/." "${SALT_TREE}/" || die "staging ${SALT_TREE} failed"
	sudo cp -r "${FETCH_PILLAR_TREE}/." "${PILLAR_TREE}/" || die "staging ${PILLAR_TREE} failed"
	sudo touch "${SALT_TREE}/.seqs-complete" "${PILLAR_TREE}/.seqs-complete" || die "could not mark staging complete"
	sudo chown -R root:root "${SALT_TREE}" "${PILLAR_TREE}"
	sudo chmod a+rx "$(dirname "${SALT_TREE}")" "$(dirname "${PILLAR_TREE}")"
	sudo chmod -R a+rX,go-w "${SALT_TREE}" "${PILLAR_TREE}"
	echo "    Staging complete."
}

# ---- Build helpers -----------------------------------------------------------

# seqs.dom0 owns the qrexec policy files in POLICY_FILES and converges them on
# every apply. Files it wrote carry MANAGED_MARKER; a file WITHOUT the marker
# is the operator's -- block, show it, and require a literal OVERWRITE before
# salt runs.
confirmPolicyTakeover() {
	# 30-user-input.policy is only written on Qubes 4.3 with sys-usb present
	# (mirrors the gate in salt/seqs/dom0.sls); skip it elsewhere so a
	# hand-written copy doesn't trigger a recurring prompt for a file salt never
	# touches. Only skip when the release is positively known -- an unreadable
	# release keeps the prompt (fail safe).
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

# ---- Phase 3 -- apply -------------------------------------------------------

readTargets() {
	TEMPLATE_TARGETS=()
	APP_TARGETS=()
	OFFLINE_TARGETS=()
	[ -r "${TARGETS_FILE}" ] || die "${TARGETS_FILE} missing -- did the seqs.dom0 state run?"
	local kind name flags flag
	while read -r kind name flags; do
		case "${kind}" in ''|\#*) continue ;; esac
		# Re-validated (root-written, but interpolated into qubesctl/qvm-* commands).
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

# verifyAirgap -- independent post-apply check that every 'offline' qube really
# has no netvm. The dom0 state sets this, but qvm-prefs semantics are
# release-dependent and this is the most security-critical pref in the setup
# (wallet/vault air gap), so refuse to provision anything if it is not in effect.
verifyAirgap() {
	local vm nv
	for vm in "${OFFLINE_TARGETS[@]}"; do
		nv="$(qvm-prefs -- "${vm}" netvm 2>/dev/null || true)"
		# Unset netvm prints as empty on current releases; accept None/none too.
		case "${nv,,}" in
			''|none) ;;
			*) die "offline qube '${vm}' still has netvm '${nv}' after the dom0 apply -- air gap NOT in effect, refusing to provision. (Check the seqs-offline state in salt/seqs/dom0.sls against your Qubes release.)" ;;
		esac
	done
	if [ "${#OFFLINE_TARGETS[@]}" -gt 0 ]; then
		echo "    Air gap verified: no netvm on ${OFFLINE_TARGETS[*]}."
	fi
	return 0
}

# shutdownAll VM... -- barrier between phases: templates must be verifiably
# halted (root volume committed) before any app qube snapshots them at start.
shutdownAll() {
	local vm
	for vm in "$@"; do
		qvm-shutdown --wait "${vm}" 2>/dev/null || true
	done
}

buildQubes() {
	[ -f "${SALT_TREE}/.seqs-complete" ] && [ -f "${PILLAR_TREE}/.seqs-complete" ] \
		|| die "stage is incomplete -- run --stage-only first"
echo ""
echo "==> Applying dom0 state (policies, qube creation)"
runQubesctl top.enable seqs.config pillar=true || die "qubesctl top.enable failed"
confirmPolicyTakeover
runQubesctl state.apply seqs.dom0 || die "seqs.dom0 failed -- nothing was provisioned inside any qube. Fix the reported problem and re-run (re-runs converge)."

readTargets
verifyAirgap
FAILED=0

echo ""
echo "==> [2/3] Provisioning ${#TEMPLATE_TARGETS[@]} template(s): ${TEMPLATE_TARGETS[*]}"
if ! runQubesctl --skip-dom0 "${QUBE_APPLY_OPTS[@]}" \
		--targets="$(joinCsv "${TEMPLATE_TARGETS[@]}")" state.apply seqs.qube; then
	echo "WARNING: at least one template failed to provision (see summary above;" >&2
	echo "         re-run with --verbose for full per-state output)." >&2
	echo "         Re-run to converge -- finished components are skipped." >&2
	FAILED=1
fi

# Commit template root volumes before any app qube snapshots them.
shutdownAll "${TEMPLATE_TARGETS[@]}"

echo ""
echo "==> [3/3] Provisioning ${#APP_TARGETS[@]} app qube(s): ${APP_TARGETS[*]}"
if ! runQubesctl --skip-dom0 "${QUBE_APPLY_OPTS[@]}" \
		--targets="$(joinCsv "${APP_TARGETS[@]}")" state.apply seqs.qube; then
	echo "WARNING: at least one app qube failed to provision (see summary above;" >&2
	echo "         re-run with --verbose for full per-state output)." >&2
	FAILED=1
fi

shutdownAll "${APP_TARGETS[@]}"

echo ""
if [ "${FAILED}" -eq 0 ]; then
	echo "==> SEQS setup complete. All targets provisioned."
else
	echo "==> SEQS setup finished WITH FAILURES -- see warnings above." >&2
	echo "    Fix and re-run (the flow is convergent; no manual rollback needed)." >&2
	exit 1
fi
}

# ---- Main -------------------------------------------------------------------

# Test hook: source helpers without running the workflow.
if [ "${SEQS_SOURCE_ONLY:-0}" = "1" ]; then
	return 0 2>/dev/null || true
fi

RUN_FETCH=0
RUN_STAGE=0
RUN_BUILD=0
EXPLICIT_STAGE=0
VERBOSE="${SEQS_VERBOSE:-0}"
while [ "$#" -gt 0 ]; do
	case "$1" in
		--fetch-only) RUN_FETCH=1; EXPLICIT_STAGE=$((EXPLICIT_STAGE + 1)) ;;
		--stage-only) RUN_STAGE=1; EXPLICIT_STAGE=$((EXPLICIT_STAGE + 1)) ;;
		--build-only) RUN_BUILD=1; EXPLICIT_STAGE=$((EXPLICIT_STAGE + 1)) ;;
		--verbose) VERBOSE=1 ;;
		--repo-vm)
			[ "$#" -gt 1 ] || die "--repo-vm requires a qube name"
			REPO_VM="$2"
			shift
			;;
		*) die "unknown argument '$1' (supported: --fetch-only, --stage-only, --build-only, --repo-vm VM, --verbose)" ;;
	esac
	shift
done
[ "${EXPLICIT_STAGE}" -le 1 ] || die "choose only one of --fetch-only, --stage-only, or --build-only"
[[ "${REPO_VM}" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] || die "unsafe repo qube name: '${REPO_VM}'"

QUBE_APPLY_OPTS=()
[ "${VERBOSE}" -eq 1 ] && QUBE_APPLY_OPTS+=(--show-output)

if [ "${EXPLICIT_STAGE}" -eq 0 ]; then
	confirm "Stage 1/3 FETCH: transfer and validate repository data? type CONTINUE: " "CONTINUE"
	fetchSaltTree
	confirm "Stage 2/3 STAGE: copy the fetched tree into /srv? type CONTINUE: " "CONTINUE"
	stageSaltTree
	confirm "Stage 3/3 BUILD: create and provision the configured qubes? type CONTINUE: " "CONTINUE"
	buildQubes
elif [ "${RUN_FETCH}" -eq 1 ]; then
	fetchSaltTree
elif [ "${RUN_STAGE}" -eq 1 ]; then
	stageSaltTree
else
	buildQubes
fi
