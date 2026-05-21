# Verifying SEQS — LLM in-depth check

A machine-runnable verification protocol for an LLM with shell access (`curl`, `gpg`, `awk`, `sed`, `grep`, `bash`, optionally `python3`) to confirm that SEQS upholds what `TRUST.md` promises. Run from the repository root of a checked-out SEQS tree. Each section ends with a clear PASS/FAIL criterion; collect them into a final report.

## 0. Conventions

- Commands assume `bash`, run from the repo root.
- "PASS" means the check produced the expected result; "FAIL" means it did not — record actual vs expected.
- Embedded-key checks use an isolated `GNUPGHOME=$(mktemp -d)` per check so no permanent keyring is touched.
- §5 (live upstream fingerprints) needs outbound HTTPS; everything else is offline.

## 1. Static syntax

Every shell script must parse.

```sh
for f in setup-qubes.sh delete-vms.sh install-scripts/lib/*.sh install-scripts/components/*/*.sh; do
    bash -n "$f" && echo "ok: $f" || echo "FAIL: $f"
done
```

**PASS:** every file reports `ok:`. **FAIL:** any `FAIL:`.

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

## 7. Qube spec validation (mirror `validateAllQubes`)

Cross-check every component in every qube spec against the actual components directory and the extension registry.

```sh
# Lookahead for the closing `"` so trailing `# comments` after each spec line
# don't bleed into a second pseudo-match.
SINGLE=$(sed -n '/^SINGLE_QUBES=(/,/^)$/p' setup-qubes.sh | grep -oP '"\K[^"]+(?=")')
WALLET=$(sed -n '/^WALLET_QUBES=(/,/^)$/p' setup-qubes.sh | grep -oP '"\K[^"]+(?=")')
DEV=$(   sed -n '/^DEV_QUBES=(/,/^)$/p'    setup-qubes.sh | grep -oP '"\K[^"]+(?=")')
# space-separated so the case-pattern membership tests below match correctly;
# `(?= )` keeps just the leading name token of each "<name> <id>" pair.
EXT_NAMES=$(sed -n '/^BRAVE_EXTENSIONS=(/,/^)$/p' setup-qubes.sh | grep -oP '"\K[a-z0-9-]+(?= )' | tr '\n' ' ')
COMPS=$(ls install-scripts/components/ | tr '\n' ' ')

# Collect all specs into an array with IFS=newline, then iterate with default
# IFS so the inner 'set --' word-splits each spec on spaces.
old_ifs=$IFS
IFS=$'\n'
specs=( $SINGLE $WALLET $DEV )
IFS=$old_ifs

errors=0; all_names=" "
for spec in "${specs[@]}"; do
    set -- $spec
    name=$1; shift 2
    args=("$@")
    n=${#args[@]}
    [ "${args[$((n-1))]:-}" = "offline" ] && unset 'args[n-1]'
    case " $all_names " in *" $name "*) echo "  FAIL: duplicate name '$name'"; errors=$((errors+1));; esac
    all_names+="$name "
    for c in "${args[@]}"; do
        case "$c" in
            brave-extension-*)
                en=${c#brave-extension-}
                case " $EXT_NAMES " in *" $en "*) ;; *) echo "  FAIL: unknown extension '$en' in '$name'"; errors=$((errors+1));; esac
                ;;
            *)
                case " $COMPS " in *" $c "*) ;; *) echo "  FAIL: unknown component '$c' in '$name'"; errors=$((errors+1));; esac
                ;;
        esac
    done
