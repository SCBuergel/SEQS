# Verifying SEQS — LLM in-depth check

A machine-runnable verification protocol for an LLM with shell access (`curl`, `gpg`, `awk`, `sed`, `grep`, `bash`, optionally `python3`) to confirm that SEQS upholds what `TRUST.md` promises. Run from the repository root of a checked-out SEQS tree. Each section ends with a clear PASS/FAIL criterion; collect them into a final report.

## 0. Conventions

- Commands assume `bash`, run from the repo root.
- "PASS" means the check produced the expected result; "FAIL" means it did not — record actual vs expected.
- Embedded-key checks use an isolated `GNUPGHOME=$(mktemp -d)` per check so no permanent keyring is touched.
- §5 (live upstream fingerprints) needs outbound HTTPS; everything else is offline.

## 1. Static syntax

Every shell script must parse, and the salt tree must be present and complete.

```sh
for f in setup-qubes.sh delete-vms.sh install-scripts/lib/*.sh install-scripts/components/*/*.sh; do
    bash -n "$f" && echo "ok: $f" || echo "FAIL: $f"
done
for f in salt/seqs/dom0.sls salt/seqs/dom0.top salt/seqs/qube.sls salt/seqs/qube.top \
         salt/pillar/seqs/config.sls salt/pillar/seqs/config.top; do
    [ -f "$f" ] && echo "ok: $f" || echo "FAIL: $f missing"
done
# Optional (needs python3-jinja2): the .sls files must at least be valid jinja.
python3 - <<'EOF' 2>/dev/null || echo "  (jinja parse skipped -- no python3/jinja2)"
import jinja2
env = jinja2.Environment(extensions=["jinja2.ext.do"])
for f in ("salt/seqs/dom0.sls", "salt/seqs/qube.sls", "salt/pillar/seqs/config.sls"):
    env.parse(open(f).read()); print("  jinja ok:", f)
EOF
```

