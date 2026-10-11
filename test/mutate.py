#!/usr/bin/env python3
"""Mutation check: break each security check on purpose and confirm a test fails.

Each entry in MUTATIONS replaces one exact string in the product code with a
weaker version. For every entry, a temporary git worktree gets the working
tree's files plus that one change, committed (the integration layer fetches
the committed tree), and the Qubes-free layers run cheapest first until one
fails twice in a row. A mutation that every layer accepts SURVIVES: no test
guards that check. One that fails a layer only once is FLAKY. The tests must
pass without a mutation first.

    python3 test/mutate.py            run every mutation
    python3 test/mutate.py tar gpg    run the mutations whose name contains one

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

# (name, file, exact original text, weakened text)
MUTATIONS = [
    # Runner: terminal sanitizing, confirmation, ownership, failure detection.
    ("sanitize-esc", R, r"tr -d '\000-\010\013-\037\177'", r"tr -d '\000-\010\013-\032\177'"),
    ("sanitize-c1", R, r"s/\xc2[\x80-\x9f]//g", r"s/\xc2[\x80-\x8f]//g"),
    ("confirm-empty", R, "y|Y) return 0 ;;", "y|Y|'') return 0 ;;"),
    ("ismanaged-anywhere", R, 'grep -q "^# ${MANAGED_MARKER}"', 'grep -q "${MANAGED_MARKER}"'),
    ("takeover-skip", R, 'if [ -e "${p}" ] && ! isManaged "${p}"; then', 'if false; then'),
    ("qubesctl-result-false", R, "Result:([[:space:]]|\\[[0-9;]*m)*False|", ""),
    ("qubesctl-failed-qube", R, '[ "${#FAILED_QUBES[@]}" -eq 0 ] || rc=1', "true"),
    ("safe-name-dash", R, "SAFE_NAME='^[A-Za-z0-9_][A-Za-z0-9._-]*$'", "SAFE_NAME='^[A-Za-z0-9_-][A-Za-z0-9._-]*$'"),
    # Runner: fetch and archive validation.
    ("commit-id-any", R, "^([0-9a-f]{40}|[0-9a-f]{64})$", "^[0-9a-f]+"),
    ("tar-symlink", R, "d|-) ;;", "d|-|l) ;;"),
    ("tar-dotdot", R, '[[ "${path}" == *..* ]] && die', '[[ "${path}" == *..* ]] && true'),
    ("tar-top-dir", R, "^(salt|install-scripts)(/", "^([a-z-]+)(/"),
    ("tar-fixed-fields", R, "[0-9]+/[0-9]+\\ [0-9]+\\ [0-9]{4}", "[^ ]+\\ [0-9]+\\ [0-9]{4}"),
    ("tar-numeric-owner", R, "< <(tar --numeric-owner -tvf", "< <(tar -tvf"),
    ("tar-marker-name", R, '[[ "${path%/}" == */.seqs-* ]] && die', '[[ "${path%/}" == */.seqs-* ]] && true'),
    ("fetch-size-limit", R, '-lt "${MAX_ARCHIVE}" ]', '-ge 0 ]'),
    ("fetch-commit-limit", R, "2>/dev/null </dev/null | head -c 100", "2>/dev/null </dev/null"),
    ("tar-whitespace", R, '[ -n "${extra}" ] && die', '[ -n "${extra}" ] && true'),
    ("tar-valid", R, 'tar -tf "${tarball}" > /dev/null 2>&1 || die', 'tar -tf "${tarball}" > /dev/null 2>&1 || true'),
    ("fetch-owner", R, 'if [ -e "${d}" ] && [ ! -e "${d}/.seqs-managed" ]; then', "if false; then"),
    ("stage-owner", R, 'sudo test -e "${d}/.seqs-managed" \\\n', 'true \\\n'),
    ("stage-incomplete", R, '[ -f "${FETCH_ROOT}/.seqs-complete" ] \\', 'true \\'),
    # Runner: targets file and air gap.
    ("targets-name", R, '[[ "${name}" =~ ${SAFE_NAME} ]] || die', '[[ "${name}" =~ ${SAFE_NAME} ]] || true'),
    ("targets-recipe", R, '[[ "${recipe}" =~ ${SAFE_NAME} ]] || die', '[[ "${recipe}" =~ ${SAFE_NAME} ]] || true'),
    ("targets-flag", R, "*) die \"unknown flag in ${TARGETS_FILE}: '${flag}'\" ;;", "*) ;;"),
    ("airgap-inherited", R, '$2 == "-" && $3 == "None" { n++ } END { exit n != 2 }\' <<<', '$3 == "None" { n++ } END { exit n != 2 }\' <<<'),
    ("airgap-one", R, '{ n++ } END { exit n != 2 }\' <<<', '{ n++ } END { exit n < 1 }\' <<<'),
    # delete-vms.sh: only SEQS qubes, only safe names, blockers stop everything.
    ("delete-name", D, '=~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]; then', '=~ ^.*$ ]]; then'),
    ("delete-unmanaged", D, 'seqs-managed 2>/dev/null)" = "1" ]', 'seqs-managed 2>/dev/null)" != "x" ]'),
    ("delete-blockers", D, 'if [ "${#blockers[@]}" -gt 0 ]; then', 'if false; then'),
    ("delete-intent-marker", D, '|| sudo test -e "${INTENTS_DIR}/${candidate}"; then', '; then'),
    ("delete-inherit-errexit", D, "shopt -s inherit_errexit\n", ""),
    ("delete-pin-sudo", D, "	if sudo head -n 1 --", "	if head -n 1 --"),
    ("delete-pin-unmarked", D, "| grep -q 'Managed by SEQS'; then", "| true; then"),
    # dom0.sls: names, offline, adoption, policy, pinning, cleanup paths.
    ("dom0-name-re", S, "{% set name_re = '^[A-Za-z0-9_][A-Za-z0-9._-]*\\\\Z' %}", "{% set name_re = '^.*' %}"),
    ("dom0-offline-dispvm", S, "        qvm-prefs -- {{ app }} default_dispvm none\n", ""),
    ("dom0-offline-netvm", S, "        qvm-prefs -- {{ app }} netvm none\n", ""),
    ("dom0-dvm-netvm", S, "        qvm-prefs -- {{ dvm }} netvm none\n", ""),
    ("dom0-dispvm-tpl-offline", S, "{%     if q.get('dispvm_template') and not q.get('offline') %}", "{%     if false %}"),
    ("dom0-offline-firewall", S, "{%         if q.get('offline') %}\n{%           do errors.append(\"qube '\" ~ name ~ \"' sets both 'offline' and 'firewall'", "{%         if false %}\n{%           do errors.append(\"qube '\" ~ name ~ \"' sets both 'offline' and 'firewall'"),
    ("dom0-adopt", S, "already exists but is not marked seqs-managed -- refusing to adopt it (remove", "x\") %}{% if false %}{% do errors.append(\"(remove"),
    ("dom0-repurpose", S, "{%       do errors.append(\"qube '\" ~ vmname ~ \"' is managed for recipe", "{%       do [].append(\"qube '\" ~ vmname ~ \"' is managed for recipe"),
    ("dom0-special-adopt", S, "and not inventory.get(special, {}).get('managed') %}", "and false %}"),
    ("dom0-escape-vmshell", S, "'qubes.VMShell', 'qubes.VMExec'", "'qubes.VMExec'"),
    ("dom0-escape-openurl", S, "['qubes.OpenURL', ", "["),
    ("dom0-escape-target", S, "*  %s  @anyvm  deny", "*  %s  @dispvm  deny"),
    ("dom0-stale-intent", S, "     if m not in inventory and m not in planned", "     if false and m not in inventory"),
    ("dom0-qr-filecopy-deny", S, "        qubes.Filecopy  *  {{ webcam_scanner_qube }}  @anyvm  deny\n", ""),
    ("dom0-qr-input-deny", S, "        qubes.InputKeyboard  *  {{ webcam_usb_qube }}  @adminvm  deny\n", ""),
    ("dom0-handoff-firewall", S, " or q.get('firewall') is not none %}\n{%   do no_handoff", " %}\n{%   do no_handoff"),
    ("dom0-handoff-unselected", S, "{%     do handoff_tags.update({vm: {'want': recipe in", "{%     do {}.update({vm: {'want': recipe in"),
    ("dom0-pin-unmarked", S, "and not salt['file.read'](pin_file).startswith(pin_marker) %}", "and false %}"),
    ("dom0-pin-core-range", S, "or c >= host_cpus | int %}", "%}"),
    ("dom0-cleanup-dotdot", S, "or ('..' in p) or ('/./' in p ~ '/') %}", "%}"),
    ("dom0-firewall-entry", S, "has invalid firewall entry", "x\") %}{% if false %}{% do errors.append(\"y"),
    ("dom0-webcam-bdf", S, "regex_match('^[0-9a-f]{2}_[0-9a-f]{2}\\.[0-7]$') is none %}", "regex_match('^.*$') is none %}"),
    ("dom0-sequential-staging-offline", S, "(not qcatalog.get('qr-staging', {}).get('offline') or ", "("),
    ("fetch-tmp-cleanup", R, """	trap "rm -rf -- '${tarball}' '${stage}'" EXIT\n""", ""),
    # The sequential QR script in dom0: offline camera side, one device, power-off.
    ("qr-start-word", QR, '[ "$answer" = START ]', '[ -n "$answer" ]'),
    ("qr-one-device", QR, '[ "${#devices[@]}" -eq 1 ] ||', '[ "${#devices[@]}" -ge 1 ] ||'),
    ("qr-device-id", QR, '=~ ^[0-9]+-[0-9]+(\\.[0-9]+)*$ ]]', '=~ ^[0-9]+-.*$ ]]'),
    ("qr-poweroff", QR, "		systemctl poweroff\n", ""),
    ("qr-offline-pref", QR, "			''|None|none) ;;", "			*) ;;"),
    ("qr-old-key", QR, "	ABSENT) ;;", "	ABSENT|PRESENT) ;;"),
    # Installer helpers: pinned keys, signatures, hashes, apt pins.
    ("gpg-exact-keys", G, '[[ "${got}" != "${expected}" ]]', '[[ -z "${got}" ]]'),
    ("gpg-validsig-pin", G, '$NF==fpr { validsig=1; next }', '{ validsig=1; next }'),
    ("gpg-badsig", G, '($2=="BADSIG"   || ', '($2=="NOPE"   || '),
    ("gpg-rc", G, ' || [ "${rc}" -ne 0 ]; then', '; then'),
    ("gpg-sha256", G, "| sha256sum --check --strict --quiet \\\n", "| true \\\n"),
    ("gpg-apt-pin", G, "Pin-Priority: -1\\n\\nPackage", "Pin-Priority: 1\\n\\nPackage"),
    ("gpg-signed-by", G, "signed-by=${keyring}]", "]"),
    ("qube-install-brave", Q, "install_brave; install_brave_extension", "install_brave_extension"),
]


def run(cmd, cwd, **kw):
    return subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True, **kw)


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


def check_one(tree, mutation):
    name, path, old, new = mutation
    target = os.path.join(tree, path)
    with open(target) as f:
        text = f.read()
    if text.count(old) != 1:
        return name, "ERROR", "original text found %d times in %s" % (text.count(old), path)
    with open(target, "w") as f:
        f.write(text.replace(old, new))
    run(["git", "-c", "user.name=mutate", "-c", "user.email=mutate@invalid",
         "commit", "-q", "-am", name], tree)
    try:
        for layer in LAYERS:
            if run(["bash", "test/run-tests.sh", layer], tree).returncode:
                # A failure under load could be a timeout, not a catch.
                if run(["bash", "test/run-tests.sh", layer], tree).returncode:
                    return name, "caught", layer
                return name, "FLAKY", layer
        return name, "SURVIVED", ""
    finally:
        run(["git", "reset", "-q", "--hard", "HEAD~1"], tree)


def main():
    wanted = [m for m in MUTATIONS if len(sys.argv) < 2 or any(a in m[0] for a in sys.argv[1:])]
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
