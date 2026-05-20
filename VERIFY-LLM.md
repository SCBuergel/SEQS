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
- **`components/keepass/template-vm.sh`** — two checks:
  1. Embedded-key fingerprint check (`IMPORTED_FPR` vs `KEEPASSXC_KEY_FPR`) → `exit 1` **before** the AppImage download.
  2. `gpg --status-fd 1 --verify` chain (`awk … VALIDSIG … $NF==fpr`) → `exit 1` **before** `sudo install -m 0755 ... /usr/bin/keepassxc.AppImage`.
- **`components/bitbox/template-vm.sh`** — analogous two checks, abort **before** `sudo apt-get install -y "${WORKDIR}/${DEB}"`.
- **`components/openoffice/template-vm.sh`** — analogous two checks, abort **before** `tar -xzf …` / the `apt-get install` of the extracted debs.
- **`components/signal/template-vm.sh`**, **`vscode/template-vm.sh`**, **`docker/template-vm.sh`**, **`element/template-vm.sh`** — single embedded-key check; `exit 1` **before** `gpg --export "${*_KEY_FPR}" | sudo tee "${KEYRING}"` (a bad embedded key must not reach the apt keyring path).

**PASS:** every abort is strictly before the corresponding irreversible write. **FAIL:** any script writes to disk first and verifies afterwards.

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
 §1 static syntax         : PASS|FAIL
 §2 component tree shape  : PASS|FAIL
 §3 embedded fingerprints : PASS|FAIL
 §4 Brave multi-key pin   : PASS|FAIL
 §5 live upstream pins    : PASS|FAIL (or "skipped, no network")
 §6 TRUST.md path refs    : PASS|FAIL
 §7 qube spec validation  : PASS|FAIL
 §8 BRAVE_EXTENSIONS form : PASS|FAIL
 §9 logic abort-order     : PASS|FAIL
 §10 README ↔ components  : PASS|FAIL
 §11 fetchRunClean call   : PASS|FAIL
 §12 offline flag logic   : PASS|FAIL
 Notes: <any FAIL details, any human follow-up required>
```

## 14. Interpretation guide

- **`TRUST.md` is the authoritative claim.** Your job is to confirm the code upholds those claims and to flag any drift.
- **Live-fingerprint FAIL (§5)** usually means an upstream rotated keys. Do **not** silently update the pin. Re-verify from three independent sources following the TRUST.md pattern; only then update the pin and the embedded key block.
- **Logic-abort FAIL (§9)** is a real bug — a verifier that runs *after* an irreversible write defeats the point.
- **Static-syntax FAIL (§1)** is a real bug.
- **Coherence FAIL (§6, §10, §11)** is usually doc-vs-code drift; fix whichever side is wrong.
- **Validation FAIL (§7, §8)** is a real bug if `validateAllQubes` should already catch it; this section catches anything that slipped past at design time.
