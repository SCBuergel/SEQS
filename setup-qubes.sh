#!/usr/bin/env bash

# SEQS dom0 runner; see docs/architecture.md and docs/configuration.md.
#
# Usage:
#   ./setup-qubes.sh --repo-vm VM --all
#                                   fetch, stage, and build the full catalogue
#   ./setup-qubes.sh --repo-vm VM --fetch-only
#                                   fetch and validate into /var/lib/seqs/fetched
#   ./setup-qubes.sh --stage-only   copy the fetched tree into /srv
#   ./setup-qubes.sh --build-only --qubes brave,signal
#   ./setup-qubes.sh --build-only --all
#   --repo-vm VM                    required explicit repository qube for fetch
#   ./setup-qubes.sh --verbose      show full per-state qubesctl output (debug)

set -uo pipefail

# ---- Config -- usually set once when first installing SEQS. -----------------
# The fetch source qube has no default: every fetch must name it explicitly.
REPO_VM=""
REPO_PATH="${SEQS_REPO_PATH:-/home/user/SEQS}"

# Filesystem roots. The SEQS_* overrides let the test harness run in a scratch
# dir; a normal dom0 install sets none and gets the real /srv + /var/lib paths.
SALT_TREE="${SEQS_SALT_TREE:-/srv/salt/seqs}"
PILLAR_TREE="${SEQS_PILLAR_TREE:-/srv/pillar/seqs}"
TARGETS_FILE="${SEQS_TARGETS_FILE:-/var/lib/seqs/targets}"  # written by seqs.dom0
SELECTION_FILE="${SEQS_SELECTION_FILE:-/var/lib/seqs/selection}"
RUN_MANIFEST="${SEQS_RUN_MANIFEST:-/var/lib/seqs/last-run}"
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

# confirm PROMPT -- conventional default-no [y/N] confirmation. Only y/Y
# proceeds. Reads from /dev/tty so piped stdin cannot be misread as approval;
# Enter, EOF, and every other response abort.
confirm() {
	local answer
	if ! read -rp "$1 [y/N] " answer </dev/tty; then
		die "no terminal available to confirm -- aborting."
	fi
	case "${answer}" in
		y|Y) return 0 ;;
		*) die "not confirmed -- aborting." ;;
	esac
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

showWorkflow() {
	echo "SEQS workflow and paths:"
	echo "  FETCH  repository qube -> ${FETCH_ROOT}"
	echo "         validated review copy; not active Salt configuration"
	echo "  STAGE  ${FETCH_ROOT} -> ${SALT_TREE} + ${PILLAR_TREE}"
	echo "         /srv/salt and /srv/pillar are the standard Qubes Salt roots"
	echo "  BUILD  explicitly selected catalogue entries -> TemplateVMs and AppVMs"
	echo ""
}

