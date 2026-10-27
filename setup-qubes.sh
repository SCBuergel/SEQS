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
#   ./setup-qubes.sh --build-only --qubes brave,signal --postfix alpha
#   ./setup-qubes.sh --build-only --all
#
# Options:
#   --repo-vm VM   the repository qube to fetch from; required for a fetch
#   --verbose      show full per-state qubesctl output (debug)

set -uo pipefail
# Bash matches [A-Za-z0-9] by the locale's collation: in en_US.UTF-8 it also
# matches look-alikes such as U+0251 and digits such as U+00B2. Every check here
# is ASCII-only, so bash itself runs in the C locale. LC_ALL is not exported,
# so the commands it runs follow the operator's LANG and LC_* settings (an
# exported LC_ALL is dropped for them: with no LANG, they run in C).
export -n LC_ALL
LC_ALL=C

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
DESKTOP_FILE="${SEQS_DESKTOP_FILE:-/var/lib/seqs/desktop}"  # written by seqs.dom0
DOM0_APPS="${SEQS_DOM0_APPS:-/usr/share/applications}"
FETCH_ROOT="${SEQS_FETCH_ROOT:-/var/lib/seqs/fetched}"
FETCH_SALT_TREE="${FETCH_ROOT}/salt"
FETCH_PILLAR_TREE="${FETCH_ROOT}/pillar"
POLICY_DIR="${SEQS_POLICY_DIR:-/etc/qubes/policy.d}"
GNOSIS_UPDATE_POLICY="${POLICY_DIR}/20-seqs-gnosisvpn-updates.policy"
GNOSIS_UPDATE_PROXY="seqs-gnosisvpn-update-proxy"
GNOSIS_PROXY_CREATED=0
# Largest archive accepted from the repository qube (SEQS's is below 1 MB).
MAX_ARCHIVE=16000000
# A safe qube, recipe, or postfix name: no option, path, or glob characters.
SAFE_NAME='^[A-Za-z0-9_][A-Za-z0-9._-]*$'

# Policy files owned by seqs.dom0. A file WITHOUT the marker was written by the
# operator or another tool -- never overwrite without confirmation.
MANAGED_MARKER="Managed by SEQS"
POLICY_FILES=(
	"${POLICY_DIR}/00-seqs-qr-input-deny.policy"
	"${POLICY_DIR}/01-seqs-qr-filecopy.policy"
	"${POLICY_DIR}/28-browser-suppress.policy"
	"${POLICY_DIR}/29-browser.policy"
	"${POLICY_DIR}/30-user-input.policy"
	"${POLICY_DIR}/50-seqs-audiovm.policy"
)

# ---- Helpers ----------------------------------------------------------------

# isManaged FILE -- SEQS wrote FILE: its first line starts with the marker.
# The marker elsewhere, such as in an operator's comment, does not count.
isManaged() {
	sudo head -n 1 -- "$1" 2>/dev/null | grep -q "^# ${MANAGED_MARKER}"
}

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
	UNATTRIBUTED_FAILURE=0
	# The output is shown as it comes and kept in memory for the scans below;
	# a temporary file would be left behind if the run is interrupted.
	out="$(sudo qubesctl "$@" 2>&1 | sanitize | tee /dev/stderr; exit "${PIPESTATUS[0]}")"
	rc=$?
	# 'Result: False' prints per failed state; 'Failed: N' matters when N > 0.
	# Salt colorizes the value, so allow whitespace/color residue between key
	# and value (sanitize() has already stripped the ESC bytes).
	if [ "${rc}" -eq 0 ] \
			&& grep -qE 'Result:([[:space:]]|\[[0-9;]*m)*False|Failed:([[:space:]]|\[[0-9;]*m)*[1-9]' <<< "${out}"; then
		echo "NOTE: qubesctl exited 0 but its output reports failed states -- treating as failure." >&2
		rc=1
		UNATTRIBUTED_FAILURE=1
	fi
	# qubesctl prints "VM: OK" or "VM: ERROR ..." per finished qube; show why
	# a qube failed from its log.
	mapfile -t OK_QUBES < <(LC_ALL=C sed -nE 's/^([A-Za-z0-9_][A-Za-z0-9._-]*): OK$/\1/p' <<< "${out}")
	mapfile -t FAILED_QUBES < <(LC_ALL=C sed -nE 's/^([A-Za-z0-9_][A-Za-z0-9._-]*): ERROR .*/\1/p' <<< "${out}")
	[ "${#FAILED_QUBES[@]}" -eq 0 ] || rc=1
	# With --show-output the stream holds the targets' own output, so a target
	# could forge an ERROR line: then no qube is singled out as the failed one.
	[[ " $* " != *" --show-output "* ]] || UNATTRIBUTED_FAILURE=1
	local vm
	for vm in "${FAILED_QUBES[@]}"; do
		echo "${vm}: last error lines of this run in /var/log/qubes/mgmt-${vm}.log:" >&2
		sudo tac "/var/log/qubes/mgmt-${vm}.log" 2>/dev/null | sed -n '2,/ exit code: /p' | tac \
			| grep -iE 'error|fail| E: ' | grep -vE 'Result: |Failed: ' | tail -n 5 \
			| sed 's/^.* output: *//' | sanitize | sed 's/^/    /' >&2
	done
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
	local name instance
	local -a requested=()
	[ "${SELECT_ALL}" -eq 0 ] || return 0
	IFS=',' read -r -a requested <<< "${SELECT_QUBES}"
	[ "${#requested[@]}" -gt 0 ] || die "--qubes requires a comma-separated list"
	for name in "${requested[@]}"; do
		[[ "${name}" =~ ${SAFE_NAME} ]] \
			|| die "unsafe or empty qube base name in --qubes: '${name}'"
	done
	mapfile -t SELECTED_NAMES < <(printf '%s\n' "${requested[@]}" | LC_ALL=C sort -u)
	SELECTED_INSTANCES=()
	for name in "${SELECTED_NAMES[@]}"; do
		instance="${name}${POSTFIX:+-${POSTFIX}}"
		[[ "${instance}" =~ ${SAFE_NAME} ]] \
			|| die "unsafe generated qube base name: '${instance}'"
		SELECTED_INSTANCES+=("${instance}")
	done
}

treeHash() {
	local sums
	sums="$(sudo find "${SALT_TREE}" "${PILLAR_TREE}" -type f ! -name .seqs-complete -print0 \
		| LC_ALL=C sort -z | sudo xargs -0 sha256sum)" || die "could not hash staged tree"
	sha256sum <<< "${sums}" | awk '{print $1}'
}

writeBuildIntent() {
	local selected tree_hash plan_hash selection_text i
	if [ "${SELECT_ALL}" -eq 1 ]; then
		selected="@all ${POSTFIX}"
		selection_text="@all${POSTFIX:+ (postfix: ${POSTFIX})}"
	else
		selected=""
		selection_text=""
		for i in "${!SELECTED_NAMES[@]}"; do
			selected+="${SELECTED_NAMES[$i]} ${SELECTED_INSTANCES[$i]}"$'\n'
			selection_text+="${selection_text:+,}${SELECTED_NAMES[$i]}=>${SELECTED_INSTANCES[$i]}"
		done
		selected="${selected%$'\n'}"
	fi
	tree_hash=$(treeHash) || exit 1
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
	RUN_SELECTION="${selection_text}"
}

