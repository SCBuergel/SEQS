#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail
# Command substitutions stop at a failure too.
shopt -s inherit_errexit

# Removes matching D-/A-/Z- qubes, or with --reset everything SEQS built;
# run with --help and use --dry-run first.

# Prefixes to check for each configured base name. Ordered by dependency so
# removal succeeds: the named disposable (D-) before the dispvm template/app
# qube (A-) it derives from, and A- before the template (Z-) it is based on.
PREFIXES=(D A Z)

# How long to wait, in seconds, for a killed qube to actually leave the
# "running" state before we give up and try qvm-remove anyway.
SHUTDOWN_TIMEOUT=30

# dom0 files that SEQS keeps per qube. The SEQS_* overrides let the test
# harness use a scratch directory.
STATE_DIR="${SEQS_STATE_DIR:-/var/lib/seqs}"
LIBVIRT_DIR="${SEQS_LIBVIRT_DIR:-/etc/qubes/templates/libvirt/xen/by-name}"
# Creation markers: written by the seqs.dom0 state before it creates a qube,
# removed once the qube carries the seqs-managed feature.
INTENTS_DIR="${STATE_DIR}/intents"
# Everything else SEQS puts into dom0, removed by --reset.
SALT_TREE="${SEQS_SALT_TREE:-/srv/salt/seqs}"
PILLAR_TREE="${SEQS_PILLAR_TREE:-/srv/pillar/seqs}"
POLICY_DIR="${SEQS_POLICY_DIR:-/etc/qubes/policy.d}"
ETC_DIR="${SEQS_ETC_DIR:-/etc/seqs}"
QR_SCRIPT="${SEQS_QR_SCRIPT:-/usr/local/sbin/seqs-qr-sequential}"
VPN_MONITOR="${SEQS_VPN_MONITOR:-/usr/local/bin/seqs-vpn-monitor}"
POLICIES=(00-seqs-qr-input-deny 01-seqs-qr-filecopy 20-seqs-gnosisvpn-updates
	28-browser-suppress 29-browser 30-user-input 50-seqs-audiovm)
DOM0_LAUNCHERS_ADDED="${XDG_CONFIG_HOME:-${HOME}/.config}/xfce4/panel/seqs-dom0-launchers"

DRY_RUN=0
RESET=0

usage() {
	cat <<EOF
Usage: $0 [--dry-run] <name> [<name> ...]
       $0 [--dry-run] --reset

Deletes qubes matching the SEQS prefix convention: for each <name>, removes
any qube called D-<name>, A-<name>, or Z-<name> that SEQS built (it carries
the seqs-managed feature, or the creation marker of an interrupted run);
same-named qubes without either are skipped. Qubes using a match as their
NetVM are preserved but disconnected (netvm set to none). If another qube uses
a match in any other setting (template, default or management disposable,
audio or GUI qube), or a match is a global default, nothing is changed.

--reset instead removes every qube SEQS built, whatever its name, and then
the files SEQS wrote in dom0: the staged Salt trees, its state directory, the
policy files and helpers it marked, and its panel launchers. It asks you to
type RESET first. sys-usb's memory setting, the window-manager shortcuts, and
your copies of the runner and this helper stay.

Options:
  --dry-run    print what would be killed/removed and exit 0
  --reset      remove everything SEQS built and wrote; takes no <name>
  -h, --help   show this message
EOF
}

# Parse options. Allowed before, between, or after positional names.
ARGS=()
while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run) DRY_RUN=1 ;;
		--reset)   RESET=1 ;;
		-h|--help) usage; exit 0 ;;
		--)        shift; ARGS+=("$@"); break ;;
		-*)        echo "ERROR: unknown option '$1'" >&2; usage >&2; exit 1 ;;
		*)         ARGS+=("$1") ;;
	esac
	shift
done

if [ "${RESET}" -eq 1 ] && [ "${#ARGS[@]}" -gt 0 ]; then
	echo "ERROR: --reset takes no name; it removes every qube SEQS built" >&2
	exit 1
