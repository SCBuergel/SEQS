#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

# shared Brave helpers; setup-qubes.sh moves brave.sh in next to this script
. "$(dirname "$0")/brave.sh"

echo "Installing docker"

echo "Installing ca-certificats for Docker Engine..."
sudo apt install ca-certificates curl gnupg -y

sudo install -m 0755 -d /etc/apt/keyrings

echo "Getting docker keys..."
curl --proxy 127.0.0.1:8082 -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
  "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "Running apt update..."
sudo apt update

echo "Installing Docker packages..."
sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y

echo "Adding  to user group..."
groups user
sudo usermod -aG docker user
groups user

install_brave

echo "downloading Frame..."
curl --proxy 127.0.0.1:8082 https://github.com/floating/frame/releases/download/v0.6.8/Frame-0.6.8.AppImage -LGso Frame.AppImage

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
TAHOE_ID=eajafomhmkipbjmfmhebemolkcicgfmd
TRUSTWALLET_ID=egjidjbpglichdcondbcbdnbeeppgdph
ZERION_ID=klghhnkeealcohjjanjjdaeeggmfmlpl

echo "installing Brave wallet extensions..."
install_brave_extensions \
	"${ARGENTX_ID}" \
	"${COSMOSTATION_ID}" \
	"${ENKRYPT_ID}" \
	"${FRAME_ID}" \
	"${METAMASK_ID}" \
	"${NABOX_ID}" \
	"${RABBY_ID}" \
	"${TAHOE_ID}" \
	"${TRUSTWALLET_ID}" \
	"${ZERION_ID}"
