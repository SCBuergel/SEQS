#!/usr/bin/env bash

# Qube that holds the SEQS repo; install scripts are fetched from here.
REPO_VM="personal"

PREFIX_APP_VM="A-"
PREFIX_TEMPLATE_VM="Z-"
OS_TEMPLATE_VM="debian-12"

# App qube that every other app qube opens web links in (for isolation).
BROWSER_VM="${PREFIX_APP_VM}brave"
# Name of the .desktop link handler installed into each non-browser app qube.
BROWSER_DESKTOP="open-links-in-browser-qube.desktop"

# Shared helper libraries fetched from REPO_VM and moved next to every install
# script inside the target VM, so install scripts can `source` them.
LIB_PATH="/home/user/SEQS/install-scripts/lib/"
LIB_FILES="brave.sh"

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

cd ~

setupBrowserPolicy

installApp brave red
installApp element red
installApp keepass black offline
installApp docker red
installApp signal red
installApp telegram red
installApp wallets orange
installApp python red
installApp openOffice red
installApp vscode red
installApp xournalpp red

# finally delete this setup file after running it
rm $0