writeRunManifest() {
	local result="$1"
	{
		printf 'staged_tree_sha256=%s\n' "${RUN_TREE_HASH}"
		printf 'build_plan_sha256=%s\n' "${RUN_PLAN_HASH}"
		printf 'selection=%s\n' "${RUN_SELECTION}"
		printf 'result=%s\n' "${result}"
		printf 'recorded_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	} | sudo tee "${RUN_MANIFEST}" >/dev/null || die "could not write ${RUN_MANIFEST}"
	sudo chown root:root "${RUN_MANIFEST}" && sudo chmod 0644 "${RUN_MANIFEST}" \
		|| die "could not protect ${RUN_MANIFEST}"
}

# ---- Stage 1 -- fetch and validate -------------------------------------------

# validateTarListing -- die unless every `tar --numeric-owner -tvf` line on
# stdin is safe to extract in dom0: regular files/dirs only (no symlinks,
# hardlinks, or devices), paths rooted at salt/ or install-scripts/, safe
# charset, no '..', and no name SEQS uses for its own markers. A hostile
# REPO_VM controls the archive. Lines are
# '<perms> <uid>/<gid> <size> <yyyy-mm-dd> <hh:mm> <path>'; every field before
# the path must have that exact form, or a field such as a huge timestamp,
# printed as one number, would shift part of the name into the time field.
# A 7th field, or a raw line that does not end in '<hh:mm> <path>', means
# whitespace in or around the name: reject (no SEQS file has one).
validateTarListing() {
	local line perms f_owner f_size f_date f_time path extra total=0
	while IFS= read -r line; do
		read -r perms f_owner f_size f_date f_time path extra <<< "${line}"
		[[ "${f_owner} ${f_size} ${f_date} ${f_time}" =~ ^[0-9]+/[0-9]+\ [0-9]{1,9}\ [0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]] \
			|| die "refusing tar entry with an unexpected listing: ${perms} ${f_owner} ${f_size} ${f_date} ${f_time} ${path}"
		# A sparse entry lists its full size but takes almost no archive space.
		total=$((total + 10#${f_size}))
		[ "${total}" -lt "${MAX_ARCHIVE}" ] \
			|| die "refusing archive: its files add up to ${MAX_ARCHIVE} bytes or more"
		# Before the whitespace check, which a link's "NAME -> TARGET" also fails.
		case "${perms:0:1}" in
			d|-) ;;
			*) die "refusing non-regular tar entry (type '${perms:0:1}'): ${path}" ;;
		esac
		[ -n "${extra}" ] && die "refusing tar entry with whitespace in its name: ${path} ${extra}"
		[[ "${line}" == *" ${f_time} ${path}" ]] \
			|| die "refusing tar entry with whitespace around its name: '${path}'"
		[[ "${path}" == *..* ]] && die "refusing tar path containing '..': ${path}"
		[[ "${path}" =~ ^(salt|install-scripts)(/[A-Za-z0-9._-]+)*/?$ ]] \
			|| die "refusing unsafe tar path: ${path}"
		[[ "${path%/}" == */.seqs-* ]] && die "refusing tar entry named like a SEQS marker: ${path}"
	done
	return 0
}

fetchSaltTree() {
	local tarball stage source_commit rc
	tarball=$(mktemp -t seqs-fetch.XXXXXX) || die "mktemp failed"
	stage=$(mktemp -d -t seqs-stage.XXXXXX) || die "mktemp -d failed"
	# Remove both on every exit, including each die below; mktemp names are safe.
	trap "rm -rf -- '${tarball}' '${stage}'" EXIT

	# Resolve HEAD without displaying source-controlled output, then restrict it
	# to a full object ID before using it in the archive command. Exporting that
	# exact object avoids both the live working tree and a moving-HEAD race.
	# Both reads are size-limited (head -c), so that a hostile repository qube
	# cannot fill dom0's memory: more than the limit fails a check below.
	source_commit="$(
		qvm-run -p "${REPO_VM}" \
			"git -C ${REPO_PATH} rev-parse --verify HEAD^{commit}" \
			2>/dev/null </dev/null | head -c 100
	)" || die "could not resolve repository HEAD in ${REPO_VM}:${REPO_PATH}"
	source_commit="${source_commit,,}"
	[[ "${source_commit}" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] \
		|| die "repository qube returned an invalid full commit ID for HEAD"

	echo "==> Fetching salt tree from source HEAD commit ${source_commit}"
	echo "    Source: ${REPO_VM}:${REPO_PATH}"
	# 2>/dev/null: bootstrap-window defense -- the source qube's stderr must
	# never reach the dom0 terminal raw (docs/architecture.md#bootstrap-window).
	# Export the resolved Git object, never the source qube's live working tree.
	# source_commit is restricted to a full hexadecimal object ID above, so it
	# is safe to interpolate into this fixed remote command.
	# git archive applies the commit's own .gitattributes: export-subst writes
	# commit-message text into a file and export-ignore drops one, so the
	# exported bytes would not be the reviewed blobs. A
	# commit holding one, at any depth, is refused with exit code 3 before the
	# export (ls-tree -z: an unusual name is not quoted, so the match holds).
	local remote
	remote="git -C ${REPO_PATH} cat-file -e ${source_commit}^{commit}"
	remote+=" && { git -C ${REPO_PATH} ls-tree -r -z --name-only ${source_commit} | grep -qzE '(^|/)\.gitattributes\$'; [ \$? -eq 1 ] || exit 3; }"
	remote+=" && git -C ${REPO_PATH} archive --format=tar ${source_commit} -- salt install-scripts"
	qvm-run -p "${REPO_VM}" "${remote}" \
		2>/dev/null </dev/null | head -c "${MAX_ARCHIVE}" > "${tarball}"
	rc=$?
	[ "$(stat -c %s -- "${tarball}")" -lt "${MAX_ARCHIVE}" ] \
		|| die "the archive from ${REPO_VM} reached the ${MAX_ARCHIVE}-byte limit -- refusing it"
	[ "${rc}" -ne 3 ] \
		|| die "refusing source HEAD commit ${source_commit}: its tree holds a .gitattributes file, which would make git archive export other bytes than the reviewed files"
	[ "${rc}" -eq 0 ] \
		|| die "could not export salt/ + install-scripts/ from source HEAD commit ${source_commit} in ${REPO_VM}:${REPO_PATH} -- check --repo-vm and the repository path"

	echo "    Transfer SHA256 (diagnostic only; the source qube exported the"
	echo "    resolved commit object rather than its live working tree):"
	printf '    '; sha256sum "${tarball}"

	# tar reads the archive from stdin, where it refuses compressed data;
	# given a file name, it would decompress it, past the size limit above.
	tar -tf - < "${tarball}" > /dev/null 2>&1 || die "fetched data is not a valid tar archive"

	validateTarListing < <(tar --numeric-owner -tvf - < "${tarball}" 2>/dev/null)

	# tar's warnings can quote archive bytes, such as an unknown pax header
	# keyword, so its stderr must not reach the dom0 terminal either.
	tar -xf - -C "${stage}" --no-same-owner --no-same-permissions < "${tarball}" 2>/dev/null \
		|| die "tar extraction failed"

	# Characters that make code display other than it runs ("Trojan Source"),
	# so that review could miss what they hide. No SEQS file has one:
	# terminal controls (C0 but TAB and LF, DEL, C1), as git's pager passes
	# colour codes, one of which hides text, to the terminal; the line
	# separators U+2028, U+2029; the interlinear annotation controls
	# U+FFF9-U+FFFB; and every Unicode default-ignorable code point, which
	# displays as nothing: U+00AD, U+034F, U+061C, U+115F, U+1160, U+17B4,
	# U+17B5, U+180B-U+180F, U+200B-U+200F, U+202A-U+202E, U+2060-U+206F,
	# U+3164, U+FE00-U+FE0F, U+FEFF, U+FFA0, U+FFF0-U+FFF8, U+1BCA0-U+1BCA3,
	# U+1D173-U+1D17A, U+E0000-U+E0FFF (tags, variation selectors).
	local hidden
	hidden="$(LC_ALL=C grep -rlaP '[\x00-\x08\x0b-\x1f\x7f]|\xc2[\x80-\x9f\xad]|\xcd\x8f|\xd8\x9c|\xe1\x85[\x9f\xa0]|\xe1\x9e[\xb4\xb5]|\xe1\xa0[\x8b-\x8f]|\xe2\x80[\x8b-\x8f\xa8-\xae]|\xe2\x81[\xa0-\xaf]|\xe3\x85\xa4|\xef\xb8[\x80-\x8f]|\xef\xbb\xbf|\xef\xbe\xa0|\xef\xbf[\xb0-\xbb]|\xf0\x9b\xb2[\xa0-\xa3]|\xf0\x9d\x85[\xb3-\xba]|\xf3\xa0' -- "${stage}")"
	rc=$?
	hidden="${hidden//"${stage}/"/}"
	[ "${rc}" -le 1 ] || die "could not scan the fetched tree for characters that hide code"
	[ "${rc}" -eq 1 ] || die "refusing archive: ${hidden//$'\n'/ } has control or invisible characters, which can hide code from review"

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

	# Refuse to replace a fetched area not owned by SEQS. Inspected with sudo,
	# as in stageSaltTree: unprivileged, an unreadable path looks absent.
	local d
	for d in "${FETCH_SALT_TREE}" "${FETCH_PILLAR_TREE}"; do
		if sudo test -e "${d}"; then
			sudo test -e "${d}/.seqs-managed" \
				|| die "${d} exists but is not managed by SEQS -- refusing to replace it"
		elif ! sudo test ! -e "${d}"; then
			die "could not inspect ${d}"
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

	rm -rf -- "${tarball}" "${stage}"
	trap - EXIT
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
	# touches. Only skip when the release or the absence of sys-usb is
	# positively known -- an unreadable release or a failed qvm-ls keeps the
	# prompt (fail safe). It is also skipped when Qubes' own
	# 50-config-input.policy already allows or asks for the keyboard, or the
	# staged pillar sets usb_keyboard_prompt to False on the line
	# docs/configuration.md tells the operator to edit: the state then only
	# removes a SEQS-marked file and never overwrites. That skip needs the
	# name to occur nowhere in config.sls but on that line and the shipped
	# pillar line, so any other spelling or assignment keeps the prompt.
	local usb_applies=1 release vms
	release="$(grep -oE '[0-9]+\.[0-9]+' /etc/qubes-release 2>/dev/null | head -1)" || true
	if [ -n "${release}" ] && [ "${release}" != "4.3" ]; then
		usb_applies=0
	elif [ -n "${release}" ] && vms="$(qvm-ls --raw-list 2>/dev/null)" && ! grep -qxF sys-usb <<< "${vms}"; then
		usb_applies=0
	elif sudo grep -Eqs '^[[:space:]]*qubes\.InputKeyboard[[:space:]]+\*[[:space:]]+sys-usb[[:space:]]+(@adminvm|dom0)[[:space:]]+(allow|ask)([[:space:]]|$)' \
			"${POLICY_DIR}/50-config-input.policy"; then
		usb_applies=0
	elif [ "$(grep -o usb_keyboard_prompt "${PILLAR_TREE}/config.sls" 2>/dev/null | wc -l)" = 3 ] \
			&& grep -Eqxs '\{%-? set usb_keyboard_prompt = False %\}' "${PILLAR_TREE}/config.sls" \
			&& grep -Fqxs '  usb_keyboard_prompt: {{ usb_keyboard_prompt | tojson }}' "${PILLAR_TREE}/config.sls"; then
		usb_applies=0
	fi

	local p unmanaged=()
	for p in "${POLICY_FILES[@]}"; do
		if [ "${usb_applies}" -eq 0 ] && [ "${p}" = "${POLICY_DIR}/30-user-input.policy" ]; then
			continue
		fi
		if [ -e "${p}" ] && ! isManaged "${p}"; then
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
	NETVM_TARGETS=()
	NODISPVM_TARGETS=()
	GNOSIS_TEMPLATE_TARGETS=()
	[ -r "${TARGETS_FILE}" ] || die "${TARGETS_FILE} missing -- did the seqs.dom0 state run?"
	local kind name recipe flags flag
	while read -r kind name recipe flags; do
		case "${kind}" in ''|\#*) continue ;; esac
		# Re-validated (root-written, but interpolated into qubesctl/qvm-* commands).
		[[ "${name}" =~ ${SAFE_NAME} ]] || die "unsafe qube name in ${TARGETS_FILE}: '${name}'"
		[[ "${recipe}" =~ ${SAFE_NAME} ]] || die "unsafe recipe name in ${TARGETS_FILE}: '${recipe}'"
		# 'disposable' entries (named DisposableVMs) are air-gap-verified like app
		# qubes but never provisioned via seqs.qube -- they inherit everything
		# from their dispvm template and reset on each shutdown.
		case "${kind}" in
			template)
				TEMPLATE_TARGETS+=("${name}")
				[ "${recipe}" != "gnosisvpn" ] || GNOSIS_TEMPLATE_TARGETS+=("${name}")
				;;
			app)        APP_TARGETS+=("${name}") ;;
			disposable) DISPOSABLE_TARGETS+=("${name}") ;;
			*) die "unknown entry kind in ${TARGETS_FILE}: '${kind}'" ;;
		esac
		for flag in ${flags}; do
			case "${flag}" in
				offline) case "${kind}" in app|disposable) OFFLINE_TARGETS+=("${name}") ;; esac ;;
				nodispvm) NODISPVM_TARGETS+=("${name}") ;;
				netvm=*)
					[[ "${flag#netvm=}" =~ ${SAFE_NAME} ]] || die "unsafe netvm in ${TARGETS_FILE}: '${flag}'"
					NETVM_TARGETS+=("${name} ${flag#netvm=}")
					;;
				*) die "unknown flag in ${TARGETS_FILE}: '${flag}'" ;;
			esac
		done
	done < "${TARGETS_FILE}"
	[ "${#TEMPLATE_TARGETS[@]}" -gt 0 ] || die "no templates listed in ${TARGETS_FILE}"
}

