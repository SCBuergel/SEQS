#!/usr/bin/env python3
"""A stand-in for xfconf-query -c xfce4-panel, backed by the JSON file
$SEQS_FAKE_XFCONF: {property: value or [values]}. It covers the calls that
setup-qubes.sh and delete-vms.sh make: -l, -p PROP (print), -p PROP -n
[-a] (-t TYPE -s VALUE)..., and -p PROP -r -R. Values are kept as strings,
and output follows xfconf-query's format."""
import json
import os
import sys

path = os.environ["SEQS_FAKE_XFCONF"]
with open(path) as f:
    store = json.load(f)
args = sys.argv[1:]
prop, values, array, remove = None, [], False, False
i = 0
while i < len(args):
    a = args[i]
    if a in ("-c", "-p", "-t", "-s"):
        if a == "-p":
            prop = args[i + 1]
        elif a == "-s":
            values.append(args[i + 1])
        i += 2
        continue
    array |= a == "-a"
    remove |= a == "-r"
    if a == "-l":
        print("\n".join(sorted(store)))
        sys.exit(0)
    i += 1
if remove:
    for k in [k for k in store if k == prop or k.startswith(prop + "/")]:
        del store[k]
elif values:
    store[prop] = values if array or len(values) > 1 else values[0]
elif prop in store:
    v = store[prop]
    if isinstance(v, list):
        print("Value is an array with %d items:\n" % len(v))
        print("\n".join(v))
    else:
        print(v)
    sys.exit(0)
else:
    print('Property "%s" does not exist on channel "xfce4-panel".' % prop, file=sys.stderr)
    sys.exit(1)
with open(path, "w") as f:
    json.dump(store, f)