done
[ "$errors" -eq 0 ] && echo "  qube specs: PASS" || echo "  qube specs: FAIL ($errors errors)"
```

**PASS:** `qube specs: PASS`.

## 8. `BRAVE_EXTENSIONS` well-formed

Each entry must be `<name> <32-char-lowercase-id>` (Chrome Web Store ID format). Names must be unique.

```sh
sed -n '/^BRAVE_EXTENSIONS=(/,/^)$/p' setup-qubes.sh | grep -oP '"\K[^"]+(?=")' | while read line; do
    name=${line%% *}; id=${line##* }
    [[ "$id" =~ ^[a-z]{32}$ ]] || echo "  FAIL: '$name' has malformed id '$id' (want 32 lowercase letters)"
done

dupes=$(sed -n '/^BRAVE_EXTENSIONS=(/,/^)$/p' setup-qubes.sh | grep -oP '"\K[a-z0-9-]+(?= )' | sort | uniq -d)
[ -z "$dupes" ] && echo "  BRAVE_EXTENSIONS names: PASS" || echo "  FAIL: duplicate extension names: $dupes"
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
- **`setup-qubes.sh::setupBrowserPolicy` and `::setupUsbKeyboardPolicy`** — when the target policy file already exists, both functions delegate to `confirmPolicyOverwrite`, which `read`s confirmation from `/dev/tty` and `exit 1`s **before** the `sudo tee` overwrite if the operator types anything other than the literal string `OVERWRITE` (or if no terminal is available). Same factoring as `verify-gpg.sh`: one helper, two callers, no drift.

**PASS:** every abort is strictly before the corresponding irreversible write. **FAIL:** any script writes to disk first and verifies afterwards.

## 9a. Verifier-helper usage parity

The two consolidation helpers (`lib/verify-gpg.sh::verify_detached_sig` and `setup-qubes.sh::confirmPolicyOverwrite`) only protect SEQS if every site that *should* use them actually does. A regression here would re-introduce the inline-awk / no-confirm bugs the helpers were created to fix.

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

# 9a.ii -- both qrexec-policy installers must funnel through
# confirmPolicyOverwrite. A direct `sudo tee /etc/qubes/policy.d/...`
# inside either function (without the helper call earlier in the same
# function body) is a drift bug.
for fn in setupBrowserPolicy setupUsbKeyboardPolicy; do
    body=$(awk -v fn="$fn" '
        $0 ~ "^function " fn         { in_fn=1; next }
        in_fn                        { print }
        in_fn && /^\}/               { in_fn=0 }
    ' setup-qubes.sh)
    echo "$body" | grep -q 'confirmPolicyOverwrite ' \
        && echo "  $fn: PASS" \
        || echo "  $fn: FAIL (does not call confirmPolicyOverwrite)"
done
```

**PASS:** every line `PASS`. **FAIL:** any inline awk / `|| true` mask back in a component, or a policy installer that bypasses the confirm helper.

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

## 9c. dom0 terminal sanitizer covers both C0 and UTF-8-encoded C1

`setup-qubes.sh::vmRun` must strip C0 control bytes (the 7-bit form of ESC, BEL, CR, …) **and** the two-byte UTF-8 encoding of the C1 control range U+0080..U+009F (including the single-byte CSI U+009B and OSC U+009D). The previous form stripped only C0; xterm with `allowC1Printable: false` (the default) interprets the UTF-8-encoded C1 codepoints as control sequences, so a sanitizer that doesn't strip them leaves a parallel channel open.

```sh
# Extract the vmRun function body and check both stages are present.
body=$(awk '/^function vmRun/{in_fn=1} in_fn{print} in_fn && /^\}/{in_fn=0}' setup-qubes.sh)
ok=1
echo "$body" | grep -q "tr -d '\\\\000-\\\\010"                           || { echo "  vmRun: FAIL (C0/DEL strip via tr missing)"; ok=0; }
echo "$body" | grep -q 'sed -E .*\\xc2\[\\x80-\\x9f\]'                    || { echo "  vmRun: FAIL (UTF-8 C1 strip via sed missing)"; ok=0; }
echo "$body" | grep -q 'LC_ALL=C'                                         || { echo "  vmRun: FAIL (LC_ALL=C not set for sed -- byte ranges may not match in non-C locale)"; ok=0; }
[ "$ok" -eq 1 ] && echo "  vmRun sanitizer: PASS"
```

**PASS:** `vmRun sanitizer: PASS`. **FAIL:** any one stage missing or `LC_ALL=C` absent.

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

## 11. `fetchRunClean` called correctly for normal components

In `installQube`'s template phase, every non-`brave-extension-*` component must pass the component name as the 5th arg to `fetchRunClean` so a per-component `menu.desktop` is picked up if present.

```sh
problems=$(grep -nE 'fetchRunClean[^#]*template-vm\.sh' setup-qubes.sh | grep -v '"\${comp}"' || true)
[ -z "$problems" ] && echo "  fetchRunClean menu.desktop arg: PASS" \
                   || { echo "  FAIL:"; echo "$problems"; }
```

## 12. Offline-flag detection logic

Confirm the trailing-`offline` parser in `installQube` behaves correctly.

```sh
bash -c '
test_one() {
    local args=("$@")
    local n=${#args[@]}
    local OFFLINE=""
    if [ "$n" -gt 0 ] && [ "${args[$((n-1))]}" = "offline" ]; then
        OFFLINE="offline"
        unset "args[n-1]"
    fi
    echo "  in: $* -> offline=[$OFFLINE]"
}
test_one keepass black keepass offline
test_one brave   red   brave
test_one wallet-ledger orange ledger brave-extension-rabby
'
```

**Expected:** the keepass line shows `offline=[offline]`; the other two show `offline=[]`.

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
 §8  BRAVE_EXTENSIONS form      : PASS|FAIL
 §9  logic abort-order          : PASS|FAIL
 §9a verifier-helper parity     : PASS|FAIL
 §9b apt-preferences pin parity : PASS|FAIL
 §9c vmRun C0+C1 sanitizer      : PASS|FAIL
 §10 README ↔ components        : PASS|FAIL
 §11 fetchRunClean call         : PASS|FAIL
 §12 offline flag logic         : PASS|FAIL
 Notes: <any FAIL details, any human follow-up required>
```

## 14. Interpretation guide

- **`TRUST.md` is the authoritative claim.** Your job is to confirm the code upholds those claims and to flag any drift.
- **Live-fingerprint FAIL (§5)** usually means an upstream rotated keys. Do **not** silently update the pin. Re-verify from three independent sources following the TRUST.md pattern; only then update the pin and the embedded key block.
- **Logic-abort FAIL (§9)** is a real bug — a verifier that runs *after* an irreversible write defeats the point.
- **Verifier-helper FAIL (§9a)** is a real bug. The helpers (`verify_detached_sig`, `confirmPolicyOverwrite`) exist specifically to make verification one-place. A site that bypasses them with inline awk / direct `sudo tee` is the drift the helpers were created to prevent.
- **apt-pin FAIL (§9b)** is a real bug. A third-party apt repo without a matching `preferences.d/*.pref` means a key-compromise at that upstream can ship arbitrary higher-version system packages and apt will prefer them over Debian's.
- **Sanitizer FAIL (§9c)** is a real bug. A missing C1 strip leaves the dom0 terminal exposed to UTF-8-encoded CSI/OSC sequences emitted from any compromised installer-side process.
- **Static-syntax FAIL (§1)** is a real bug.
- **Coherence FAIL (§6, §10, §11)** is usually doc-vs-code drift; fix whichever side is wrong.
- **Validation FAIL (§7, §8)** is a real bug if `validateAllQubes` should already catch it; this section catches anything that slipped past at design time.
