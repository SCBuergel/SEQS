#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

echo "Installing Open Office"

# get latest download link for Lunix 64 bit DEB version from https://www.openoffice.org/download/index.html	
echo "downloading installation files..."
curl --proxy 127.0.0.1:8082 https://sourceforge.net/projects/openofficeorg.mirror/files/4.1.14/binaries/en-US/Apache_OpenOffice_4.1.14_Linux_x86-64_install-deb_en-US.tar.gz/download -LGso oo.tar.gz

echo "unpacking..."
tar -xvzf oo.tar.gz

echo "changing directory..."
cd ./en-US/DEBS/
sudo dpkg -i *.deb

echo "changing directory..."
cd ./desktop-integration/

echo "installing..."
sudo dpkg -i *.deb