**PASS:** every file reports `ok:`. **FAIL:** any `FAIL:`. (Full render verification needs salt's mocked functions — that belongs on a real Qubes box via `sudo qubesctl state.show_sls seqs.dom0`.)

## 2. Component tree shape

Every component directory must contain at least one of `template-vm.sh` / `app-vm.sh`; an isolated `menu.desktop` without a script is malformed.

```sh
for d in install-scripts/components/*/; do
    name=$(basename "$d")
    if [ ! -f "$d/template-vm.sh" ] && [ ! -f "$d/app-vm.sh" ]; then
        echo "FAIL: $name has neither template-vm.sh nor app-vm.sh"
    fi
done
```

**PASS:** no output.

## 3. Embedded key fingerprints match the in-script pin

For each verified component with an embedded key block, extract the block, import to a throwaway GNUPGHOME, and compare the primary fingerprint to the `*_KEY_FPR` value declared at the top of the same script. The two must match.

```sh
check_embedded() {
    local file="$1" var="$2"
    local declared
    declared=$(grep -E "^${var}=" "$file" | sed -E "s/.*=\"([^\"]+)\".*/\1/" | head -1)
    local gh; gh=$(mktemp -d)
    local got
    got=$(awk '/-----BEGIN PGP/,/-----END PGP/' "$file" \
            | GNUPGHOME="$gh" gpg --import 2>/dev/null; \
          GNUPGHOME="$gh" gpg --with-colons --fingerprint 2>/dev/null \
            | awk -F: '$1=="fpr"{print $10; exit}')
    rm -rf "$gh"
    if [ "$got" = "$declared" ]; then echo "  $file: PASS ($declared)"
    else echo "  $file: FAIL  got=$got  want=$declared"; fi
}

check_embedded install-scripts/components/keepass/template-vm.sh    KEEPASSXC_KEY_FPR
check_embedded install-scripts/components/signal/template-vm.sh     SIGNAL_KEY_FPR
check_embedded install-scripts/components/vscode/template-vm.sh     MS_KEY_FPR
check_embedded install-scripts/components/docker/template-vm.sh     DOCKER_KEY_FPR
check_embedded install-scripts/components/openoffice/template-vm.sh AOO_KEY_FPR
check_embedded install-scripts/components/bitbox/template-vm.sh     BITBOX_KEY_FPR
check_embedded install-scripts/components/element/template-vm.sh    ELEMENT_KEY_FPR
```

**PASS:** every line reports `PASS`.

## 4. Brave keyring (multi-key special case)

`lib/brave.sh` pins **three** fingerprints (`BRAVE_KEY_FPRS`). The keyring currently served by Brave's S3 bucket must contain exactly that set (sorted).

```sh
want=$(awk '/^BRAVE_KEY_FPRS=/,/^"$/' install-scripts/lib/brave.sh | grep -oE '[0-9A-F]{40}' | sort)
gh=$(mktemp -d)
got=$(curl -fsSL https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg \
        | GNUPGHOME="$gh" gpg --show-keys --with-colons 2>/dev/null \
        | awk -F: '$1=="pub"{w=1}$1=="fpr"&&w{print $10;w=0}' | sort)
rm -rf "$gh"
if [ "$want" = "$got" ]; then echo "  Brave keyring: PASS"
else echo "  Brave keyring: FAIL"; diff <(echo "$want") <(echo "$got"); fi
```

**PASS:** `Brave keyring: PASS`.

## 5. Live upstream fingerprints still match the pins

For each verified component, fetch the documented authoritative source and confirm the live fingerprint still equals what's pinned in the code. A FAIL here usually means upstream rotated keys; do **not** silently update the pin — re-verify the new key against three independent sources (see TRUST.md for the pattern) before changing anything.

```sh
fetch_fpr() {
    local gh; gh=$(mktemp -d)
    curl -fsSL "$1" 2>/dev/null \
      | GNUPGHOME="$gh" gpg --show-keys --with-colons 2>/dev/null \
      | awk -F: '$1=="pub"{w=1}$1=="fpr"&&w{print $10;w=0}'
    rm -rf "$gh"
}
expect()  { local got="$1" want="$2" label="$3"
            [ "$got" = "$want" ] && echo "  $label: PASS" || echo "  $label: FAIL  got=$got"; }

expect "$(fetch_fpr https://keys.openpgp.org/vks/v1/by-fingerprint/BF5A669F2272CF4324C1FDA8CFB4C2166397D0D2)" \
       BF5A669F2272CF4324C1FDA8CFB4C2166397D0D2 "KeePassXC live"

expect "$(fetch_fpr https://updates.signal.org/desktop/apt/keys.asc | head -1)" \
       DBA36B5181D0C816F630E889D980A17457F6FB06 "Signal live"

expect "$(fetch_fpr https://download.docker.com/linux/debian/gpg)" \
       9DC858229FC7DD38854AE2D88D81803C0EBFCD88 "Docker live"

expect "$(fetch_fpr https://packages.microsoft.com/keys/microsoft.asc)" \
       BC528686B50D79E339D3721CEB3E94ADBE1229CF "Microsoft live"

expect "$(fetch_fpr https://keys.openpgp.org/vks/v1/by-keyid/509249B068D215AE)" \
       DD09E41309750EBFAE0DEF63509249B068D215AE "BitBox live"

expect "$(fetch_fpr https://packages.element.io/debian/element-io-archive-keyring.gpg)" \
       12D4CD600C2240A9F4A82071D7B0B66941D01538 "Element live"

# Apache OpenOffice -- pinned key must appear inside the KEYS file
curl -fsSL https://downloads.apache.org/openoffice/KEYS \
  | gpg --show-keys --with-colons 2>/dev/null \
  | awk -F: '$1=="pub"{w=1}$1=="fpr"&&w{print $10;w=0}' \
  | grep -qx A93D62ECC3C8EA12DB220EC934EA76E6791485A8 \
  && echo "  AOO live: PASS" || echo "  AOO live: FAIL"

# Brave -- live keyring must equal the sorted pin set
want=$(awk '/^BRAVE_KEY_FPRS=/,/^"$/' install-scripts/lib/brave.sh | grep -oE '[0-9A-F]{40}' | sort | tr '\n' ' ')
got=$(fetch_fpr https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg | sort | tr '\n' ' ')
[ "$want" = "$got" ] && echo "  Brave live: PASS" || echo "  Brave live: FAIL"
```

**PASS:** every line `PASS`. **FAIL** suggests upstream key rotation.

## 6. TRUST.md ↔ code path references exist

Every `install-scripts/...` path mentioned in TRUST.md must exist on disk.

```sh
# Exclude wildcards (e.g. "install-scripts/*.sh") -- those are descriptive
# in prose, not real paths to check.
grep -oE 'install-scripts/[^ )`*?]+' TRUST.md | sort -u | while read p; do
    [ -e "$p" ] && echo "  $p: PASS" || echo "  $p: FAIL (missing)"
