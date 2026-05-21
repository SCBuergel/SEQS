#!/usr/bin/env bash

# ════════════════════════════════════════════════════════════════════════════
# Qubes to build -- the main knobs. Edit these to change what gets created.
# ════════════════════════════════════════════════════════════════════════════
#
# Every qube spec is: "NAME COLOR component [component ...] [offline]"
#   * NAME     -- gets PREFIX_TEMPLATE_VM/PREFIX_APP_VM prepended (default Z-/A-)
#   * COLOR    -- Qubes label. The window border is your last-glance check
#                 before clicking. Each color names a risk class (not a unique
#                 qube), building on Qubes' own sys-* convention
#                 (sys-net/sys-usb=red, sys-firewall=green):
#                   red    -- arbitrary network input from strangers
#                             (brave, element, telegram)
#                   orange -- heavy tooling / agent code execution
#                             (dev qubes -- npm/pypi/curl|bash/LLM agents)
#                   yellow -- local docs with import risk
#                             (openoffice, xournalpp)
#                   green  -- clean utility, known-only input
#                             (signal: E2E with known contacts)
#                   gray   -- exposed AND holds value: no safe zone classifies
#                             (wallets: extensions over Brave, signs irrev. tx)
#                   black  -- offline vault, no network at all (keepass)
#                 blue and purple are left unused -- reserve them for user-
#                 added qubes that don't fit the categories above.
#                 https://doc.qubes-os.org/en/latest/introduction/getting-started.html
#   * components live under install-scripts/components/<name>/ (mix and match)
#   * trailing 'offline' detaches the app qube from netvm (used for keepass)

# Single-component qubes -- one app per qube.
SINGLE_QUBES=(
	"brave             red    brave"                # network strangers -- web
	"element           red    element"              # network strangers -- chat (links/files)
	"telegram          red    telegram"             # network strangers -- bots/channels/groups
	"signal            green  signal"               # E2E with known contacts only
	"openoffice        yellow openoffice"           # local docs -- import risk
	"xournalpp         yellow xournalpp"            # local docs -- minimal surface
	"usb-data-transfer red    adb"                  # USB-attached devices -- arbitrary file input
	"keepass           black  keepass    offline"   # offline vault
)

# Developer qubes -- mix any components; typical: docker, python, node, vscode,
# claude-code. Each entry builds one template + app qube.
DEV_QUBES=(
	"dev-full orange docker python node vscode claude-code"   # heavy tooling + LLM-agent code execution
)

# Wallet qubes -- use 'brave-extension-<name>' to add a wallet extension
# (looked up in BRAVE_EXTENSIONS below; Brave is auto-installed when needed).
WALLET_QUBES=(
	"wallet-ledger gray ledger brave-extension-rabby"   # exposed (extensions, online) AND holds value
	"wallet-trezor gray trezor brave-extension-rabby"   # exposed (extensions, online) AND holds value
)

# Brave wallet extension name -> Chrome Web Store ID. Reference these as
# 'brave-extension-<name>' in WALLET_QUBES (or any other qube spec).
# Add/remove lines to enable/retire an extension.
BRAVE_EXTENSIONS=(
	"ready         dlcobpjiigpikoobohmabehhmhfoodbb"
	"cosmostation  fpkhgmpbidmiogeglndfbkegfdlnajnf"
	"enkrypt       kkpllkodjeloidieedojogacfhpaihoh"
	"metamask      nkbihfbeogaeaoehlefnkodbefgpgknn"
	"nabox         nknhiehlklippafakaeklbeglecifhad"
	"okx           mcohilncbfahbmgdjkbpemcciiolgcge"
	"rabby         acmacodkjbdgmoleebolmdjonilkdbch"
	"rainbow       opfgelmcmbiajamepnmloijbpoleiama"
	"tahoe         eajafomhmkipbjmfmhebemolkcicgfmd"
	"trustwallet   egjidjbpglichdcondbcbdnbeeppgdph"
	"zeal          heamnjbnflcikcggoiplibfommfbkjpj"
	"zerion        klghhnkeealcohjjanjjdaeeggmfmlpl"
)

# ════════════════════════════════════════════════════════════════════════════
# Source / base qubes -- usually set once when first installing SEQS.
# ════════════════════════════════════════════════════════════════════════════

# Qube that holds the SEQS repo; install scripts are fetched from here.
REPO_VM="personal"

# Base template every new template VM clones from.
OS_TEMPLATE_VM="debian-13-xfce"

# Naming prefix added to each created qube.
PREFIX_APP_VM="A-"
PREFIX_TEMPLATE_VM="Z-"

# App qube every non-browser qube opens web links in (for isolation). Must
# match a qube that actually gets built (or an existing one).
BROWSER_VM="${PREFIX_APP_VM}brave"
# Filename of the .desktop link handler installed into each non-browser qube.
BROWSER_DESKTOP="open-links-in-browser-qube.desktop"

# ════════════════════════════════════════════════════════════════════════════
# Hardening
# ════════════════════════════════════════════════════════════════════════════

# Transient-directory cleanup at app-qube boot and shutdown, via a systemd
# service installed into each template. Empty array disables.
CLEANUP_DIRS=(
	"/home/user/QubesIncoming"
	"/home/user/Downloads"
)

# Per-qube build timeout in seconds. A normal component-heavy build (e.g.
# dev-full with docker+python+node+vscode+claude-code) finishes well under
# 15 minutes on typical hardware; longer implies a network stall, a hung
# qvm-run, or a stuck install script. On timeout, installQube's watchdog
# kills the build subshell and the usual rollback removes the half-built
# Z-/A- pair.
BUILD_TIMEOUT_SECONDS=900

# ════════════════════════════════════════════════════════════════════════════
# Internal -- rarely edited.
# ════════════════════════════════════════════════════════════════════════════

# Every *.sh under LIB_PATH is auto-discovered (see discoverLibFiles) and
# shipped next to every install script inside the target VM, so install
# scripts can `source` them.
LIB_PATH="/home/user/SEQS/install-scripts/lib/"

