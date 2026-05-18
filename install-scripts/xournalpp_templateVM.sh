#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

echo "Installing Xournal++"

# Install straight from the Debian repository. xournalpp's package already
# depends on the right libzip/portaudio versions, so do not pin lib names
# here -- hard-coded SONAME packages (e.g. libzip4) break across Debian releases.
sudo apt-get update
sudo apt-get install -y xournalpp
