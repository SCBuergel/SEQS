#!/usr/bin/env python3
"""Render a SEQS Salt state/pillar offline and print it -- an eyeball tool.

When you change dom0.sls, qube.sls or the pillar config, run this to SEE
exactly what Salt would generate before you ever touch a real dom0:

    test/render_states.py pillar dom0
    test/render_states.py pillar A-keepass
    test/render_states.py dom0
    test/render_states.py qube Z-brave
    test/render_states.py qube A-keepass

Add --list to just list the state IDs the render produced (a quick "did my
new state show up / did the one I deleted disappear" check).
"""
import argparse
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0] + "/lib")
import salt_render as sr  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("what", choices=["pillar", "dom0", "qube"])
    ap.add_argument("minion", nargs="?", default="dom0",
                    help="minion id (default dom0; e.g. Z-brave, A-keepass)")
    ap.add_argument("--list", action="store_true", help="list state IDs only")
    args = ap.parse_args()

    if args.what == "pillar":
        seqs = sr.render_pillar(args.minion)
        import json
        print(json.dumps({"seqs": seqs}, indent=2))
        return

    text, parsed = sr.render_state(args.what, args.minion)
    if args.list:
        for k in parsed:
            print(k)
    else:
        print(text)


if __name__ == "__main__":
    main()
