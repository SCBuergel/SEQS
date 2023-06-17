#!/bin/bash

PREFIX_APP_VM="A-"
PREFIX_TEMPLATE_VM="Z-"

# fetchFromVM VMNAME FILE [EXE]
function fetchFromVm() {
	echo "fetching $2 from VM $1..."

	if [ $# -lt 2 ]; then
		echo "Expected at least two parameters: fetchFromVm SOURCEVMNAME FILENAME [EXE]"
		return 1
	fi
	
	# delete file in case it already exists on dom0 and ignore errors
	FILE=$(basename "$2")
	rm $FILE 2>>/dev/null

	# fetch the file via the 'cat' hack to avoid dom0 security precautions 
	if qvm-run -p $1 cat $2 >> $FILE; then
		# make the file executable if EXE parameter is passed along
		if [ $# -gt 2 ] && [ $3 == "EXE" ]; then
			chmod +x $FILE
		fi
	else
		# bubble up errors
		return 1
	fi
}

# fetchRunClean VMNAME PACKAGENAME PATH FILENAME
function fetchRunClean() {
	if fetchFromVm personal $3$4 EXE; then
		echo "moving $2 install files to VM $1..."
		qvm-move-to-vm $1 $4

		echo "running $2 installer on VM $1..."
		qvm-run -p $1 sudo ./QubesIncoming/dom0/$4

		echo "cleaning up $2 install files on VM $1..."
		qvm-run -p $1 rm ./QubesIncoming -rf
	else
		echo "looks like there is no $4 script for $1. You do you. ¯\\_ (ツ)_/¯"
		rm $4
		# bubble up errors
		return 1
	fi

}

function installApp () {
	if [ $# -lt 2 ]; then
		echo "Expected two parameters: installApp APPNAME COLOR [offline]"
		return 1
	fi

	echo "STARTING INSTALLATION OF $1..."

	echo "setting up template VM $PREFIX_TEMPLATE_VM$1...."
	qvm-clone debian-11 $PREFIX_TEMPLATE_VM$1
	
	echo "trying to fetch $1 templateVM install files...."
	fetchRunClean $PREFIX_TEMPLATE_VM$1 $1 /home/user/SEQS/install-scripts/ $1_templateVM.sh
	
	echo "creating app VM $PREFIX_APP_VM$1..."
	qvm-create $PREFIX_APP_VM$1 --template $PREFIX_TEMPLATE_VM$1 --label $2
	if [ $# -gt 2 ] && [ $3 == "offline" ]; then
		echo "taking app VM offline..."
		sleep 2
		qvm-prefs $PREFIX_APP_VM$1 netvm none
	fi

	echo "trying to fetch $1.desktop file..."
	if fetchFromVm personal /home/user/SEQS/menu-files/$1.desktop; then
		echo "moving $1.desktop file to template VM..."
		qvm-move-to-vm $PREFIX_TEMPLATE_VM$1 $1.desktop
		qvm-run -p $PREFIX_TEMPLATE_VM$1 sudo mv /home/user/QubesIncoming/dom0/$1.desktop /usr/share/applications/
	else
		echo "looks like there is no $.desktop file for. No biggie ¯\\_ (ツ)_/¯"
		rm $1.desktop
	fi

	echo "shutting down template VM..."
	qvm-shutdown $PREFIX_TEMPLATE_VM$1

	echo "starting app VM..."
	qvm-start $PREFIX_APP_VM$1
	
	echo "trying to fetch $1 appVM install files...."
	fetchRunClean $PREFIX_APP_VM$1 $1 /home/user/SEQS/install-scripts/ $1_appVM.sh

	echo "shutting app VM down..."
	qvm-shutdown $PREFIX_APP_VM$1
}

cd ~

installApp brave red
installApp element red
installApp keepass black offline
installApp signal red
installApp telegram red
installApp wallets orange

# finally delete this setup file after running it
rm $0
