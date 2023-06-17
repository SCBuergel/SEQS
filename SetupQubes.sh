#!/bin/bash

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
		sleep 2

		echo "cleaning up $2 install files on VM $1..."
		qvm-run -p $1 rm ./QubesIncoming -rf
	else
		echo "looks like there is no $4 script for $1. You do you. ¯\\_ (ツ)_/¯"
		# bubble up errors
		return 1
	fi

}

function installApp () {
	if [ $# -lt 2 ]; then
		echo "Expected two parameters: installApp APPNAME COLOR [offline]"
		return 1
	fi

	echo "running $0..."

	echo "setting up template VM ZZ-$1...."
	qvm-clone debian-11 ZZ-$1
	
	echo "trying to fetch $1 templateVM install files...."
	fetchRunClean ZZ-$1 $1 /home/user/SEQS/install-scripts/ $1_templateVM.sh

	echo "shutting down template VM..."
	qvm-shutdown ZZ-$1
	sleep 3

	echo "starting template VM once more..."
	qvm-start ZZ-$1
	sleep 10

	echo "and shutting template VM off again..."
	qvm-shutdown ZZ-$1
	sleep 3
	
	echo "creating app VM AA-$1..."
	qvm-create AA-$1 --template ZZ-$1 --label $2
	if [ $# -gt 2 ] && [ $3 == "offline" ]; then
		echo "taking app VM offline..."
		sleep 2
		qvm-prefs AA-$1 netvm none
	fi

	echo "trying to fetch $1.desktop file..."
	if fetchFromVm personal /home/user/SEQS/menu-files/$1.desktop; then
		echo "moving $1.desktop file to template VM..."
		qvm-move-to-vm ZZ-$1 $1.desktop
		qvm-run -p ZZ-$1 sudo mv /home/user/QubesIncoming/dom0/$1.desktop /usr/share/applications/
	else
		echo "looks like there is no $.desktop file for. No biggie ¯\\_ (ツ)_/¯"
	fi

	echo "shutting down template VM..."
	qvm-shutdown ZZ-$1

	echo "starting app VM..."
	qvm-start AA-$1
	
	echo "trying to fetch $1 appVM install files...."
	fetchRunClean AA-$1 $1 /home/user/SEQS/install-scripts/ $1_appVM.sh

	echo "shutting app VM down..."
	qvm-shutdown AA-$1
}

cd ~

#installApp brave red
#installApp keepass black offline
#installApp element red
#installApp signal red
#installApp telegram red
installApp wallets orange

# finally delete this setup file after running it
rm $0