canonicalizeSelection() {
	local raw name
	local -a requested=()
	if [ "${SELECT_ALL}" -eq 1 ]; then
		SELECTED_NAMES=("@all")
		return 0
	fi
	IFS=',' read -r -a requested <<< "${SELECT_QUBES}"
	[ "${#requested[@]}" -gt 0 ] || die "--qubes requires a comma-separated list"
	for raw in "${requested[@]}"; do
		name="${raw}"
		[[ "${name}" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] \
			|| die "unsafe or empty qube base name in --qubes: '${name}'"
	done
	mapfile -t SELECTED_NAMES < <(printf '%s\n' "${requested[@]}" | LC_ALL=C sort -u)
}

treeHash() {
	local listing
	listing=$(mktemp /tmp/seqs-tree-hash.XXXXXX) || die "mktemp failed"
	if ! sudo find "${SALT_TREE}" "${PILLAR_TREE}" -type f ! -name .seqs-complete -print0 \
		| LC_ALL=C sort -z | sudo xargs -0 sha256sum > "${listing}"; then
		rm -f "${listing}"
		die "could not hash staged tree"
	fi
	sha256sum "${listing}" | awk '{print $1}'
	rm -f "${listing}"
}

writeBuildIntent() {
	local selected tree_hash plan_hash selection_text
	selected=$(printf '%s\n' "${SELECTED_NAMES[@]}")
	selection_text=$(printf '%s\n' "${SELECTED_NAMES[@]}" | paste -sd, -)
	tree_hash=$(treeHash)
	plan_hash=$(printf '%s\n%s\n' "${tree_hash}" "${selected}" | sha256sum | awk '{print $1}')
	sudo mkdir -p "${SELECTION_FILE%/*}" "${RUN_MANIFEST%/*}" \
		|| die "could not create runtime state directory"
	printf '%s\n' "${selected}" | sudo tee "${SELECTION_FILE}" >/dev/null \
		|| die "could not write runtime selection to ${SELECTION_FILE}"
	sudo chown root:root "${SELECTION_FILE}" && sudo chmod 0644 "${SELECTION_FILE}" \
		|| die "could not protect ${SELECTION_FILE}"
	echo "    Staged tree SHA256: ${tree_hash}"
	echo "    Build-plan SHA256:  ${plan_hash}"
	echo "    Requested qubes:    ${selection_text}"
	RUN_TREE_HASH="${tree_hash}"
	RUN_PLAN_HASH="${plan_hash}"
}

writeRunManifest() {
	local result="$1" selected
	selected=$(printf '%s\n' "${SELECTED_NAMES[@]}" | paste -sd, -)
	{
		printf 'staged_tree_sha256=%s\n' "${RUN_TREE_HASH}"
		printf 'build_plan_sha256=%s\n' "${RUN_PLAN_HASH}"
		printf 'selection=%s\n' "${selected}"
		printf 'result=%s\n' "${result}"
		printf 'recorded_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	} | sudo tee "${RUN_MANIFEST}" >/dev/null || die "could not write ${RUN_MANIFEST}"
	sudo chown root:root "${RUN_MANIFEST}" && sudo chmod 0644 "${RUN_MANIFEST}" \
		|| die "could not protect ${RUN_MANIFEST}"
}

# ---- Stage 1 -- fetch and validate -------------------------------------------

fetchSaltTree() {
	local tarball stage source_commit
	tarball=$(mktemp /tmp/seqs-fetch.XXXXXX.tar) || die "mktemp failed"
	stage=$(mktemp -d /tmp/seqs-stage.XXXXXX) || die "mktemp -d failed"

	# Resolve HEAD without displaying source-controlled output, then restrict it
	# to a full object ID before using it in the archive command. Exporting that
	# exact object avoids both the live working tree and a moving-HEAD race.
	source_commit="$(
		qvm-run -p "${REPO_VM}" \
			"git -C ${REPO_PATH} rev-parse --verify HEAD^{commit}" \
			2>/dev/null
	)" || {
		rm -rf "${tarball}" "${stage}"
		die "could not resolve repository HEAD in ${REPO_VM}:${REPO_PATH}"
	}
	source_commit="${source_commit,,}"
	[[ "${source_commit}" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || {
		rm -rf "${tarball}" "${stage}"
		die "repository qube returned an invalid full commit ID for HEAD"
	}

	echo "==> Fetching salt tree from source HEAD commit ${source_commit}"
	echo "    Source: ${REPO_VM}:${REPO_PATH}"
	# 2>/dev/null: bootstrap-window defense -- the source qube's stderr must
	# never reach the dom0 terminal raw (docs/architecture.md#bootstrap-window).
	# Export the resolved Git object, never the source qube's live working tree.
	# source_commit is restricted to a full hexadecimal object ID above, so it
	# is safe to interpolate into this fixed remote command.
	if ! qvm-run -p "${REPO_VM}" \
		"git -C ${REPO_PATH} cat-file -e ${source_commit}^{commit} && git -C ${REPO_PATH} archive --format=tar ${source_commit} -- salt install-scripts" \
		2>/dev/null > "${tarball}"; then
		rm -rf "${tarball}" "${stage}"
		die "could not export salt/ + install-scripts/ from source HEAD commit ${source_commit} in ${REPO_VM}:${REPO_PATH} -- check --repo-vm and the repository path"
	fi

	echo "    Transfer SHA256 (diagnostic only; the source qube exported the"
	echo "    resolved commit object rather than its live working tree):"
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
	printf '%s\n' "${source_commit}" | sudo tee "${FETCH_ROOT}/source-commit" >/dev/null \
		|| die "could not record fetched source commit"
	sudo touch "${FETCH_ROOT}/.seqs-complete" || die "could not mark fetch complete"
	sudo chown -R root:root "${FETCH_ROOT}"
	sudo chmod a+rx "$(dirname "${FETCH_ROOT}")" "${FETCH_ROOT}"
	sudo chmod -R a+rX,go-w "${FETCH_ROOT}"

	rm -rf "${tarball}" "${stage}"
	echo "    Fetch complete. No Salt state was staged or applied."
	echo "    Review ${FETCH_SALT_TREE} and ${FETCH_PILLAR_TREE}."
}

# ---- Stage 2 -- stage the reviewed tree in /srv ------------------------------

stageSaltTree() {
	[ -f "${FETCH_ROOT}/.seqs-complete" ] \
		&& [ -f "${FETCH_SALT_TREE}/.seqs-managed" ] \
		&& [ -f "${FETCH_PILLAR_TREE}/.seqs-managed" ] \
		|| die "fetch stage is incomplete -- run --fetch-only first"

	local d diffout one rc i
	for d in "${SALT_TREE}" "${PILLAR_TREE}"; do
		# /srv may not be traversable by the dom0 user. Inspect it with the
		# same privilege used for staging; otherwise a permission error looks
		# exactly like an absent path and bypasses the ownership guard.
		if sudo test -e "${d}"; then
			sudo test -e "${d}/.seqs-managed" \
				|| die "${d} exists but is not managed by SEQS -- refusing to replace it"
		elif ! sudo test ! -e "${d}"; then
			die "could not inspect ${d}"
		fi
	done

	# Preview with privileged reads too. Treat a real diff as expected, but do
	# not turn a read/permission failure into a misleading list of changes.
	diffout=""
	local -a current_trees=("${SALT_TREE}" "${PILLAR_TREE}")
	local -a fetched_trees=("${FETCH_SALT_TREE}" "${FETCH_PILLAR_TREE}")
	for i in 0 1; do
		if sudo test -e "${current_trees[$i]}"; then
			one="$(sudo diff -r --exclude=.seqs-complete \
				"${current_trees[$i]}" "${fetched_trees[$i]}" 2>&1)"
			rc=$?
			[ "${rc}" -le 1 ] || die "could not compare ${current_trees[$i]} with fetched tree: ${one}"
		else
			one="${current_trees[$i]} is not yet staged"
		fi
		if [ -n "${one}" ]; then
			diffout="${diffout}${diffout:+$'\n'}${one}"
		fi
	done
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
	echo "    Staging complete. The files are visible to Qubes Salt; no qubes were built."
}

# ---- Build helpers -----------------------------------------------------------

# seqs.dom0 owns the qrexec policy files in POLICY_FILES and converges them on
# every apply. Files it wrote carry MANAGED_MARKER; a file WITHOUT the marker
# is the operator's -- block, show it, and require explicit confirmation before
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

	confirm "Overwrite the file(s) above?"
}

# ---- Phase 3 -- apply -------------------------------------------------------

readTargets() {
	TEMPLATE_TARGETS=()
	APP_TARGETS=()
	DISPOSABLE_TARGETS=()
	OFFLINE_TARGETS=()
	[ -r "${TARGETS_FILE}" ] || die "${TARGETS_FILE} missing -- did the seqs.dom0 state run?"
	local kind name flags flag
	while read -r kind name flags; do
		case "${kind}" in ''|\#*) continue ;; esac
		# Re-validated (root-written, but interpolated into qubesctl/qvm-* commands).
		[[ "${name}" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] || die "unsafe qube name in ${TARGETS_FILE}: '${name}'"
		# 'disposable' entries (named DisposableVMs) are air-gap-verified like app
		# qubes but never provisioned via seqs.qube -- they inherit everything
		# from their dispvm template and reset on each shutdown.
		case "${kind}" in
			template)   TEMPLATE_TARGETS+=("${name}") ;;
			app)        APP_TARGETS+=("${name}") ;;
			disposable) DISPOSABLE_TARGETS+=("${name}") ;;
			*) die "unknown entry kind in ${TARGETS_FILE}: '${kind}'" ;;
		esac
		for flag in ${flags}; do
			case "${flag}" in
				offline) case "${kind}" in app|disposable) OFFLINE_TARGETS+=("${name}") ;; esac ;;
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
	writeBuildIntent
	writeRunManifest started
	echo ""
	echo "==> Applying dom0 state (policies, qube creation)"
	runQubesctl top.enable seqs.config pillar=true || die "qubesctl top.enable failed"
	confirmPolicyTakeover
	runQubesctl state.apply seqs.dom0 || die "seqs.dom0 failed -- nothing was provisioned inside any qube. Fix the reported problem and re-run (re-runs converge)."

