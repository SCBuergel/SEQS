#!/usr/bin/env python3
"""Mutation check: break each security check on purpose and confirm a test fails.

Each entry in MUTATIONS replaces one exact string in the product code with a
weaker version. For every entry, a temporary git worktree gets the working
tree's files plus that one change, and the Qubes-free layers run cheapest
first until one fails twice in a row. A mutation that every layer accepts SURVIVES: no test
guards that check. One that fails a layer only once is FLAKY. One that breaks
the syntax of its file is BROKEN: lint would catch it, not a test of the
check. The tests must pass without a mutation first.

    python3 test/mutate.py            run every mutation
    python3 test/mutate.py tar gpg    run the mutations whose name contains one
    python3 test/mutate.py --check    only check that each original occurs once

Exit status: 0 if every mutation was caught, 1 if one survived, 2 on error.
"""
import os
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LAYERS = ["unit", "lint", "integration", "render"]  # cheapest first

R = "setup-qubes.sh"
D = "delete-vms.sh"
S = "salt/seqs/dom0.sls"
Q = "salt/seqs/qube.sls"
G = "install-scripts/lib/verify-gpg.sh"
QR = "salt/seqs/files/qr-sequential.sh"
VM = "salt/seqs/files/seqs-vpn-monitor"
L = "install-scripts/components/ledger/template-vm.sh"
B = "install-scripts/lib/brave.sh"
GV = "install-scripts/components/gnosisvpn/template-vm.sh"