fi
if [ "${RESET}" -eq 0 ] && [ "${#ARGS[@]}" -eq 0 ]; then
	usage >&2
	exit 1
fi

# isMarked FILE -- SEQS wrote FILE: its first line starts with the marker.
isMarked() {
	sudo head -n 1 -- "$1" 2>/dev/null | grep -q '^# Managed by SEQS'
}

# waitForShutdown VM [VM ...] -- poll until shutdown or SHUTDOWN_TIMEOUT.
waitForShutdown() {
	local deadline=$(( SECONDS + SHUTDOWN_TIMEOUT ))
	local vm still_running
	while [ "${SECONDS}" -lt "${deadline}" ]; do
		still_running=()
		for vm in "$@"; do
			if qvm-check --running "${vm}" &>/dev/null; then
				still_running+=("${vm}")
			fi
		done
		if [ "${#still_running[@]}" -eq 0 ]; then
			return 0
		fi
		sleep 1
	done
	echo "WARNING: still running after ${SHUTDOWN_TIMEOUT}s: ${still_running[*]}" >&2
	return 1
}

# findUsers TARGET [TARGET ...] -- print "consumer property target" for each
# reference that stops Qubes from removing a target: any qube's netvm, a
# non-target's template, default_dispvm, management_dispvm, audiovm or guivm,
# and a global default (consumer dom0). netvm users are disconnected; the
# others block the deletion.
findUsers() {
	qvm-ls --raw-data --fields name,netvm,template,default_dispvm,management_dispvm,audiovm,guivm \
			| awk -F'|' -v t=" $* " '
		{
			split("netvm template default_dispvm management_dispvm audiovm guivm", prop, " ")
			for (i = 2; i <= 7; i++)
				if ($i != "-" && $i != "" && $i != $1 && index(t, " " $i " ") \
						&& (i == 2 || !index(t, " " $1 " ")))
					print $1, prop[i - 1], $i
		}' || { echo "ERROR: could not list the qubes -- nothing was changed" >&2; return 1; }
	qubes-prefs | awk -v t=" $* " 'index(t, " " $3 " ") { print "dom0", $1, $3 }' \
		|| { echo "ERROR: could not read the global defaults -- nothing was changed" >&2; return 1; }
}

# Check every name before changing anything, so that a refusal for one name
# leaves the others untouched too.
found=()
if [ "${RESET}" -eq 1 ]; then
	# Every qube SEQS marked as its own, whatever its name: the catalogue
	# qubes, the QR camera qubes, and a GnosisVPN proxy a run left behind. A
	# qube without a marker is never touched, so an unreadable list must not
	# read as an empty one.
	echo "looking for every qube SEQS built..."
	all="$(qvm-ls --raw-list)" || { echo "ERROR: could not list the qubes -- nothing was changed" >&2; exit 1; }
	while IFS= read -r vm; do
		[ -n "${vm}" ] && [ "${vm}" != dom0 ] || continue
		[[ "${vm}" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] || { echo "  skipping '${vm}': unsafe name"; continue; }
		if [ "$(qvm-features -- "${vm}" seqs-managed 2>/dev/null)" = "1" ] \
			|| [ "$(qvm-features -- "${vm}" seqs-gnosisvpn-temporary-proxy 2>/dev/null)" = "1" ]; then
			found+=("${vm}")
		elif sudo test -e "${INTENTS_DIR}/${vm}"; then
			echo "  ${vm}: no seqs-managed feature, but an interrupted SEQS build left its creation marker"
			found+=("${vm}")
		fi
	done <<< "${all}"
fi
for app in "${ARGS[@]}"; do
	# Reject anything that isn't a safe identifier. $app is interpolated into
	# qube names and passed straight to qvm-remove -f, so a value like '.*'
	# or '-h' must never reach the match loop below. First char must be
	# alphanumeric or underscore so '.', '..', and leading '-' are rejected.
	if ! [[ "${app}" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]; then
		echo "ERROR: refusing unsafe name '${app}' (allowed: [A-Za-z0-9_][A-Za-z0-9._-]*)" >&2
		exit 1
	fi

	# Build the kill list by literal name + existence check -- no regex. A
	# same-named qube that SEQS did not build (no seqs-managed feature and no
	# creation marker from an interrupted run) is never touched.
	echo "looking for qubes matching ${PREFIXES[*]/%/-${app}}..."
	for prefix in "${PREFIXES[@]}"; do
		candidate="${prefix}-${app}"
		qvm-check "${candidate}" &>/dev/null || continue
		if [ "$(qvm-features -- "${candidate}" seqs-managed 2>/dev/null)" = "1" ]; then
			found+=("${candidate}")
		elif sudo test -e "${INTENTS_DIR}/${candidate}"; then
			echo "  ${candidate}: no seqs-managed feature, but an interrupted SEQS build left its creation marker"
			found+=("${candidate}")
		else
			echo "  skipping ${candidate}: SEQS did not build it (no seqs-managed feature or creation marker)"
		fi
	done
done

if [ "${#found[@]}" -eq 0 ] && [ "${RESET}" -eq 0 ]; then
	echo "  no qubes match"
	exit 0
fi
[ "${#found[@]}" -eq 0 ] || { echo "found:"; printf '  %s\n' "${found[@]}"; }

netvm_users=()
blockers=()
users="$(findUsers "${found[@]}")"
while read -r consumer prop provider; do
	case "${prop:-}" in
		'') ;;
		netvm) netvm_users+=("${consumer} ${provider}") ;;
		*) blockers+=("${consumer} has ${prop} ${provider}") ;;
	esac