# verifyAirgap -- independent post-apply check that every 'offline' qube really
# has no netvm and no default disposable. The dom0 state sets both, but
# qvm-prefs semantics are release-dependent and these are the most
# security-critical prefs in the setup (wallet/vault air gap), so refuse to
# provision anything if they are not in effect.
verifyAirgap() {
	local vm prefs
	for vm in "${OFFLINE_TARGETS[@]}"; do
		prefs="$(qvm-prefs -- "${vm}" 2>/dev/null)" \
			|| die "could not read the preferences of offline qube '${vm}' -- refusing to provision."
		# Both must be explicitly None (flag "-"): an inherited value (flag D)
		# becomes networked when the global default changes. A default
		# disposable is reachable without a prompt through qubes.OpenInVM.
		awk '($1 == "netvm" || $1 == "default_dispvm") && $2 == "-" && $3 == "None" { n++ } END { exit n != 2 }' <<< "${prefs}" \
			|| die "offline qube '${vm}' does not have netvm and default_dispvm explicitly set to none after the dom0 apply -- air gap NOT in effect, refusing to provision. (Check the seqs-offline state in salt/seqs/dom0.sls against your Qubes release.)"
	done
	if [ "${#OFFLINE_TARGETS[@]}" -gt 0 ]; then
		echo "    Air gap verified: no netvm and no default disposable on ${OFFLINE_TARGETS[*]}."
	fi
}