# (name, file, exact original text, weakened text)
MUTATIONS = [
    # Runner: terminal sanitizing, confirmation, ownership, failure detection.
    ("sanitize-esc", R, r"tr -d '\000-\010\013-\037\177'", r"tr -d '\000-\010\013-\032\177'"),
    ("sanitize-c1", R, r"s/\xc2[\x80-\x9f]//g", r"s/\xc2[\x80-\x8f]//g"),
    ("sanitize-iconv", R, "\t\t| iconv -f UTF-8 -t UTF-8 -c \\\n", ""),
    ("sanitize-mgmt-log", R, "| sed 's/^.* output: *//' | sanitize |", "| sed 's/^.* output: *//' |"),
    ("sanitize-gnosis-apt", R, "2>&1 </dev/null | sanitize; then", "2>&1 </dev/null | cat; then"),
    ("repo-stderr-commit", R, "2>/dev/null </dev/null | head -c 100", "</dev/null | head -c 100"),
    ("repo-stderr-archive", R, '2>/dev/null </dev/null | head -c "${MAX_ARCHIVE}"', '</dev/null | head -c "${MAX_ARCHIVE}"'),
    ("confirm-empty", R, "y|Y) return 0 ;;", "y|Y|'') return 0 ;;"),
    ("ismanaged-anywhere", R, 'grep -q "^# ${MANAGED_MARKER}"', 'grep -q "${MANAGED_MARKER}"'),
    ("takeover-skip", R, 'if [ -e "${p}" ] && ! isManaged "${p}"; then', 'if false; then'),
    ("takeover-usb-failsafe", R, 'vms="$(qvm-ls --raw-list 2>/dev/null)" && !', '{ vms="$(qvm-ls --raw-list 2>/dev/null)" || true; } && !'),
    ("qubesctl-result-false", R, "Result:([[:space:]]|\\[[0-9;]*m)*False|", ""),
    ("qubesctl-unattributed", R, '[ "${UNATTRIBUTED_FAILURE}" -eq 0 ]; then', 'true; then'),
    ("qubesctl-ok-required", R, '[[ " ${OK_QUBES[*]} " == *" $1 "* && ', '[[ '),
    ("qubesctl-ok-clears-error", R, ' && " ${FAILED_QUBES[*]} " != *" $1 "* ]]', ' ]]'),
    ("qubesctl-verbose-forged", R, '[[ " $* " != *" --show-output "* ]] || UNATTRIBUTED_FAILURE=1', 'true'),
    ("gnosis-policy-unmarked", R, '\t\t&& ! isManaged "${GNOSIS_UPDATE_POLICY}"; then\n\t\tdie', '\t\t&& false; then\n\t\tdie'),
    ("gnosis-proxy-unmarked", R, 'seqs-gnosisvpn-temporary-proxy 2>/dev/null)" != "1" ]; then', 'seqs-gnosisvpn-temporary-proxy 2>/dev/null)" = "never" ]; then'),
    ("arg-repo-vm-name", R, '|| die "unsafe repo qube name', '|| true "unsafe repo qube name'),
    ("arg-qubes-name", R, '|| die "unsafe or empty qube base name in --qubes', '|| true "unsafe or empty qube base name in --qubes'),
    ("gnosis-stale-cleanup", R, '\t# A temporary GnosisVPN proxy or policy that a killed run left behind.\n\tcleanupGnosisUpdateProxy\n', ''),
    ("gnosis-cleanup-unverified", R, '\tverifyGnosisUpdateProxyRemoved\n', ''),
    ("gnosis-policy-left", R, '|| die "temporary GnosisVPN updates policy was not removed"', '|| true'),
    ("gnosis-proxy-left", R, '|| die "temporary GnosisVPN updates proxy was not removed"', '|| true'),
    ("dom0-apply-fail", R, '|| die "seqs.dom0 failed', '|| true "seqs.dom0 failed'),
    ("qubesctl-failed-qube", R, '[ "${#FAILED_QUBES[@]}" -eq 0 ] || rc=1', "true"),
    ("template-still-running", R, '\t\t\tFAILED_TEMPLATES+=("${vm}")\n', ''),
    ("template-cannot-stop", R, '|| die "could not stop ${vm}"', '|| true "could not stop ${vm}"'),
    ("c-locale-runner", R, "export -n LC_ALL\nLC_ALL=C\n", ""),
    ("c-locale-delete", D, "export -n LC_ALL\nLC_ALL=C\n", ""),
    ("c-locale-qr", QR, "export -n LC_ALL\nLC_ALL=C\n", ""),
    ("c-locale-monitor", VM, "export -n LC_ALL\nLC_ALL=C\n", ""),
    ("safe-name-dash", R, "SAFE_NAME='^[A-Za-z0-9_][A-Za-z0-9._-]*$'", "SAFE_NAME='^[A-Za-z0-9_-][A-Za-z0-9._-]*$'"),
    # Runner: fetch and archive validation.
    ("commit-id-any", R, "^([0-9a-f]{40}|[0-9a-f]{64})$", "^[0-9a-f]+"),
    ("tar-symlink", R, "d|-) ;;", "d|-|l) ;;"),
    ("tar-dotdot", R, '[[ "${path}" == *..* ]] && die', '[[ "${path}" == *..* ]] && true'),
    ("tar-top-dir", R, "^(salt|install-scripts)(/", "^([a-z-]+)(/"),
    ("tar-fixed-fields", R, "[0-9]+/[0-9]+\\ [0-9]{1,9}\\ [0-9]{4}", "[^[:space:]]+\\ [0-9]{1,9}\\ [0-9]{4}"),
    ("tar-numeric-owner", R, "< <(tar --numeric-owner -tvf", "< <(tar -tvf"),
    ("tar-marker-name", R, '[[ "${path%/}" == */.seqs-* ]] && die', '[[ "${path%/}" == */.seqs-* ]] && true'),
    ("fetch-size-limit", R, '[ "$(stat -c %s -- "${tarball}")" -lt "${MAX_ARCHIVE}" ]', '[ 0 -ge 0 ]'),
    ("fetch-commit-limit", R, "2>/dev/null </dev/null | head -c 100", "2>/dev/null </dev/null"),
    ("tar-whitespace", R, '[ -n "${extra}" ] && die', '[ -n "${extra}" ] && true'),
    ("tar-whitespace-around", R, '[[ "${line}" == *" ${f_time} ${path}" ]] \\', 'true \\'),
    ("tar-valid", R, 'tar -tf - < "${tarball}" > /dev/null 2>&1 || die', 'tar -tf - < "${tarball}" > /dev/null 2>&1 || true'),
    ("fetch-gitattributes", R, "|| exit 3; }", "|| true; }"),
    ("tar-stdin", R, 'tar -tf - < "${tarball}"', 'tar -tf "${tarball}"'),
    ("tar-listed-size", R, "total=$((total + 10#${f_size}))", "total=0"),
    ("fetch-bidi", R, '[ "${rc}" -eq 1 ] || die "refusing archive', '[ "${rc}" -ge 0 ] || die "refusing archive'),
    ("fetch-hidden-control", R, "grep -rlaP '[\\x00-\\x08\\x0b-\\x1f\\x7f]|", "grep -rlaP '"),
    ("fetch-hidden-zero-width", R, "\\xe2\\x80[\\x8b-\\x8f\\xa8-\\xae]", "\\xe2\\x80[\\xaa-\\xae]"),
    ("fetch-hidden-tag", R, "|\\xf3\\xa0' -- ", "' -- "),
    ("fetch-hidden-variation", R, "|\\xef\\xb8[\\x80-\\x8f]|", "|"),
    ("fetch-hidden-del", R, "\\x0b-\\x1f\\x7f]|", "\\x0b-\\x1f]|"),
    ("fetch-hidden-c1", R, "|\\xc2[\\x80-\\x9f\\xad]|", "|"),
    ("fetch-hidden-line-separator", R, "\\xa8-\\xae]|\\xe2\\x81", "\\xaa-\\xae]|\\xe2\\x81"),
    ("fetch-hidden-isolate", R, "|\\xe2\\x81[\\xa0-\\xaf]|", "|\\xe2\\x81[\\xa0-\\xa4]|"),
    ("fetch-hidden-bom", R, "|\\xef\\xbb\\xbf|", "|"),
    ("fetch-hidden-interlinear", R, "\\xef\\xbf[\\xb0-\\xbb]", "\\xef\\xbf[\\xb0-\\xb8]"),
    ("fetch-owner", R, '"${FETCH_PILLAR_TREE}"; do\n\t\tif sudo test -e "${d}"; then\n\t\t\tsudo test -e "${d}/.seqs-managed" \\\n',
     '"${FETCH_PILLAR_TREE}"; do\n\t\tif sudo test -e "${d}"; then\n\t\t\ttrue \\\n'),
    ("stage-owner", R, 'staging; otherwise a permission error looks\n\t\t# exactly like an absent path and bypasses the ownership guard.\n\t\tif sudo test -e "${d}"; then\n\t\t\tsudo test -e "${d}/.seqs-managed" \\\n',
     'staging; otherwise a permission error looks\n\t\t# exactly like an absent path and bypasses the ownership guard.\n\t\tif sudo test -e "${d}"; then\n\t\t\ttrue \\\n'),
    ("stage-incomplete", R, '[ -f "${FETCH_ROOT}/.seqs-complete" ] \\', 'true \\'),
    # Runner: targets file and air gap.
    ("targets-name", R, '[[ "${name}" =~ ${SAFE_NAME} ]] || die', '[[ "${name}" =~ ${SAFE_NAME} ]] || true'),
    ("targets-recipe", R, '[[ "${recipe}" =~ ${SAFE_NAME} ]] || die', '[[ "${recipe}" =~ ${SAFE_NAME} ]] || true'),
    ("targets-flag", R, "*) die \"unknown flag in ${TARGETS_FILE}: '${flag}'\" ;;", "*) ;;"),
    ("airgap-inherited", R, '$2 == "-" && $3 == "None" { n++ } END { exit n != 2 }\' <<<', '$3 == "None" { n++ } END { exit n != 2 }\' <<<'),
    ("targets-netvm-name", R, '[[ "${flag#netvm=}" =~ ${SAFE_NAME} ]] || die', '[[ "${flag#netvm=}" =~ ${SAFE_NAME} ]] || true'),
    ("netvm-verify-call", R, "\tverifyAirgap\n\tverifyNetvm\n", "\tverifyAirgap\n"),
    ("nodispvm-verify-call", R, "\tverifyNetvm\n\tverifyNoDispvm\n", "\tverifyNetvm\n"),
    ("nodispvm-inherited", R, '$1 == "default_dispvm" && $2 == "-" && $3 == "None" { f = 1 }', '$1 == "default_dispvm" && $3 == "None" { f = 1 }'),
    ("nodispvm-flag", S, "{{ ' nodispvm' if not", "{{ '' if not"),
    ("netvm-second-wave", R, '[[ " ${routed[*]} " == *" ${vm} "* ]] || first+=("${vm}")', 'first+=("${vm}")'),
    ("netvm-provider-ready", R, '\t\tif ! isProvisioned "${netvm}"; then', '\t\tif false; then'),
    ("netvm-provider-failed", R, 'if [[ " ${FAILED_APPS[*]} " == *" ${netvm} "* ]]; then', 'if false; then'),
    ("netvm-template-failed", R, '\t\t\tFAILED=1\n\t\t\tFAILED_APPS+=("${vm}")\n', '\t\t\tFAILED=1\n'),
    ("netvm-set-after-provider", R, 'qvm-prefs -- "${vm}" netvm "${netvm}" || die', 'true || die'),
    ("netvm-verify-before-ready", R, '! isProvisioned "${netvm}" || want="${netvm}"', 'want="${netvm}"'),
    ("netvm-verify-after-ready", R, '\tverifyNetvm\n\tprovisionApps "${second[@]}"', '\tprovisionApps "${second[@]}"'),
    ("provisioned-ok-required", R, '{ [ "${attributed}" -eq 1 ] && finished "${vm}"; }', '[ "${attributed}" -eq 1 ]'),
    ("provisioned-unattributed", R, '[ "${UNATTRIBUTED_FAILURE}" -ne 0 ] || attributed=1', 'attributed=1'),
    ("provisioned-failed-run", R, 'FAILED=1 all=0', 'FAILED=1'),
    ("netvm-inherited", R, '\'$1 == "netvm" && $2 == "-" && $3 == n { f = 1 }', '\'$1 == "netvm" && $3 == n { f = 1 }'),
    ("airgap-one", R, '{ n++ } END { exit n != 2 }\' <<<', '{ n++ } END { exit n < 1 }\' <<<'),
    # delete-vms.sh: only SEQS qubes, only safe names, blockers stop everything.
    ("delete-name", D, '=~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]; then', '=~ ^.*$ ]]; then'),
    ("delete-unmanaged", D, '"${candidate}" seqs-managed 2>/dev/null)" = "1" ]', '"${candidate}" seqs-managed 2>/dev/null)" != "x" ]'),
    ("delete-blockers", D, 'if [ "${#blockers[@]}" -gt 0 ]; then', 'if false; then'),
    ("delete-intent-marker", D, 'elif sudo test -e "${INTENTS_DIR}/${candidate}"; then', 'elif false; then'),
    ("delete-qvm-ls-fail", D, """}' || { echo "ERROR: could not list the qubes -- nothing was changed" >&2; return 1; }""", "}' || true"),
    ("delete-pin-sudo", D, "	if sudo head -n 1 --", "	if head -n 1 --"),
    ("delete-pin-unmarked", D, "| grep -q 'Managed by SEQS'; then", "| true; then"),
    ("delete-users-fields", D, '" ")\n\t\t\tfor (i = 2; i <= 7; i++)', '" ")\n\t\t\tfor (i = 2; i <= 4; i++)'),
    ("delete-panel-entry-other-qube", D, 'if [ -n "${vm}" ] && [[ " ${found[*]} " == *" ${vm} "* ]]; then', 'if [ -n "${vm}" ]; then'),
    ("panel-items-name", R, '[[ "${items}" =~ ^${name_re}( ${name_re})*$ ]] \\', '[[ -n "${items}" ]] \\'),
    # Runner: the temporary GnosisVPN download proxy and its policy.
    ("gnosis-proxy-drop", R, 'qvm-firewall -- "${GNOSIS_UPDATE_PROXY}" add drop \\\n', 'true \\\n'),
    ("gnosis-proxy-allow-all", R, 'qvm-firewall -- "${GNOSIS_UPDATE_PROXY}" del --rule-no 0 \\\n', 'true \\\n'),
    ("gnosis-policy-deny", R, "\t\t\tprintf 'qubes.UpdatesProxy * %s @anyvm deny\\n' \"${template}\"\n", ""),
    ("gnosis-whonix", R, 'whonix-gw 2>/dev/null)" != "1" ]', 'whonix-gw 2>/dev/null)" != "x" ]'),
    ("app-template-lookup", R, '|| die "could not read the template of ${vm}"', "|| true"),
    ("no-handoff-dispvm", S, "    - name: qvm-prefs -- {{ app }} default_dispvm none\n", '    - name: "true"\n'),
    ("firewall-port-range", S, "or (port | int) < 1 or (port | int) > 65535", "or false"),
    ("firewall-ipv4-range", S, "octet = '(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])' %}", "octet = '[0-9]+' %}"),
    ("fetch-hash-first", G, "\t# The hash first: gpg then never reads file bytes the pin rejects.\n",
     '\tverify_detached_sig "${dir}/${file}${sig}" "${dir}/${file}" "${fpr}" "${file}"\n'),
    # dom0.sls: names, offline, adoption, policy, pinning, cleanup paths.
    ("dom0-name-re", S, "{% set name_re = '^[A-Za-z0-9_][A-Za-z0-9._-]*\\\\Z' %}", "{% set name_re = '^.*' %}"),
    ("dom0-selection-instance", S, " or (fields | length == 2 and fields[1] | regex_match(name_re) is none) %}", " %}"),
    ("dom0-selection-postfix", S, "{%     elif fields | length == 2 and fields[1] | regex_match(name_re) is none %}", "{%     elif false %}"),
    ("dom0-offline-dispvm", S, "        qvm-prefs -- {{ app }} default_dispvm none\n", ""),
    ("dom0-tag-after-offline", S, "      - file: seqs-intent-app-{{ name }}\n{%     if q.get('offline') %}", "      - file: seqs-intent-app-{{ name }}\n{%     if false %}"),
    ("dom0-offline-netvm", S, "        qvm-prefs -- {{ app }} netvm none\n", ""),
    ("dom0-dvm-netvm", S, "        qvm-prefs -- {{ dvm }} netvm {{ routed_netvm }}\n", ""),
    ("dom0-dvm-netvm-default", S, ".get('provisioned') else 'none' %}", ".get('provisioned') else 'sys-firewall' %}"),
    ("dom0-routed-netvm-provisioned", S, "if q.get('netvm') and inventory.get(papp ~ q.netvm, {}).get('provisioned') else", "if q.get('netvm') else"),
    ("dom0-netvm-pending", S, "{%   if q.get('netvm') and routed_netvm == 'none' %}", "{%   if false %}"),
    ("dom0-dispvm-tpl-offline", S, "{%     if q.get('dispvm_template') and not q.get('offline') and q.get('netvm') is none %}", "{%     if false %}"),
    ("dom0-inventory-end", S, "{% if inventory_lines[-1:] != ['END'] %}", "{% if false %}"),
    ("dom0-webcam-list-checked", S, '        [ -n "$vms" ]\n', ''),
    ("dom0-audio-offline", S, "{%     if q.get('audio_provider') and (not q.get('offline') or q.get('dispvm_template')) %}", "{%     if q.get('audio_provider') and q.get('dispvm_template') %}"),
    ("dom0-audio-dispvm", S, "{%     if q.get('audio_provider') and (not q.get('offline') or q.get('dispvm_template')) %}", "{%     if q.get('audio_provider') and not q.get('offline') %}"),
    ("dom0-audio-policy-target", S, "{%-      for target in [a, '@adminvm', '@tag:audiovm-' ~ a] %}", "{%-      for target in [a, '@adminvm', '@anyvm'] %}"),
    ("dom0-audio-policy-get", S, "'%-40s %s  @tag:audiovm-%s  allow target=dom0' | format(arg, a, a)", "'%-40s %s  @anyvm  allow target=dom0' | format(arg, a)"),
    ("dom0-audio-own-audiovm", S, "        qvm-prefs -- {{ app }} audiovm ''\n", ""),
    ("runner-audio-policy-takeover", R, '\t"${POLICY_DIR}/50-seqs-audiovm.policy"\n', ""),
    ("runner-qr-input-policy-takeover", R, '\t"${POLICY_DIR}/00-seqs-qr-input-deny.policy"\n', ''),
    ("runner-browser-suppress-policy-takeover", R, '\t"${POLICY_DIR}/28-browser-suppress.policy"\n', ''),
    ("reset-qr-input-policy", D, "POLICIES=(00-seqs-qr-input-deny 01-", "POLICIES=(01-"),
    ("reset-gnosis-policy", D, " 20-seqs-gnosisvpn-updates\n", "\n"),
    ("dom0-netvm-provider", S, " or not qcatalog.get(nv, {}).get('network_provider') %}", " %}"),
    ("dom0-netvm-offline", S, "{%       elif q.get('offline') or q.get('network_provider') %}", "{%       elif false %}"),
    ("dom0-netvm-built", S, "{%   if q.netvm not in qmap and (inventory.get(provider, {}).get('recipe') != q.netvm or", "{%   if false and (inventory.get(provider, {}).get('recipe') != q.netvm or"),
    ("dom0-netvm-recipe", S, "(inventory.get(provider, {}).get('recipe') != q.netvm or", "(provider not in inventory or"),
    ("dom0-netvm-provisioned", S, " or not inventory[provider].provisioned) %}", ") %}"),
    ("dom0-catalogue-unknown-key", S, "{%     if unknown %}", "{%     if false %}"),
    ("dom0-catalogue-bool", S, "q[k] is not sameas true and q[k] is not sameas false %}", "false %}"),
    ("dom0-offline-firewall", S, "{%         if q.get('offline') %}\n{%           do errors.append(\"qube '\" ~ name ~ \"' sets both 'offline' and 'firewall'", "{%         if false %}\n{%           do errors.append(\"qube '\" ~ name ~ \"' sets both 'offline' and 'firewall'"),
    ("dom0-firewall-named-disposable", S, "{%         if q.get('named_disposable') %}", "{%         if false %}"),
    ("dom0-adopt", S, "{%     if not inventory[vmname].managed and not salt['file.file_exists'](intents_dir ~ '/' ~ vmname) %}", "{%     if false %}"),
    ("dom0-repurpose", S, "{%       do errors.append(\"qube '\" ~ vmname ~ \"' is managed for recipe", "{%       do [].append(\"qube '\" ~ vmname ~ \"' is managed for recipe"),
    ("dom0-special-adopt", S, "and not inventory.get(special, {}).get('managed') %}", "and false %}"),
    ("dom0-escape-vmshell", S, "'qubes.VMShell', 'qubes.VMExec'", "'qubes.VMExec'"),
    ("dom0-escape-openurl", S, "['qubes.OpenURL', ", "["),
    ("dom0-escape-target", S, "*  %s  @anyvm  deny", "*  %s  @dispvm  deny"),
    ("dom0-stale-intent", S, "     if m not in inventory and m not in planned", "     if false and m not in inventory"),
    ("dom0-sys-usb-memory-int", S, "{% if sys_usb_memory is not integer or sys_usb_memory < 0 %}", "{% if false %}"),
    ("dom0-sys-usb-memory-raise", S, "    - unless: test \"$(qvm-prefs -- sys-usb memory)\" -ge {{ sys_usb_memory }}\n", ""),
    ("dom0-nuc11-headset-bool", S, "{% if nuc11_headset_fix is not sameas true and nuc11_headset_fix is not sameas false %}", "{% if false %}"),
    ("dom0-nuc11-headset-codec", S, "{%   set nuc11_headset_install = '0x10ec0256 0x80863004' in codecs.splitlines() %}", "{%   set nuc11_headset_install = true %}"),
    ("dom0-qr-filecopy-deny", S, "        qubes.Filecopy  *  {{ webcam_scanner_qube }}  @anyvm  deny\n", ""),
    ("dom0-usb-override-unmarked", S, "    - onlyif: head -n 1 /etc/qubes/policy.d/30-user-input.policy 2>/dev/null | grep -q '^# Managed by SEQS'\n", ""),
    ("dom0-usb-override-kept", S, "{% if release == '4.3' and ('sys-usb' in inventory) and (keyboard_handled.value or not usb_keyboard_prompt) %}", "{% if false %}"),
    ("dom0-usb-override-setting", S, "and (keyboard_handled.value or not usb_keyboard_prompt) %}", "and keyboard_handled.value %}"),
    ("dom0-usb-prompt-bool", S, "{% if usb_keyboard_prompt is not sameas true and usb_keyboard_prompt is not sameas false %}", "{% if false %}"),
    ("runner-usb-takeover-single", R, "2>/dev/null | wc -l)\" = 3 ]", "2>/dev/null | wc -l)\" -ge 3 ]"),
    ("runner-usb-takeover-pillar-line", R, " \\\n\t\t\t&& grep -Fqxs '  usb_keyboard_prompt: {{ usb_keyboard_prompt | tojson }}' \"${PILLAR_TREE}/config.sls\"", ""),
    ("runner-usb-takeover-setting", R, "\"${PILLAR_TREE}/config.sls\"; then\n\t\tusb_applies=0", "\"${PILLAR_TREE}/config.sls\"; then\n\t\tusb_applies=1"),
    ("runner-usb-takeover-50", R, "(allow|ask)([[:space:]]|$)' \\\n\t\t\t\"${POLICY_DIR}/50-config-input.policy\"; then\n\t\tusb_applies=0", "(allow|ask)([[:space:]]|$)' \\\n\t\t\t\"${POLICY_DIR}/50-config-input.policy\"; then\n\t\tusb_applies=1"),
    ("dom0-qr-input-deny", S, "        qubes.InputKeyboard  *  {{ webcam_usb_qube }}  @adminvm  deny\n", ""),
    ("dom0-handoff-firewall", S, " or q.get('firewall') is not none %}\n{%   do no_handoff", " %}\n{%   do no_handoff"),
    ("dom0-handoff-unselected", S, "{%     do handoff_tags.update({vm: {'want': recipe in", "{%     do {}.update({vm: {'want': recipe in"),
    ("dom0-pin-unmarked", S, "and not salt['file.read'](pin_file).startswith(pin_marker) %}", "and false %}"),
    ("dom0-pin-core-range", S, "or c >= host_cpus | int %}", "%}"),
    ("dom0-vcpus-integer", S, "(q.vcpus is not integer or q.vcpus < 1) %}", "false %}"),
    ("dom0-main-app-name", S, "q.main_app | regex_match('^[A-Za-z0-9][A-Za-z0-9._-]*[.]desktop\\\\Z') is none) %}", "false) %}"),
    ("vpn-monitor-name", VM, '[[ "${vm}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]', '[[ -n "${vm}" ]]'),
    ("vpn-monitor-timeout", VM, "$(timeout 2 qvm-run", "$(qvm-run"),
    ("vpn-monitor-read-limit", VM, " | head -c 100)", ")"),
    ("vpn-monitor-four-numbers", VM, "^[0-9]{1,19}\\ [0-9]{1,19}\\ [0-9]{1,19}\\ [0-9]{1,19}$ ]]", "^.*$ ]]"),
    ("dom0-main-app-anchor", S, "[.]desktop\\\\Z') is none) %}", "[.]desktop$') is none) %}"),
    # Dom0 desktop settings: names in the runner's file paths and xfconf properties.
    ("dom0-launcher-name", S, "d | regex_match('^[A-Za-z0-9][A-Za-z0-9._-]*[.]desktop\\\\Z') is none %}", "false %}"),
    ("dom0-tiling-shortcut", S, "or action is not string or action | regex_match('^[a-z][a-z_]*_key\\\\Z') is none %}", "%}"),
    ("desktop-launcher-name", R, '[[ "${a}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*[.]desktop$ && -z "${b}" ]] \\', 'true \\'),
    ("desktop-shortcut", R, '[[ "${a}" =~ ${shortcut_re} && "${b}" =~ ^[a-z][a-z_]*_key$ ]] \\', 'true \\'),
    ("dom0-cleanup-dotdot", S, "or ('..' in p) or ('/./' in p ~ '/') %}", "%}"),
    ("dom0-firewall-entry", S, "{%           if e not in ['dns', 'icmp'] and ((es", "{%           if false and ((es"),
    ("dom0-webcam-bdf", S, "regex_match('^[0-9a-f]{2}_[0-9a-f]{2}\\.[0-7]\\\\Z') is none %}", "regex_match('^.*$') is none %}"),
    # \Z, not $, which also matches before a trailing newline.
    ("dom0-webcam-bdf-anchor", S, "[0-7]\\\\Z') is none %}", "[0-7]$') is none %}"),
    ("dom0-webcam-dedicated-strict", S, "{% elif webcam_mode == 'dedicated' and webcam_strict_reset is sameas false %}", "{% elif false %}"),
    ("dom0-webcam-skip-reset", S, "{%   elif not webcam_strict_reset and methods %}", "{%   elif false %}"),
    ("dom0-webcam-reset-methods", S, "['flr', 'af_flr', 'pm', 'bus']", "['flr', 'af_flr', 'bus']"),
    ("dom0-webcam-stale-unassign", S, '          qvm-pci unassign {{ webcam_usb_qube }} "$dev" 2>/dev/null || true\n', ''),
    ("dom0-webcam-only-check", S, '[ "$(printf \'%s\\n\' "$listing" | awk -v vm="{{ webcam_usb_qube }}" "$owned" | sort -u)" = "dom0:{{ webcam_controller }}" ]', 'true'),
    ("dom0-webcam-stale-bdf", S, "grep -Eq '^dom0:[0-9a-f]{2}_[0-9a-f]{2}\\.[0-7]$' ||", "grep -Eq '.' ||"),
    ("dom0-webcam-other-owner", S, '        if [ -n "$others" ]; then\n', '        if false; then\n'),
    ("dom0-webcam-unless-extra", S, "exit !(mine && !other && !extra)", "exit !(mine && !other)"),
    ("dom0-ext-id-anchor", S, "exts[en] | regex_match('^[a-p]{32}\\\\Z')", "exts[en] | regex_match('^[a-p]{32}$')"),
    ("dom0-firewall-anchor", S, "(:[0-9]{1,5})?\\\\Z')", "(:[0-9]{1,5})?$')"),
    ("dom0-cleanup-anchor", S, "(p | regex_match('^/home/user(/[A-Za-z0-9._-]+)+\\\\Z')", "(p | regex_match('^/home/user(/[A-Za-z0-9._-]+)+$')"),
    ("qube-ext-id-anchor", Q, "regex_match('^[a-p]{32}\\\\Z')", "regex_match('^[a-p]{32}$')"),
    ("qube-browser-desktop-anchor", Q, "\\\\.desktop\\\\Z')", "\\\\.desktop$')"),
    ("qube-cleanup-anchor", Q, "regex_match('^/home/user(/[A-Za-z0-9._-]+)+\\\\Z')", "regex_match('^/home/user(/[A-Za-z0-9._-]+)+$')"),
    ("dom0-qr-staging-derived", S, "{% set webcam_staging_qube = papp ~ 'qr-staging' %}", "{% set webcam_staging_qube = seqs.get('webcam_staging_qube', papp ~ 'qr-staging') %}"),
    ("dom0-qr-camera-derived", S, "{% set webcam_scanner_dvm = papp ~ 'qr-camera' %}", "{% set webcam_scanner_dvm = seqs.get('webcam_scanner_dvm', papp ~ 'qr-camera') %}"),
    ("dom0-qr-staging-managed", S, "inventory.get(webcam_staging_qube, {}).get('managed') and", "webcam_staging_qube in inventory and"),
    ("dom0-qr-staging-recipe", S, "inventory[webcam_staging_qube].recipe in ['', 'qr-staging']", "true"),
    ("dom0-qr-camera-managed", S, "inventory.get(webcam_scanner_dvm, {}).get('managed') and", "webcam_scanner_dvm in inventory and"),
    ("dom0-qr-camera-recipe", S, "inventory[webcam_scanner_dvm].recipe in ['', 'qr-camera']", "true"),
    ("dom0-sequential-staging-offline", S, "(not qcatalog.get('qr-staging', {}).get('offline') or ", "("),
    ("fetch-tmp-cleanup", R, """	trap "rm -rf -- '${tarball}' '${stage}'" EXIT\n""", ""),
    # delete-vms.sh --reset: only marked qubes and files, in order, after RESET.
    ("reset-unmarked-qube", D, 'if [ "$(qvm-features -- "${vm}" seqs-managed 2>/dev/null)" = "1" ] \\\n\t\t\t|| [ "$(qvm-features -- "${vm}" seqs-gnosisvpn-temporary-proxy 2>/dev/null)" = "1" ]; then', "if true; then"),
    ("reset-clone-name", D, 'elif isSeqsName "${vm}"; then', 'elif true; then'),
    ("reset-no-names-refusal", D, 'if [ "${#unnamed[@]}" -gt 0 ] && [ "${#removable[@]}" -gt 0 ]; then', 'if false; then'),
    ("delete-no-names", D, 'elif [ "${RESET}" -eq 0 ]; then\n\techo "ERROR: ${NAMES_FILE} is missing', 'elif false; then\n\techo "ERROR: ${NAMES_FILE} is missing'),
    ("delete-names-unsafe", D, '[[ "${value}" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] && [ -z "${rest}" ] || return 1', '[ -z "${rest}" ] || return 1'),
    ("reset-file-marker", D, '[[ "${l1}" == "# Managed by SEQS"* ]] || [[ "${l1}" == "#!"* && "${l2}" == "# Managed by SEQS"* ]]', '[[ "${l1}" == "# "*SEQS* ]] || [[ "${l1}" == "#!"* && "${l2}" == "# "*SEQS* ]]'),
    ("reset-remove-order", D, """\t\tif awk -F'|' -v r=" ${remaining[*]} " -v t="${vm}" \\\n\t\t\t\t'$1 != t && index(r, " " $1 " ") { for (i = 2; i <= 7; i++) if ($i == t) exit 1 }' <<< "${rows}"; then""", "\t\tif true; then"),
    ("reset-confirm-word", D, '[ "${answer}" = RESET ] ||', '[ -n "${answer}" ] ||'),
    # The sequential QR script in dom0: offline camera side, one device, power-off.
    ("qr-running-webcam-poweroff", QR, "\texpose; exit 1;", "\texit 1;"),
    ("qr-watchdog-hup", QR, "( trap '' HUP INT QUIT; set +e;", "( trap '' INT QUIT; set +e;"),
    ("qr-watchdog", QR, "set +e; sleep 840; systemctl poweroff --force --force", "set +e; sleep 840"),
    ("qr-poweroff-force", QR, "systemctl poweroff || systemctl poweroff --force --force", "systemctl poweroff"),
    ("qr-start-word", QR, '[ "$answer" = START ]', '[ -n "$answer" ]'),
    ("qr-one-device", QR, '[ "${#devices[@]}" -eq 1 ] ||', '[ "${#devices[@]}" -ge 1 ] ||'),
    ("qr-device-id", QR, '=~ ^[0-9]+-[0-9]+(\\.[0-9]+)*$ ]]', '=~ ^[0-9]+-.*$ ]]'),
    ("qr-poweroff", QR, "		systemctl poweroff || systemctl poweroff --force --force\n", ""),
    ("qr-offline-explicit", QR, '&& $2 == "-" && $3 == "None" { n++ } END { exit n != 2 }\' || {', '&& $3 == "None" { n++ } END { exit n != 2 }\' || {'),
    ("qr-offline-pref", QR, '&& $2 == "-" && $3 == "None" { n++ } END { exit n != 2 }\' || {', '{ n++ } END { exit n != 2 }\' || {'),
    ("qr-conf-names", QR, '[[ "$value" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] || {', 'true || {'),
    ("qr-conf-bdf", QR, '[[ "$CONTROLLER" =~ ^[0-9a-f]{2}_[0-9a-f]{2}\\.[0-7]$ ]] || {', 'true || {'),
    ("qr-scanner-running", QR, 'qvm-check --running -q -- "$SCANNER_QUBE" && {', 'false && {'),
    ("qr-old-key", QR, "	ABSENT) ;;", "	ABSENT|PRESENT) ;;"),
    ("qr-strip-control", QR, " | LC_ALL=C tr -cd '[:print:]\\t\\n')\" || {", ")\" || {"),
    ("qr-staging-stderr", QR, "</dev/null 2>/dev/null)\" || staged=''", "</dev/null)\" || staged=''"),
    ("qr-scanner-stdout", QR, "</dev/null >/dev/null 2>/dev/null; then", "</dev/null 2>/dev/null; then"),
    ("qr-scanner-stderr", QR, "</dev/null >/dev/null 2>/dev/null; then", "</dev/null >/dev/null; then"),
    ("qr-normal-stopped", QR, 'if qvm-check --running -q -- "$NORMAL_USB_QUBE"; then\n\techo "ERROR:', 'if false; then\n\techo "ERROR:'),
    ("qr-normal-not-running", QR, 'if ! qvm-check --running -q -- "$NORMAL_USB_QUBE"; then', 'if false; then'),
    ("wg-allowlist", "install-scripts/components/wireguard/seqs-wireguard", "PersistentKeepalive)[[:space:]]*=.*)?", "PersistentKeepalive|[A-Za-z]+)[[:space:]]*=.*)?"),
    ("wg-full-tunnel", "install-scripts/components/wireguard/seqs-wireguard", "=([^#]*,)?[[:space:]]*0\\.0\\.0\\.0/0[[:space:]]*([,#].*)?$'", "=.*0\\.0\\.0\\.0/0'"),
    ("wg-dns-before-qubes", "install-scripts/components/wireguard/wireguard-dns.sh", "nat hook prerouting priority -101;", "nat hook prerouting priority dstnat;"),
    ("wg-dns-output-before-qubes", "install-scripts/components/wireguard/wireguard-dns.sh", "nat hook output priority -101;", "nat hook output priority dstnat;"),
    ("gnosis-autoconnect-destination", "install-scripts/components/gnosisvpn/seqs-gnosisvpn-autoconnect", 'gnosis_vpn-ctl destinations | grep -Fqx -- "$exit_id" ||', "true ||"),
    ("proton-drop-ip6", "install-scripts/components/protonvpn/protonvpn-firewall.sh", 'nft add rule ip6 qubes custom-forward oifname "eth0" counter drop\n', ""),
    ("proton-hook-entry", "install-scripts/components/protonvpn/app-vm.sh", 'printf \'%s\\n\' "${entry}"; } | sudo tee -a "${hook}"', 'true; } | true'),
    ("proton-hook-newline", "install-scripts/components/protonvpn/app-vm.sh", '[ -z "$(sudo tail -c 1 -- "${hook}")" ] || echo;', ''),
    ("wg-rclocal-newline", "install-scripts/components/wireguard/app-vm.sh", '[ -z "$(sudo tail -c 1 -- /rw/config/rc.local)" ] || echo;', ''),
    ("wg-hook-newline", "install-scripts/components/wireguard/app-vm.sh", '[ -z "$(sudo tail -c 1 -- /rw/config/qubes-firewall-user-script)" ] || echo;', ''),
    ("gnosis-hook-newline", "install-scripts/components/gnosisvpn/seqs-gnosisvpn-prepare-app", '[[ -z "$(tail -c 1 -- "$hook")" ]] || echo;', ''),
    # Installer helpers: pinned keys, signatures, hashes, apt pins.
    ("gpg-exact-keys", G, '[[ "${got}" != "${expected}" ]]', '[[ -z "${got}" ]]'),
    ("gpg-lock-recheck", G, '| require_exact_keys "${1}" "${2}" || exit 1', '>/dev/null || true'),
    ("gpg-validsig-pin", G, '$2=="VALIDSIG" && $NF==fpr {', '$2=="VALIDSIG" {'),
    ("gpg-badsig", G, '($2=="BADSIG"   || ', '($2=="NOPE"   || '),
    ("gpg-rc", G, ' || [ "${rc}" -ne 0 ]; then', '; then'),
    ("gpg-sha256", G, "| sha256sum --check --strict --quiet \\\n", "| true \\\n"),
    ("gpg-apt-pin", G, "Pin-Priority: -1\\n\\nPackage", "Pin-Priority: 1\\n\\nPackage"),
    ("gpg-signed-by", G, "signed-by=${keyring}]", "]"),
    ("brave-exact-keys", B, '|| { rm -rf "${tmp}" "${gh}"; exit 1; }', "|| true"),
    ("brave-apt-pin", B, "Pin-Priority: -1\n", "Pin-Priority: 1\n"),
    ("brave-signed-by", B, "signed-by=${keyring}]", "]"),
    ("brave-keyring-restore", B, 'sudo install -m 0644 "${tmp}" "${keyring}"\n\trm -f', "rm -f"),
    ("gnosisvpn-apt-pin", GV, 'gnosis.eth.limo"\nPin-Priority: -1', 'gnosis.eth.limo"\nPin-Priority: 1'),
    ("gnosisvpn-own-keyring", GV, 'Signed-By: %s\\n\' "$1" "${KEYRING}"', 'Signed-By: %s\\n\' "$1" "${PACKAGE_KEYRING}"'),
    ("gnosisvpn-lock-keyring", GV, 'lock_keyring "${KEYRING}" "${GNOSISVPN_KEY_FPR}"\n', ''),
    ("gnosisvpn-apt-pin-mirror", GV, 'gnosisvpn.io"\nPin-Priority: -1', 'gnosisvpn.io"\nPin-Priority: 1'),
    ("ledger-sha512", L, "| sha512sum --check --strict --quiet \\\n", "| true \\\n"),
    ("ledger-signature", L, "openssl dgst -sha256 -verify", "true || openssl dgst -sha256 -verify"),
    ("ledger-listed", L, "'$1 == h && $2 == f { ok = 1 }", "'{ ok = 1 }"),
    ("qube-component-name", Q, "{%   if comp | regex_match(name_re) is none %}", "{%   if false %}"),
    ("qube-extension-id", Q, "{%     if exts.get(comp[16:], '') | regex_match('^[a-p]{32}\\\\Z') is none %}", "{%     if false %}"),
    ("qube-browser-vm", Q, "{% if browser_vm | regex_match(name_re) is none %}", "{% if false %}"),
    ("qube-browser-desktop", Q, "{% if browser_desktop | regex_match('^[A-Za-z0-9._-]+\\\\.desktop\\\\Z') is none %}", "{% if false %}"),
    ("qube-timeout-number", Q, "{% if timeout is not number %}", "{% if false %}"),
    ("qube-cleanup-path", Q, "          or e.get('path', '') | regex_match('^/home/user(/[A-Za-z0-9._-]+)+\\\\Z') is none\n", "\n"),
    ("qube-cleanup-template", Q, "          rw-only|none) ;;", "          rw-only|none|full) ;;"),
    ("qube-install-brave", Q, "install_brave; install_brave_extension", "install_brave_extension"),
]


