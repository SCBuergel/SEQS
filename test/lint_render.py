#!/usr/bin/env python3
"""Smoke-render every Salt template across representative minions and assert
each one produces parseable YAML. This is the cheap "does it even compile"
gate; test_render.py makes the detailed assertions.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "lib"))
import salt_render as sr  # noqa: E402

FAIL = 0


def try_render(desc, fn):
    global FAIL
    try:
        fn()
        print("  ok   " + desc)
    except Exception as exc:  # noqa: BLE001 -- report any render/parse failure
        FAIL += 1
        print("  FAIL " + desc + " -> " + type(exc).__name__ + ": " + str(exc))


def main():
    minions = ["dom0"]
    dom0 = sr.render_pillar("dom0")
    for name in dom0.get("catalogue", {}):
        minions.extend(["Z-" + name, "A-" + name])
    minions.append("A-not-a-seqs-qube")  # stray-glob path

    for m in minions:
        try_render("pillar for %s" % m, lambda m=m: sr.render_pillar(m))

    for m in minions:
        state = "dom0" if m == "dom0" else "qube"
        try_render("state %s for %s" % (state, m),
                   lambda state=state, m=m: sr.render_state(state, m))

    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