# verifyNetvm -- independent post-apply check that every qube whose catalogue
# entry names a 'netvm' provider has exactly that NetVM, set explicitly: one
# inherited from the global default would bypass the VPN.
verifyNetvm() {
	local entry vm netvm
	for entry in "${NETVM_TARGETS[@]}"; do
		vm="${entry% *}" netvm="${entry#* }"
		qvm-prefs -- "${vm}" 2>/dev/null | awk -v n="${netvm}" '$1 == "netvm" && $2 == "-" && $3 == n { f = 1 } END { exit !f }' \
			|| die "qube '${vm}' does not have its netvm explicitly set to '${netvm}' after the dom0 apply -- refusing to provision."
		echo "    NetVM verified: ${vm} uses ${netvm}."
	done
}

# verifyNoDispvm -- the same check for the default disposable of every
# no_handoff or firewalled qube: one inherited from the global default is
# networked, and only the seqs-no-handoff tag would keep the qube out of it.
verifyNoDispvm() {
	local vm
	for vm in "${NODISPVM_TARGETS[@]}"; do
		qvm-prefs -- "${vm}" 2>/dev/null | awk '$1 == "default_dispvm" && $2 == "-" && $3 == "None" { f = 1 } END { exit !f }' \
			|| die "qube '${vm}' does not have default_dispvm explicitly set to none after the dom0 apply -- refusing to provision."
	done
	if [ "${#NODISPVM_TARGETS[@]}" -gt 0 ]; then
		echo "    No default disposable verified on ${NODISPVM_TARGETS[*]}."
	fi
}

# shutdownAll VM... -- barrier between phases: templates must be verifiably
# halted (root volume committed) before any app qube snapshots them at start.
shutdownAll() {
	local vm
	for vm in "$@"; do
		qvm-shutdown --wait "${vm}" 2>/dev/null || true
	done
}

# ---- Panel launchers, monitors, and keyboard shortcuts ----------------------
# Each app qube and named disposable that the seqs.dom0 state gave the
# seqs-launcher-items feature (its main app, a terminal, a file manager) gets
# one launcher in the dom0 XFCE panel: the button starts the first item, its
# arrow lists the others. A qube with the seqs-vpn-monitor feature also gets
# a monitor that shows its VPN traffic. Each plugin names its qube in a
# seqs-qube or seqs-monitor property, so a rerun finds it and delete-vms.sh
# removes it with the qube. The seqs-launcher-added and seqs-monitor-added
# features record that a plugin was added: one the user removed from the
# panel is not added again.
# The dom0 programs listed in the desktop file (dom0_launchers) get one
# launcher each, right after the panel's first plugin, the Qubes menu, marked
# seqs-dom0; the file also carries xfwm4 shortcuts (window_tiling_keys).

xfpanel() { xfconf-query -c xfce4-panel "$@"; }
xfkeys() { xfconf-query -c xfce4-keyboard-shortcuts "$@"; }
# xfArray PROPERTY -- the values of an xfconf array, one per line.
xfArray() { xfpanel -p "$1" | tail -n +3; }

# panelReady -- this user's XFCE panel runs and can be configured. The runner
# may run outside the graphical session, so it takes the session's display
# and bus from the panel's environment.
panelReady() {
	local pid v
	command -v xfconf-query >/dev/null 2>&1 || return 1
	pid="$(pgrep -u "$(id -u)" -x xfce4-panel | head -n 1)"
	[ -n "${pid}" ] || return 1
	while IFS= read -r -d '' v; do
		case "${v}" in DISPLAY=* | DBUS_SESSION_BUS_ADDRESS=*) export "${v?}" ;; esac
	done < "/proc/${pid}/environ"
	xfpanel -p /panels >/dev/null 2>&1
}

# panelPluginOf MARK VM -- the number of the plugin whose MARK property is VM.
panelPluginOf() {
	local p
	for p in $(xfpanel -l | sed -n "s|^/plugins/plugin-\([0-9]*\)/$1\$|\1|p"); do
		[ "$(xfpanel -p "/plugins/plugin-${p}/$1")" = "$2" ] && { echo "${p}"; return 0; }
	done
	return 1
}

# newPanelPlugin TYPE MARK VM WHERE -- add a TYPE plugin whose MARK property
# is VM to the first panel and print its number. WHERE is a plugin type: before
# the first plugin of that type (for a separator, an expanding one); or
# after:<number>: right after that plugin; or at the end if neither is found.
newPanelPlugin() {
	local panel id p args=() placed=0
	panel="$(xfArray /panels | head -n 1)"
	id="$(xfpanel -l | sed -n 's|^/plugins/plugin-\([0-9]*\)$|\1|p' | sort -n | tail -n 1)"
	[[ "${panel}" =~ ^[0-9]+$ && "${id}" =~ ^[0-9]+$ ]] || return 1
	id=$((id + 1))
	for p in $(xfArray "/panels/panel-${panel}/plugin-ids"); do
		if [ "${placed}" -eq 0 ] && [[ "$4" != after:* ]] \
			&& [ "$(xfpanel -p "/plugins/plugin-${p}" 2>/dev/null)" = "$4" ] \
			&& { [ "$4" != separator ] || [ "$(xfpanel -p "/plugins/plugin-${p}/expand" 2>/dev/null)" = true ]; }; then
			args+=(-t int -s "${id}")
			placed=1
		fi
		args+=(-t int -s "${p}")
		if [ "${placed}" -eq 0 ] && [ "$4" = "after:${p}" ]; then
			args+=(-t int -s "${id}")
			placed=1
		fi
	done
	[ "${placed}" -eq 1 ] || args+=(-t int -s "${id}")
	xfpanel -p "/plugins/plugin-${id}" -n -t string -s "$1" \
		&& xfpanel -p "/plugins/plugin-${id}/$2" -n -t string -s "$3" \
		&& xfpanel -p "/panels/panel-${panel}/plugin-ids" -n -a "${args[@]}" \
		&& echo "${id}"
}