done
```

**PASS:** no missing.

## 7. Qube spec validation (mirror the `seqs.dom0` pre-flight)

Cross-check every component in every `qube_list` entry (in `salt/pillar/seqs/config.sls`) against the actual components directory and the `brave_extensions` registry; names must be unique. This statically mirrors what the `seqs.dom0` state validates at render time.

```sh
EXT_NAMES=$(sed -n "/^{%- set brave_extensions = {/,/^} %}/p" salt/pillar/seqs/config.sls \
            | grep -oP "^  '\K[a-z0-9-]+(?=':)")
COMPS=$(ls install-scripts/components/)
errors=0; seen=" "
while IFS= read -r line; do
    name=$(grep -oP "'name': '\K[^']+" <<<"$line") || true
    [ -z "$name" ] && continue
    case "$seen" in *" $name "*) echo "  FAIL: duplicate name '$name'"; errors=$((errors+1));; esac
    seen+="$name "
    for c in $(grep -oP "'components': \[\K[^]]*" <<<"$line" | tr -d "'," ); do
        case "$c" in
            brave-extension-*)
                en=${c#brave-extension-}
                grep -qx "$en" <<<"$EXT_NAMES" || { echo "  FAIL: unknown extension '$en' in '$name'"; errors=$((errors+1)); } ;;
            *)
                grep -qx "$c" <<<"$COMPS" || { echo "  FAIL: unknown component '$c' in '$name'"; errors=$((errors+1)); } ;;
        esac
    done
done < <(sed -n "/^{%- set qube_list = \[/,/^\] %}/p" salt/pillar/seqs/config.sls)
[ "$errors" -eq 0 ] && echo "  qube specs: PASS" || echo "  qube specs: FAIL ($errors errors)"
```

**PASS:** `qube specs: PASS`.

## 8. `brave_extensions` well-formed

Each entry in `config.sls` must map a unique name to a 32-character `[a-p]` Chrome Web Store ID (the same `^[a-p]{32}$` the states enforce before interpolating an ID into a shell command).

```sh
bad=0
while IFS= read -r line; do
    name=$(grep -oP "^  '\K[a-z0-9-]+(?=':)" <<<"$line") || true; [ -z "$name" ] && continue
    id=$(grep -oP ": *'\K[a-z]+(?=',)" <<<"$line") || true
    [[ "$id" =~ ^[a-p]{32}$ ]] || { echo "  FAIL: '$name' has malformed id '$id' (want 32 chars a-p)"; bad=1; }
done < <(sed -n "/^{%- set brave_extensions = {/,/^} %}/p" salt/pillar/seqs/config.sls)
dupes=$(sed -n "/^{%- set brave_extensions = {/,/^} %}/p" salt/pillar/seqs/config.sls \
        | grep -oP "^  '\K[a-z0-9-]+(?=':)" | sort | uniq -d)
[ "$bad" -eq 0 ] && [ -z "$dupes" ] && echo "  brave_extensions: PASS" \
    || echo "  brave_extensions: FAIL (dupes: ${dupes:-none})"
