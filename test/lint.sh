#!/usr/bin/env bash
# Layer 0 -- static lint. Fast, no Qubes, no Salt. Catches the cheap mistakes
# (shell syntax errors, obviously-broken constructs) before anything heavier
# runs.
#
#   * bash -n on every shell script         -- parse-only syntax check
#   * shellcheck on every shell script      -- deeper shell linting; skipped
#     (if present)                             with a note when not installed
#   * every Salt state/pillar renders + parses as YAML (delegated to the
#     Python render layer, which is the real check)
#   * embedded signing keys: warn within 180 days of expiry, fail within 30
#     (test/key_expiry.py; skipped without gpg)
#   * the docs name every catalogue flag, setting, component, option, pinned
#     fingerprint, and guarded policy file the code defines, and relative
#     Markdown links resolve (test/doc_coherence.py)
#   * each test/mutate.py entry's original text occurs once in its file
#
# Exit non-zero if any hard check fails. shellcheck being absent is a skip,
# not a failure -- install it (apt-get install shellcheck) for full coverage.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

fail=0
note() { printf '  %s\n' "$*"; }

# Every *.sh file, and every other file that starts with a shell's #! line,
# such as the helpers installed into dom0 and the qubes without a suffix.
shellScripts() {
	find . -type f -not -path './.git/*' -not -path './test/hardware/results/*' | sort \
		| while IFS= read -r f; do
			case "$f" in
				*.sh) echo "$f" ;;
				*) head -n 1 "$f" | grep -qE '^#!.*[/ ](ba|da)?sh$' && echo "$f" ;;
			esac
		done
}

echo "== bash -n (syntax) =="
while IFS= read -r f; do
	if err="$(bash -n "$f" 2>&1)"; then
		note "ok   $f"
	else
		note "FAIL $f"; printf '%s\n' "$err" | sed 's/^/       /'; fail=1
	fi
done < <(shellScripts)

echo
echo "== shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
	# -x: follow `. lib.sh` sources. -S error keeps this gate about real
	# breakage only: the repo deliberately carries info/warning-level
	# findings (intentional word-splitting, tar-field placeholders, ...)
	# and a gate that fails on style gets bypassed, not read.
	while IFS= read -r f; do
		if shellcheck -x -S error "$f"; then
			note "ok   $f"
		else
			fail=1
		fi
	done < <(shellScripts)
else
	note "SKIP: shellcheck not installed (apt-get install shellcheck for deeper checks)"
fi

echo
echo "== salt states/pillar render + parse as YAML =="
if python3 test/lint_render.py; then
	note "ok   all states/pillar render to valid YAML"
else
	fail=1
fi

echo
echo "== embedded signing keys: expiry =="
if python3 test/key_expiry.py; then
	note "ok   no embedded signing key expires within 30 days"
else
	fail=1
fi

echo
echo "== docs name what the code defines; relative links resolve =="
if python3 test/doc_coherence.py; then
	note "ok   docs match the code's flags, settings, components, options, keys"
else
	fail=1
fi

echo
echo "== every mutation in test/mutate.py still applies =="
if [ -n "${SEQS_MUTATING:-}" ]; then
	note "SKIP: a mutation is being tested"
elif python3 test/mutate.py --check; then
	note "ok   each mutation's original text occurs once in its file"
else
	fail=1
fi

echo
if [ "$fail" -eq 0 ]; then
	echo "lint: PASS"
else
	echo "lint: FAIL"
fi
exit "$fail"