# appmenuFile VM ITEM -- dom0's menu entry that starts ITEM (a desktop file
# name) in VM, as qvm-appmenus generated it.
appmenuFile() {
	local f
	for f in "${XDG_DATA_HOME:-${HOME}/.local/share}"/applications/org.qubes-os.vm.*.desktop; do
		grep -qx "X-Qubes-VmName=$1" "${f}" 2>/dev/null && grep -qx "X-Qubes-AppName=${2%.desktop}" "${f}" \
			&& { echo "${f}"; return 0; }
	done
	return 1
}

# panelLauncher VM -- add or refresh VM's launcher; fails if it has none.
panelLauncher() {
	local vm="$1" items item id file dir n=0 args=()
	local name_re='[A-Za-z0-9][A-Za-z0-9._-]*[.]desktop'
	items="$(qvm-features -- "${vm}" seqs-launcher-items 2>/dev/null)" || return 1
	[[ "${items}" =~ ^${name_re}( ${name_re})*$ ]] \
		|| { echo "WARNING: ${vm}: unexpected seqs-launcher-items; no panel launcher" >&2; return 1; }
	if ! id="$(panelPluginOf seqs-qube "${vm}")"; then
		[ -z "$(qvm-features -- "${vm}" seqs-launcher-added 2>/dev/null)" ] || return 1
		id="$(newPanelPlugin launcher seqs-qube "${vm}" separator)" \
			|| { echo "WARNING: could not add a panel launcher for ${vm}" >&2; return 1; }
		qvm-features -- "${vm}" seqs-launcher-added 1
	fi
	# Menus of a qube whose menu items just changed may not exist yet.
	for item in ${items}; do
		appmenuFile "${vm}" "${item}" >/dev/null || { qvm-appmenus --update -- "${vm}" >/dev/null 2>&1; break; }
	done
	dir="${XDG_CONFIG_HOME:-${HOME}/.config}/xfce4/panel/launcher-${id}"
	mkdir -p -- "${dir}" && rm -f -- "${dir}"/seqs-*.desktop
	for item in ${items}; do
		if file="$(appmenuFile "${vm}" "${item}")"; then
			n=$((n + 1))
			cp -- "${file}" "${dir}/seqs-${n}.desktop" && args+=(-t string -s "seqs-${n}.desktop")
		else
			echo "WARNING: ${vm} has no menu entry ${item}; left out of its panel launcher" >&2
		fi
	done
	[ "${#args[@]}" -eq 0 ] || xfpanel -p "/plugins/plugin-${id}/items" -n -a "${args[@]}"
}

# panelMonitor VM -- add VM's VPN traffic monitor, next to the notification
# area, unless it has one or had one; fails if nothing was added.
panelMonitor() {
	local vm="$1" id
	[ "$(qvm-features -- "${vm}" seqs-vpn-monitor 2>/dev/null)" = 1 ] || return 1
	! panelPluginOf seqs-monitor "${vm}" >/dev/null || return 1
	[ -z "$(qvm-features -- "${vm}" seqs-monitor-added 2>/dev/null)" ] || return 1
	id="$(newPanelPlugin genmon seqs-monitor "${vm}" systray)" \
		|| { echo "WARNING: could not add a panel monitor for ${vm}" >&2; return 1; }
	# Two seconds: a monitor updated every second can make the panel hang.
	xfpanel -p "/plugins/plugin-${id}/command" -n -t string -s "/usr/local/bin/seqs-vpn-monitor ${vm}" \
		&& xfpanel -p "/plugins/plugin-${id}/update-period" -n -t int -s 2000 \
		&& xfpanel -p "/plugins/plugin-${id}/use-label" -n -t bool -s true \
		&& xfpanel -p "/plugins/plugin-${id}/text" -n -t string -s "${vm}" \
		&& qvm-features -- "${vm}" seqs-monitor-added 1
}

# dropPanelPlugin N -- take panel plugin N off every panel and delete its
# settings and files.
dropPanelPlugin() {
	local panel i ids
	for panel in $(xfArray /panels); do
		ids=()
		for i in $(xfArray "/panels/panel-${panel}/plugin-ids"); do
			[ "${i}" = "$1" ] || ids+=(-t int -s "${i}")
		done
		if [ "${#ids[@]}" -gt 0 ]; then
			xfpanel -p "/panels/panel-${panel}/plugin-ids" -n -a "${ids[@]}"
		else
			xfpanel -p "/panels/panel-${panel}/plugin-ids" -r
		fi
	done
	xfpanel -p "/plugins/plugin-$1" -r -R
	rm -rf -- "${XDG_CONFIG_HOME:-${HOME}/.config}/xfce4/panel/launcher-$1"
}

# readDesktop -- the dom0 desktop settings that the seqs.dom0 state validated:
# DESKTOP_LAUNCHERS (desktop file names) and DESKTOP_KEYS ("shortcut action").
readDesktop() {
	DESKTOP_LAUNCHERS=()
	DESKTOP_KEYS=()
	[ -r "${DESKTOP_FILE}" ] || return 0
	local kind a b
	local shortcut_re='^(<(Super|Alt|Control|Shift|Primary|Meta|Hyper)>)+[A-Za-z0-9_]+$'
	while read -r kind a b; do
		case "${kind}" in ''|\#*) continue ;; esac
		# Re-validated (root-written, but used in file paths and xfconf properties).
		case "${kind}" in
			launcher)
				[[ "${a}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*[.]desktop$ && -z "${b}" ]] \
					|| die "unsafe launcher in ${DESKTOP_FILE}: '${a} ${b}'"
				DESKTOP_LAUNCHERS+=("${a}") ;;
			key)
				[[ "${a}" =~ ${shortcut_re} && "${b}" =~ ^[a-z][a-z_]*_key$ ]] \
					|| die "unsafe shortcut in ${DESKTOP_FILE}: '${a} ${b}'"
				DESKTOP_KEYS+=("${a} ${b}") ;;
			*) die "unknown entry in ${DESKTOP_FILE}: '${kind}'" ;;
		esac
	done < "${DESKTOP_FILE}"
}