done <<< "${users}"
if [ "${#blockers[@]}" -gt 0 ]; then
	echo "ERROR: nothing was changed; these use a target, so remove them or change the property first:" >&2
	printf '  %s\n' "${blockers[@]}" >&2
	exit 1
fi
if [ "${#netvm_users[@]}" -gt 0 ]; then
	echo "qubes using a target as netvm:"
	for pair in "${netvm_users[@]}"; do
		read -r consumer provider <<< "${pair}"
		echo "  ${consumer} -> ${provider}"
	done
fi

if [ "${RESET}" -eq 1 ]; then
	echo "SEQS files in dom0 to remove:"
	for f in "${SALT_TREE}" "${PILLAR_TREE}" "${STATE_DIR}" "${ETC_DIR}" "${QR_SCRIPT}" "${VPN_MONITOR}"; do
		! sudo test -e "${f}" || echo "  ${f}"
	done
	for p in "${POLICIES[@]}"; do
		! sudo test -e "${POLICY_DIR}/${p}.policy" || echo "  ${POLICY_DIR}/${p}.policy"
	done
fi
if [ "${DRY_RUN}" -eq 1 ]; then
	echo "  (dry-run: not killing or removing)"
	for pair in "${netvm_users[@]}"; do
		read -r consumer provider <<< "${pair}"
		echo "  (dry-run: would set ${consumer} netvm to none)"
	done
	exit 0
fi
if [ "${RESET}" -eq 1 ]; then
	# A typed word, from the terminal only: a piped answer must not count.
	read -rp "Type RESET to delete these qubes with their data and the SEQS files in dom0: " answer </dev/tty \
		|| { echo "ERROR: no terminal available to confirm -- nothing was changed" >&2; exit 1; }
	[ "${answer}" = RESET ] || { echo "not confirmed -- nothing was changed" >&2; exit 1; }
fi

# qvm-remove refuses to remove a NetVM in use. Preserve the consumers, but
# disconnect them explicitly.
if [ "${#netvm_users[@]}" -gt 0 ]; then
	echo "disconnecting netvm users..."
	for pair in "${netvm_users[@]}"; do
		read -r consumer provider <<< "${pair}"
		qvm-prefs -- "${consumer}" netvm none
	done
fi

# Surface kill errors before attempting removal.
echo "killing..."
for vm in "${found[@]}"; do
	qvm-kill "${vm}" || echo "  qvm-kill ${vm} failed (continuing)" >&2
done

echo "waiting for qubes to shut down..."
waitForShutdown "${found[@]}" || true

