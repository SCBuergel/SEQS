#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

echo "Installing Bitbox"

# get latest download link for Lunix 64 bit DEB version from https://bitbox.swiss/download/?source=start
echo "downloading installation files..."
curl --proxy 127.0.0.1:8082 https://github.com/digitalbitbox/bitbox-wallet-app/releases/download/v4.41.0/bitbox_4.41.0_amd64.deb -LGso bitbox.deb

echo "installing..."
sudo dpkg -i *.deb