# dom0Launchers -- one launcher per configured dom0 program, in order, right
# after the panel's first plugin; a launcher whose program left the list
# goes, and one the user removed from the panel is not added again (the
# seqs-dom0-launchers file in the panel's directory records additions).
# Returns 0 if the panel changed.
dom0Launchers() {
	local added="${XDG_CONFIG_HOME:-${HOME}/.config}/xfce4/panel/seqs-dom0-launchers"
	local panel p prop entry id anchor="" changed=1
	for prop in $(xfpanel -l | grep -E '^/plugins/plugin-[0-9]+/seqs-dom0$'); do
		entry="$(xfpanel -p "${prop}")"
		[[ " ${DESKTOP_LAUNCHERS[*]} " == *" ${entry} "* ]] && continue
		p="${prop#/plugins/plugin-}"
		dropPanelPlugin "${p%/seqs-dom0}"
		changed=0
	done
	panel="$(xfArray /panels | head -n 1)"
	[[ "${panel}" =~ ^[0-9]+$ ]] || return 1
	# New launchers go after the last current one, or after the first plugin.
	for p in $(xfArray "/panels/panel-${panel}/plugin-ids"); do
		[ -n "${anchor}" ] || anchor="${p}"
		xfpanel -p "/plugins/plugin-${p}/seqs-dom0" >/dev/null 2>&1 && anchor="${p}"
	done
	for entry in "${DESKTOP_LAUNCHERS[@]}"; do
		panelPluginOf seqs-dom0 "${entry}" >/dev/null && continue
		! grep -qxF -- "${entry}" "${added}" 2>/dev/null || continue
		[ -f "${DOM0_APPS}/${entry}" ] \
			|| { echo "WARNING: dom0 has no menu entry ${entry}; no panel launcher" >&2; continue; }
		id="$(newPanelPlugin launcher seqs-dom0 "${entry}" "after:${anchor}")" \
			|| { echo "WARNING: could not add a panel launcher for ${entry}" >&2; continue; }
		xfpanel -p "/plugins/plugin-${id}/items" -n -a -t string -s "${DOM0_APPS}/${entry}"
		mkdir -p -- "$(dirname "${added}")" && echo "${entry}" >> "${added}"
		anchor="${id}"
		changed=0
	done
	# Forget removals of programs that left the list, so a later return adds them.
	if [ -e "${added}" ]; then
		grep -xF -f <(printf '%s\n' "${DESKTOP_LAUNCHERS[@]}") -- "${added}" > "${added}.new" || true
		mv -f -- "${added}.new" "${added}"
	fi
	return "${changed}"
}

# tilingKeys -- bind the configured window-tiling shortcuts in xfwm4's custom
# key theme; a shortcut bound to another action is rebound.
tilingKeys() {
	local entry shortcut action prop
	[ "${#DESKTOP_KEYS[@]}" -gt 0 ] || return 0
	# xfwm4 reads the custom theme only once it overrides the default one; the
	# keyboard settings dialog copies every default into it first, and so does this.
	if [ "$(xfkeys -p /xfwm4/custom/override 2>/dev/null)" != true ]; then
		for prop in $(xfkeys -l | grep '^/xfwm4/default/'); do
			xfkeys -p "/xfwm4/custom/${prop#/xfwm4/default/}" -n -t string -s "$(xfkeys -p "${prop}")"
		done
		xfkeys -p /xfwm4/custom/override -n -t bool -s true
	fi
	for entry in "${DESKTOP_KEYS[@]}"; do
		read -r shortcut action <<< "${entry}"
		[ "$(xfkeys -p "/xfwm4/custom/${shortcut}" 2>/dev/null)" = "${action}" ] \
			|| xfkeys -p "/xfwm4/custom/${shortcut}" -n -t string -s "${action}"
	done
}

addPanelPlugins() {
	local vm changed=0
	panelReady || { echo "    No XFCE panel in this session: no panel launchers or shortcuts added."; return 0; }
	readDesktop
	for vm in "$@"; do
		panelLauncher "${vm}" && changed=1
		panelMonitor "${vm}" && changed=1
	done
	dom0Launchers && changed=1
	tilingKeys
	# The panel reads new plugins only when it starts.
	[ "${changed}" -eq 0 ] || xfce4-panel -r >/dev/null 2>&1 \
		|| echo "WARNING: could not restart the panel; the launchers appear at the next login" >&2
}

prepareGnosisPrerequisites() {
	[ "${#GNOSIS_TEMPLATE_TARGETS[@]}" -gt 0 ] || return 0
	local template
	echo "==> Preparing GnosisVPN dependencies through the default UpdateVM"
	for template in "${GNOSIS_TEMPLATE_TARGETS[@]}"; do
		echo "    ${template}"
		if ! qvm-run -p -u root "${template}" \
			"apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y curl gnupg openresolv wireguard-tools libc6 systemd iptables logrotate wireguard ca-certificates libwebkit2gtk-4.1-0 libgtk-3-0t64 libayatana-appindicator3-1 libglib2.0-bin" \
			2>&1 </dev/null | sanitize; then
			die "could not install GnosisVPN prerequisites in ${template} through the default updates proxy"
		fi
		qvm-shutdown --wait "${template}" \
			|| die "could not commit GnosisVPN prerequisite installation in ${template}"
	done
}

cleanupGnosisUpdateProxy() {
	sudo rm -f "${GNOSIS_UPDATE_POLICY}.new" || true
	if sudo test -f "${GNOSIS_UPDATE_POLICY}" \
		&& isManaged "${GNOSIS_UPDATE_POLICY}"; then
		sudo rm -f "${GNOSIS_UPDATE_POLICY}" || true
	fi
	if qvm-check -q -- "${GNOSIS_UPDATE_PROXY}" >/dev/null 2>&1 \
		&& { [ "${GNOSIS_PROXY_CREATED}" -eq 1 ] \
			|| [ "$(qvm-features "${GNOSIS_UPDATE_PROXY}" seqs-gnosisvpn-temporary-proxy 2>/dev/null)" = "1" ]; }; then
		qvm-kill "${GNOSIS_UPDATE_PROXY}" >/dev/null 2>&1 || true
		qvm-remove -f "${GNOSIS_UPDATE_PROXY}" >/dev/null 2>&1 || true
	fi
	GNOSIS_PROXY_CREATED=0
}

verifyGnosisUpdateProxyRemoved() {
	sudo test ! -e "${GNOSIS_UPDATE_POLICY}" \
		|| die "temporary GnosisVPN updates policy was not removed"
	! qvm-check -q -- "${GNOSIS_UPDATE_PROXY}" >/dev/null 2>&1 \
		|| die "temporary GnosisVPN updates proxy was not removed"
}

resolveTemplateVM() {
	local current=$1 klass parent depth=0
	local visited=" "
	while [ "${depth}" -lt 8 ]; do
		[[ "${current}" =~ ${SAFE_NAME} ]] \
			|| die "unsafe or empty VM name while resolving UpdateVM template: '${current}'"
		[[ "${visited}" != *" ${current} "* ]] \
			|| die "cycle while resolving TemplateVM for UpdateVM at '${current}'"
		visited+="${current} "
		klass="$(qvm-prefs -- "${current}" klass 2>/dev/null)" \
			|| die "could not determine the class of UpdateVM dependency ${current}"
		case "${klass}" in
			TemplateVM)
				printf '%s\n' "${current}"
				return 0
				;;
			AppVM|DispVM)
				parent="$(qvm-prefs -- "${current}" template 2>/dev/null)" \
					|| die "could not determine the template of UpdateVM dependency ${current}"
				current="${parent}"
				;;
			*)
				die "UpdateVM dependency ${current} has unsupported class '${klass}'"
				;;
		esac
		depth=$((depth + 1))
	done
	die "UpdateVM template chain exceeds the maximum supported depth"
}