# Qubes refuses to remove a qube that another one still uses as its template,
# NetVM, default or management disposable, audio or GUI qube, so each pass
# removes the qubes no remaining target refers to.
echo "removing..."
rows="$(qvm-ls --raw-data --fields name,netvm,template,default_dispvm,management_dispvm,audiovm,guivm)" \
	|| { echo "ERROR: could not list the qubes" >&2; exit 1; }
remaining=("${found[@]}")
while [ "${#remaining[@]}" -gt 0 ]; do
	pass=()
	keep=()
	for vm in "${remaining[@]}"; do
		if awk -F'|' -v r=" ${remaining[*]} " -v t="${vm}" \
				'$1 != t && index(r, " " $1 " ") { for (i = 2; i <= 7; i++) if ($i == t) exit 1 }' <<< "${rows}"; then
			pass+=("${vm}")
		else
			keep+=("${vm}")
		fi
	done
	[ "${#pass[@]}" -gt 0 ] || { echo "ERROR: these qubes refer to each other in a cycle: ${remaining[*]}" >&2; exit 1; }
	for vm in "${pass[@]}"; do
		qvm-remove "${vm}" -f
	done
	remaining=("${keep[@]}")
done

# dom0 files SEQS wrote for a removed qube: its CPU pinning or creation
# marker would apply to a later qube of the same name, and its recorded
# firewall is stale.
for vm in "${found[@]}"; do
	pin="${LIBVIRT_DIR}/${vm}.xml"
	# The directory is readable by root only.
	if sudo head -n 1 -- "${pin}" 2>/dev/null | grep -q 'Managed by SEQS'; then
		sudo rm -f -- "${pin}"
	fi
	sudo rm -f -- "${STATE_DIR}/firewall/${vm}" "${INTENTS_DIR}/${vm}"
done

# dropPanelPlugin N -- take panel plugin N off every panel and delete its
# settings and files.
dropPanelPlugin() {
	local panel i ids
	for panel in $(xfconf-query -c xfce4-panel -p /panels | tail -n +3); do
		ids=()
		for i in $(xfconf-query -c xfce4-panel -p "/panels/panel-${panel}/plugin-ids" | tail -n +3); do
			[ "${i}" = "$1" ] || ids+=(-t int -s "${i}")
		done
		if [ "${#ids[@]}" -gt 0 ]; then
			xfconf-query -c xfce4-panel -p "/panels/panel-${panel}/plugin-ids" -n -a "${ids[@]}"
		else
			xfconf-query -c xfce4-panel -p "/panels/panel-${panel}/plugin-ids" -r
		fi
	done
	xfconf-query -c xfce4-panel -p "/plugins/plugin-$1" -r -R
	rm -rf -- "${XDG_CONFIG_HOME:-${HOME}/.config}/xfce4/panel/launcher-$1"
}

