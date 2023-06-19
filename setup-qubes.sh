#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

PREFIX_APP_VM="A-"
PREFIX_TEMPLATE_VM="Z-"

# fetchFromVM VMNAME FILE [EXE]
function fetchFromVm() {
	if [ $# -lt 2 ]; then
		echo "Expected at least two parameters: fetchFromVm SOURCEVMNAME FILENAME [EXE]"
		return 1
	fi
	VMNAME="${1}"
	FILE="${2}"
	EXE="${3}"

	echo "Fetching ${FILE} from VM ${VMNAME}..."
	
	# delete file in case it already exists on dom0 and ignore errors
	FILENAME=$(basename "$FILE")
	rm $FILENAME 2>>/dev/null

	# fetch the file via the 'cat' hack to avoid dom0 security precautions 
	if qvm-run -p ${VMNAME} cat ${FILE} >> $FILENAME; then
		# make the file executable if EXE parameter is passed along
		if [ $# -gt 2 ] && [ ${EXE} == "EXE" ]; then
			chmod +x $FILENAME
		fi
	else
		# bubble up errors
		return 1
	fi
}

# fetchRunClean VMNAME PACKAGENAME PATH FILENAME
function fetchRunClean() {
	VMNAME="${1}"
	PACKAGENAME="${2}"
	PATH="${3}"
	FILENAME="${4}"
	if fetchFromVm personal ${PATH}/${FILENAME} EXE; then
		echo "Moving ${PACKAGENAME} install files to VM ${VMNAME}..."
		qvm-move-to-vm ${VMNAME} ${FILENAME}

		echo "Running ${PACKAGENAME} installer on VM ${VMNAME}..."
		qvm-run -p ${VMNAME} sudo ./QubesIncoming/dom0/${FILENAME}

		echo "Cleaning up ${PACKAGENAME} install files on VM ${VMNAME}..."
		qvm-run -p ${VMNAME} rm ./QubesIncoming -rf
	else
		echo "Looks like there is no ${FILENAME} script for ${VMNAME}. You do you. ¯\\_ (ツ)_/¯"
		rm ${FILENAME}
		# bubble up errors
		return 1
	fi

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
	qvm-clone debian-11 ${TEMPLATE_VM}
	
	echo "trying to fetch ${APPNAME} templateVM install files...."
	fetchRunClean ${TEMPLATE_VM} ${APPNAME} /home/user/SEQS/install-scripts/ ${APPNAME}_templateVM.sh
	
	echo "creating app VM ${APP_VM}..."
	qvm-create ${APP_VM} --template ${TEMPLATE_VM} --label ${COLOR}
	if [ $# -gt 2 ] && [ ${OFFLINE} == "offline" ]; then
		echo "taking app VM offline..."
		sleep 2
		qvm-prefs ${APP_VM} netvm none
	fi

	echo "trying to fetch ${APPNAME}.desktop file..."
	if fetchFromVm personal /home/user/SEQS/menu-files/${APPNAME}.desktop; then
		echo "moving ${APPNAME}.desktop file to template VM..."
		qvm-move-to-vm ${TEMPLATE_VM} ${APPNAME}.desktop
		qvm-run -p ${TEMPLATE_VM} sudo mv /home/user/QubesIncoming/dom0/${APPNAME}.desktop /usr/share/applications/
	else
		echo "looks like there is no $.desktop file for. No biggie ¯\\_ (ツ)_/¯"
		rm ${APPNAME}.desktop
	fi

	echo "shutting down template VM..."
	qvm-shutdown ${TEMPLATE_VM}

	echo "starting app VM..."
	qvm-start ${APP_VM}
	
	echo "trying to fetch ${APPNAME} appVM install files...."
	fetchRunClean ${APP_VM} ${APPNAME} /home/user/SEQS/install-scripts/ ${APPNAME}_appVM.sh

	echo "shutting app VM down..."
	qvm-shutdown ${APP_VM}
}

cd ~

installApp brave red
installApp element red
installApp keepass black offline
installApp docker red
installApp signal red
installApp telegram red
installApp wallets orange

# finally delete this setup file after running it
rm $0