setupGnosisUpdateProxy() {
	local updatevm proxy_template proxy_netvm value template
	[ "${#GNOSIS_TEMPLATE_TARGETS[@]}" -gt 0 ] || return 0

	if sudo test -e "${GNOSIS_UPDATE_POLICY}" \
		&& ! isManaged "${GNOSIS_UPDATE_POLICY}"; then
		die "${GNOSIS_UPDATE_POLICY} exists but is not managed by SEQS"
	fi
	if qvm-check -q -- "${GNOSIS_UPDATE_PROXY}" >/dev/null 2>&1 \
		&& [ "$(qvm-features "${GNOSIS_UPDATE_PROXY}" seqs-gnosisvpn-temporary-proxy 2>/dev/null)" != "1" ]; then
		die "${GNOSIS_UPDATE_PROXY} exists but is not marked as the SEQS temporary proxy"
	fi
	cleanupGnosisUpdateProxy

	updatevm="$(qubes-prefs updatevm 2>/dev/null)" \
		|| die "could not determine the default Qubes UpdateVM"
	[[ "${updatevm}" =~ ${SAFE_NAME} ]] \
		|| die "unsafe or empty default UpdateVM name: '${updatevm}'"
	proxy_template="$(resolveTemplateVM "${updatevm}")"
	# Behind a Whonix gateway (updates over Tor) the proxy's firewall is not
	# enforced, and a proxy built on the gateway template cannot download
	# (both seen on Qubes 4.3 with Whonix 18), so refuse instead.
	[ "$(qvm-features -- "${proxy_template}" whonix-gw 2>/dev/null)" != "1" ] \
		|| die "the UpdateVM ${updatevm} is a Whonix gateway (updates over Tor); the temporary GnosisVPN download proxy cannot be restricted to its domain behind it. To build gnosisvpn, set a non-Tor UpdateVM for this run (qubes-prefs updatevm sys-firewall), knowing the download then leaves without Tor."
	# Download over the UpdateVM's route: through the UpdateVM itself when it
	# provides network (such as sys-firewall), otherwise through its NetVM.
	if [ "$(qvm-prefs -- "${updatevm}" provides_network 2>/dev/null)" = "True" ]; then
		proxy_netvm="${updatevm}"
	else
		proxy_netvm="$(qvm-prefs -- "${updatevm}" netvm 2>/dev/null)" \
			|| die "could not determine the NetVM of UpdateVM ${updatevm}"
	fi
	for value in "${proxy_template}" "${proxy_netvm}"; do
		[[ "${value}" =~ ${SAFE_NAME} ]] \
			|| die "unsafe or empty temporary proxy dependency: '${value}'"
	done

	echo "==> Creating domain-restricted temporary GnosisVPN updates proxy"
	# Set first: a qube of this name that an interrupt leaves behind is ours,
	# since none existed after the cleanup above.
	GNOSIS_PROXY_CREATED=1
	qvm-create --class AppVM --template "${proxy_template}" --label gray \
		"${GNOSIS_UPDATE_PROXY}" || die "could not create temporary GnosisVPN updates proxy"
	qvm-features "${GNOSIS_UPDATE_PROXY}" seqs-gnosisvpn-temporary-proxy 1 \
		|| die "could not mark temporary GnosisVPN updates proxy"
	qvm-prefs -- "${GNOSIS_UPDATE_PROXY}" netvm "${proxy_netvm}" \
		|| die "could not set temporary proxy NetVM"
	qvm-service --enable "${GNOSIS_UPDATE_PROXY}" qubes-updates-proxy \
		|| die "could not enable temporary updates proxy service"
	qvm-firewall -- "${GNOSIS_UPDATE_PROXY}" reset \
		|| die "could not reset temporary proxy firewall"
	qvm-firewall -- "${GNOSIS_UPDATE_PROXY}" del --rule-no 0 \
		|| die "could not remove temporary proxy's default allow rule"
	qvm-firewall -- "${GNOSIS_UPDATE_PROXY}" add accept specialtarget=dns \
		|| die "could not allow temporary proxy DNS"
	qvm-firewall -- "${GNOSIS_UPDATE_PROXY}" add accept \
		dsthost=download.gnosisvpn.io proto=tcp dstports=443 \
		|| die "could not allow the GnosisVPN download host"
	qvm-firewall -- "${GNOSIS_UPDATE_PROXY}" add drop \
		|| die "could not install temporary proxy default deny"

	sudo mkdir -p "${GNOSIS_UPDATE_POLICY%/*}" \
		|| die "could not create qrexec policy directory"
	{
		printf '# %s\n' "${MANAGED_MARKER}"
		for template in "${GNOSIS_TEMPLATE_TARGETS[@]}"; do
			printf 'qubes.UpdatesProxy * %s @default allow target=%s\n' "${template}" "${GNOSIS_UPDATE_PROXY}"
			printf 'qubes.UpdatesProxy * %s @anyvm deny\n' "${template}"
		done
	} | sudo tee "${GNOSIS_UPDATE_POLICY}.new" >/dev/null \
		|| die "could not install temporary GnosisVPN updates policy"
	# qrexec reads only *.policy files, so it never sees a half-written one.
	sudo chmod 0644 "${GNOSIS_UPDATE_POLICY}.new" \
		&& sudo mv -f "${GNOSIS_UPDATE_POLICY}.new" "${GNOSIS_UPDATE_POLICY}" \
		|| die "could not install temporary GnosisVPN updates policy"
}

# provisionApps VM... -- apply seqs.qube to the app qubes VM...; a failure
# marks the run failed.
provisionApps() {
	[ "$#" -gt 0 ] || return 0
	if ! runQubesctl --skip-dom0 "${QUBE_APPLY_OPTS[@]}" --targets="$(joinCsv "$@")" state.apply seqs.qube; then
		echo "WARNING: at least one app qube failed to provision (see above; re-run" >&2
		echo "         with --verbose for full per-state output)." >&2
		FAILED=1
	fi
}