```

## 9. Logic check — every verifier aborts *before* an irreversible write

Read each verifier script (no automated check; do it manually) and confirm the abort-on-mismatch happens **before** any side effect that would commit the unverified material:

- **`lib/brave.sh` → `install_brave()`** — compares sorted `${got}` against sorted `${expected}` (the three pinned `BRAVE_KEY_FPRS`). On mismatch the function does `rm -f "${tmp}"` and `exit 1` **before** `sudo install -m 0644 "${tmp}" "${keyring}"`.
- **`lib/verify-gpg.sh` → `verify_detached_sig()`** — the single source of truth for detached-signature verification used by the keepass / bitbox / openoffice installers. Captures `gpg --status-fd 1 --verify`'s exit code explicitly into `$rc` (NO `|| true` masking, unlike the earlier inlined version), then runs an awk filter that:
  - **requires both** a `[GNUPG:] GOODSIG` line and a `[GNUPG:] VALIDSIG <… primary_fpr>` line whose primary-key fingerprint equals the pin (one or the other alone is insufficient — `VALIDSIG` fires whenever the math works, including for expired/revoked keys);
  - **rejects** any `[GNUPG:] BADSIG` / `ERRSIG` / `EXPSIG` / `EXPKEYSIG` / `REVKEYSIG` / `KEYEXPIRED` / `KEYREVOKED` / `NO_PUBKEY` line anywhere in the output.

  Any failure path ends in `exit 1` **before** the calling script reaches its install/extract step.
- **`components/keepass/template-vm.sh`** — two checks:
  1. Embedded-key fingerprint check (`IMPORTED_FPR` vs `KEEPASSXC_KEY_FPR`) → `exit 1` **before** the AppImage download.
  2. `verify_detached_sig` call (delegated to `lib/verify-gpg.sh`) → `exit 1` **before** `sudo install -m 0755 ... /usr/bin/keepassxc.AppImage`.
- **`components/bitbox/template-vm.sh`** — analogous two checks (the second via `verify_detached_sig`), abort **before** `sudo apt-get install -y "${WORKDIR}/${DEB}"`.
- **`components/openoffice/template-vm.sh`** — analogous two checks (the second via `verify_detached_sig`), abort **before** `tar -xzf …` / the `apt-get install -y "${DEBS[@]}"` of the extracted debs. (Note: install passes the hashed `DEBS[@]` array directly — *not* a fresh `*.deb` glob — so the install set is exactly the set whose SHA-256 was re-verified above.)
- **`components/signal/template-vm.sh`**, **`vscode/template-vm.sh`**, **`docker/template-vm.sh`**, **`element/template-vm.sh`** — single embedded-key check; `exit 1` **before** `gpg --export "${*_KEY_FPR}" | sudo tee "${KEYRING}"` (a bad embedded key must not reach the apt keyring path).
- **`setup-qubes.sh::fetchSaltTree`** — every tar entry is validated (type, charset, no `..`, no whitespace) **before** `tar -xf`, the `.seqs-managed` marker guard refuses `/srv` trees SEQS did not create **before** `rm -rf`, and the `CONTINUE` review gate (read from `/dev/tty`) blocks **before** the fetched tree is installed as root-owned salt code.
- **`setup-qubes.sh::confirmPolicyTakeover`** — a policy file without the `Managed by SEQS` header blocks on a literal `OVERWRITE` (read from `/dev/tty`) **before** `qubesctl state.apply seqs.dom0` is invoked at all.
- **`salt/seqs/dom0.sls` pre-flight** — every validation failure funnels into the `seqs-validation-failed` state (`test.fail_without_changes` + `failhard: True`), and the entire creation/policy section is inside the `{% else %}` branch — nothing is changed on a validation failure.
- **`setup-qubes.sh::verifyAirgap`** — refuses to start per-qube provisioning if any `offline` qube still has a netvm after the dom0 apply.

**PASS:** every abort is strictly before the corresponding irreversible write. **FAIL:** any script writes to disk first and verifies afterwards.

## 9a. Verifier-helper usage parity & policy ownership parity

The consolidation helpers only protect SEQS if every site that *should* use them actually does, and the runner's takeover gate only protects the policy files the dom0 state actually writes.

```sh
# 9a.i -- every component that downloads a tarball / .deb / AppImage and a
# detached signature must source verify-gpg.sh AND call verify_detached_sig,
# AND must NOT contain the old inline-awk VALIDSIG pattern.
for c in keepass bitbox openoffice; do
    f="install-scripts/components/$c/template-vm.sh"
    ok=1
    grep -q '\. "\$(dirname "\$0")/verify-gpg\.sh"' "$f" || { echo "  $c: FAIL (verify-gpg.sh not sourced)"; ok=0; }
    grep -q 'verify_detached_sig '                    "$f" || { echo "  $c: FAIL (no verify_detached_sig call)"; ok=0; }
    grep -q 'VALIDSIG.*\$NF==fpr'                     "$f" && { echo "  $c: FAIL (inline awk VALIDSIG check still present -- regression)"; ok=0; }
    grep -q '|| true'                                 "$f" && { echo "  $c: FAIL (|| true mask still present -- regression)"; ok=0; }
    [ "$ok" -eq 1 ] && echo "  $c: PASS"