# vmRun -- wrapper around `qvm-run` for any caller that DISPLAYS the VM's
# stdout/stderr on the dom0 terminal (i.e. anything not captured into a
# variable or redirected to a file).
#
# Why: a single install run pipes the output of apt-get, dpkg post-install
# scriptlets, gpg, snapd, third-party installer scripts (pyenv.run, nvm,
# claude.ai/install.sh, Ledger Live download, ...) back through qvm-run to
# the dom0 terminal. We do not audit any of that downstream output, and even
# a single OSC / CSI sequence reaching the terminal emulator is enough to
# reposition the cursor (repaint earlier "OK" lines as something else), ring
# the bell, set the window title to smuggle keys via paste tricks, or fire
# OSC 52 clipboard writes. Defense is two-stage:
#
#   1. `tr` strips every C0 control character except TAB and LF, plus DEL.
#      That removes the 7-bit form of ESC (0x1B), so ESC[ (CSI), ESC] (OSC),
#      BEL, etc. cannot reach the terminal as control bytes.
#
#   2. `iconv -f UTF-8 -t UTF-8 -c` drops any byte that is NOT part of a
#      valid UTF-8 sequence. The relevant target is a raw single-byte
#      0x80..0x9F (the 8-bit form of C1 control codes -- 0x9B is CSI,
#      0x9D is OSC). On a terminal in any 8-bit mode (xterm with
#      `allowC1Printable: true`, several non-default Konsole/gnome-term
#      configurations) those raw bytes are interpreted as control
#      sequences. We cannot just `tr -d '\200-\237'` because the same
#      byte range is valid UTF-8 continuation; iconv inspects context
#      and drops only the lone-byte form, preserving multi-byte
#      characters like "Über" (\xC3\x9C ...) intact.
#
#   3. `sed` strips the UTF-8 encoding of the C1 control range
#      U+0080..U+009F (two-byte sequences `\xc2\x80` .. `\xc2\x9f`). U+009B
#      is the single-byte CSI, U+009D is single-byte OSC; xterm with
#      `allowC1Printable: false` (the default) and several other terminals
#      DO interpret encoded UTF-8 C1 codepoints as control sequences, so
#      preserving them would have left a parallel channel to the C0 one
#      stage 1 closes. The LC_ALL=C is required so the byte-range pattern
#      bypasses sed's locale-aware regex behaviour.
#
# Visible UTF-8 (everything in 0x80..0xFF outside the encoded-C1 sequences)
# is preserved so apt/dpkg log lines stay readable.
#
# Heredoc support: a heredoc attached to the vmRun call becomes the
# function's stdin and is therefore forwarded to qvm-run inside. Callers
# that previously used `qvm-run -p VM "cat > file" <<EOF ... EOF` keep that
# pattern verbatim via vmRun.
#
# Exit-code propagation requires `set -o pipefail` in the caller -- the
# installQube subshell sets it. Without pipefail, a non-zero qvm-run is
# masked by tr/sed's success and the build silently continues on broken state.
function vmRun() {
	qvm-run "$@" 2>&1 \
		| LC_ALL=C tr -d '\000-\010\013-\037\177' \
		| iconv -f UTF-8 -t UTF-8 -c \
		| LC_ALL=C sed -E $'s/\xc2[\x80-\x9f]//g'
}