buildQubes() {
	[ -f "${SALT_TREE}/.seqs-complete" ] && [ -f "${PILLAR_TREE}/.seqs-complete" ] \
		|| die "stage is incomplete -- run --stage-only first"
	# Ask before anything is recorded or changed, so a refusal leaves no trace.
	confirmPolicyTakeover
	# A temporary GnosisVPN proxy or policy that a killed run left behind.
	cleanupGnosisUpdateProxy
	writeBuildIntent
	writeRunManifest started
	echo ""
	echo "==> Applying dom0 state (policies, qube creation)"
	runQubesctl top.enable seqs.config pillar=true || die "qubesctl top.enable failed"
	runQubesctl state.apply seqs.dom0 || die "seqs.dom0 failed -- nothing was provisioned inside any qube. Fix the reported problem and re-run (re-runs converge)."

	readTargets
	verifyAirgap
	verifyNetvm
	verifyNoDispvm
	if [ "${#DISPOSABLE_TARGETS[@]}" -gt 0 ]; then
		# Named disposables are created and air-gap-verified by the dom0 apply above;
		# they inherit everything from their dispvm template and are never provisioned.
		echo "    Named disposable(s) ready (not provisioned): ${DISPOSABLE_TARGETS[*]}"
	fi
	FAILED=0

	# A template still running here was left by an interrupted run, and an
	# install inside it may still hold the package lock; stop it first. A busy one
	# may not shut down in time: kill it, and seqs.qube finishes the interrupted
	# package installation on the next start.
	for vm in "${TEMPLATE_TARGETS[@]}"; do
		if qvm-check --running -q -- "${vm}" >/dev/null 2>&1; then
			echo "    ${vm} is still running, perhaps from an interrupted run; shutting it down"
			qvm-shutdown --wait -- "${vm}" >/dev/null 2>&1 || qvm-kill -- "${vm}" >/dev/null 2>&1 \
				|| die "could not stop ${vm}"
		fi
	done

	echo ""
	prepareGnosisPrerequisites
	if [ "${#GNOSIS_TEMPLATE_TARGETS[@]}" -gt 0 ]; then
		trap cleanupGnosisUpdateProxy EXIT
		trap 'cleanupGnosisUpdateProxy; trap - EXIT; exit 130' INT TERM
	fi
	setupGnosisUpdateProxy
	echo "==> [2/3] Provisioning ${#TEMPLATE_TARGETS[@]} template(s): ${TEMPLATE_TARGETS[*]}"
	if ! runQubesctl --skip-dom0 "${QUBE_APPLY_OPTS[@]}" \
		--targets="$(joinCsv "${TEMPLATE_TARGETS[@]}")" state.apply seqs.qube; then
		echo "WARNING: at least one template failed to provision (see above; re-run" >&2
		echo "         with --verbose for full per-state output)." >&2
		echo "         Re-run to converge -- finished components are skipped." >&2
		FAILED=1
		# With qubesctl's own per-qube ERROR lines, a template counts as
		# provisioned only if it has an OK line and no ERROR line: one with
		# neither did not finish. Without ERROR lines, or when a template's
		# output could have forged one, every template counts as failed.
		if [ "${#FAILED_QUBES[@]}" -gt 0 ] && [ "${UNATTRIBUTED_FAILURE}" -eq 0 ]; then
			local -a failed=()
			for vm in "${TEMPLATE_TARGETS[@]}"; do
				[[ " ${OK_QUBES[*]} " == *" ${vm} "* && " ${FAILED_QUBES[*]} " != *" ${vm} "* ]] \
					|| failed+=("${vm}")
			done
			FAILED_QUBES=("${failed[@]}")
		else
			FAILED_QUBES=("${TEMPLATE_TARGETS[@]}")
		fi
	fi
	FAILED_TEMPLATES=("${FAILED_QUBES[@]}")
	cleanupGnosisUpdateProxy
	verifyGnosisUpdateProxyRemoved
	trap - EXIT INT TERM

	# Commit template root volumes before any app qube snapshots them. A template
	# that is still running counts as failed: its app qubes would start on the
	# old root snapshot.
	shutdownAll "${TEMPLATE_TARGETS[@]}"
	for vm in "${TEMPLATE_TARGETS[@]}"; do
		if qvm-check --running -q -- "${vm}" >/dev/null 2>&1; then
			echo "WARNING: ${vm} did not shut down" >&2
			FAILED=1
			FAILED_TEMPLATES+=("${vm}")
		fi
	done
	# A template reports new menu entries while it is provisioned, which refreshes
	# the menus of its app qubes but not of named disposables one level further.
	for vm in "${DISPOSABLE_TARGETS[@]}"; do
		qvm-appmenus --update -- "${vm}" >/dev/null 2>&1 \
			|| echo "WARNING: could not refresh the menu of ${vm}" >&2
	done

	# An app qube of a failed template would be provisioned on a partial install.
	apps=()
	local tpl
	for vm in "${APP_TARGETS[@]}"; do
		tpl="$(qvm-prefs -- "${vm}" template)" && [ -n "${tpl}" ] || die "could not read the template of ${vm}"
		if [[ " ${FAILED_TEMPLATES[*]} " == *" ${tpl} "* ]]; then
			echo "WARNING: skipping ${vm}: its template failed" >&2
			FAILED=1
		else
			apps+=("${vm}")
		fi
	done
	APP_TARGETS=("${apps[@]}")

	# Qubes with a 'netvm' go in a second wave: Salt shuts each qube down after
	# provisioning it, and Qubes refuses to shut down a NetVM that a running
	# qube uses.
	local entry
	local -a routed=() first=() second=()
	for entry in "${NETVM_TARGETS[@]}"; do routed+=("${entry% *}"); done
	for vm in "${APP_TARGETS[@]}"; do
		if [[ " ${routed[*]} " == *" ${vm} "* ]]; then second+=("${vm}"); else first+=("${vm}"); fi
	done

	echo ""
	echo "==> [3/3] Provisioning ${#APP_TARGETS[@]} app qube(s): ${APP_TARGETS[*]}"
	provisionApps "${first[@]}"
	provisionApps "${second[@]}"

	shutdownAll "${second[@]}" "${first[@]}"
	addPanelPlugins "${APP_TARGETS[@]}" "${DISPOSABLE_TARGETS[@]}"

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
POSTFIX=""
POSTFIX_SET=0
REPO_VM_SET=0
while [ "$#" -gt 0 ]; do
	case "$1" in
		--fetch-only) RUN_FETCH=1; EXPLICIT_STAGE=$((EXPLICIT_STAGE + 1)) ;;
		--stage-only) RUN_STAGE=1; EXPLICIT_STAGE=$((EXPLICIT_STAGE + 1)) ;;
		--build-only) RUN_BUILD=1; EXPLICIT_STAGE=$((EXPLICIT_STAGE + 1)) ;;
		--verbose) VERBOSE=1 ;;
		--all) SELECT_ALL=1 ;;
		--postfix)
			[ "$#" -gt 1 ] || die "--postfix requires a value"
			[ "${POSTFIX_SET}" -eq 0 ] || die "--postfix may be specified only once"
			POSTFIX="$2"
			POSTFIX_SET=1
			shift
			;;
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
		*) die "unknown argument '$1' (supported: --fetch-only, --stage-only, --build-only, --qubes LIST, --all, --postfix NAME, --repo-vm VM, --verbose)" ;;
	esac
	shift
done
[ "${EXPLICIT_STAGE}" -le 1 ] || die "choose only one of --fetch-only, --stage-only, or --build-only"
[ "${SELECT_ALL}" -eq 0 ] || [ -z "${SELECT_QUBES}" ] || die "choose only one of --all or --qubes"
if [ "${RUN_BUILD}" -eq 1 ] || [ "${EXPLICIT_STAGE}" -eq 0 ]; then
	[ "${SELECT_ALL}" -eq 1 ] || [ -n "${SELECT_QUBES}" ] \
		|| die "a build selection is required: use --qubes NAME[,NAME...] or --all"
	if [ "${POSTFIX_SET}" -eq 1 ] && ! [[ "${POSTFIX}" =~ ${SAFE_NAME} ]]; then
		die "unsafe or empty postfix '${POSTFIX}' (allowed: [A-Za-z0-9_][A-Za-z0-9._-]*)"
	fi
	canonicalizeSelection
elif [ "${SELECT_ALL}" -eq 1 ] || [ -n "${SELECT_QUBES}" ] || [ "${POSTFIX_SET}" -eq 1 ]; then
	die "--qubes/--all/--postfix applies only to a build or the full fetch-stage-build workflow"
fi
if [ "${RUN_FETCH}" -eq 1 ] || [ "${EXPLICIT_STAGE}" -eq 0 ]; then
	[ "${REPO_VM_SET}" -eq 1 ] \
		|| die "fetch requires --repo-vm with the explicit repository qube name"
	[[ "${REPO_VM}" =~ ${SAFE_NAME} ]] \
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
