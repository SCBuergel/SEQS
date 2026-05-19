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
# Format: "NAME COLOR component component ..."
# Available components: docker python node vscode claude-code
DEV_QUBES=(
	"dev-full gray docker python node vscode claude-code"
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

# fetchRunClean VMNAME APP PATH FILENAME
function fetchRunClean() {
	VMNAME="${1}"
	APP="${2}"
	FILE_PATH="${3}"
	FILENAME="${4}"
	if fetchFromVm ${REPO_VM} ${FILE_PATH}${FILENAME} EXE; then
		# fetch shared helper libraries so the install script can source them
		local lib libs=""
		for lib in ${LIB_FILES}; do
			if fetchFromVm ${REPO_VM} ${LIB_PATH}${lib}; then
				libs="${libs} ${lib}"
			fi
		done

		echo "Moving ${APP} install files to VM ${VMNAME}..."
		qvm-move-to-vm ${VMNAME} ${FILENAME} ${libs}

		echo "Running ${APP} installer on VM ${VMNAME}..."
		qvm-run -p ${VMNAME} ./QubesIncoming/dom0/${FILENAME}

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

# installApp APPNAME COLOR OFFLINE
function installApp () {
	if [ $# -lt 2 ]; then
		echo "Expected two parameters: installApp APPNAME COLOR [offline]"
		return 1
	fi

	APPNAME="${1}"
	COLOR="${2}"
	OFFLINE="${3}"
	APP_VM="${PREFIX_APP_VM}${APPNAME}"
	TEMPLATE_VM="${PREFIX_TEMPLATE_VM}${APPNAME}"

	echo "STARTING INSTALLATION OF ${APPNAME}..."

	echo "setting up template VM ${TEMPLATE_VM}...."
	qvm-clone ${OS_TEMPLATE_VM} ${TEMPLATE_VM}
	
	echo "trying to fetch ${APPNAME} templateVM install files...."
	fetchRunClean ${TEMPLATE_VM} ${APPNAME} /home/user/SEQS/install-scripts/ ${APPNAME}_templateVM.sh

	echo "trying to fetch ${APPNAME}.desktop file..."
	if fetchFromVm ${REPO_VM} /home/user/SEQS/menu-files/${APPNAME}.desktop; then
		echo "moving ${APPNAME}.desktop file to template VM..."
		qvm-move-to-vm ${TEMPLATE_VM} ${APPNAME}.desktop
		qvm-run -p ${TEMPLATE_VM} sudo mv /home/user/QubesIncoming/dom0/${APPNAME}.desktop /usr/share/applications/
	else
		echo "looks like there is no $APPNAME.desktop file. No biggie ¯\\_ (ツ)_/¯"
		rm ${APPNAME}.desktop
	fi

	installCleanupService ${TEMPLATE_VM}

	echo "shutting down template VM..."
	qvm-shutdown ${TEMPLATE_VM}
	sleep 4

	echo "creating app VM ${APP_VM}..."
	qvm-create ${APP_VM} --template ${TEMPLATE_VM} --label ${COLOR}
	if [ ! -z "${OFFLINE}" ] && [[ ${OFFLINE} == "offline" ]]; then
		echo "taking app VM offline..."
		sleep 2
		qvm-prefs ${APP_VM} netvm none
	fi

	echo "starting app VM..."
	qvm-start ${APP_VM}
	
	echo "trying to fetch ${APPNAME} appVM install files...."
	fetchRunClean ${APP_VM} ${APPNAME} /home/user/SEQS/install-scripts/ ${APPNAME}_appVM.sh

	# point every app qube at the browser qube for links (except the browser qube itself)
	if [[ "${APP_VM}" != "${BROWSER_VM}" ]]; then
		setBrowserQube ${APP_VM}
	fi

	echo "shutting app VM down..."
	qvm-shutdown ${APP_VM}
}

# installQube NAME COLOR component [component ...]
# Builds a Z-NAME template + A-NAME app qube composed of the named components
# (install-scripts/components/<component>/). Each component may provide a
# template-vm.sh (system-wide install) and/or an app-vm.sh (per-app-qube
# setup); missing parts are skipped.
function installQube() {
	if [ $# -lt 3 ]; then
		echo "Expected: installQube NAME COLOR component [component ...]"
		return 1
	fi

	local NAME="${1}"
	local COLOR="${2}"
	shift 2
	local COMPONENTS="$*"
	local APP_VM="${PREFIX_APP_VM}${NAME}"
	local TEMPLATE_VM="${PREFIX_TEMPLATE_VM}${NAME}"
	local COMPONENT_PATH="/home/user/SEQS/install-scripts/components/"
	local comp

	echo "STARTING BUILD OF ${NAME} from components: ${COMPONENTS}"

	echo "setting up template VM ${TEMPLATE_VM}..."
	qvm-clone ${OS_TEMPLATE_VM} ${TEMPLATE_VM}

	# template phase: run each component's template-vm.sh in the template
	for comp in ${COMPONENTS}; do
		echo "installing component '${comp}' into ${TEMPLATE_VM}..."
		fetchRunClean ${TEMPLATE_VM} "${comp}" "${COMPONENT_PATH}${comp}/" template-vm.sh
	done

	installCleanupService ${TEMPLATE_VM}

	echo "shutting down template VM..."
	qvm-shutdown ${TEMPLATE_VM}
	sleep 4

	echo "creating app VM ${APP_VM}..."
	qvm-create ${APP_VM} --template ${TEMPLATE_VM} --label ${COLOR}

	echo "starting app VM..."
	qvm-start ${APP_VM}

	# app-VM phase: run each component's app-vm.sh in the app qube
	for comp in ${COMPONENTS}; do
		echo "configuring component '${comp}' on ${APP_VM}..."
		fetchRunClean ${APP_VM} "${comp}" "${COMPONENT_PATH}${comp}/" app-vm.sh
	done

	# open web links in the browser qube
	if [[ "${APP_VM}" != "${BROWSER_VM}" ]]; then
		setBrowserQube ${APP_VM}
	fi

	echo "shutting app VM down..."
	qvm-shutdown ${APP_VM}
}

cd ~

requireOsTemplate
requireRepoVm

setupBrowserPolicy

installApp brave red
installApp element red
installApp keepass black offline
installApp signal red
installApp telegram red
installApp wallets orange
installApp openOffice red
installApp xournalpp red

# developer qubes -- composed from the DEV_QUBES list configured at the top
for spec in "${DEV_QUBES[@]}"; do
	installQube ${spec}
done

# finally delete this setup file after running it
rm $0
