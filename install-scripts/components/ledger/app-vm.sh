#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

# LedgerLive.AppImage is installed system-wide in the template phase
# (template-vm.sh -> /usr/bin/LedgerLive.AppImage, owned root:root) so
# the binary cannot be silently replaced by anything compromising the
# wallet qube user account between sessions. There is no per-app-VM
# action remaining; this file exists only to make the move explicit
# in the component directory and to avoid the misleading "no app-vm.sh"
# log line that fetchRunClean prints when an expected file is absent.
echo "ledger: AppImage installed in template phase; nothing to do per-qube."