done

# 9a.ii -- the runner's POLICY_FILES list and the policy paths managed by the
# dom0 state must be the same set (a policy the state writes but the runner
# doesn't gate would be silently clobberable; the reverse is a stale prompt),
# and every policy the state writes must carry the managed marker its own
# takeover logic looks for.
runner=$(sed -n '/^POLICY_FILES=(/,/^)$/p' setup-qubes.sh | grep -oP '/etc/qubes/policy\.d/[0-9A-Za-z.-]+' | sort -u)
state=$(grep -oP '/etc/qubes/policy\.d/[0-9A-Za-z.-]+' salt/seqs/dom0.sls | sort -u)
diff <(echo "$runner") <(echo "$state") >/dev/null \
    && echo "  policy ownership parity: PASS" \
    || { echo "  policy ownership parity: FAIL"; diff <(echo "$runner") <(echo "$state"); }
n=$(grep -c 'Managed by SEQS' salt/seqs/dom0.sls)
[ "$n" -ge 4 ] && echo "  managed markers present: PASS ($n)" \
               || echo "  managed markers present: FAIL (only $n)"
```

**PASS:** every line `PASS`. **FAIL:** any inline awk / `|| true` mask back in a component, a policy-path mismatch between runner and state, or a managed policy without its marker.

## 9b. apt-preferences pin parity for third-party repos

Every third-party apt repository SEQS adds must drop a matching `/etc/apt/preferences.d/*.pref` that default-denies the origin (`Pin-Priority: -1`) and re-allows only the specific packages it ships. Without this, a signing-key compromise at the upstream could ship a higher-version `bash` / `libc6` / `systemd` / etc. via that repo and apt would prefer it over Debian's.

```sh
# For each (file, origin) pair, the file must contain BOTH a
# Pin-Priority: -1 default-deny AND a re-allow at Pin-Priority: 500,
# both targeting the same origin string.
check_apt_pin() {
    local file="$1" origin="$2"
    local ok=1
    grep -qE "Pin: *origin *\"${origin}\"" "$file" || { echo "  $file: FAIL (no Pin: origin \"${origin}\")"; ok=0; }
    grep -qE 'Pin-Priority: *-1'           "$file" || { echo "  $file: FAIL (no Pin-Priority: -1 default-deny)"; ok=0; }
    grep -qE 'Pin-Priority: *500'          "$file" || { echo "  $file: FAIL (no Pin-Priority: 500 re-allow)"; ok=0; }
    [ "$ok" -eq 1 ] && echo "  $file ($origin): PASS"
}
check_apt_pin install-scripts/lib/brave.sh                       'brave-browser-apt-release\.s3\.brave\.com'
check_apt_pin install-scripts/components/docker/template-vm.sh   'download\.docker\.com'
check_apt_pin install-scripts/components/vscode/template-vm.sh   'packages\.microsoft\.com'
check_apt_pin install-scripts/components/signal/template-vm.sh   'updates\.signal\.org'
check_apt_pin install-scripts/components/element/template-vm.sh  'packages\.element\.io'
```

**PASS:** every line `PASS`. **FAIL:** any third-party apt installer missing its pin file.

## 9c. dom0 terminal sanitizer covers C0, raw C1, and UTF-8-encoded C1

`setup-qubes.sh::sanitize` must strip C0 control bytes (the 7-bit form of ESC, BEL, CR, …), raw 8-bit C1 bytes (via `iconv`), **and** the two-byte UTF-8 encoding of the C1 control range U+0080..U+009F (including CSI U+009B and OSC U+009D) — xterm with `allowC1Printable: false` (the default) interprets those as control sequences. And every `qubesctl` invocation must actually route through it.

```sh
body=$(awk '/^sanitize\(\) \{/{in_fn=1} in_fn{print} in_fn && /^\}/{in_fn=0}' setup-qubes.sh)
ok=1
echo "$body" | grep -q "tr -d '\\\\000-\\\\010"        || { echo "  sanitize: FAIL (C0/DEL strip via tr missing)"; ok=0; }
echo "$body" | grep -q 'iconv -f UTF-8 -t UTF-8 -c'    || { echo "  sanitize: FAIL (raw C1 strip via iconv missing)"; ok=0; }
echo "$body" | grep -qE 'sed -E .*xc2\[.x80-.x9f\]'    || { echo "  sanitize: FAIL (UTF-8 C1 strip via sed missing)"; ok=0; }
echo "$body" | grep -q 'LC_ALL=C'                      || { echo "  sanitize: FAIL (LC_ALL=C not set -- byte ranges may not match in non-C locale)"; ok=0; }
grep -qF 'sudo qubesctl "$@" 2>&1 | sanitize' setup-qubes.sh \
                                                       || { echo "  sanitize: FAIL (runQubesctl does not pipe qubesctl through sanitize)"; ok=0; }
[ "$ok" -eq 1 ] && echo "  sanitize: PASS"
```

**PASS:** `sanitize: PASS`. **FAIL:** any one stage missing, `LC_ALL=C` absent, or a qubesctl path that bypasses the filter.

## 10. README ↔ components coherence

Every component listed in the README's component table must exist on disk, and every on-disk component should appear in the table.

```sh
# Extract just the FIRST backtick'd token per table row (the component name),
# not every backtick'd token (which would pick up package names in the
# description column).
table=$(awk '/^\| Component \|/,/^$/' README.md \
        | sed -nE 's/^\| `([a-z][a-z0-9-]*)`.*/\1/p' | sort -u)
