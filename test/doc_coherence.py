#!/usr/bin/env python3
"""Check that the docs name what the code has, so that neither drifts alone.

Each check lists the names one side of the repository defines and fails for
every name the documentation that should explain it does not mention:

  * catalogue flags (config.sls entries, q.get() in the states) and pillar
    settings (config.sls) in docs/configuration.md, or the QR guide for the
    webcam settings;
  * component directories in docs/configuration.md and TRUST.md;
  * runner and delete-vms.sh options in their usage text and the docs;
  * pinned signing-key fingerprints in TRUST.md and VERIFY-HUMAN.md;
  * qrexec policy files the runner guards in TRUST.md;
  * relative Markdown links: the file exists, and so does the #anchor.
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FAILURES = []


def read(rel):
    with open(os.path.join(ROOT, rel)) as f:
        return f.read()


def require(names, doc_text, where, what):
    for name in sorted(names):
        if name not in doc_text:
            FAILURES.append("%s does not mention %s %s" % (where, what, name))


def main():
    config = read("salt/pillar/seqs/config.sls")
    states = read("salt/seqs/dom0.sls") + read("salt/seqs/qube.sls")
    configuration = read("docs/configuration.md")

    catalogue = config[config.index("qube_catalog = ["):]
    catalogue = catalogue[:catalogue.index("] %}")]
    flags = set(re.findall(r"'([a-z_]+)': ", catalogue))
    flags |= set(re.findall(r"\bq\.get\('([a-z_]+)'", states))
    flags -= {"name", "label", "components"}
    require({"`'%s'" % f for f in flags}, configuration, "docs/configuration.md", "catalogue flag")

    head = config[:config.index("qube_catalog = [")]
    settings = set(re.findall(r"^\{%- set ([a-z_]+) = ", head, re.M))
    qr_guide = read("docs/secure-qr-transfer.md")
    for s in sorted(settings):
        if "`%s`" % s not in configuration and "`%s`" % s not in qr_guide:
            FAILURES.append("neither docs/configuration.md nor the QR guide mentions setting %s" % s)

    components = {os.path.basename(d) for d in glob.glob(os.path.join(ROOT, "install-scripts/components/*"))}
    require({"`%s`" % c for c in components}, configuration, "docs/configuration.md", "component")
    trust = read("TRUST.md")
    for c in sorted(components):
        if not re.search(r"\b%s\b" % re.escape(c), trust, re.I):
            FAILURES.append("TRUST.md does not mention component %s" % c)

    docs = "".join(read(os.path.relpath(p, ROOT)) for p in
                   glob.glob(os.path.join(ROOT, "docs/*.md")) + [os.path.join(ROOT, "README.md")])
    for script, doc in (("setup-qubes.sh", docs), ("delete-vms.sh", read("docs/deleting-vms.md"))):
        text = read(script)
        options = set(re.findall(r"^\t\t(--[a-z][a-z-]*)\)", text, re.M))
        usage = text[:text.index("set -")] + text[text.find("usage()"):][:2000]
        require(options, usage, script + " usage text", "option")
        require(options, doc, "the docs for " + script, "option")

    vh = read("VERIFY-HUMAN.md")
    fprs = set()
    for p in glob.glob(os.path.join(ROOT, "install-scripts/**/*.sh"), recursive=True):
        for value in re.findall(r'_FPRS?="([0-9A-F ]+)"', read(os.path.relpath(p, ROOT))):
            fprs |= set(value.split())
    require(fprs, trust, "TRUST.md", "pinned fingerprint")
    require(fprs, vh, "VERIFY-HUMAN.md", "pinned fingerprint")

    runner = read("setup-qubes.sh")
    policies = set(re.findall(r'"\$\{POLICY_DIR\}/([0-9a-z.-]+\.policy)"', runner))
    require(policies, trust, "TRUST.md", "policy file")

    check_links()
    for f in FAILURES:
        print("  FAIL: " + f)
    print("doc coherence: %d problem(s)" % len(FAILURES))
    return 1 if FAILURES else 0


def anchors(text):
    """GitHub's heading anchors: lowercase, punctuation dropped, spaces to '-'."""
    out = set()
    for heading in re.findall(r"^#+\s+(.*?)\s*$", text, re.M):
        slug = re.sub(r"[^\w\- ]", "", heading.lower()).replace(" ", "-")
        out.add(slug)
    return out


def check_links():
    for path in glob.glob(os.path.join(ROOT, "**/*.md"), recursive=True):
        if "/.git/" in path or "/results/" in path:
            continue
        text = read(os.path.relpath(path, ROOT))
        text = re.sub(r"```.*?```", "", text, flags=re.S)
        for target in re.findall(r"\]\(([^)\s]+)\)", text):
            if re.match(r"[a-z]+:", target):
                continue
            file_part, _, anchor = target.partition("#")
            dest = os.path.normpath(os.path.join(os.path.dirname(path), file_part)) if file_part else path
            rel = os.path.relpath(path, ROOT)
            if not os.path.exists(dest):
                FAILURES.append("%s links to missing %s" % (rel, target))
            elif anchor and dest.endswith(".md") and anchor not in anchors(read(os.path.relpath(dest, ROOT))):
                FAILURES.append("%s links to missing anchor %s" % (rel, target))


if __name__ == "__main__":
    sys.exit(main())