# fetchFromVM SOURCE_VM FILE [EXE]
function fetchFromVm() {
	if [ $# -lt 2 ]; then
		echo "Expected at least two parameters: fetchFromVm SOURCE_VM FILE [EXE]"
		return 1
	fi
	SOURCE_VM="${1}"
	FILE="${2}"
	EXE="${3}"

	# Defense-in-depth: both args are interpolated unquoted into the remote
	# shell command below. Callers also validate upstream; this is the
	# primitive's own boundary check so a future caller cannot bypass it.
	if ! [[ "${SOURCE_VM}" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]; then
		echo "ERROR: refusing unsafe SOURCE_VM '${SOURCE_VM}' in fetchFromVm" >&2
		return 1
	fi
	# Pin FILE strictly under /home/user/SEQS/ -- every legitimate caller
	# (fetchRunClean, braveExtensionInstall) only ever passes paths under
	# COMPONENT_PATH or LIB_PATH, both of which live there. An earlier
	# regex allowed any absolute path; tightening here means a future
	# caller that interpolates user input cannot turn this primitive into
	# an arbitrary-file-read against REPO_VM (which can hold secrets in
	# the qube user's home unrelated to SEQS).
	if ! [[ "${FILE}" =~ ^/home/user/SEQS/[A-Za-z0-9._/-]+$ ]] || [[ "${FILE}" == *..* ]]; then
		echo "ERROR: refusing unsafe FILE '${FILE}' in fetchFromVm (must be under /home/user/SEQS/)" >&2
		return 1
	fi

	echo "Fetching ${FILE} from VM ${SOURCE_VM}..."

	BASE=$(basename "${FILE}")

	# Write to a temp file first so a partial or failed cat-hack transfer
	# is never left under the final name. mv on success; rm on failure.
	# mktemp gives a unique fresh path so no stale-file pre-cleanup is
	# needed (the previous "rm $BASE 2>>/dev/null" pattern had an unquoted
	# expansion and an append-redirect typo).
	TMP=$(mktemp "./.${BASE}.XXXXXX") || return 1
	if qvm-run -p "${SOURCE_VM}" cat "${FILE}" > "${TMP}"; then
		# make the file executable if EXE parameter is passed along
		if [ -n "${EXE}" ] && [[ "${EXE}" == "EXE" ]]; then
			chmod +x "${TMP}"
		fi
		mv -f "${TMP}" "${BASE}"
	else
		rm -f "${TMP}"
		return 1
	fi
}

# fetchRunClean VMNAME APP FILE_PATH FILENAME [DESKTOP_NAME]
# Fetches FILENAME from ${REPO_VM}:${FILE_PATH}, plus LIB_FILES alongside, plus
# any per-component asset files (anything in ${FILE_PATH} other than
# template-vm.sh, app-vm.sh and menu.desktop), and (when DESKTOP_NAME is given
# AND ${FILE_PATH}menu.desktop exists) that too. Moves them all into VMNAME in
# one batch, runs FILENAME (which can reference assets via $(dirname "$0")),
# installs the menu.desktop as /usr/share/applications/${DESKTOP_NAME}.desktop,
# then cleans QubesIncoming once. Returns 0 also when FILENAME does not exist
# for this component (template-vm.sh / app-vm.sh are both optional) -- a real
# failure inside the success branch propagates through `set -e` in the caller.
function fetchRunClean() {
	VMNAME="${1}"
	APP="${2}"
	FILE_PATH="${3}"
	FILENAME="${4}"
	local DESKTOP_NAME="${5:-}"

	if fetchFromVm ${REPO_VM} ${FILE_PATH}${FILENAME} EXE; then
		# Enumerate the component directory once. The listing drives BOTH:
		#   * whether to attempt a menu.desktop fetch (skipping the fetch
		#     when none exists avoids a noisy `cat: ... No such file` from
		#     the VM that looks like a real install error in the log);
		#   * which per-component asset files to ship.
		local raw_assets=""
		raw_assets=$(qvm-run -p ${REPO_VM} "ls ${FILE_PATH} 2>/dev/null" 2>/dev/null) || raw_assets=""

		# fetch shared helper libraries so the install script can source them
		local lib libs=""
		for lib in ${LIB_FILES}; do
			if fetchFromVm ${REPO_VM} ${LIB_PATH}${lib}; then
				libs="${libs} ${lib}"
			fi
		done

		# optionally fetch a per-component menu.desktop in the same batch.
		# Only attempt the fetch if the directory listing shows it -- the
		# previous unconditional fetch printed `cat: ... menu.desktop:
		# No such file or directory` to stderr for every component that
		# carries no menu (most of them) and was easy to mistake for a
		# real install failure.
		local has_desktop=0
		if [ -n "${DESKTOP_NAME}" ] && grep -qFx 'menu.desktop' <<< "${raw_assets}"; then
			if fetchFromVm ${REPO_VM} "${FILE_PATH}menu.desktop"; then
				has_desktop=1
			else
				rm -f menu.desktop
			fi
		fi

		# Fetch per-component assets: any file in the component directory other
		# than the canonical scripts and menu.desktop handled above. Names are
		# validated against the same safe pattern used elsewhere so a hostile
		# REPO_VM cannot return a filename containing shell metacharacters that
		# would then be interpolated into a remote qvm-run command.
		local assets="" asset
		if [ -n "${raw_assets}" ]; then
			while IFS= read -r asset; do
				[ -z "${asset}" ] && continue
				case "${asset}" in
					template-vm.sh|app-vm.sh|menu.desktop) continue ;;
				esac
				if ! [[ "${asset}" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]; then
					echo "ERROR: refusing unsafe asset filename from ${REPO_VM}: '${asset}'" >&2
					exit 1
				fi
				if fetchFromVm ${REPO_VM} "${FILE_PATH}${asset}"; then
					assets="${assets} ${asset}"
				fi
			done <<< "${raw_assets}"
		fi

		local move_files="${FILENAME}${libs}${assets}"
		[ "${has_desktop}" -eq 1 ] && move_files="${move_files} menu.desktop"

		echo "Moving ${APP} install files to VM ${VMNAME}..."
		qvm-move-to-vm ${VMNAME} ${move_files}

		echo "Running ${APP} installer on VM ${VMNAME}..."
		vmRun -p ${VMNAME} ./QubesIncoming/dom0/${FILENAME}

		if [ "${has_desktop}" -eq 1 ]; then
			echo "Installing ${DESKTOP_NAME}.desktop launcher..."
			vmRun -p ${VMNAME} "sudo mv /home/user/QubesIncoming/dom0/menu.desktop /usr/share/applications/${DESKTOP_NAME}.desktop"
		fi

		echo "Cleaning up ${APP} install files on VM ${VMNAME}..."
		vmRun -p ${VMNAME} rm ./QubesIncoming -rf
	else
		echo "Looks like there is no ${FILENAME} script for ${VMNAME}. You do you. ¯\\_ (ツ)_/¯"
		# template-vm.sh / app-vm.sh are both optional per component, so a
		# missing FILENAME is a no-op, not an error -- return 0 so the
		# caller's `set -e` rollback isn't tripped. Use -f because the
		# fetch may not have written anything to dom0.
		rm -f "${FILENAME}"
		return 0
	fi
}

# confirmPolicyOverwrite POLICY_PATH NEW_RULE_PREVIEW EXTRA_RATIONALE
# Single source of truth for "we are about to clobber a qrexec policy file"
# warnings. Both setupBrowserPolicy and setupUsbKeyboardPolicy go through
# this helper so the two paths cannot drift apart -- adding a confirmation
# prompt in one and forgetting it in the other has happened in the past.
#
# Behaviour:
#   * if POLICY_PATH does not exist, returns 0 silently (fresh install --
#     no clobber, no prompt);
#   * if it exists, prints a banner with the path, the new rule that will
#     replace it, the EXTRA_RATIONALE line, and a dump of the current
#     contents, then BLOCKS on `read` for the operator to type OVERWRITE.
#     Any other input (including EOF / empty / Ctrl-D) aborts the whole
#     setup with exit 1 BEFORE any policy write or any qube is built.
#
# The exit-on-non-confirm is deliberately strict: these policies sit in
# dom0 and changes to them are isolation-affecting, so a slipped Enter or
# a stdin-less invocation must not silently overwrite. To bypass in a
# scripted context, delete the policy file first.
function confirmPolicyOverwrite() {
	local policy="${1}"
	local new_rule_preview="${2}"
	local extra_rationale="${3:-}"
	[ -e "${policy}" ] || return 0

	# _boxedLine TEXT -- emit TEXT inside the 80-char "##   …   ##" frame,
	# wrapping at word boundaries to fit the 70-char content area
	# (80 - 5 left padding "##   " - 5 right padding "   ##" = 70).
	# Each emitted line is exactly 80 chars. Word-unbreakable input >70 chars
	# still overflows; pass prose, not URLs / long single tokens.
	_boxedLine() {
		local text="${1}"
		while IFS= read -r line; do
			printf '##   %-70s   ##\n' "${line}" >&2
		done < <(printf '%s\n' "${text}" | fold -s -w 70)
	}

	cat >&2 <<EOF


################################################################################
################################################################################
##                                                                            ##
##   !!!  WARNING  !!!  WARNING  !!!  WARNING  !!!  WARNING  !!!              ##
##                                                                            ##
EOF
	_boxedLine "${policy}"
	_boxedLine "ALREADY EXISTS and is about to be OVERWRITTEN."
	cat >&2 <<EOF
##                                                                            ##
##   Any custom rules in this file -- yours or another tool's -- will be      ##
##   LOST. No backup is taken.                                                ##
EOF
	if [ -n "${extra_rationale}" ]; then
		# Each rationale paragraph is one logical line on input but may be
		# arbitrarily long; _boxedLine wraps it into the frame.
		echo "##                                                                            ##" >&2
		while IFS= read -r para; do
			_boxedLine "${para}"
		done <<< "${extra_rationale}"
	fi
	cat >&2 <<EOF
##                                                                            ##
##   New rule will be:                                                        ##
EOF
	_boxedLine "    ${new_rule_preview}"
	cat >&2 <<EOF
##                                                                            ##
##   Current contents:                                                        ##
##   ------------------------------------------------------------------       ##
EOF
	# Frame each line of the live policy file the same way as the rationale,
	# so long policy lines don't break the box either.
	while IFS= read -r line || [ -n "${line}" ]; do
		_boxedLine "${line}"
	done < "${policy}"
	cat >&2 <<EOF
##   ------------------------------------------------------------------       ##
##                                                                            ##
################################################################################
################################################################################


EOF

	local confirm
	# Read explicit confirmation from /dev/tty so that a piped or empty
	# stdin (e.g. invocation from a wrapper, CI, or someone hitting <Enter>
	# on a stale terminal) cannot be misread as approval. Anything but the
	# literal string "OVERWRITE" -- including EOF -- aborts.
	if ! read -rp "Overwrite ${policy}? type OVERWRITE to confirm (anything else aborts): " confirm </dev/tty; then
		echo "ERROR: no terminal available to confirm overwrite of ${policy} -- aborting." >&2
		exit 1
	fi
	if [ "${confirm}" != "OVERWRITE" ]; then
		echo "ERROR: overwrite of ${policy} not confirmed -- aborting before any qube is built." >&2
		exit 1
	fi
}

# installRootFile DEST CONTENT
# Atomically install a file with root:root, mode 0644, at DEST, with body
# CONTENT (a string). Uses sudo install via a user-side mktemp so failures
# abort with exit 1 instead of silently producing an empty file or one with
# the wrong owner / mode.
#
# Why this exists: the top-level orchestrator does NOT enable `set -e` or
# `set -o pipefail` (the absence is intentional for the qube-spec loops --
# one failed qube must not abort all). But the previous policy-installer
# pattern was `echo X | sudo tee FILE > /dev/null` followed by separate
# `sudo chmod` and `sudo chown` calls. Without pipefail, a non-zero `sudo`
# in the pipe is masked by `tee`'s success and the script proceeds to
# build qubes that depend on the policy. Without `set -e`, a failed
# chmod / chown leaves the file with surprising ownership or mode.
# `sudo install` does the write + chown + chmod atomically and we check
# its exit explicitly.
function installRootFile() {
	local dest="$1"
	local content="$2"
	local tmp
	if ! tmp=$(mktemp); then
		echo "ERROR: mktemp failed while preparing ${dest} -- aborting." >&2
		exit 1
	fi
	if ! printf '%s' "${content}" > "${tmp}"; then
		rm -f "${tmp}"
		echo "ERROR: writing temp content for ${dest} failed -- aborting." >&2
		exit 1
	fi
	if ! sudo install -m 0644 -o root -g root "${tmp}" "${dest}"; then
		rm -f "${tmp}"
		echo "ERROR: sudo install of ${dest} failed -- aborting before any qube is built." >&2
		exit 1
	fi
	rm -f "${tmp}"
}

# create the dom0 qrexec policy so any qube may open links in the browser qube
function setupBrowserPolicy() {
	local policy="/etc/qubes/policy.d/29-browser.policy"
	local rule="qubes.OpenURL * @anyvm ${BROWSER_VM} allow"

	confirmPolicyOverwrite "${policy}" "${rule}" \
		"This policy concentrates link-handoff into ${BROWSER_VM}. A hand-edited rule (e.g. 'ask' instead of 'allow', or a per-qube exception) getting overwritten silently is a real isolation downgrade."

	echo "allowing all qubes to open links in ${BROWSER_VM}..."
	installRootFile "${policy}" "${rule}"$'\n'
}

# On Qubes 4.3 the shipped /etc/qubes/policy.d/50-config-input.policy silently
# DENIES qubes.InputKeyboard from sys-usb to dom0 (mouse/tablet ask; keyboard
# does not). External USB keyboards therefore don't work out of the box.
#
# We install a higher-precedence override at 30-user-input.policy that brings
# keyboard in line with mouse/tablet: prompt on every connect, dom0 pre-selected.
# Editing the shipped 50- file directly would be clobbered by qubes-core-dom0
# package updates; the 30- prefix wins by file evaluation order.
#
# Idempotent: re-running setup-qubes.sh re-writes the file with identical
# content. Skipped on releases other than 4.3 and when sys-usb is absent.
function setupUsbKeyboardPolicy() {
	local release
	release=$(grep -oE '[0-9]+\.[0-9]+' /etc/qubes-release 2>/dev/null | head -1)
	if [ "${release}" != "4.3" ]; then
		echo "Qubes ${release:-unknown} -- skipping USB keyboard policy override (only needed on 4.3)."
		return 0
	fi
	if ! qvm-check sys-usb &>/dev/null; then
		echo "sys-usb not found -- skipping USB keyboard policy override."
		return 0
	fi

	local policy="/etc/qubes/policy.d/30-user-input.policy"
	local rule="qubes.InputKeyboard  *  sys-usb  @adminvm  ask default_target=@adminvm"

	# Share the warn+confirm+abort path with setupBrowserPolicy via the
	# common helper so the two cannot drift -- one with a confirmation
	# gate and one without is exactly the failure mode (7) flagged. The
	# USB-keyboard policy controls qubes.InputKeyboard attach from
	# sys-usb to dom0; overwriting a hand-tightened version of THIS rule
	# is a worse isolation downgrade than the browser policy, not better.
	confirmPolicyOverwrite "${policy}" "${rule}" \
		"This file controls qubes.InputKeyboard attach from sys-usb to dom0. A hand-tightened rule (e.g. pinned to a single trusted keyboard qube, or denied outright) getting overwritten silently is a worse isolation downgrade than the browser policy."

	echo "installing ${policy} so USB keyboards prompt before attaching to dom0..."
	local content
	content=$(cat <<'EOF'
# SEQS override: prompt before attaching a USB keyboard from sys-usb to dom0.
# Lower numeric prefix (30-) wins over the shipped 50-config-input.policy,
# which silently denies qubes.InputKeyboard on Qubes 4.3. Managed by
# setup-qubes.sh; re-running the setup re-writes this file.
qubes.InputKeyboard  *  sys-usb  @adminvm  ask default_target=@adminvm
EOF
)
	# Atomic install with root:root mode 0644. The previous 3-step pattern
	# (sudo tee -> sudo chmod -> sudo chown) could leave the file with
	# wrong owner / mode if any of the three sudo calls failed silently
	# under the top-level no-set-e/no-pipefail orchestrator -- a writable
	# /etc/qubes/policy.d/30-user-input.policy is a real isolation
	# downgrade since the dom0 user could then rewrite the keyboard
	# policy and 30- outranks 50-config-input.policy.
	installRootFile "${policy}" "${content}"$'\n'
}

# setBrowserQube APP_VM -- make APP_VM open all web links in ${BROWSER_VM}
function setBrowserQube() {
	local APP_VM="${1}"

	echo "configuring ${APP_VM} to open links in ${BROWSER_VM}..."

	# Install the link-handoff handler to /usr/share/applications/ as root,
	# mode 0644. Putting it in the user's ~/.local/share/applications/
	# (the previous location) let anything running as 'user' rewrite the
	# Exec= line to divert links to a different qube or a local sniffer.
	# Now the file is root-owned and read-only for the qube user; xdg can
	# still resolve it (the system dir is on XDG_DATA_DIRS) but the user
	# cannot modify it. This matches where the rest of SEQS installs
	# per-component menu launchers (see fetchRunClean's desktop install).
	# MimeType: ONLY http/https are forwarded to the browser qube. An earlier
	# version registered x-scheme-handler/unknown -- which is xdg's catch-all
	# for any URL scheme the system does not explicitly know -- so any
	# application in any non-browser qube that called xdg-open with a URL
	# using an unrecognized scheme (data:, javascript:, vbscript:, file:,
	# attacker-chosen custom schemes used by hostile installers / phishing
	# payloads) would be silently ferried into A-brave's URL bar via the
	# `allow` qrexec policy. The link-handoff that justifies the qrexec
	# policy is web links specifically; widening to "every unknown scheme"
	# gave any qube a silent channel for crafted URLs at A-brave from any
	# code that uses xdg-open.
	vmRun -u root -p ${APP_VM} "cat > /usr/share/applications/${BROWSER_DESKTOP} && chown root:root /usr/share/applications/${BROWSER_DESKTOP} && chmod 0644 /usr/share/applications/${BROWSER_DESKTOP}" <<EOF
[Desktop Entry]
Encoding=UTF-8
Name=Open links in ${BROWSER_VM}
Exec=qvm-open-in-vm ${BROWSER_VM} %u
Terminal=false
X-MultipleArgs=false
Type=Application
Categories=Network;WebBrowser;
MimeType=x-scheme-handler/http;x-scheme-handler/https;
EOF

	vmRun -p ${APP_VM} "xdg-settings set default-web-browser ${BROWSER_DESKTOP}"
}

# requireOsTemplate -- abort early if the base template to clone is missing
function requireOsTemplate() {
	if ! qvm-check "${OS_TEMPLATE_VM}" &>/dev/null; then
		echo "ERROR: base template '${OS_TEMPLATE_VM}' does not exist." >&2
		echo "Install it in dom0 first, e.g.:" >&2
		echo "  sudo qubes-dom0-update qubes-template-${OS_TEMPLATE_VM}" >&2
		echo "or set OS_TEMPLATE_VM at the top of this script to a template you have." >&2
		exit 1
	fi
	echo "Base template '${OS_TEMPLATE_VM}' found."
}

# requireRepoVm -- abort early if the qube holding the SEQS repo is missing
function requireRepoVm() {
	if ! qvm-check "${REPO_VM}" &>/dev/null; then
		echo "ERROR: source qube '${REPO_VM}' does not exist." >&2
		echo "This is the qube that should hold the SEQS repo and install scripts." >&2
		echo "Set REPO_VM at the top of this script to the qube where you cloned it." >&2
		exit 1
	fi
	echo "Source qube '${REPO_VM}' found."
}

# discoverLibFiles -- enumerate *.sh under LIB_PATH inside REPO_VM and store
# the space-separated basenames in the global LIB_FILES. Called once after
# requireRepoVm so fetchRunClean can ship every helper alongside each install.
# Each basename is validated against a strict pattern before being accepted:
# basenames are later interpolated into qvm-run command strings (via
# fetchFromVm), so a hostile or broken REPO_VM returning a basename with shell
# metacharacters could otherwise inject commands into the remote shell.
function discoverLibFiles() {
	local listing
	if ! listing=$(qvm-run -p ${REPO_VM} "ls ${LIB_PATH}*.sh 2>/dev/null | xargs -n1 basename" 2>/dev/null); then
		echo "WARNING: could not enumerate ${LIB_PATH} on ${REPO_VM}; no helper libs will ship." >&2
		LIB_FILES=""
		return
	fi
	local lib
	LIB_FILES=""
	while IFS= read -r lib; do
		[ -z "${lib}" ] && continue
		if ! [[ "${lib}" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*\.sh$ ]]; then
			echo "ERROR: refusing unsafe helper-library basename from ${REPO_VM}: '${lib}'" >&2
			exit 1
		fi
		LIB_FILES="${LIB_FILES}${lib} "
	done <<< "${listing}"
	echo "Helper libraries discovered: ${LIB_FILES:-<none>}"
}

# validateAllQubes -- pre-flight check across SINGLE_QUBES, WALLET_QUBES,
# DEV_QUBES. Verifies every referenced component exists (under
# install-scripts/components/ or in the BRAVE_EXTENSIONS array), no two configured
# qubes share a NAME, and no target qube (Z-NAME / A-NAME) is already taken.
# Aborts before any qube is built if anything looks wrong.
function validateAllQubes() {
	echo "validating all qube specs..."

	# Components available in REPO_VM. Each directory name is validated against
	# a strict pattern before being accepted -- the names are later interpolated
	# into qvm-run command strings (e.g. the desktop filename moved into
	# /usr/share/applications/ by fetchRunClean), so a hostile or broken REPO_VM
	# returning a directory name with shell metacharacters could otherwise
	# inject commands into the remote shell as root.
	local raw_components available_components=" " cname
	if ! raw_components=$(qvm-run -p ${REPO_VM} "ls /home/user/SEQS/install-scripts/components/" 2>/dev/null); then
		echo "ERROR: could not enumerate components from ${REPO_VM}." >&2
		exit 1
	fi
	while IFS= read -r cname; do
		[ -z "${cname}" ] && continue
		if ! [[ "${cname}" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]; then
			echo "ERROR: refusing unsafe component name from ${REPO_VM}: '${cname}'" >&2
			exit 1
		fi
		available_components+="${cname} "
	done <<< "${raw_components}"

	# Brave extension names + IDs from BRAVE_EXTENSIONS. Both are validated:
	# names get interpolated into shell commands; IDs are interpolated into the
	# single-quoted Chrome Web Store ID arg of install_brave_extension and must
	# match the published 32-char a-p format exactly so a stray quote cannot
	# break out of the single-quoted string.
	local available_extensions=" " entry ename eid
	for entry in "${BRAVE_EXTENSIONS[@]}"; do
		ename="${entry%% *}"
		eid="${entry##* }"
		if ! [[ "${ename}" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]; then
			echo "ERROR: BRAVE_EXTENSIONS contains unsafe name '${ename}'." >&2
			exit 1
		fi
		if ! [[ "${eid}" =~ ^[a-p]{32}$ ]]; then
			echo "ERROR: BRAVE_EXTENSIONS entry '${ename}' has invalid Chrome Web Store ID '${eid}' (expected 32 chars a-p)." >&2
			exit 1
		fi
		available_extensions+="${ename} "
	done

	local errors=0
	local seen_names=" " spec NAME

	# iterate every configured qube
	for spec in "${SINGLE_QUBES[@]}" "${WALLET_QUBES[@]}" "${DEV_QUBES[@]}"; do
		local args=(${spec})
		NAME="${args[0]}"
		local n=${#args[@]}
		# strip trailing 'offline'
		if [ "${args[$((n-1))]}" = "offline" ]; then
			n=$((n-1))
		fi

		# duplicate name within this run?
		if [[ "${seen_names}" == *" ${NAME} "* ]]; then
			echo "ERROR: duplicate qube name '${NAME}' in the configured specs." >&2
			errors=$((errors+1))
		fi
		seen_names+="${NAME} "

		# template/app qube already exist?
		if qvm-check "${PREFIX_TEMPLATE_VM}${NAME}" &>/dev/null; then
			echo "ERROR: template '${PREFIX_TEMPLATE_VM}${NAME}' already exists -- refusing to clobber it." >&2
			errors=$((errors+1))
		fi
		if qvm-check "${PREFIX_APP_VM}${NAME}" &>/dev/null; then
			echo "ERROR: app qube '${PREFIX_APP_VM}${NAME}' already exists -- refusing to clobber it." >&2
			errors=$((errors+1))
		fi

		# components valid?
		local i comp ext_name
		for (( i=2; i<n; i++ )); do
			comp="${args[i]}"
			# Each component name is later interpolated into remote shell
			# commands (path + desktop filename), so require a safe identifier
			# up-front before any further check. brave-extension-<name> follows
			# the same rule -- the full token must be safe.
			if ! [[ "${comp}" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]; then
				echo "ERROR: qube '${NAME}' references component with unsafe name '${comp}'." >&2
				errors=$((errors+1))
				continue
			fi
			case "${comp}" in
				brave-extension-*)
					ext_name="${comp#brave-extension-}"
					if [[ "${available_extensions}" != *" ${ext_name} "* ]]; then
						echo "ERROR: qube '${NAME}' references unknown Brave extension '${ext_name}' (not in BRAVE_EXTENSIONS)." >&2
						errors=$((errors+1))
					fi
					;;
				*)
					if [[ "${available_components}" != *" ${comp} "* ]]; then
						echo "ERROR: qube '${NAME}' references unknown component '${comp}' (no install-scripts/components/${comp}/)." >&2
						errors=$((errors+1))
					fi
					;;
			esac
		done
	done

	if [ "${errors}" -gt 0 ]; then
		echo "Validation failed with ${errors} error(s). Aborting before any qube is built." >&2
		exit 1
	fi
	echo "All qube specs valid."
}

# validateCleanupDirs -- refuse to proceed if any CLEANUP_DIRS entry would
# wipe a path the operator almost certainly did not mean. The generated
# seqs-cleanup script runs `rm -rf` as root on every app-qube boot AND
# shutdown, so a typo here is destructive on a recurring schedule.
#
# Rule: every entry must be an absolute path strictly under /home/user/ with
# at least one extra non-empty segment, and may not contain a '..' component.
# This bounds the blast radius to the qube's user home and refuses obvious
# footguns like "/home/user", "/etc", "/" or "/home/user/../etc".
function validateCleanupDirs() {
	local d errors=0
	for d in "${CLEANUP_DIRS[@]}"; do
		[ -z "${d}" ] && continue
		# Must begin with /home/user/ and have a non-empty segment after it;
		# the [^/] guards against a trailing-slash-only entry like "/home/user/".
		if ! [[ "${d}" =~ ^/home/user/[^/].* ]]; then
			echo "ERROR: CLEANUP_DIRS entry '${d}' is not strictly under /home/user/." >&2
			errors=$((errors+1))
			continue
		fi
		# Reject any '..' segment so paths like /home/user/../etc cannot
		# escape the bound check above.
		if [[ "${d}" == *..* ]]; then
			echo "ERROR: CLEANUP_DIRS entry '${d}' contains '..'; refusing." >&2
			errors=$((errors+1))
		fi
	done
	if [ "${errors}" -gt 0 ]; then
		echo "Refusing to install the boot/shutdown cleanup service with unsafe" >&2
		echo "CLEANUP_DIRS entries. Each entry must be an absolute path strictly" >&2
		echo "under /home/user/ with at least one extra path segment and no '..'." >&2
		exit 1
	fi
}

# installCleanupService TEMPLATE_VM -- install a systemd service into the
# template so every app qube based on it deletes the configured directories
# on boot and on shutdown. The service is a no-op inside TemplateVMs.
function installCleanupService() {
	local TEMPLATE_VM="${1}"

	# build a shell-quoted, space-separated directory list from the config.
	# printf %q escapes $, `, \, ", spaces, quotes etc. so the generated
	# seqs-cleanup script can't be hijacked by a path containing shell
	# metacharacters (CLEANUP_DIRS is dom0-side config, so the worst case
	# is self-inflicted, but the cleanup runs as root and is worth quoting
	# robustly).
	local dirs="" d esc
	for d in "${CLEANUP_DIRS[@]}"; do
		[ -n "${d}" ] || continue
		printf -v esc '%q' "${d}"
		dirs="${dirs} ${esc}"
	done
	if [ -z "${dirs}" ]; then
		echo "no cleanup directories configured -- skipping ${TEMPLATE_VM}"
		return 0
	fi

	echo "installing boot/shutdown cleanup service in ${TEMPLATE_VM}..."

	# cleanup script -- fail CLOSED, not open: only delete when the VM is
	# explicitly known to be an AppVM or DispVM. The previous shape was
	#     [ "\$(qubesdb-read ...)" = "TemplateVM" ] && exit 0
	# which fails OPEN -- if qubesdb-read errored or returned empty for
	# any reason (binary missing, qubesdb socket unavailable, perm change,
	# package removal during an upgrade window) the test would not match
	# "TemplateVM" and the cleanup would proceed *inside the template*,
	# wiping the template's persistent /home/user/Downloads (and
	# QubesIncoming, and anything else in CLEANUP_DIRS), which then
	# propagates to every downstream app qube. Now: any qubesdb-read
	# failure or any value other than the explicit AppVM/DispVM set is
	# treated as "do nothing".
	vmRun -u root -p ${TEMPLATE_VM} "cat > /usr/local/bin/seqs-cleanup && chmod 0755 /usr/local/bin/seqs-cleanup" <<EOF
#!/bin/sh
# SEQS: delete transient directories on app-qube boot and shutdown.
# Generated by setup-qubes.sh -- edit the SEQS repo, not this copy.
vmtype="\$(qubesdb-read /qubes-vm-type 2>/dev/null)" || exit 0
case "\$vmtype" in
	AppVM|DispVM) ;;   # proceed
	*) exit 0 ;;       # template, standalone, unknown, or read failure: do nothing
esac
for d in ${dirs}; do
	rm -rf -- "\$d"
done
exit 0
EOF

	# systemd oneshot: ExecStart runs on boot, ExecStop runs on shutdown
	vmRun -u root -p ${TEMPLATE_VM} "cat > /etc/systemd/system/seqs-cleanup.service" <<'EOF'
[Unit]
Description=SEQS delete transient directories on boot and shutdown
RequiresMountsFor=/home

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/seqs-cleanup
ExecStop=/usr/local/bin/seqs-cleanup

[Install]
WantedBy=multi-user.target
EOF

	vmRun -u root -p ${TEMPLATE_VM} "systemctl enable seqs-cleanup.service"
}

# braveExtensionInstall VM EXT_NAME -- install one Brave extension into VM.
# Looks up the Chrome Web Store ID in the BRAVE_EXTENSIONS array, ensures Brave
# is installed (idempotent), then force-installs the extension. Used by
# installQube to dispatch the synthetic 'brave-extension-<name>' component
# namespace -- no per-extension component directory is needed.
function braveExtensionInstall() {
	local VM="${1}"
	local EXT_NAME="${2}"
	local id="" entry name
	for entry in "${BRAVE_EXTENSIONS[@]}"; do
		name="${entry%% *}"
		if [ "${name}" = "${EXT_NAME}" ]; then
			id="${entry##* }"
			break
		fi
	done
	if [ -z "${id}" ]; then
		echo "ERROR: unknown Brave extension '${EXT_NAME}' -- not in BRAVE_EXTENSIONS." >&2
		return 1
	fi
	echo "installing Brave extension '${EXT_NAME}' (${id}) into ${VM}..."
	if ! fetchFromVm ${REPO_VM} "${LIB_PATH}brave.sh"; then
		echo "ERROR: failed to fetch lib/brave.sh from ${REPO_VM}" >&2
		return 1
	fi
	qvm-move-to-vm "${VM}" brave.sh
	vmRun -p "${VM}" ". ./QubesIncoming/dom0/brave.sh && ensure_brave && install_brave_extension '${id}'"
	vmRun -p "${VM}" "rm ./QubesIncoming -rf"
}

# installQube NAME COLOR component [component ...] [offline]
# Builds a Z-NAME template + A-NAME app qube composed of the named components
# (install-scripts/components/<component>/). Each component may provide:
#   * template-vm.sh -- system-wide install in the template (skipped if absent)
#   * app-vm.sh      -- per-app-qube setup        (skipped if absent)
#   * menu.desktop   -- launcher installed into /usr/share/applications/<comp>.desktop
# The synthetic 'brave-extension-<name>' component namespace is dispatched via
# braveExtensionInstall (looked up in BRAVE_EXTENSIONS) -- no per-extension
# component directory is needed; Brave is auto-installed on first call.
# Trailing 'offline' flag detaches the app qube from netvm (e.g. for keepass).
function installQube() {
	if [ $# -lt 3 ]; then
		echo "Expected: installQube NAME COLOR component [component ...] [offline]"
		return 1
	fi

	local NAME="${1}"
	local COLOR="${2}"
	shift 2

	# detect trailing 'offline' flag and strip it from the component list
	local OFFLINE=""
	local args=("$@")
	local n=${#args[@]}
	if [ "${n}" -gt 0 ] && [ "${args[$((n-1))]}" = "offline" ]; then
		OFFLINE="offline"
		unset 'args[n-1]'
	fi
	local COMPONENTS="${args[*]}"

	local APP_VM="${PREFIX_APP_VM}${NAME}"
	local TEMPLATE_VM="${PREFIX_TEMPLATE_VM}${NAME}"
	local COMPONENT_PATH="/home/user/SEQS/install-scripts/components/"
	local comp

	echo "STARTING BUILD OF ${NAME} from components: ${COMPONENTS}"

	# Run the build in a backgrounded subshell with `set -e` so any failure
	# (qvm-clone, qvm-create, qvm-start, a component installer inside
	# qvm-run via fetchRunClean, etc.) aborts at the failure point instead
	# of silently rolling into the next step on broken state. A watchdog
	# bounds the build at BUILD_TIMEOUT_SECONDS; on either failure or
	# timeout, the rollback below removes whichever of the Z-/A- pair got
	# created -- otherwise a re-run is blocked by validateAllQubes refusing
	# to clobber. The watchdog kills the subshell only; any qvm-run still
	# pending on dom0 lingers briefly until the rollback's qvm-kill closes
	# its qrexec connection.
	local start_seconds=$SECONDS

	(
		# pipefail so that the vmRun `qvm-run ... | tr -d ...` sanitizer
		# pipeline cannot mask a non-zero qvm-run exit (cat/tr always
		# succeed). Without it, a failed VM-side step would be silently
		# overwritten by the sanitizer's success and the build would
		# carry on against broken state.
		set -eo pipefail

		echo "setting up template VM ${TEMPLATE_VM}..."
		qvm-clone ${OS_TEMPLATE_VM} ${TEMPLATE_VM}

		# template phase
		for comp in ${COMPONENTS}; do
			case "${comp}" in
				brave-extension-*)
					braveExtensionInstall "${TEMPLATE_VM}" "${comp#brave-extension-}"
					;;
				*)
					echo "installing component '${comp}' into ${TEMPLATE_VM}..."
					# fetchRunClean handles an optional menu.desktop in the same fetch/move/run/clean cycle
					fetchRunClean ${TEMPLATE_VM} "${comp}" "${COMPONENT_PATH}${comp}/" template-vm.sh "${comp}"
					;;
			esac
		done

		installCleanupService ${TEMPLATE_VM}

		echo "shutting down template VM..."
		# --wait blocks until the template is actually stopped (bounded by
		# the qube's shutdown_timeout, default 60 s). Replaces a fixed
		# `sleep 4` that was a guess and raced under load.
		qvm-shutdown --wait ${TEMPLATE_VM}

		echo "creating app VM ${APP_VM}..."
		qvm-create ${APP_VM} --template ${TEMPLATE_VM} --label ${COLOR}
		if [ "${OFFLINE}" = "offline" ]; then
			echo "taking app VM offline..."
			sleep 2
			qvm-prefs ${APP_VM} netvm none
		fi

		echo "starting app VM..."
		qvm-start ${APP_VM}

		# app-VM phase
		for comp in ${COMPONENTS}; do
			case "${comp}" in
				brave-extension-*)
					: # brave-extension-* is template-only; no app-vm action
					;;
				*)
					echo "configuring component '${comp}' on ${APP_VM}..."
					fetchRunClean ${APP_VM} "${comp}" "${COMPONENT_PATH}${comp}/" app-vm.sh
					;;
			esac
		done

		# open web links in the browser qube (except for the browser qube itself)
		if [[ "${APP_VM}" != "${BROWSER_VM}" ]]; then
			setBrowserQube ${APP_VM}
		fi

		echo "shutting app VM down..."
		qvm-shutdown ${APP_VM}
	) &
	local build_pid=$!

	# Watchdog: TERM after the timeout, KILL 5s later as a backstop.
	(
		sleep "${BUILD_TIMEOUT_SECONDS}"
		kill -TERM "${build_pid}" 2>/dev/null
		sleep 5
		kill -KILL "${build_pid}" 2>/dev/null
	) &
	local killer_pid=$!

	# Wait for the build (or its killer) to finish.
	wait "${build_pid}" 2>/dev/null
	local build_exit=$?
	local elapsed=$(( SECONDS - start_seconds ))

	# Cancel the watchdog if the build finished on its own.
	kill "${killer_pid}" 2>/dev/null
	wait "${killer_pid}" 2>/dev/null

	if [ "${build_exit}" -eq 0 ]; then
		return 0
	fi

	# Build failed somewhere above (or the watchdog killed it). Diagnose by
	# elapsed wall time -- if we hit the budget, it was the watchdog.
	local why="failed (exit ${build_exit})"
	if [ "${elapsed}" -ge "${BUILD_TIMEOUT_SECONDS}" ]; then
		why="timed out after ${elapsed}s (limit: ${BUILD_TIMEOUT_SECONDS}s)"
	fi

	# Kill+remove whichever of the Z-/A- pair got created. Best-effort:
	# every step is `&>/dev/null || true` so the rollback never itself
	# fails the run (qubes that were never created are skipped silently).
	# Kill before remove so qvm-remove does not trip over a still-running
	# qube; wait up to 30s for shutdown.
	echo "ERROR: build of '${NAME}' ${why} -- rolling back ${TEMPLATE_VM} and ${APP_VM}..." >&2
	qvm-kill "${APP_VM}" &>/dev/null || true
	qvm-kill "${TEMPLATE_VM}" &>/dev/null || true
	local deadline=$(( SECONDS + 30 ))
	while [ "${SECONDS}" -lt "${deadline}" ]; do
		if ! qvm-check --running "${APP_VM}" &>/dev/null \
		    && ! qvm-check --running "${TEMPLATE_VM}" &>/dev/null; then
			break
		fi
		sleep 1
	done
	qvm-remove -f "${APP_VM}" &>/dev/null || true
	qvm-remove -f "${TEMPLATE_VM}" &>/dev/null || true

	# Timeout-only escalation: the watchdog killed the subshell but cannot
	# reach the dom0-side qvm-run processes it spawned, so a root-level
	# command that was mid-flight inside the qube (apt, dpkg, gpg, a cat>
	# into /etc/...) may have committed a partial change before being
	# interrupted. `qvm-remove -f` returning success is not proof that
	# dpkg locks, /var/lib/qubes state, LVM volume metadata, qrexec
	# connection slots and dom0 mount entries are all clean. The safe
	# response on a high-value box is to reboot dom0 before retrying.
	# Mirror this in TRUST.md whenever the wording here changes.
	if [ "${elapsed}" -ge "${BUILD_TIMEOUT_SECONDS}" ]; then
		cat >&2 <<'EOF'


################################################################################
################################################################################
##                                                                            ##
##   !!!  WARNING  !!!  WARNING  !!!  WARNING  !!!  WARNING  !!!  WARNING  !! ##
##                                                                            ##
##   A build hit the watchdog timeout. The watchdog killed the build          ##
##   subshell but CANNOT reach the dom0-side qvm-run processes it spawned.    ##
##   Any root-level command that was mid-flight inside the qube at that       ##
##   moment (apt-get / dpkg / gpg / cat > /etc/...) may have committed a      ##
##   PARTIAL CHANGE before being interrupted. qvm-remove -f succeeding is     ##
##   NOT proof that dpkg locks, /var/lib/qubes state, LVM volume metadata,    ##
##   qrexec slots and dom0 mount entries are clean.                           ##
##                                                                            ##
##   Re-running setup-qubes.sh against the same name now will proceed on      ##
##   top of that potentially-corrupted dom0 state. There is no logical        ##
##   interlock -- the 30s shutdown wait masks most cases, not all.            ##
##                                                                            ##
##                                                                            ##
##   >>>  REBOOT dom0 BEFORE RETRYING THIS QUBE.  <<<                         ##
##                                                                            ##
##                                                                            ##
##   After the reboot:                                                        ##
##     1. sudo qvm-volume info       (confirm no orphan volumes remain)       ##
##     2. ./delete-vms.sh <name>     (if the rollback left a stale name)      ##
##     3. then re-run setup-qubes.sh                                          ##
##                                                                            ##
##   This warning is also recorded in TRUST.md (setup-qubes.sh entry).        ##
##                                                                            ##
################################################################################
################################################################################


EOF
	fi

	return 1
}

cd ~

requireOsTemplate
requireRepoVm
discoverLibFiles
validateAllQubes
validateCleanupDirs

setupBrowserPolicy
setupUsbKeyboardPolicy

# Single-component qubes (one app per qube)
for spec in "${SINGLE_QUBES[@]}"; do
	installQube ${spec}
done

# Wallet qubes -- composed from the WALLET_QUBES list configured at the top
for spec in "${WALLET_QUBES[@]}"; do
	installQube ${spec}
done

# Developer qubes -- composed from the DEV_QUBES list configured at the top
for spec in "${DEV_QUBES[@]}"; do
	installQube ${spec}
done

# Uncomment to delete this setup file after a successful run.
#rm $0
