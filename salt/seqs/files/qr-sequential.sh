#!/usr/bin/env bash
# SEQS sequential-path QR scan on a USB controller shared with the keyboard.
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
[[ "$CONTROLLER" =~ ^[0-9a-f]{2}_[0-9a-f]{2}\.[0-7]$ ]] || {
	echo "ERROR: invalid controller BDF in $CONF" >&2; exit 1;
}

[ "${EUID}" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }
command -v systemctl >/dev/null || { echo "ERROR: systemctl is unavailable" >&2; exit 1; }

exposed=0
teardown_and_poweroff() {
	local rc=$?
	# Once teardown has started, no signal may stop it short of the power-off;
	# the ignored signals are inherited by the commands below.
	trap - EXIT
	trap '' HUP INT QUIT TERM
	set +e
	qvm-kill -- "$SCANNER_QUBE" >/dev/null 2>&1
	qvm-kill -- "$WEBCAM_USB_QUBE" >/dev/null 2>&1
	# A clean shutdown commits the received file to the staging qube's disk
	# before the power-off; qvm-shutdown kills the qube if it ignores this.
	echo "Shutting down $STAGING_QUBE."
	qvm-shutdown --wait -- "$STAGING_QUBE" >/dev/null 2>&1
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
# The camera side must stay offline at every scan, not only after setup:
# no NetVM, and no default disposable that qubes.OpenInVM could reach.
# Checked first: the old-key.asc check below starts the staging qube.
for vm in "$WEBCAM_USB_QUBE" "$SCANNER_QUBE" "$STAGING_QUBE"; do
	for pref in netvm default_dispvm; do
		value="$(qvm-prefs -- "$vm" "$pref" 2>/dev/null)" || {
			echo "ERROR: cannot read $pref of '$vm'" >&2; exit 1;
		}
		case "$value" in
			''|None|none) ;;
			*) echo "ERROR: '$vm' has $pref set; the camera side must be offline" >&2; exit 1 ;;
		esac
	done
done
# The staging qube's answer is only compared, never printed. The scanner name
# was charset-checked above, so it is safe inside the remote command.
staged="$(qvm-run --pass-io "$STAGING_QUBE" \
	"if test -e \"\$HOME/QubesIncoming/$SCANNER_QUBE/key.asc\"; then echo PRESENT; else echo ABSENT; fi" \
	</dev/null 2>/dev/null)" || staged=''
case "$staged" in
	ABSENT) ;;
	PRESENT)
		echo "ERROR: $STAGING_QUBE already holds an incoming key.asc; inspect and remove it before a new scan" >&2
		exit 1 ;;
	*)
		echo "ERROR: could not check $STAGING_QUBE for an old key.asc" >&2
		exit 1 ;;
esac
# Device descriptions originate in the USB backend; strip control characters.
normal_devices="$(qvm-usb 2>/dev/null | awk -v p="$NORMAL_USB_QUBE:" 'index($1, p) == 1' | LC_ALL=C tr -cd '[:print:]\t\n')" || {
	echo "ERROR: cannot list the USB devices of $NORMAL_USB_QUBE" >&2; exit 1;
}
# A stopped backend lists nothing, which must not read as "no devices".
if ! qvm-check --running -q -- "$NORMAL_USB_QUBE"; then
	normal_devices="  ($NORMAL_USB_QUBE is not running, so its devices cannot be listed)"
fi

cat <<EOF
SEQS SEQUENTIAL-PATH QR SCAN

Controller:       dom0:$CONTROLLER
Normal backend:   $NORMAL_USB_QUBE
Webcam backend:   $WEBCAM_USB_QUBE
Scanner:          $SCANNER_QUBE
Offline staging:  $STAGING_QUBE

USB devices in $NORMAL_USB_QUBE now:
${normal_devices:-  (none)}

Only your USB keyboard and mouse, and internal devices you recorded on another
controller, may be listed above. Anything else may be an internal device that
was switched back on: do not type START.

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
if qvm-check --running -q -- "$NORMAL_USB_QUBE"; then
	qvm-shutdown --wait -- "$NORMAL_USB_QUBE"
fi
if qvm-check --running -q -- "$NORMAL_USB_QUBE"; then
	echo "ERROR: $NORMAL_USB_QUBE is still running" >&2
	exit 1
fi

echo "NORMAL USB BACKEND STOPPED. Connect only the webcam now; waiting 30 seconds."
sleep 30

# From this point every failure reaches the poweroff trap. Whether the
# controller moves with a strict PCI reset is fixed by setup; with or without
# it, sys-usb gets the controller back only after the power-off.
qvm-start -- "$WEBCAM_USB_QUBE" || {
	echo "ERROR: $WEBCAM_USB_QUBE did not start; nothing was scanned. If the message above says the device cannot be reset, see webcam_usb_no_strict_reset in the QR guide. Powering off in 60 seconds." >&2
	sleep 60
	exit 1
}
qvm-start -- "$SCANNER_QUBE"

# Wait up to 20 seconds for the webcam to be listed, then let enumeration
# settle before the final count, so a slow start does not cost a power cycle.
list_webcam_devices() {
	qvm-usb 2>/dev/null | awk -v p="$WEBCAM_USB_QUBE:" 'index($1, p) == 1 {print $1}'
}
for _ in $(seq 20); do
	[ -n "$(list_webcam_devices)" ] && break
	sleep 1
done
sleep 3
mapfile -t devices < <(list_webcam_devices)
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
# The camera node appears a moment after the USB attach; waiting for it keeps
# a slow enumeration from costing a power cycle.
scan_rc=0
if qvm-run --pass-io "$SCANNER_QUBE" \
	"set -euo pipefail; umask 077; for _ in \$(seq 15); do test -e /dev/video0 && break; sleep 1; done; timeout 180 zbarcam -q --raw --oneshot -Sdisable -Sqrcode.enable > key.asc; test -s key.asc; test \"\$(stat -c %s key.asc)\" -le 16384; qvm-copy-to-vm '$STAGING_QUBE' key.asc" \
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