def run(cmd, cwd, **kw):
    return subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True, errors="replace", **kw)


def make_worktree(parent):
    """A detached worktree holding the working tree's files, committed."""
    tree = os.path.join(parent, "tree")
    if run(["git", "worktree", "add", "--quiet", "--detach", tree, "HEAD"], REPO).returncode:
        sys.exit("ERROR: git worktree add failed")
    files = run(["git", "ls-files", "-z", "-co", "--exclude-standard"], REPO).stdout.split("\0")
    for f in filter(None, files):
        src, dst = os.path.join(REPO, f), os.path.join(tree, f)
        if os.path.isfile(src):
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(src, dst)
    run(["git", "add", "-A"], tree)
    run(["git", "-c", "user.name=mutate", "-c", "user.email=mutate@invalid",
         "commit", "-q", "--allow-empty", "-m", "base"], tree)
    return tree


def syntax_error(path):
    """True if the Jinja of a .sls file, or a shell script, does not parse."""
    if path.endswith(".sls"):
        from jinja2 import Environment, TemplateSyntaxError
        try:
            with open(path) as f:
                Environment(extensions=["jinja2.ext.do"]).parse(f.read())
        except TemplateSyntaxError:
            return True
        return False
    return run(["bash", "-n", path], os.path.dirname(path)).returncode != 0