readTargets
verifyAirgap
if [ "${#DISPOSABLE_TARGETS[@]}" -gt 0 ]; then
	# Named disposables are created and air-gap-verified by the dom0 apply above;
	# they inherit everything from their dispvm template and are never provisioned.
	echo "    Named disposable(s) ready (not provisioned): ${DISPOSABLE_TARGETS[*]}"
fi
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
		writeRunManifest success
		echo "==> SEQS setup complete. All targets provisioned."
	else
		writeRunManifest failure
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
SELECT_ALL=0
SELECT_QUBES=""
REPO_VM_SET=0
while [ "$#" -gt 0 ]; do
	case "$1" in
		--fetch-only) RUN_FETCH=1; EXPLICIT_STAGE=$((EXPLICIT_STAGE + 1)) ;;
		--stage-only) RUN_STAGE=1; EXPLICIT_STAGE=$((EXPLICIT_STAGE + 1)) ;;
		--build-only) RUN_BUILD=1; EXPLICIT_STAGE=$((EXPLICIT_STAGE + 1)) ;;
		--verbose) VERBOSE=1 ;;
		--all) SELECT_ALL=1 ;;
		--qubes)
			[ "$#" -gt 1 ] || die "--qubes requires a comma-separated list"
			[ -z "${SELECT_QUBES}" ] || die "--qubes may be specified only once"
			SELECT_QUBES="$2"
			shift
			;;
		--repo-vm)
			[ "$#" -gt 1 ] || die "--repo-vm requires a qube name"
			[ "${REPO_VM_SET}" -eq 0 ] || die "--repo-vm may be specified only once"
			REPO_VM="$2"
			REPO_VM_SET=1
			shift
			;;
		*) die "unknown argument '$1' (supported: --fetch-only, --stage-only, --build-only, --qubes LIST, --all, --repo-vm VM, --verbose)" ;;
	esac
	shift
