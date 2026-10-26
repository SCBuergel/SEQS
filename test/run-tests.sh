#!/usr/bin/env bash
# SEQS test harness -- single entry point.
#
# Runs every layer that does NOT need a real Qubes machine, in cheap-first
# order, and reports a summary. Any layer failing fails the whole run
# (non-zero exit), so this is safe to wire into CI or a git pre-push hook.
#
#   ./test/run-tests.sh            run all layers
#   ./test/run-tests.sh lint       run only the lint layer
#   ./test/run-tests.sh render     run only the render tests
#   ./test/run-tests.sh unit       run only the bash unit tests
#   ./test/run-tests.sh integration run only the integration test
#   ./test/run-tests.sh fast       run lint and render tests
#   ./test/run-tests.sh prove [REV] run the working tree's tests against the
#                                  product code of REV (default HEAD)
#   ./test/run-tests.sh mutate [NAME] weaken each security check in turn and
#                                  confirm a test fails (test/mutate.py)
#   ./test/run-tests.sh help       show this command summary
#
# See test/README.md for what each layer covers and the (hardware-bound)
# Layer 5 that this harness deliberately cannot run.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "${HERE}/.." || exit 2

want="${1:-all}"
rc=0
declare -a RESULTS

usage() {
	cat <<'EOF'
Usage: ./test/run-tests.sh [all|fast|lint|render|unit|integration|prove [REV]|mutate [NAME]]

  all          run every Qubes-free layer (default)
  fast         run the lint and render layers
  lint         shell lint and Salt render smoke tests
  render       detailed Salt and pillar render assertions
  unit         bash helper unit tests
  integration  end-to-end tests against mock Qubes commands
  prove [REV]  run the working tree's tests against the product code of REV
               (default HEAD): a new test must fail there, which proves it
               detects the change it was written for
  mutate [NAME] weaken each security check in turn (those whose name contains
               NAME) and confirm that some test fails; takes several minutes
EOF
}

# prove REV -- copy REV's tree into a temporary git worktree, replace its
# test/ with the working tree's, and run every layer there. Exit 0 if some
# check fails (the tests detect the difference), 1 if all pass. Lint's
# mutate.py --check is skipped there: a new entry's original text is absent
# from REV, which would count as a failure whatever the tests detect.
prove() {
	local rev tmp out
	rev="$(git rev-parse --verify --quiet "${1:-HEAD}^{commit}")" \
		|| { echo "ERROR: not a commit: ${1:-HEAD}" >&2; return 2; }
	tmp="$(mktemp -d)"
	git worktree add --quiet --detach "${tmp}/tree" "${rev}" || return 2
	rm -r -- "${tmp}/tree/test"
	cp -a test "${tmp}/tree/test"
	out="$(cd "${tmp}/tree" && SEQS_SKIP_MUTATION_CHECK=1 bash test/run-tests.sh all 2>&1)"
	local result=$?
	git worktree remove --force "${tmp}/tree"
	rm -rf -- "${tmp}"
	echo "Tests of the working tree against the product code of ${rev:0:7}:"
	if [ "${result}" -ne 0 ]; then
		grep -E 'FAIL:|FAIL  Layer|Traceback|Error:' <<< "${out}" | sed 's/^/  /'
		echo "PROVED: the checks above fail against ${rev:0:7}."
		return 0
	fi
	echo "NOT PROVED: every check passes against ${rev:0:7}, so no test detects the change."
	echo "That is expected only for a test that guards behaviour ${rev:0:7} already had."
	return 1
}

case "${want}" in
	all | fast | lint | render | unit | integration) ;;
	prove)
		prove "${2:-HEAD}"
		exit $?
		;;
	mutate)
		python3 test/mutate.py "${@:2}"
		exit $?
		;;
	help | -h | --help)
		usage
		exit 0
		;;
	*)
		printf 'ERROR: unknown test layer: %s\n\n' "${want}" >&2
		usage >&2
		exit 2
		;;
esac

run_layer() {
	local key="$1" label="$2"; shift 2
	if [ "${want}" != "all" ] && [ "${want}" != "${key}" ] \
		&& ! { [ "${want}" = "fast" ] && { [ "${key}" = "lint" ] || [ "${key}" = "render" ]; }; }; then
		return 0
	fi
	echo
	echo "════════════════════════════════════════════════════════════════════"
	echo "▶ ${label}"
	echo "════════════════════════════════════════════════════════════════════"
	if "$@"; then
		RESULTS+=("PASS  ${label}")
	else
		RESULTS+=("FAIL  ${label}")
		rc=1
	fi
}

# Fail early with a clear message if the one hard dependency is missing.
if ! python3 -c 'import jinja2, yaml' 2>/dev/null; then
	echo "ERROR: the render/lint layers need python3 with jinja2 + pyyaml." >&2
	echo "       pip install jinja2 pyyaml   (or apt-get install python3-jinja2 python3-yaml)" >&2
	exit 2
fi

run_layer lint        "Layer 0/1  lint + salt render smoke test"   bash test/lint.sh
run_layer render      "Layer 1/2  salt render assertions"          python3 test/test_render.py
run_layer unit        "Layer 3    bash helper unit tests"          bash test/unit_bash.sh
run_layer integration "Layer 4    installer integration (mock dom0)" bash test/integration/run.sh

echo
echo "════════════════════════════════════════════════════════════════════"
echo "SUMMARY"
echo "════════════════════════════════════════════════════════════════════"
for r in "${RESULTS[@]}"; do echo "  ${r}"; done
echo
if [ "${rc}" -eq 0 ]; then
	echo "ALL LAYERS PASSED ✅"
else
	echo "SOME LAYERS FAILED ❌"
fi
exit "${rc}"
