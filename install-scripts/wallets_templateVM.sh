#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

# shared Brave helpers; setup-qubes.sh moves brave.sh in next to this script
. "$(dirname "$0")/brave.sh"

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

install_brave

echo "downloading Frame..."
curl --proxy 127.0.0.1:8082 https://github.com/floating/frame/releases/download/v0.6.9/Frame-0.6.9.AppImage -LGso Frame.AppImage

sudo chmod +x Frame.AppImage
sudo mv ./Frame.AppImage /usr/bin/

# Brave wallet extension IDs (Chrome Web Store)
ARGENTX_ID=dlcobpjiigpikoobohmabehhmhfoodbb
COSMOSTATION_ID=fpkhgmpbidmiogeglndfbkegfdlnajnf
ENKRYPT_ID=kkpllkodjeloidieedojogacfhpaihoh
FRAME_ID=ldcoohedfbjoobcadoglnnmmfbdlmmhf
METAMASK_ID=nkbihfbeogaeaoehlefnkodbefgpgknn
NABOX_ID=nknhiehlklippafakaeklbeglecifhad
RABBY_ID=acmacodkjbdgmoleebolmdjonilkdbch
OKX_ID=mcohilncbfahbmgdjkbpemcciiolgcge
RAINBOW_ID=opfgelmcmbiajamepnmloijbpoleiama
TAHOE_ID=eajafomhmkipbjmfmhebemolkcicgfmd
TRUSTWALLET_ID=egjidjbpglichdcondbcbdnbeeppgdph
ZEAL_ID=heamnjbnflcikcggoiplibfommfbkjpj
ZERION_ID=klghhnkeealcohjjanjjdaeeggmfmlpl

echo "installing Brave wallet extensions..."
install_brave_extensions \
	"${ARGENTX_ID}" \
	"${COSMOSTATION_ID}" \
	"${ENKRYPT_ID}" \
	"${FRAME_ID}" \
	"${METAMASK_ID}" \
	"${OKX_ID}" \
	"${NABOX_ID}" \
	"${RABBY_ID}" \
	"${RAINBOW_ID}" \
	"${TAHOE_ID}" \
	"${TRUSTWALLET_ID}" \
	"${ZEAL_ID}" \
	"${ZERION_ID}"
