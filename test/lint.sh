#!/usr/bin/env bash
# Layer 0 -- static lint. Fast, no Qubes, no Salt. Catches the cheap mistakes
# (shell syntax errors, obviously-broken constructs) before anything heavier
# runs.
#
#   * bash -n on every *.sh                 -- parse-only syntax check
#   * shellcheck on every *.sh (if present) -- deeper shell linting; skipped
#                                              with a note when not installed
#   * every Salt state/pillar renders + parses as YAML (delegated to the
#     Python render layer, which is the real check)
#
# Exit non-zero if any hard check fails. shellcheck being absent is a skip,
# not a failure -- install it (apt-get install shellcheck) for full coverage.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

fail=0
note() { printf '  %s\n' "$*"; }

echo "== bash -n (syntax) =="
while IFS= read -r f; do
	if err="$(bash -n "$f" 2>&1)"; then
		note "ok   $f"
	else
		note "FAIL $f"; printf '%s\n' "$err" | sed 's/^/       /'; fail=1
	fi
done < <(find . -name '*.sh' -not -path './.git/*' | sort)

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
	done < <(find . -name '*.sh' -not -path './.git/*' | sort)
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
if [ "$fail" -eq 0 ]; then
	echo "lint: PASS"
else
	echo "lint: FAIL"
fi
exit "$fail"
