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
# Hardening -- transient-directory cleanup at app-qube boot and shutdown,
# via a systemd service installed into each template. Empty array disables.
# ════════════════════════════════════════════════════════════════════════════

CLEANUP_DIRS=(
	"/home/user/QubesIncoming"
	"/home/user/Downloads"
)

# ════════════════════════════════════════════════════════════════════════════
# Internal -- rarely edited.
# ════════════════════════════════════════════════════════════════════════════

# Every *.sh under LIB_PATH is auto-discovered (see discoverLibFiles) and
# shipped next to every install script inside the target VM, so install
# scripts can `source` them.
LIB_PATH="/home/user/SEQS/install-scripts/lib/"

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
	if ! [[ "${FILE}" =~ ^[A-Za-z0-9/][A-Za-z0-9._/-]*$ ]] || [[ "${FILE}" == *..* ]]; then
		echo "ERROR: refusing unsafe FILE '${FILE}' in fetchFromVm" >&2
		return 1
	fi

	echo "Fetching ${FILE} from VM ${SOURCE_VM}..."
	
	# delete file in case it already exists on dom0 and ignore errors
	BASE=$(basename "$FILE")
	rm $BASE 2>>/dev/null

	# fetch the file via the 'cat' hack to avoid dom0 security precautions 
	if qvm-run -p ${SOURCE_VM} cat ${FILE} > $BASE; then
		# make the file executable if EXE parameter is passed along
		if [ ! -z "${EXE}" ] && [[ ${EXE} == "EXE" ]]; then
			chmod +x $BASE
		fi
	else
		# bubble up errors
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
		# fetch shared helper libraries so the install script can source them
		local lib libs=""
		for lib in ${LIB_FILES}; do
			if fetchFromVm ${REPO_VM} ${LIB_PATH}${lib}; then
				libs="${libs} ${lib}"
			fi
		done

		# optionally fetch a per-component menu.desktop in the same batch
		local has_desktop=0
		if [ -n "${DESKTOP_NAME}" ]; then
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
		local assets="" asset raw_assets
		if raw_assets=$(qvm-run -p ${REPO_VM} "ls ${FILE_PATH} 2>/dev/null" 2>/dev/null); then
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
		qvm-run -p ${VMNAME} ./QubesIncoming/dom0/${FILENAME}

		if [ "${has_desktop}" -eq 1 ]; then
			echo "Installing ${DESKTOP_NAME}.desktop launcher..."
			qvm-run -p ${VMNAME} "sudo mv /home/user/QubesIncoming/dom0/menu.desktop /usr/share/applications/${DESKTOP_NAME}.desktop"
		fi

		echo "Cleaning up ${APP} install files on VM ${VMNAME}..."
		qvm-run -p ${VMNAME} rm ./QubesIncoming -rf
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

# create the dom0 qrexec policy so any qube may open links in the browser qube
function setupBrowserPolicy() {
	echo "allowing all qubes to open links in ${BROWSER_VM}..."
	echo "qubes.OpenURL * @anyvm ${BROWSER_VM} allow" \
		| sudo tee /etc/qubes/policy.d/29-browser.policy > /dev/null
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
	echo "installing /etc/qubes/policy.d/30-user-input.policy so USB keyboards prompt before attaching to dom0..."
	sudo tee /etc/qubes/policy.d/30-user-input.policy > /dev/null <<'EOF'
# SEQS override: prompt before attaching a USB keyboard from sys-usb to dom0.
# Lower numeric prefix (30-) wins over the shipped 50-config-input.policy,
# which silently denies qubes.InputKeyboard on Qubes 4.3. Managed by
# setup-qubes.sh; re-running the setup re-writes this file.
qubes.InputKeyboard  *  sys-usb  @adminvm  ask default_target=@adminvm
EOF
	sudo chmod 0644 /etc/qubes/policy.d/30-user-input.policy
	sudo chown root:root /etc/qubes/policy.d/30-user-input.policy
}

# setBrowserQube APP_VM -- make APP_VM open all web links in ${BROWSER_VM}
function setBrowserQube() {
	local APP_VM="${1}"

	echo "configuring ${APP_VM} to open links in ${BROWSER_VM}..."
	qvm-run -p ${APP_VM} "mkdir -p ~/.local/share/applications && cat > ~/.local/share/applications/${BROWSER_DESKTOP}" <<EOF
[Desktop Entry]
Encoding=UTF-8
Name=Open links in ${BROWSER_VM}
Exec=qvm-open-in-vm ${BROWSER_VM} %u
Terminal=false
X-MultipleArgs=false
Type=Application
Categories=Network;WebBrowser;
MimeType=x-scheme-handler/unknown;x-scheme-handler/about;text/html;text/xml;application/xhtml+xml;application/xml;application/vnd.mozilla.xul+xml;application/rss+xml;application/rdf+xml;image/gif;image/jpeg;image/png;x-scheme-handler/http;x-scheme-handler/https;
EOF

	qvm-run -p ${APP_VM} "xdg-settings set default-web-browser ${BROWSER_DESKTOP}"
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

	# cleanup script -- the qubes-vm-type guard makes it a no-op in templates
	qvm-run -u root -p ${TEMPLATE_VM} "cat > /usr/local/bin/seqs-cleanup && chmod 0755 /usr/local/bin/seqs-cleanup" <<EOF
#!/bin/sh
# SEQS: delete transient directories on app-qube boot and shutdown.
# Generated by setup-qubes.sh -- edit the SEQS repo, not this copy.
[ "\$(qubesdb-read /qubes-vm-type 2>/dev/null)" = "TemplateVM" ] && exit 0
for d in ${dirs}; do
	rm -rf -- "\$d"
done
exit 0
EOF

	# systemd oneshot: ExecStart runs on boot, ExecStop runs on shutdown
	qvm-run -u root -p ${TEMPLATE_VM} "cat > /etc/systemd/system/seqs-cleanup.service" <<'EOF'
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

	qvm-run -u root -p ${TEMPLATE_VM} "systemctl enable seqs-cleanup.service"
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
	qvm-run -p "${VM}" ". ./QubesIncoming/dom0/brave.sh && ensure_brave && install_brave_extension '${id}'"
	qvm-run -p "${VM}" "rm ./QubesIncoming -rf"
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

	# Run the build in a subshell with `set -e` so any failure (qvm-clone,
	# qvm-create, qvm-start, a component installer inside qvm-run via
	# fetchRunClean, etc.) aborts at the failure point instead of silently
	# rolling into the next step on broken state. On non-zero exit the
	# rollback below removes whichever of the Z-/A- pair got created --
	# otherwise a re-run is blocked by validateAllQubes refusing to clobber.
	if (
		set -e

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
		qvm-shutdown ${TEMPLATE_VM}
		sleep 4

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
	); then
		return 0
	fi

	# Build failed somewhere above. Kill+remove whichever of the Z-/A- pair
	# got created. Best-effort: every step is `&>/dev/null || true` so the
	# rollback never itself fails the run (qubes that were never created
	# are skipped silently). Kill before remove so qvm-remove does not trip
	# over a still-running qube; wait up to 30s for shutdown.
	echo "ERROR: build of '${NAME}' failed -- rolling back ${TEMPLATE_VM} and ${APP_VM}..." >&2
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
	return 1
}

cd ~

requireOsTemplate
requireRepoVm
discoverLibFiles
validateAllQubes

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