# Panel entries that start a removed qube would start nothing. The launcher
# and VPN monitor setup-qubes.sh added name their qube in a seqs-qube or
# seqs-monitor property and go entirely. In any other launcher, such as one
# the user added, each entry whose menu file names a removed qube in its
# X-Qubes-VmName line goes, and the launcher goes once it has none left.
# A reset also drops every plugin SEQS marked, including the launchers for
# dom0 programs (seqs-dom0), whether or not its qube still existed.
removePanelPlugins() {
	local pid v prop p vm item dir keep gone removed=0
	command -v xfconf-query >/dev/null 2>&1 || return 0
	pid="$(pgrep -u "$(id -u)" -x xfce4-panel | head -n 1)" && [ -n "${pid}" ] || return 0
	# This may run outside the graphical session: use the panel's display and bus.
	while IFS= read -r -d '' v; do
		case "${v}" in DISPLAY=* | DBUS_SESSION_BUS_ADDRESS=*) export "${v?}" ;; esac
	done < "/proc/${pid}/environ"
	for prop in $(xfconf-query -c xfce4-panel -l | grep -E '^/plugins/plugin-[0-9]+/seqs-(qube|monitor|dom0)$'); do
		vm="$(xfconf-query -c xfce4-panel -p "${prop}")"
		[[ " ${found[*]} " == *" ${vm} "* ]] || [ "${RESET}" -eq 1 ] || continue
		p="${prop#/plugins/plugin-}"
		dropPanelPlugin "${p%/seqs-*}"
		echo "removed a panel plugin of ${vm}"
		removed=1
	done
	for prop in $(xfconf-query -c xfce4-panel -l | grep -E '^/plugins/plugin-[0-9]+/items$'); do
		p="${prop#/plugins/plugin-}"
		p="${p%/items}"
		dir="${XDG_CONFIG_HOME:-${HOME}/.config}/xfce4/panel/launcher-${p}"
		keep=()
		gone=0
		while IFS= read -r item; do
			[ -n "${item}" ] || continue
			vm=""
			# An item with a path is not a file XFCE copied from a qube's menu into
			# the launcher's own directory: leave it alone.
			[[ "${item}" == */* ]] || vm="$(sed -n 's/^X-Qubes-VmName=//p' -- "${dir}/${item}" 2>/dev/null | head -n 1)"
			if [ -n "${vm}" ] && [[ " ${found[*]} " == *" ${vm} "* ]]; then
				rm -f -- "${dir}/${item}"
				echo "removed the panel entry ${item} of ${vm}"
				gone=1
			else
				keep+=(-t string -s "${item}")
			fi
		done < <(xfconf-query -c xfce4-panel -p "${prop}" | tail -n +3)
		[ "${gone}" -eq 1 ] || continue
		if [ "${#keep[@]}" -eq 0 ]; then
			dropPanelPlugin "${p}"
		else
			xfconf-query -c xfce4-panel -p "${prop}" -n -a "${keep[@]}"
		fi
		removed=1
	done
	[ "${removed}" -eq 0 ] || xfce4-panel -r
}
removePanelPlugins || echo "WARNING: could not remove every panel plugin of the removed qubes" >&2

[ "${RESET}" -eq 1 ] || exit 0

# The files SEQS wrote in dom0. A policy or helper under a SEQS name that
# does not carry the SEQS marker was written by the operator: it stays, and
# the reset reports it.
echo "removing the SEQS files in dom0..."
left=0
sudo qubesctl top.disable seqs.config pillar=true >/dev/null 2>&1 \
	|| { echo "WARNING: could not disable the SEQS pillar: run 'sudo qubesctl top.disable seqs.config pillar=true'" >&2; left=1; }
for p in "${POLICIES[@]}"; do
	f="${POLICY_DIR}/${p}.policy"
	sudo test -e "${f}" || continue
	if isMarked "${f}"; then
		sudo rm -f -- "${f}"
	else
		echo "WARNING: ${f} was not written by SEQS; left in place" >&2
		left=1
	fi
done
for f in "${QR_SCRIPT}" "${VPN_MONITOR}"; do
	sudo test -e "${f}" || continue
	if sudo head -n 2 -- "${f}" 2>/dev/null | grep -q 'SEQS'; then
		sudo rm -f -- "${f}"
	else
		echo "WARNING: ${f} was not written by SEQS; left in place" >&2
		left=1
	fi
done
sudo rm -rf -- "${SALT_TREE}" "${PILLAR_TREE}" "${STATE_DIR}" "${ETC_DIR}"
rm -f -- "${DOM0_LAUNCHERS_ADDED}"
if [[ " ${found[*]} " == *" sys-usb-webcam "* ]]; then
	echo "NOTE: on the dedicated-controller QR path, the webcam's USB controller now belongs to no qube;"
	echo "      the recovery steps in docs/secure-qr-transfer.md give it back to sys-usb."
fi
echo "Left as they were: sys-usb's memory setting, the window-manager shortcuts, and your copies of"
echo "setup-qubes.sh and delete-vms.sh in dom0 (such as ~/s.sh and ~/d.sh); delete those yourself."
if [ "${left}" -eq 1 ]; then
	echo "SEQS reset finished with the files reported above left in place." >&2
	exit 1
fi
echo "SEQS reset complete."
