#!/usr/bin/env bash

# exit on errors, undefined variables, ensure errors in pipes are not hidden
set -Eeuo pipefail

function f() {
	if [ $# -lt 2 ]; then
		echo "Expected at least two parameters: fetchFromVm SOURCEVMNAME FILENAME [EXE]"
		return 1
	fi
	VMNAME="${1}"
	FILE="${2}"
	
	# Is there a better way to set variables for optional parameters?
	if [ $# -ge 3 ]; then
		EXE="${3}"
	fi

	# DO STUFF
	
	if [ $# -ge 3 ]; then
		echo "EXE is set and its value is ${EXE}"
	fi
}

f sourcename filename exeee