disk=$(ls install-scripts/components/ | sort -u)
diff <(echo "$table") <(echo "$disk") && echo "  README table: PASS" \
                                       || echo "  README table: FAIL (diff above)"
```

## 11. Component staging contract (lib overlay + menu.desktop)

The `seqs.qube` state must overlay the shared libs **after** each component's own files (so a component asset can never shadow `verify-gpg.sh`/`brave.sh` — the lib must win), and must install a component's `menu.desktop` root-owned.

```sh
grep -A8 'seqs-stage-{{ comp }}-libs:' salt/seqs/qube.sls | grep -q 'file: seqs-stage-{{ comp }}' \
    && echo "  lib overlay ordering: PASS" \
    || echo "  lib overlay ordering: FAIL (libs not required after component stage)"
grep -q 'install -m 0644 -o root -g root /run/seqs/stage/{{ comp }}/menu.desktop' salt/seqs/qube.sls \
    && echo "  menu.desktop root-owned: PASS" \
    || echo "  menu.desktop root-owned: FAIL"
```

## 12. Offline / air-gap logic (three layers)

The `offline` flag must (a) exist in the pillar spec, (b) produce the netvm-clearing state and the `offline` column in the targets file in `seqs.dom0`, and (c) be independently re-verified by the runner **before** any provisioning starts.

```sh
grep -q "'name': 'keepass'.*'offline': True" salt/pillar/seqs/config.sls \
    && echo "  pillar offline flag: PASS" || echo "  pillar offline flag: FAIL"
