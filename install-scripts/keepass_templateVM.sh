#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

echo "Installing KeepassXC from AppImage"

curl --proxy 127.0.0.1:8082 https://github.com/keepassxreboot/keepassxc/releases/download/2.7.5/KeePassXC-2.7.5-x86_64.AppImage -LGso keepassxc.AppImage

sudo chmod +x keepassxc.AppImage
sudo cp ./keepassxc.AppImage /usr/bin/
