#!/bin/bash
echo "Installing wallets and brave-browser"

curl --proxy 127.0.0.1:8082 -s https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg | sudo tee /usr/share/keyrings/brave-browser-archive-keyring.gpg >> /dev/null

echo "deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main" | sudo tee /etc/apt/sources.list.d/brave-browser-release.list

sudo apt update

sudo apt install brave-browser -y

echo "downloading Frame..."
curl --proxy 127.0.0.1:8082 https://github.com/floating/frame/releases/download/v0.6.6/Frame-0.6.6.AppImage -LGso Frame.AppImage

sudo chmod +x Frame.AppImage
sudo mv ./Frame.AppImage /usr/bin/

# https://stackoverflow.com/questions/73289644/how-to-install-browser-extension-for-namely-brave-through-terminal
function installExtension() {
	echo "installing $1"
	EXTENSIONS_PATH=/opt/brave.com/brave/extensions
	mkdir -p $EXTENSIONS_PATH
	echo '{ "external_update_url": "https://clients2.google.com/service/update2/crx" }' > "${EXTENSIONS_PATH}/$1.json"
}

METAMASK_ID=nkbihfbeogaeaoehlefnkodbefgpgknn
RABBY_ID=acmacodkjbdgmoleebolmdjonilkdbch
FRAME_ID=ldcoohedfbjoobcadoglnnmmfbdlmmhf
BLOCKWALLET_ID=bopcbmipnjdcdfflfgjdgdjejmgpoaab
BLOCKWALLET_EXPERIMENTAL_ID=fhjkaoanopnkfmlahebnoeghlacnimpj
ZERION_ID=klghhnkeealcohjjanjjdaeeggmfmlpl
TAHOE_ID=eajafomhmkipbjmfmhebemolkcicgfmd

echo "installing Metamask Brave extension..."
installExtension $METAMASK_ID
echo "installing Rabby Brave extension..."
installExtension $RABBY_ID
echo "installing Frame Brave extension..."
installExtension $FRAME_ID 
echo "installing Blockwallet Brave extension..."
installExtension $BLOCKWALLET_ID
echo "installing Blockwallet Experimental Brave extension..."
installExtension $BLOCKWALLET_EXPERIMENTAL_ID
echo "installing Zerion Brave extension..."
installExtension $ZERION_ID
echo "installing Tahoe Brave extension..."
installExtension $TAHOE_ID