grep -q 'netvm none' salt/seqs/dom0.sls \
    && echo "  dom0 netvm-clearing state: PASS" || echo "  dom0 netvm-clearing state: FAIL"
grep -qF "{{ ' offline' if q.get('offline') else '' }}" salt/seqs/dom0.sls \
    && echo "  targets offline column: PASS" || echo "  targets offline column: FAIL"
va=$(grep -n '^verifyAirgap$' setup-qubes.sh | cut -d: -f1)
prov=$(grep -n 'state.apply seqs.qube' setup-qubes.sh | head -1 | cut -d: -f1)
[ -n "$va" ] && [ -n "$prov" ] && [ "$va" -lt "$prov" ] \
    && echo "  runner air-gap gate before provisioning: PASS" \
    || echo "  runner air-gap gate before provisioning: FAIL (va=$va prov=$prov)"
# offline implies no_handoff in the per-qube state:
grep -qF "spec.get('no_handoff', False) or spec.get('offline', False)" salt/seqs/qube.sls \
    && echo "  offline implies no_handoff: PASS" || echo "  offline implies no_handoff: FAIL"
```

**PASS:** all five lines `PASS`.

## 13. Final report format

Aggregate the section results into one block:

```
SEQS LLM verification report — <date>
 §1  static syntax              : PASS|FAIL
 §2  component tree shape       : PASS|FAIL
 §3  embedded fingerprints      : PASS|FAIL
 §4  Brave multi-key pin        : PASS|FAIL
 §5  live upstream pins         : PASS|FAIL (or "skipped, no network")
 §6  TRUST.md path refs         : PASS|FAIL
 §7  qube spec validation       : PASS|FAIL
 §8  brave_extensions form      : PASS|FAIL
 §9  logic abort-order          : PASS|FAIL
 §9a helper + policy parity     : PASS|FAIL
 §9b apt-preferences pin parity : PASS|FAIL
 §9c sanitize C0+C1 coverage    : PASS|FAIL
 §10 README ↔ components        : PASS|FAIL
 §11 component staging contract : PASS|FAIL
 §12 offline / air-gap logic    : PASS|FAIL
 Notes: <any FAIL details, any human follow-up required>
```

## 14. Interpretation guide

- **`TRUST.md` is the authoritative claim.** Your job is to confirm the code upholds those claims and to flag any drift.
- **Live-fingerprint FAIL (§5)** usually means an upstream rotated keys. Do **not** silently update the pin. Re-verify from three independent sources following the TRUST.md pattern; only then update the pin and the embedded key block.
- **Logic-abort FAIL (§9)** is a real bug — a verifier that runs *after* an irreversible write defeats the point.
- **Helper/parity FAIL (§9a)** is a real bug. `verify_detached_sig` exists specifically to make signature verification one-place; a component that bypasses it with inline awk is the drift it was created to prevent. A policy-path mismatch between the runner's `POLICY_FILES` and the dom0 state means a policy salt writes that the takeover prompt does not guard (or a stale prompt for a file salt never touches).
- **apt-pin FAIL (§9b)** is a real bug. A third-party apt repo without a matching `preferences.d/*.pref` means a key-compromise at that upstream can ship arbitrary higher-version system packages and apt will prefer them over Debian's.
- **Sanitizer FAIL (§9c)** is a real bug. A missing C1 strip leaves the dom0 terminal exposed to UTF-8-encoded CSI/OSC sequences embedded in qubesctl-relayed installer output.
- **Static-syntax FAIL (§1)** is a real bug.
- **Coherence FAIL (§6, §10)** is usually doc-vs-code drift; fix whichever side is wrong.
- **Validation FAIL (§7, §8)** is a real bug if the `seqs.dom0` pre-flight should already catch it; this section catches anything that slipped past at design time.
- **Staging/offline FAIL (§11, §12)** is a real bug — a lib shadowed by a component asset runs unreviewed code as root in the template; a broken air-gap layer defeats the `offline` flag's entire purpose.