def check_one(tree, mutation):
    name, path, old, new = mutation
    target = os.path.join(tree, path)
    with open(target) as f:
        text = f.read()
    if text.count(old) != 1:
        return name, "ERROR", "original text found %d times in %s" % (text.count(old), path)
    with open(target, "w") as f:
        f.write(text.replace(old, new))
    if syntax_error(target):
        run(["git", "checkout", "-q", "--", path], tree)
        return name, "BROKEN", "the mutated %s does not parse" % path
    run(["git", "-c", "user.name=mutate", "-c", "user.email=mutate@invalid",
         "commit", "-q", "-am", name], tree)
    # Lint checks that every original text is present; that would catch any mutation.
    env = dict(os.environ, SEQS_SKIP_MUTATION_CHECK="1")
    try:
        for layer in LAYERS:
            if run(["bash", "test/run-tests.sh", layer], tree, env=env).returncode:
                # A failure under load could be a timeout, not a catch.
                if run(["bash", "test/run-tests.sh", layer], tree, env=env).returncode:
                    return name, "caught", layer
                return name, "FLAKY", layer
        return name, "SURVIVED", ""
    finally:
        run(["git", "reset", "-q", "--hard", "HEAD~1"], tree)


def stale():
    """The entries whose original text does not occur exactly once."""
    out = []
    for name, path, old, _ in MUTATIONS:
        with open(os.path.join(REPO, path)) as f:
            n = f.read().count(old)
        if n != 1:
            out.append("%s: original text found %d times in %s" % (name, n, path))
    return out


