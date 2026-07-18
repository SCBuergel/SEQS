#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

# LedgerLive.AppImage is installed system-wide in the template phase
# (template-vm.sh -> /usr/bin/LedgerLive.AppImage, owned root:root) so
# the binary cannot be silently replaced by anything compromising the
# wallet qube user account between sessions. No per-app-qube action is needed.
echo "ledger: AppImage installed in template phase; nothing to do per-qube."
