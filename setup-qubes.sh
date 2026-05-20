#!/usr/bin/env bash

# Qube that holds the SEQS repo; install scripts are fetched from here.
REPO_VM="personal"

PREFIX_APP_VM="A-"
PREFIX_TEMPLATE_VM="Z-"
OS_TEMPLATE_VM="debian-13-xfce"

# App qube that every other app qube opens web links in (for isolation).
BROWSER_VM="${PREFIX_APP_VM}brave"
# Name of the .desktop link handler installed into each non-browser app qube.
BROWSER_DESKTOP="open-links-in-browser-qube.desktop"

# Shared helper libraries fetched from REPO_VM and moved next to every install
# script inside the target VM, so install scripts can `source` them.
LIB_PATH="/home/user/SEQS/install-scripts/lib/"
LIB_FILES="brave.sh"

# Directories deleted on every app qube's boot AND shutdown, via a systemd
# service installed into each template. Leave a value empty to skip it.
CLEANUP_QUBESINCOMING="/home/user/QubesIncoming"
CLEANUP_DOWNLOADS="/home/user/Downloads"

# Developer qubes -- each entry builds one template + app qube composed of the
# listed components (install-scripts/components/<name>/). Mix and match freely.
# Format: "NAME COLOR component component ..." with a trailing 'offline' to
# detach the app qube from netvm. Typical dev components: docker, python, node,
# vscode, claude-code -- but any component (see install-scripts/components/) is
# valid here; for wallet qubes use WALLET_QUBES below.
DEV_QUBES=(
	"dev-full gray docker python node vscode claude-code"
)

# Single-component qubes -- one app per qube. Same format as WALLET_QUBES /
# DEV_QUBES; a trailing 'offline' detaches the app qube from netvm (used here
# for keepass).
SINGLE_QUBES=(
	"brave      red    brave"
	"element    red    element"
	"keepass    black  keepass    offline"
	"signal     red    signal"
	"telegram   red    telegram"
	"openoffice red    openoffice"
	"xournalpp  red    xournalpp"
)

# Brave wallet extension name -> Chrome Web Store ID.
# Reference these as 'brave-extension-<name>' in qube specs (see WALLET_QUBES).
# To add an extension: add a line. To retire one: remove its line.
BRAVE_EXTENSIONS=(
	"argentx       dlcobpjiigpikoobohmabehhmhfoodbb"
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

# Wallet qubes -- each entry builds one template + app qube composed of the
# listed components. Use 'brave-extension-<name>' to add a wallet extension
# (looked up in BRAVE_EXTENSIONS above; Brave is auto-installed when needed).
# Format: "NAME COLOR component component ..."
WALLET_QUBES=(
	"wallet-ledger orange ledger brave-extension-rabby"
	"wallet-trezor orange trezor brave-extension-rabby"
)

# fetchFromVM SOURCE_VM FILE [EXE]
function fetchFromVm() {
	if [ $# -lt 2 ]; then
		echo "Expected at least two parameters: fetchFromVm SOURCE_VM FILE [EXE]"
		return 1
	fi
	SOURCE_VM="${1}"
	FILE="${2}"
	EXE="${3}"

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
# Fetches FILENAME from ${REPO_VM}:${FILE_PATH}, plus LIB_FILES alongside, and
# (when DESKTOP_NAME is given AND ${FILE_PATH}menu.desktop exists) that too.
# Moves them all into VMNAME in one batch, runs FILENAME, installs the
# menu.desktop as /usr/share/applications/${DESKTOP_NAME}.desktop, then cleans
# QubesIncoming once. Returns non-zero (and skips cleanup) only if FILENAME
# itself cannot be fetched.
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

		local move_files="${FILENAME}${libs}"
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
		rm ${FILENAME}
		# bubble up errors
		return 1
	fi
}

# create the dom0 qrexec policy so any qube may open links in the browser qube
function setupBrowserPolicy() {
	echo "allowing all qubes to open links in ${BROWSER_VM}..."
	echo "qubes.OpenURL * @anyvm ${BROWSER_VM} allow" \
		| sudo tee /etc/qubes/policy.d/29-browser.policy > /dev/null
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

# validateAllQubes -- pre-flight check across SINGLE_QUBES, WALLET_QUBES,
# DEV_QUBES. Verifies every referenced component exists (under
# install-scripts/components/ or in the BRAVE_EXTENSIONS array), no two configured
# qubes share a NAME, and no target qube (Z-NAME / A-NAME) is already taken.
# Aborts before any qube is built if anything looks wrong.
function validateAllQubes() {
	echo "validating all qube specs..."

	# components available in REPO_VM
	local available_components
	if ! available_components=$(qvm-run -p ${REPO_VM} "ls /home/user/SEQS/install-scripts/components/" 2>/dev/null); then
		echo "ERROR: could not enumerate components from ${REPO_VM}." >&2
		exit 1
	fi
	available_components=" $(echo ${available_components} | tr '\n' ' ') "

	# brave extension names available in BRAVE_EXTENSIONS
	local available_extensions=" " entry ename
	for entry in "${BRAVE_EXTENSIONS[@]}"; do
		ename="${entry%% *}"
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

	# build a shell-quoted, space-separated directory list from the config
	local dirs="" d
	for d in "${CLEANUP_QUBESINCOMING}" "${CLEANUP_DOWNLOADS}"; do
		[ -n "${d}" ] && dirs="${dirs} \"${d}\""
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
}

cd ~

requireOsTemplate
requireRepoVm
validateAllQubes

setupBrowserPolicy

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

# finally delete this setup file after running it
rm $0
