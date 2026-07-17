#!/usr/bin/env bash
# SEQS reduced-assurance QR receive ceremony for a shared USB controller.
# Installed in dom0 and configured by /etc/seqs/qr-sequential.conf.
set -Eeuo pipefail

CONF=/etc/seqs/qr-sequential.conf
[ -r "$CONF" ] || { echo "ERROR: $CONF is missing" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CONF"

for value in "$NORMAL_USB_QUBE" "$WEBCAM_USB_QUBE" "$SCANNER_QUBE" "$STAGING_QUBE"; do
	[[ "$value" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] || {
		echo "ERROR: unsafe qube name in $CONF" >&2; exit 1;
	}
done
[[ "$CONTROLLER" =~ ^[0-9A-Fa-f]{2}_[0-9A-Fa-f]{2}\.[0-7]$ ]] || {
	echo "ERROR: invalid controller BDF in $CONF" >&2; exit 1;
}

[ "${EUID}" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }
command -v systemctl >/dev/null || { echo "ERROR: systemctl is unavailable" >&2; exit 1; }

exposed=0
teardown_and_poweroff() {
	local rc=$?
	trap - EXIT HUP INT QUIT TERM
	set +e
	qvm-kill -- "$SCANNER_QUBE" >/dev/null 2>&1
	qvm-kill -- "$WEBCAM_USB_QUBE" >/dev/null 2>&1
	if [ "$exposed" -eq 1 ]; then
		echo "Camera phase ended (status $rc). Powering off; do not reconnect USB input before power is off."
		sync
		systemctl poweroff
	fi
	exit "$rc"
}
trap teardown_and_poweroff EXIT HUP INT QUIT TERM

# Fail before input is lost if the fixed destination or qubes are unavailable.
for vm in "$NORMAL_USB_QUBE" "$WEBCAM_USB_QUBE" "$SCANNER_QUBE" "$STAGING_QUBE"; do
	qvm-check -q -- "$vm" || { echo "ERROR: required qube '$vm' is missing" >&2; exit 1; }
done
qvm-check --running -q -- "$WEBCAM_USB_QUBE" && {
	echo "ERROR: $WEBCAM_USB_QUBE is already running" >&2; exit 1;
}
qvm-check --running -q -- "$SCANNER_QUBE" && {
	echo "ERROR: $SCANNER_QUBE is already running" >&2; exit 1;
}
qvm-run --pass-io "$STAGING_QUBE" \
	'test ! -e "$HOME/QubesIncoming/seqs-qr-scanner/key.asc"' \
	</dev/null >/dev/null 2>/dev/null || {
	echo "ERROR: staging already contains an incoming key.asc; inspect and remove it before a new ceremony" >&2
	exit 1
}

cat <<EOF
REDUCED-ASSURANCE SEQUENTIAL USB CEREMONY

Controller:       dom0:$CONTROLLER
Normal backend:   $NORMAL_USB_QUBE
Webcam backend:   $WEBCAM_USB_QUBE
Scanner:          $SCANNER_QUBE
Offline staging:  $STAGING_QUBE

Before typing START:
  * Put away all paper values and secret-bearing screens.
  * Physically unplug the webcam.
  * Be ready to unplug keyboard and mouse immediately after confirmation.
  * The machine will POWER OFF whether scanning succeeds or fails.
  * Do not reconnect keyboard/mouse until power is completely off and the
    webcam has been physically unplugged.
EOF

read -r -p "Type START to begin: " answer </dev/tty
[ "$answer" = START ] || { echo "Not confirmed; nothing changed." >&2; exit 1; }

echo "Unplug keyboard and mouse now. The normal USB backend stops in 10 seconds."
sleep 10
exposed=1
qvm-shutdown --wait -- "$NORMAL_USB_QUBE"

echo "NORMAL USB BACKEND STOPPED. Connect only the webcam now; waiting 30 seconds."
sleep 30

# From this point every failure reaches the poweroff trap. Strict PCI reset is
# enforced by setup: sequential mode cannot be rendered with no-strict-reset.
qvm-start -- "$WEBCAM_USB_QUBE"
qvm-start -- "$SCANNER_QUBE"
sleep 5

mapfile -t devices < <(qvm-usb 2>/dev/null | awk -v p="$WEBCAM_USB_QUBE:" '$1 ~ ("^" p) {print $1}')
[ "${#devices[@]}" -eq 1 ] || {
	echo "ERROR: expected exactly one USB device in $WEBCAM_USB_QUBE, found ${#devices[@]}" >&2
	exit 1
}
device="${devices[0]}"
case "$device" in
	"$WEBCAM_USB_QUBE":*) usb_path="${device#*:}" ;;
	*) echo "ERROR: webcam backend returned the wrong backend name" >&2; exit 1 ;;
esac
[[ "$usb_path" =~ ^[0-9]+-[0-9]+(\.[0-9]+)*$ ]] || {
	echo "ERROR: webcam backend returned an unsafe device identifier" >&2; exit 1;
}
qvm-usb attach "$SCANNER_QUBE" "$device"

# No scanner/backend output reaches the dom0 terminal. The untrusted scanner
# may invoke only qubes.Filecopy to the fixed staging qube under qrexec policy.
scan_rc=0
if qvm-run --pass-io "$SCANNER_QUBE" \
	"set -euo pipefail; umask 077; timeout 180 zbarcam -q --raw --oneshot -Sdisable -Sqrcode.enable > key.asc; test -s key.asc; test \"\$(stat -c %s key.asc)\" -le 16384; qvm-copy-to-vm '$STAGING_QUBE' key.asc" \
	</dev/null >/dev/null 2>/dev/null; then
	echo "Ciphertext copy completed. Physically unplug the webcam now."
else
	echo "ERROR: scan/copy failed; no trusted interpretation was attempted" >&2
	scan_rc=1
fi

# Give the operator time to remove the webcam, but never trust device-removal
# reports from the exposed backend and never restore the keyboard in this boot.
sleep 20
exit "$scan_rc"
