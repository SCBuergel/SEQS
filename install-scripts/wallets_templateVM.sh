#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

echo "Installing wallets and brave-browser"

echo "Adding Ledger udev rules..."

cat << EOF | sudo tee /etc/udev/rules.d/20-hw1.rules
# HW.1, Nano
SUBSYSTEMS=="usb", ATTRS{idVendor}=="2581", ATTRS{idProduct}=="1b7c|2b7c|3b7c|4b7c", TAG+="uaccess", TAG+="udev-acl"

# Blue, NanoS, Aramis, HW.2, Nano X, NanoSP, Stax, Ledger Test,
SUBSYSTEMS=="usb", ATTRS{idVendor}=="2c97", TAG+="uaccess", TAG+="udev-acl"

# Same, but with hidraw-based library (instead of libusb)
KERNEL=="hidraw*", ATTRS{idVendor}=="2c97", MODE="0666"
EOF

echo "Adding Trezor udev rules..."
sudo cat << EOF | sudo tee /etc/udev/rules.d/51-trezor.rules
# Trezor
SUBSYSTEM=="usb", ATTR{idVendor}=="534c", ATTR{idProduct}=="0001", MODE="0660", GROUP="plugdev", TAG+="uaccess", TAG+="udev-acl", SYMLINK+="trezor%n"
KERNEL=="hidraw*", ATTRS{idVendor}=="534c", ATTRS{idProduct}=="0001", MODE="0660", GROUP="plugdev", TAG+="uaccess", TAG+="udev-acl"

# Trezor v2
SUBSYSTEM=="usb", ATTR{idVendor}=="1209", ATTR{idProduct}=="53c0", MODE="0660", GROUP="plugdev", TAG+="uaccess", TAG+="udev-acl", SYMLINK+="trezor%n"
SUBSYSTEM=="usb", ATTR{idVendor}=="1209", ATTR{idProduct}=="53c1", MODE="0660", GROUP="plugdev", TAG+="uaccess", TAG+="udev-acl", SYMLINK+="trezor%n"
KERNEL=="hidraw*", ATTRS{idVendor}=="1209", ATTRS{idProduct}=="53c1", MODE="0660", GROUP="plugdev", TAG+="uaccess", TAG+="udev-acl"
EOF

echo "triggering udevadm..."
sudo udevadm trigger

echo "reloading rules..."
sudo udevadm control --reload-rules

echo "loading brave keyring..."
curl --proxy 127.0.0.1:8082 -s https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg | sudo tee /usr/share/keyrings/brave-browser-archive-keyring.gpg >> /dev/null

echo "deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main" | sudo tee /etc/apt/sources.list.d/brave-browser-release.list

sudo apt update

sudo apt install brave-browser -y

echo "downloading Frame..."
curl --proxy 127.0.0.1:8082 https://github.com/floating/frame/releases/download/v0.6.9/Frame-0.6.9.AppImage -LGso Frame.AppImage

sudo chmod +x Frame.AppImage
sudo mv ./Frame.AppImage /usr/bin/

# https://stackoverflow.com/questions/73289644/how-to-install-browser-extension-for-namely-brave-through-terminal
function installExtension() {
	echo "installing $1"
	EXTENSIONS_PATH=/opt/brave.com/brave/extensions
	sudo mkdir -p $EXTENSIONS_PATH
	echo '{ "external_update_url": "https://clients2.google.com/service/update2/crx" }' | sudo tee "${EXTENSIONS_PATH}/$1.json"
}

ARGENTX_ID=dlcobpjiigpikoobohmabehhmhfoodbb
BLOCKWALLET_ID=bopcbmipnjdcdfflfgjdgdjejmgpoaab
BLOCKWALLET_EXPERIMENTAL_ID=fhjkaoanopnkfmlahebnoeghlacnimpj
COSMOSTATION_ID=fpkhgmpbidmiogeglndfbkegfdlnajnf
ENKRYPT_ID=kkpllkodjeloidieedojogacfhpaihoh
FRAME_ID=ldcoohedfbjoobcadoglnnmmfbdlmmhf
LIQUALITY_ID=kpfopkelmapcoipemfendmdcghnegimn
METAMASK_ID=nkbihfbeogaeaoehlefnkodbefgpgknn
NABOX_ID=nknhiehlklippafakaeklbeglecifhad
RABBY_ID=acmacodkjbdgmoleebolmdjonilkdbch
OKX_ID=mcohilncbfahbmgdjkbpemcciiolgcge
RAINBOW_ID=opfgelmcmbiajamepnmloijbpoleiama
TAHOE_ID=eajafomhmkipbjmfmhebemolkcicgfmd
TRUSTWALLET_ID=egjidjbpglichdcondbcbdnbeeppgdph
ZEAL_ID=heamnjbnflcikcggoiplibfommfbkjpj
ZERION_ID=klghhnkeealcohjjanjjdaeeggmfmlpl

echo "installing ArgentX Brave extension..."
installExtension $ARGENTX_ID
echo "installing Blockwallet Brave extension..."
installExtension $BLOCKWALLET_ID
echo "installing Blockwallet Experimental Brave extension..."
installExtension $BLOCKWALLET_EXPERIMENTAL_ID
echo "installing Cosmostation Wallet Brave extension..."
installExtension $COSMOSTATION_ID
echo "installing Enkrypt Brave extension..."
installExtension $ENKRYPT_ID
echo "installing Frame Brave extension..."
installExtension $FRAME_ID 
echo "installing Liquality Brave extension..."
installExtension $LIQUALITY_ID
echo "installing Metamask Brave extension..."
installExtension $METAMASK_ID
echo "installing OKX wallet Brave extension..."
installExtension $OKX_ID
echo "installing Nabox Brave extension..."
installExtension $NABOX_ID
echo "installing Rabby Brave extension..."
installExtension $RABBY_ID
echo "installing Rainbow Brave extension..."
installExtension $RAINBOW_ID
echo "installing Tahoe Brave extension..."
installExtension $TAHOE_ID
echo "installing Trust Wallet Brave extension..."
installExtension $TRUSTWALLET_ID
echo "installing Zeal wallet Brave extension..."
installExtension $ZEAL_ID
echo "installing Zerion wallet Brave extension..."
installExtension $ZERION_ID
