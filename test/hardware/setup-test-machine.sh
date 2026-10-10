#!/usr/bin/env bash

# SEQS hardware test machine: remote dom0 control for a DEDICATED test box.
#
# THIS SCRIPT DELIBERATELY BREAKS QUBES ISOLATION. It creates a networked
# control qube (test-ctl) that accepts SSH from a LAN range and may run any
# shell command in dom0. Run it only in the dom0 of a machine that holds no
# real secrets and is used for nothing but testing. Never run it on a Qubes
# installation you use for real work. See test/hardware/README.md.
#
# Usage:
#   setup-test-machine.sh [--ssh-keys-url URL | --ssh-key-file PATH]
#                         [--allow-from CIDR] [--port PORT] [--template TEMPLATE]
#                         [--no-autologin]
#   setup-test-machine.sh --remove
#
# Without a key option, the SSH public key is read from a QR code with a USB
# webcam: the laptop shows "seqs-test-v1 <public key line>" as a QR code.
# Without --allow-from, the LAN range is sys-net's own network.
#
# What it sets up (all idempotent; rerun to change the CIDR, port, or keys):
#   1. test-ctl: a StandaloneVM with netvm sys-net, sshd (key-only), autostart,
#      and a `dom0` command that forwards its input to seqs.TestShell.
#   2. sys-net: a DNAT rule forwarding PORT from CIDR to test-ctl:22, persisted
#      in sys-net's /rw/config/rc.local.
#   3. dom0: the qrexec service seqs.TestShell (runs stdin as a bash script as
#      the dom0 user) and a policy that allows only test-ctl to call it.
#   4. dom0 (unless --no-autologin): desktop autologin and no screen blanking,
#      so qubes can show windows (e.g. the QR code) after an unattended boot.

set -uo pipefail

CTL_VM="test-ctl"
CTL_FEATURE="seqs-test-control"
MARKER="Managed by SEQS test machine setup"
BLOCK_BEGIN="# BEGIN seqs-test-control"
BLOCK_END="# END seqs-test-control"
RPC_SERVICE="seqs.TestShell"
RPC_FILE="/etc/qubes-rpc/${RPC_SERVICE}"
POLICY_FILE="/etc/qubes/policy.d/20-seqs-test-control.policy"
LIGHTDM_FILE="/etc/lightdm/lightdm.conf.d/50-seqs-test-autologin.conf"
AUTOSTART_FILE="${HOME}/.config/autostart/seqs-test-noblank.desktop"
NET_VM="sys-net"
NAT_TABLE="seqs-test-control"
QR_PREFIX="seqs-test-v1 "

# ---- Helpers ----------------------------------------------------------------

# sanitize -- strip terminal-control bytes from qube output shown in dom0
# (same filter as setup-qubes.sh).
sanitize() {
	LC_ALL=C tr -d '\000-\010\013-\037\177' \
		| iconv -f UTF-8 -t UTF-8 -c \
		| LC_ALL=C sed -E $'s/\xc2[\x80-\x9f]//g'
}

die() {
	printf 'ERROR: %s\n' "$*" | sanitize >&2
	exit 1
}

# validCidr CIDR -- IPv4 network with a prefix of /8 or longer, so a typo can
# not open the control path to the whole internet.
validCidr() {
	local ip prefix
	[[ "$1" =~ ^([0-9]{1,3}(\.[0-9]{1,3}){3})/([0-9]{1,2})$ ]] || return 1
	ip="${BASH_REMATCH[1]}"
	prefix="${BASH_REMATCH[3]}"
	[ "$((10#${prefix}))" -ge 8 ] && [ "$((10#${prefix}))" -le 32 ] || return 1
	validIpv4 "${ip}"
}