done
[ "${EXPLICIT_STAGE}" -le 1 ] || die "choose only one of --fetch-only, --stage-only, or --build-only"
[ "${SELECT_ALL}" -eq 0 ] || [ -z "${SELECT_QUBES}" ] || die "choose only one of --all or --qubes"
if [ "${RUN_BUILD}" -eq 1 ] || [ "${EXPLICIT_STAGE}" -eq 0 ]; then
	[ "${SELECT_ALL}" -eq 1 ] || [ -n "${SELECT_QUBES}" ] \
		|| die "a build selection is required: use --qubes NAME[,NAME...] or --all"
	canonicalizeSelection
elif [ "${SELECT_ALL}" -eq 1 ] || [ -n "${SELECT_QUBES}" ]; then
	die "--qubes/--all applies only to a build or the full fetch-stage-build workflow"
fi
if [ "${RUN_FETCH}" -eq 1 ] || [ "${EXPLICIT_STAGE}" -eq 0 ]; then
	[ "${REPO_VM_SET}" -eq 1 ] \
		|| die "fetch requires --repo-vm with the explicit repository qube name"
	[[ "${REPO_VM}" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] \
		|| die "unsafe repo qube name: '${REPO_VM}'"
	[[ "${REPO_PATH}" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "${REPO_PATH}" != *..* ]] \
		|| die "unsafe repository path: '${REPO_PATH}'"
elif [ "${REPO_VM_SET}" -eq 1 ]; then
	die "--repo-vm applies only to --fetch-only or the full fetch-stage-build workflow"
fi

QUBE_APPLY_OPTS=()
[ "${VERBOSE}" -eq 1 ] && QUBE_APPLY_OPTS+=(--show-output)
showWorkflow

if [ "${EXPLICIT_STAGE}" -eq 0 ]; then
	# Single-step install: fetch -> stage -> build in one confirmed run. The
	# policy-takeover prompt and air-gap verification inside BUILD still gate
	# their own actions; reviewers who want to pause between phases use the
	# explicit --fetch-only / --stage-only / --build-only commands instead.
	confirm "Install: fetch and validate, stage under /srv, then build the selected qubes?"
	fetchSaltTree
	stageSaltTree
	buildQubes
elif [ "${RUN_FETCH}" -eq 1 ]; then
	fetchSaltTree
elif [ "${RUN_STAGE}" -eq 1 ]; then
	stageSaltTree
else
	buildQubes
fi
