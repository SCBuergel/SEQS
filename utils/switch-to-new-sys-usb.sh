#!/bin/bash
# Setup script for adb access in sys-usb on QubesOS
# Run this in dom0
set -e

TEMPLATE_BASE="debian-12"
TEMPLATE_CLONE="debian-12-usb"
DVM_TEMPLATE="debian-12-usb-dvm"
USB_QUBE="sys-usb"

echo "=== Step 1: Clone base template ==="
if qvm-check "$TEMPLATE_CLONE" &>/dev/null; then
    echo "$TEMPLATE_CLONE already exists, skipping clone"
else
    qvm-clone "$TEMPLATE_BASE" "$TEMPLATE_CLONE"
    echo "Cloned $TEMPLATE_BASE -> $TEMPLATE_CLONE"
fi

echo "=== Step 2: Install adb in cloned template ==="
qvm-start --skip-if-running "$TEMPLATE_CLONE"
qvm-run -u root --pass-io "$TEMPLATE_CLONE" "apt-get update && apt-get install -y adb"
qvm-shutdown --wait "$TEMPLATE_CLONE"
echo "adb installed and template shut down"

echo "=== Step 3: Create DispVM template ==="
if qvm-check "$DVM_TEMPLATE" &>/dev/null; then
    echo "$DVM_TEMPLATE already exists, skipping creation"
else
    qvm-create "$DVM_TEMPLATE" --template "$TEMPLATE_CLONE" --label red --prop template_for_dispvms=True
    echo "Created $DVM_TEMPLATE"
fi

echo "=== Step 4: Switch sys-usb to new template ==="
echo "WARNING: Keyboard and mouse will be lost briefly during sys-usb restart."
echo "Press Enter to continue or Ctrl+C to abort..."
read -r

qvm-shutdown --wait "$USB_QUBE" && qvm-prefs "$USB_QUBE" template "$DVM_TEMPLATE" && qvm-start "$USB_QUBE"
echo "=== Done! sys-usb is running with adb available ==="

echo ""
echo "Next steps (run inside sys-usb):"
echo "  adb devices                  # approve prompt on phone"
echo "  adb pull /path/to/file /tmp/ # pull file over USB"
echo "  qvm-copy-to-vm TARGET /tmp/file  # send to target qube"