validIpv4() {
	local o
	[[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
	for o in ${1//./ }; do
		[ "$((10#${o}))" -le 255 ] || return 1
	done
}

validPort() {
	[[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$((10#$1))" -ge 1 ] && [ "$((10#$1))" -le 65535 ]
}

# validUrl URL -- https only, and no quote, space, or shell metacharacter, so
# the value can be placed in single quotes in a qube-side script.
validUrl() {
	[[ "$1" =~ ^https://[A-Za-z0-9._~:/?=\&%+@-]+$ ]]
}

validVmName() {
	[[ "$1" =~ ^[A-Za-z][A-Za-z0-9_.-]{0,30}$ ]]
}

validUser() {
	[[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

# validKeys FILE -- every non-empty, non-comment line is one public key in
# authorized_keys format without options, and there is at least one.
validKeys() {
	local LC_ALL=C line n=0
	local re='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/]+={0,3}( [[:print:]]*)?$'
	while IFS= read -r line || [ -n "${line}" ]; do
		case "${line}" in ''|'#'*) continue ;; esac
		[[ "${line}" =~ ${re} ]] || return 1
		n=$((n + 1))
	done < "$1"
	[ "${n}" -gt 0 ]
}

# networkOf IP PREFIX -- the network address in CIDR form, e.g.
# 192.168.1.50 24 -> 192.168.1.0/24.
networkOf() {
	local a b c d n mask
	IFS=. read -r a b c d <<< "$1"
	n=$(( (10#${a} << 24) | (10#${b} << 16) | (10#${c} << 8) | 10#${d} ))
	mask=$(( (0xFFFFFFFF << (32 - $2)) & 0xFFFFFFFF ))
	n=$(( n & mask ))
	printf '%d.%d.%d.%d/%d\n' $(( n >> 24 & 255 )) $(( n >> 16 & 255 )) \
		$(( n >> 8 & 255 )) $(( n & 255 )) "$2"
}

# parseQrPayload TEXT -- print the key line from a scanned QR code, or fail
# if the code is not one the README tells the operator to show.
parseQrPayload() {
	local p="${1%%$'\n'*}"
	p="${p%$'\r'}"
	[[ "${p}" == "${QR_PREFIX}"* ]] || return 1
	printf '%s\n' "${p#"${QR_PREFIX}"}"
}

# confirmPhrase -- the operator types the phrase; piped stdin never counts.
confirmPhrase() {
	local answer
	printf '%s\n' \
		"This turns THIS Qubes installation into a remotely controlled test machine:" \
		"anyone holding one of the SSH keys and reaching ${NET_VM} from ${ALLOW_FROM:-the LAN}" \
		"can run any command in dom0. Do this only on a dedicated test machine."
	if ! read -rp "Type TEST MACHINE to continue: " answer </dev/tty; then
		die "no terminal available to confirm -- aborting."
	fi
	[ "${answer}" = "TEST MACHINE" ] || die "not confirmed -- aborting."
}

# installRoot MODE DEST -- install stdin as a root-owned file.
installRoot() {
	local tmp
	tmp="$(mktemp)" || die "mktemp failed"
	cat > "${tmp}"
	sudo install -D -o root -g root -m "$1" "${tmp}" "$2" || { rm -f "${tmp}"; die "cannot write $2"; }
	rm -f "${tmp}"
}

# refuseUnmarked FILE -- never overwrite a file this script did not write.
refuseUnmarked() {
	if sudo test -e "$1" && ! sudo grep -qF "${MARKER}" "$1"; then
		die "$1 exists and was not written by this script -- move it away first."
	fi
}

# runIn VM USER -- run stdin as a bash script in VM; output sanitized.
runIn() {
	qvm-run --pass-io --no-gui -u "$2" "$1" 'bash -s' 2>&1 | sanitize
	return "${PIPESTATUS[0]}"
}

# ---- Steps ------------------------------------------------------------------

checkDom0() {
	[ "$(hostname)" = "dom0" ] && command -v qvm-prefs >/dev/null \
		|| die "run this in dom0 of the test machine."
	[ "$(id -u)" -ne 0 ] || die "run as the normal dom0 user, not root (sudo is used where needed)."
	validUser "${DOM0_USER}" || die "unexpected dom0 user name '${DOM0_USER}'."
	[ "$(qvm-prefs -- "${NET_VM}" klass 2>/dev/null)" = "AppVM" ] \
		|| die "${NET_VM} must be a persistent AppVM (a disposable ${NET_VM} would lose the forwarding rule)."
}

# pickTemplate -- debian-13-xfce if installed, else the newest debian-N
# template; test-ctl needs apt.
pickTemplate() {
	local names
	names="$(qvm-ls --raw-data --fields name,class 2>/dev/null | awk -F'|' '$2 == "TemplateVM" { print $1 }')"
	if grep -qx 'debian-13-xfce' <<< "${names}"; then
		echo "debian-13-xfce"
		return
	fi
	grep -E '^debian-[0-9]+(-xfce)?$' <<< "${names}" | sort -t- -k2,2n | tail -n 1
}

# detectLan -- set LAN_IP to sys-net's address on its uplink and, unless
# --allow-from was given, ALLOW_FROM to that network.
detectLan() {
	local addr
	# shellcheck disable=SC2016 # expanded in sys-net, not here
	addr="$(qvm-run --pass-io --no-gui "${NET_VM}" \
		'ip -4 -o addr show dev "$(ip -4 -o route get 1.1.1.1 | sed -nE "s/.* dev ([^ ]+).*/\1/p")"' \
		2>/dev/null | sanitize | sed -nE 's/.* inet ([0-9.]+)\/([0-9]+) .*/\1 \2/p' | head -n 1)"
	LAN_IP="${addr% *}"
	if ! validIpv4 "${LAN_IP}"; then
		LAN_IP=""
		[ -n "${ALLOW_FROM}" ] || die "${NET_VM} has no LAN address -- connect the network cable, or pass --allow-from."
		return
	fi
	if [ -z "${ALLOW_FROM}" ]; then
		ALLOW_FROM="$(networkOf "${LAN_IP}" "${addr#* }")"
	fi
}

# scanQr -- attach a USB webcam to test-ctl, read one QR code with zbarcam,
# and put the key line it carries into KEYS_FILE.
scanQr() {
	local line id desc choice payload i
	local -a ids=() descs=() cams=()
	while IFS= read -r line; do
		id="${line%% *}"
		desc="$(sed -E 's/^[^ ]+ +//' <<< "${line}")"
		[[ "${id}" =~ ^[A-Za-z0-9_.:-]+$ ]] || continue
		ids+=("${id}")
		descs+=("${desc}")
		if grep -qiE 'cam|video|uvc' <<< "${desc}"; then
			cams+=("$(( ${#ids[@]} - 1 ))")
		fi
	done < <(qvm-usb list 2>/dev/null | sanitize | tail -n +2)
	[ "${#ids[@]}" -gt 0 ] || die "no USB devices found -- plug in the webcam (or pass --ssh-keys-url)."
	if [ "${#cams[@]}" -eq 1 ]; then
		i="${cams[0]}"
	else
		echo "==> USB devices:"
		for i in "${!ids[@]}"; do
			printf '    %d) %s  %s\n' "$(( i + 1 ))" "${ids[i]}" "${descs[i]}"
		done
		read -rp "Number of the webcam: " choice </dev/tty || die "no terminal -- aborting."
		[[ "${choice}" =~ ^[0-9]+$ ]] && [ "${choice}" -ge 1 ] && [ "${choice}" -le "${#ids[@]}" ] \
			|| die "no such device: ${choice}"
		i="$(( choice - 1 ))"
	fi
	echo "==> Using webcam ${ids[i]}  ${descs[i]}"
	qvm-usb attach "${CTL_VM}" "${ids[i]}" || die "cannot attach ${ids[i]} to ${CTL_VM}."
	echo "==> Hold the QR code from your laptop in front of the webcam (2 minutes)..."
	payload="$(qvm-run --pass-io --no-gui "${CTL_VM}" \
		'for i in $(seq 15); do [ -e /dev/video0 ] && break; sleep 1; done
		 timeout 120 zbarcam --nodisplay --oneshot --raw -Sdisable -Sqrcode.enable /dev/video0' \
		2>/dev/null | head -c 4096)"
	qvm-usb detach "${CTL_VM}" "${ids[i]}" 2>/dev/null || true
	[ -n "${payload}" ] || die "no QR code read -- rerun the script to try again."
	parseQrPayload "${payload}" > "${KEYS_FILE}" \
		|| die "that QR code is not a SEQS test key; show the code from the README."
}

# readKeys -- put the validated public keys into KEYS_FILE.
readKeys() {
	if [ -z "${KEY_FILE}" ] && [ -z "${KEYS_URL}" ]; then
		scanQr
	elif [ -n "${KEY_FILE}" ]; then
		[ -f "${KEY_FILE}" ] || die "no such key file: ${KEY_FILE}"
		head -c 65536 "${KEY_FILE}" > "${KEYS_FILE}"
	else
		echo "==> Fetching SSH keys in ${CTL_VM} from ${KEYS_URL}"
		# The URL passed validUrl, so it cannot leave the single quotes.
		qvm-run --pass-io --no-gui "${CTL_VM}" \
			"curl -fsSL --proto '=https' --max-time 30 '${KEYS_URL}' | head -c 65536" \
			> "${KEYS_FILE}" 2>/dev/null || die "fetching ${KEYS_URL} failed."
	fi
	validKeys "${KEYS_FILE}" || die "the keys are not plain OpenSSH public keys, one per line."
	echo "==> Keys that will be able to control dom0:"
	# test-ctl computes the fingerprints if dom0 has no ssh-keygen; the keys
	# are already validated, and the output is only displayed.
	if command -v ssh-keygen >/dev/null; then
		ssh-keygen -lf "${KEYS_FILE}" 2>&1 | sanitize
	else
		qvm-run --pass-io --no-gui "${CTL_VM}" 'ssh-keygen -lf /dev/stdin' < "${KEYS_FILE}" 2>&1 | sanitize
	fi
}

createCtl() {
	if qvm-check --quiet -- "${CTL_VM}" 2>/dev/null; then
		[ "$(qvm-features -- "${CTL_VM}" "${CTL_FEATURE}" 2>/dev/null)" = "1" ] \
			|| die "a qube named ${CTL_VM} exists but was not created by this script."
		echo "==> ${CTL_VM} exists; updating it"
	else
		qvm-check --quiet -- "${TEMPLATE}" 2>/dev/null || die "template ${TEMPLATE} does not exist."
		echo "==> Creating ${CTL_VM} (StandaloneVM from ${TEMPLATE})"
		qvm-create --class StandaloneVM --template "${TEMPLATE}" --label purple -- "${CTL_VM}" \
			|| die "qvm-create ${CTL_VM} failed."
		qvm-features -- "${CTL_VM}" "${CTL_FEATURE}" 1
	fi
	qvm-prefs -- "${CTL_VM}" netvm "${NET_VM}" || die "cannot set ${CTL_VM} netvm."
	qvm-prefs -- "${CTL_VM}" autostart True || die "cannot set ${CTL_VM} autostart."
	CTL_IP="$(qvm-prefs -- "${CTL_VM}" ip)"
	validIpv4 "${CTL_IP}" || die "unexpected IP for ${CTL_VM}: ${CTL_IP}"
}

configureCtl() {
	echo "==> Installing and configuring sshd in ${CTL_VM}"
	# A StandaloneVM keeps its root filesystem, so packages and sshd config
	# persist. The proxy overrides make apt use the direct network even if the
	# template's Qubes updates-proxy configuration was cloned along.
	runIn "${CTL_VM}" root <<EOF || die "configuring ${CTL_VM} failed."
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get -o Acquire::http::Proxy=false -o Acquire::https::Proxy=false update -q
apt-get -o Acquire::http::Proxy=false -o Acquire::https::Proxy=false install -y -q openssh-server curl zbar-tools git
cat > /usr/local/bin/dom0 <<'CMD'
#!/bin/sh
# ${MARKER}
# dom0 [COMMAND...] -- run COMMAND, or the script on standard input, in dom0.
if [ "\$#" -gt 0 ]; then
	printf '%s\\n' "\$*" | qrexec-client-vm dom0 ${RPC_SERVICE}
else
	exec qrexec-client-vm dom0 ${RPC_SERVICE}
fi
CMD
chmod 755 /usr/local/bin/dom0
cat > /etc/ssh/sshd_config.d/50-seqs-test-control.conf <<'CONF'
# ${MARKER}
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers user
CONF
systemctl enable ssh
systemctl restart ssh
f=/rw/config/rc.local
[ -s "\$f" ] || printf '#!/bin/sh\\n' > "\$f"
awk -v b='${BLOCK_BEGIN}' -v e='${BLOCK_END}' '\$0==b{s=1;next} \$0==e{s=0;next} !s{print}' "\$f" > "\$f.new"
cat >> "\$f.new" <<'BLOCK'
${BLOCK_BEGIN}
nft list chain ip qubes custom-input 2>/dev/null | grep -q seqs-test-control \\
  || nft add rule ip qubes custom-input ip saddr ${ALLOW_FROM} tcp dport 22 accept comment '"seqs-test-control"'
${BLOCK_END}
BLOCK
mv "\$f.new" "\$f"
chmod 755 "\$f"
# Apply now: drop an older rule (the CIDR may have changed), then add.
for h in \$(nft -a list chain ip qubes custom-input | awk '/seqs-test-control/ {print \$NF}'); do
  nft delete rule ip qubes custom-input handle "\$h"
done
nft add rule ip qubes custom-input ip saddr ${ALLOW_FROM} tcp dport 22 accept comment '"seqs-test-control"'
EOF
}

installKeys() {
	echo "==> Installing authorized keys for user in ${CTL_VM}"
	qvm-run --pass-io --no-gui "${CTL_VM}" \
		'umask 077; mkdir -p ~/.ssh && cat > ~/.ssh/authorized_keys' < "${KEYS_FILE}" \
		|| die "writing authorized_keys failed."
}

# netBlock -- the sys-net rules, as a script for rc.local and for applying now.
netBlock() {
	cat <<EOF
${BLOCK_BEGIN}
nft delete table ip ${NAT_TABLE} 2>/dev/null || true
nft add table ip ${NAT_TABLE}
nft add chain ip ${NAT_TABLE} prerouting '{ type nat hook prerouting priority dstnat; policy accept; }'
nft add rule ip ${NAT_TABLE} prerouting iifname != "vif*" ip saddr ${ALLOW_FROM} tcp dport ${PORT} dnat to ${CTL_IP}:22
for h in \$(nft -a list chain ip qubes custom-forward | awk '/seqs-test-control/ {print \$NF}'); do
  nft delete rule ip qubes custom-forward handle "\$h"
done
nft add rule ip qubes custom-forward iifname != "vif*" ip saddr ${ALLOW_FROM} ip daddr ${CTL_IP} tcp dport 22 accept comment '"seqs-test-control"'
${BLOCK_END}
EOF
}

# configureNet MODE -- MODE is "install" or "remove".
configureNet() {
	local block
	if [ "$1" = "install" ]; then
		block="$(netBlock)"
		echo "==> Forwarding ${ALLOW_FROM} -> ${NET_VM}:${PORT} -> ${CTL_VM}:22"
	else
		block=""
		echo "==> Removing the forwarding rules from ${NET_VM}"
	fi
	# The block goes into rc.local for later boots and is applied now on its
	# own; rerunning all of rc.local could repeat unrelated operator commands.
	runIn "${NET_VM}" root <<EOF || die "configuring ${NET_VM} failed."
set -e
f=/rw/config/rc.local
cur=/run/seqs-test-control.sh
cat > "\$cur" <<'BLOCK'
${block}
BLOCK
[ -s "\$f" ] || printf '#!/bin/sh\\n' > "\$f"
awk -v b='${BLOCK_BEGIN}' -v e='${BLOCK_END}' '\$0==b{s=1;next} \$0==e{s=0;next} !s{print}' "\$f" > "\$f.new"
cat "\$cur" >> "\$f.new"
mv "\$f.new" "\$f"
chmod 755 "\$f"
nft delete table ip ${NAT_TABLE} 2>/dev/null || true
for h in \$(nft -a list chain ip qubes custom-forward | awk '/seqs-test-control/ {print \$NF}'); do
  nft delete rule ip qubes custom-forward handle "\$h"
done
sh -e "\$cur"
rm -f "\$cur"
EOF
}

configureDom0() {
	refuseUnmarked "${RPC_FILE}"
	refuseUnmarked "${POLICY_FILE}"
	echo "==> Installing qrexec service ${RPC_SERVICE} and its policy"
	# qrexec may start dom0 services as root; drop to the dom0 user either way
	# so commands run exactly as they would in an operator's dom0 terminal.
	installRoot 0755 "${RPC_FILE}" <<EOF
#!/bin/bash
# ${MARKER} -- runs stdin as a bash script in dom0. Test machines only.
exec 2>&1
if [ "\$(id -u)" -eq 0 ]; then
	exec runuser -u ${DOM0_USER} -- env HOME=/home/${DOM0_USER} USER=${DOM0_USER} LOGNAME=${DOM0_USER} /bin/bash -s
fi
exec /bin/bash -s
EOF
	installRoot 0644 "${POLICY_FILE}" <<EOF
# ${MARKER} -- remote dom0 control. Test machines only.
${RPC_SERVICE}  *  ${CTL_VM}  @adminvm  allow
${RPC_SERVICE}  *  @anyvm     @anyvm    deny
EOF
}

configureDesktop() {
	refuseUnmarked "${LIGHTDM_FILE}"
	echo "==> Enabling desktop autologin for ${DOM0_USER} and disabling screen blanking"
	installRoot 0644 "${LIGHTDM_FILE}" <<EOF
# ${MARKER}
[Seat:*]
autologin-user=${DOM0_USER}
autologin-user-timeout=0
EOF
	mkdir -p "$(dirname "${AUTOSTART_FILE}")"
	cat > "${AUTOSTART_FILE}" <<EOF
# ${MARKER}
[Desktop Entry]
Type=Application
Name=SEQS test: no screen blanking
Exec=sh -c 'sleep 5; xset s off -dpms; xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-enabled -n -t bool -s false; xscreensaver-command -exit'
EOF
}

# selfTest -- call the service from test-ctl, as a remote client would.
selfTest() {
	local out
	echo "==> Self-test: ${CTL_VM} -> dom0 via ${RPC_SERVICE}"
	out="$(qvm-run --pass-io --no-gui "${CTL_VM}" \
		"echo 'echo seqs-test-ok \$(hostname)' | qrexec-client-vm dom0 ${RPC_SERVICE}" 2>&1 | sanitize)"
	[ "${out}" = "seqs-test-ok dom0" ] || die "self-test failed; output: ${out}"
	echo "    ok"
}

summary() {
	local hostkey
	hostkey="$(qvm-run --pass-io --no-gui "${CTL_VM}" \
		'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub' 2>/dev/null | sanitize | awk '{ print $2 }')"
	cat <<EOF

==> Done. Write these down for your laptop:
      address   ${LAN_IP:-<${NET_VM} LAN address>}
      port      ${PORT}
      host key  ${hostkey:-<unknown>}
    Connections are accepted from ${ALLOW_FROM}.
EOF
	if [ "${AUTOLOGIN}" -eq 1 ]; then
		echo "    Reboot once so that the desktop logs in automatically."
	fi
}

removeAll() {
	echo "==> Removing test machine control"
	if qvm-check --quiet -- "${CTL_VM}" 2>/dev/null; then
		[ "$(qvm-features -- "${CTL_VM}" "${CTL_FEATURE}" 2>/dev/null)" = "1" ] \
			|| die "a qube named ${CTL_VM} exists but was not created by this script; not removing it."
		qvm-kill -- "${CTL_VM}" 2>/dev/null || true
		qvm-remove --force -- "${CTL_VM}" || die "qvm-remove ${CTL_VM} failed."
	fi
	configureNet remove
	local f
	for f in "${POLICY_FILE}" "${RPC_FILE}" "${LIGHTDM_FILE}"; do
		if sudo test -e "${f}"; then
			sudo grep -qF "${MARKER}" "${f}" || die "${f} was not written by this script; not removing it."
			sudo rm -f -- "${f}"
		fi
	done
	if [ -f "${AUTOSTART_FILE}" ] && grep -qF "${MARKER}" "${AUTOSTART_FILE}"; then
		rm -f -- "${AUTOSTART_FILE}"
	fi
	echo "==> Removed. Reboot to end the autologin session."
}

# ---- Main -------------------------------------------------------------------

# Test hook: source helpers without running anything.
if [ "${SEQS_SOURCE_ONLY:-0}" = "1" ]; then
	return 0 2>/dev/null || true
fi

ALLOW_FROM=""
KEYS_URL=""
KEY_FILE=""
PORT=2222
TEMPLATE=""
LAN_IP=""
AUTOLOGIN=1
REMOVE=0
DOM0_USER="$(id -un)"
while [ "$#" -gt 0 ]; do
	case "$1" in
		--allow-from|--ssh-keys-url|--ssh-key-file|--port|--template)
			[ "$#" -gt 1 ] || die "$1 requires a value"
			case "$1" in
				--allow-from) ALLOW_FROM="$2" ;;
				--ssh-keys-url) KEYS_URL="$2" ;;
				--ssh-key-file) KEY_FILE="$2" ;;
				--port) PORT="$2" ;;
				--template) TEMPLATE="$2" ;;
			esac
			shift
			;;
		--no-autologin) AUTOLOGIN=0 ;;
		--remove) REMOVE=1 ;;
		-h|--help) sed -n '3,29p' "$0"; exit 0 ;;
		*) die "unknown argument '$1' (see --help)" ;;
	esac
	shift
done

checkDom0

if [ "${REMOVE}" -eq 1 ]; then
	removeAll
	exit 0
fi

validPort "${PORT}" || die "--port must be 1-65535."
PORT="$((10#${PORT}))"
[ -n "${TEMPLATE}" ] || TEMPLATE="$(pickTemplate)"
[ -n "${TEMPLATE}" ] || die "no Debian template installed -- run: qvm-template install debian-13-xfce"
validVmName "${TEMPLATE}" || die "invalid template name."
if [ -n "${KEYS_URL}" ] && [ -n "${KEY_FILE}" ]; then
	die "use either --ssh-keys-url or --ssh-key-file, not both."
fi
if [ -n "${KEYS_URL}" ]; then
	validUrl "${KEYS_URL}" || die "--ssh-keys-url must be a plain https:// URL."
fi
detectLan
validCidr "${ALLOW_FROM}" \
	|| die "the allowed range ${ALLOW_FROM} is not an IPv4 network of /8 or longer; pass --allow-from, e.g. 192.168.1.0/24."

confirmPhrase

KEYS_FILE="$(mktemp)" || die "mktemp failed"
trap 'rm -f "${KEYS_FILE}"' EXIT

createCtl
configureCtl
readKeys
read -rp "Allow these keys? [y/N] " answer </dev/tty || die "no terminal -- aborting."
case "${answer}" in y|Y) ;; *) die "not confirmed -- aborting." ;; esac
installKeys
configureNet install
configureDom0
if [ "${AUTOLOGIN}" -eq 1 ]; then
	configureDesktop
fi
selfTest
summary
