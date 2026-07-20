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
Usage: ./test/run-tests.sh [all|fast|lint|render|unit|integration]

  all          run every Qubes-free layer (default)
  fast         run the lint and render layers
  lint         shell lint and Salt render smoke tests
  render       detailed Salt and pillar render assertions
  unit         bash helper unit tests
  integration  end-to-end tests against mock Qubes commands
EOF
}

case "${want}" in
	all | fast | lint | render | unit | integration) ;;
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
