cd ~

echo "setting up fetch-from-vm..."
echo "
if [ \$# -ne 2 ]; then
echo \"Expect two parameters: fetch-from-vm source_vm file\"
exit 1
fi
FILE=\$(basename \"\$2\")
rm \$FILE 2>>/dev/null
qvm-run --pass-io \$1 cat \$2 >> \$FILE
chmod +x \$FILE
" >> ./.local/bin/fetch-from-vm
chmod +x ./.local/bin/fetch-from-vm

function installApp () {
	if [ $# -lt 2 ]; then
	echo "Expected two parameters: installApp APPNAME COLOR [offline]"
	exit 1
	fi
	
	echo "setting up template VM ZZ-$1...."
	qvm-clone debian-11 ZZ-$1
	
	echo "fetching $1 install files...."
	fetch-from-vm personal /home/user/SEQS/install-scripts/$1.sh
	
	echo "moving $1 install files to template VM..."
	qvm-move-to-vm ZZ-$1 $1.sh

	echo "running $1 installer..."
	qvm-run ZZ-$1 ./QubesIncoming/dom0/$1.sh	

	echo "cleaning up $1 install files on app VM..."
	qvm-run ZZ-$1 rm ./QubesIncoming -rf
	qvm-shutdown ZZ-$1
	sleep 2
	
	echo "creating app VM AA-$1..."
	qvm-create AA-$1 --template ZZ-$1 --label $2
	if [ $# -gt 2 ] && [ $3 == "offline" ]; then
	echo "taking app VM offline..."
	sleep 2
	qvm-prefs AA-$1 netvm none
	fi

	echo "trying to fetch $1.desktop file..."
	fetch-from-vm personal /home/user/SEQS/menu-files/$1.desktop 

	if [ -f "$1.desktop" ]; then
		echo "moving $1.desktop file to template VM..."
		qvm-move-to-vm ZZ-$1 $1.desktop
		qvm-run ZZ-$1 sudo mv /home/user/QubesIncoming/dom0/$1.desktop /usr/share/applications/
	fi

	echo "shutting down template VM..."
	qvm-shutdown ZZ-$1

	echo "starting app VM..."
	qvm-start AA-$1
}

#installApp brave red
#installApp keepass black offline
#installApp element red
installApp signal red