def main():
    if sys.argv[1:] == ["--check"]:
        bad = stale()
        for line in bad:
            print("FAIL: mutation " + line)
        return 1 if bad else 0
    wanted = [m for m in MUTATIONS if len(sys.argv) < 2 or any(a in m[0] for a in sys.argv[1:])]
    if not wanted:
        print("ERROR: no mutation name contains %s" % " or ".join(sys.argv[1:]))
        return 2
    workers = min(len(wanted), os.cpu_count() or 1) or 1
    parent = tempfile.mkdtemp()
    trees = []
    try:
        trees = [make_worktree(os.path.join(parent, str(i))) for i in range(workers)]
        if run(["bash", "test/run-tests.sh"], trees[0]).returncode:
            print("ERROR: the tests fail without any mutation")
            return 2
        chunks = [wanted[i::workers] for i in range(workers)]
        with ThreadPoolExecutor(workers) as pool:
            results = pool.map(lambda tc: [check_one(tc[0], m) for m in tc[1]],
                               zip(trees, chunks))
            results = [r for chunk in results for r in chunk]
    finally:
        for tree in trees:
            run(["git", "worktree", "remove", "--force", tree], REPO)
        shutil.rmtree(parent, ignore_errors=True)
    bad = 0
    for name, verdict, detail in sorted(results):
        print("%-9s %-32s %s" % (verdict, name, detail))
        bad += verdict != "caught"
    print("%d of %d mutations caught." % (len(results) - bad, len(results)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
