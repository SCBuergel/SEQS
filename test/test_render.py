#!/usr/bin/env python3
"""Render-layer tests: compile the pillar and the Salt states across a range
of scenarios and assert on the result.

This is the highest-value layer -- the .sls files carry almost all of the
setup's logic (validation, qube creation, per-qube flags, policy generation)
and are the easiest thing to break while editing. Every check here runs in
milliseconds with no Qubes.

Run directly: `python3 test/test_render.py` (exits non-zero on failure).
"""
import os
import re
import sys
import copy
import subprocess
import tempfile

import yaml

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "lib"))
import salt_render as sr  # noqa: E402
from salt_render import Scenario, render_state, render_pillar  # noqa: E402

# ---------------------------------------------------------------------------
# Tiny zero-dependency test harness (no pytest needed).
# ---------------------------------------------------------------------------
_PASS = 0
_FAIL = 0
_FAILURES = []


def check(cond, msg):
    global _PASS, _FAIL
    if cond:
        _PASS += 1
    else:
        _FAIL += 1
        _FAILURES.append(msg)
        print("  FAIL: " + msg)


def case(name):
    print("• " + name)


def ids_containing(parsed, needle):
    return [k for k in parsed if needle in k]


def state_arg(parsed, state_id, function, key):
    return next(item[key] for item in parsed[state_id][function] if key in item)


def unresolved_requisites(parsed):
    """State IDs named in a `require` that this render does not contain.

    Salt fails a state whose requisite is missing, so a requisite that is only
    rendered under some selections must be guarded by the same condition.
    """
    missing = []
    for state_id, body in parsed.items():
        if not isinstance(body, dict):
            continue
        for args in body.values():
            if not isinstance(args, list):
                continue
            for item in args:
                if isinstance(item, dict) and "require" in item:
                    for ref in item["require"]:
                        for target in ref.values():
                            if target not in parsed:
                                missing.append("%s -> %s" % (state_id, target))
    return missing


# ---------------------------------------------------------------------------
# Pillar slicing
# ---------------------------------------------------------------------------
def test_pillar_slicing():
    case("pillar: dom0 gets the whole map, minions get only their slice")
    dom0 = render_pillar("dom0")
    check("catalogue" in dom0, "dom0 pillar should carry the full catalogue")
    check(len(dom0.get("catalogue", {})) >= 10,
          "dom0 pillar should list all configured qubes")
    check(dom0.get("config_errors") == [],
          "shipped config.sls must compile with no config_errors, got %r"
          % dom0.get("config_errors"))

    kp = render_pillar("A-keepass")
    check(kp.get("role") == "app", "A-keepass should be role=app")
    check(kp.get("spec", {}).get("offline") is True,
          "A-keepass spec should be offline")
    check("catalogue" not in kp,
          "an app qube's pillar must NOT leak the full qube map")
    check("brave_extensions" in kp and "rabby" not in kp.get("brave_extensions", {}),
          "keepass must not receive Brave-extension IDs it never references")

    tpl = render_pillar("Z-brave")
    check(tpl.get("role") == "template", "Z-brave should be role=template")
    check("cleanup_dirs" in tpl, "template slice should include cleanup_dirs")

    wallet = render_pillar("A-wallet-ledger")
    exts = wallet.get("brave_extensions", {})
    check(exts.get("rabby") and len(exts) == 1,
          "wallet-ledger should receive exactly the rabby extension ID it uses")

    stray = render_pillar("A-not-a-seqs-qube")
    check(stray == {}, "a stray A-* qube with no spec should get an empty pillar")

    staging = render_pillar("A-qr-staging")
    check(staging.get("spec", {}).get("preserve_incoming") is True,
          "qr-staging must preserve the ciphertext across physical shutdown")

    claude = render_pillar("A-claude-code")
    check(claude.get("spec", {}).get("components") == ["claude-code"],
          "claude-code app should contain only the claude-code component")


# ---------------------------------------------------------------------------
# dom0.sls -- happy path
# ---------------------------------------------------------------------------
def test_dom0_happy_path():
    case("dom0.sls: fresh install renders all expected states, no validation error")
    _, parsed = render_state("dom0", "dom0", Scenario())
    check("seqs-validation-failed" not in parsed,
          "shipped config should pass pre-flight validation")
    check("seqs-targets" in parsed, "targets file state must be present")
    check("seqs-policy-browser" in parsed, "browser OpenURL policy must be present")
    check("seqs-policy-browser-suppress" in parsed, "the tag-based suppress policy is always managed")
    # every configured qube gets a clone + app + tag state on a fresh dom0
    for name in ("brave", "keepass", "claude-code", "dev-full", "wallet-ledger"):
        check("seqs-clone-%s" % name in parsed, "expected clone state for %s" % name)
        check("seqs-app-%s" % name in parsed, "expected app state for %s" % name)
        check("seqs-tag-app-%s" % name in parsed, "expected app tag state for %s" % name)
    # keepass air-gap state
    check("seqs-offline-keepass" in parsed, "keepass should get an offline state")
    offline_cmd = state_arg(parsed, "seqs-offline-keepass", "cmd.run", "name")
    check("qvm-prefs -- A-keepass netvm none" in offline_cmd
          and "qvm-prefs -- A-keepass default_dispvm none" in offline_cmd,
          "the offline state must clear both the netvm and the default disposable")
    check("seqs-offline-brave" not in parsed, "brave must NOT be air-gapped")
    # The managed tag (and the intent marker's removal) waits for the air gap,
    # so a failed offline step never leaves a SEQS-owned qube with network.
    tag_requires = state_arg(parsed, "seqs-tag-app-keepass", "cmd.run", "require")
    check({"cmd": "seqs-offline-keepass"} in (tag_requires or []),
          "seqs-tag-app-keepass must require seqs-offline-keepass")
    # netvm=none does not gate qrexec, so offline, no_handoff and firewalled
    # qubes carry the seqs-no-handoff tag and the policy denies by tag; a
    # disposable inherits the tag from its template, named or not.
    suppress = policy_rules(state_arg(parsed, "seqs-policy-browser-suppress", "file.managed", "contents"))
    for service, target in ESCAPE_ROUTES:
        check((service, "*", "@tag:seqs-no-handoff", target, "deny") in suppress,
              "%s to %s must be denied by tag" % (service, target))
    for vm in ("A-keepass", "A-qr-camera", "A-qr-display", "D-qr-display", "A-qr-staging",
               "A-wallet-ledger", "A-wireguard", "A-gnosisvpn"):
        sid = "seqs-handoff-tag-" + vm
        check(sid in parsed and state_arg(parsed, sid, "cmd.run", "name")
              == "qvm-tags -- %s add seqs-no-handoff && qvm-tags -- %s del seqs-handoff" % (vm, vm),
              "%s must be tagged seqs-no-handoff and lose seqs-handoff" % vm)
    check(state_arg(parsed, "seqs-handoff-tag-A-signal", "cmd.run", "name")
          == "qvm-tags -- A-signal add seqs-handoff && qvm-tags -- A-signal del seqs-no-handoff",
          "a handoff qube must carry seqs-handoff and not seqs-no-handoff")
    check(state_arg(parsed, "seqs-handoff-tag-A-keepass", "cmd.run", "unless")
          == 't="$(qvm-tags -- A-keepass list)" && printf \'%s\\n\' "$t" | grep -qx seqs-no-handoff'
             ' && ! printf \'%s\\n\' "$t" | grep -qx seqs-handoff',
          "the tag state may be skipped only when the qube has exactly the wanted tag")
    for sid, f in (("seqs-policy-qr-input-deny", "00-seqs-qr-input-deny"), ("seqs-policy-qr-filecopy", "01-seqs-qr-filecopy")):
        check(state_arg(parsed, sid, "cmd.run", "onlyif")
              == "head -n 1 /etc/qubes/policy.d/%s.policy | grep -q '^# Managed by SEQS'" % f,
              "with QR disabled, %s is removed only when SEQS wrote it (header on line 1)" % f)
    browser = state_arg(parsed, "seqs-policy-browser", "file.managed", "contents")
    check("qubes.OpenURL  *  @tag:seqs-handoff  A-brave  allow" in browser,
          "only qubes tagged seqs-handoff may hand links to the browser qube")
    check("@anyvm" not in browser,
          "qubes SEQS did not build must keep the Qubes default for link handoff")
    check(not unresolved_requisites(parsed), "tag states must require rendered states only")
    offline = state_arg(parsed, "seqs-offline-keepass", "cmd.run", "name")
    check("default_dispvm none" in offline,
          "an offline qube must lose its (networked) default disposable")
    named = state_arg(parsed, "seqs-disposable-prefs-qr-display", "cmd.run", "name")
    check("default_dispvm none" in named,
          "a named offline disposable must lose its default disposable")
    camera_state = parsed["seqs-app-qr-camera"]["qvm.vm"]
    camera_prefs = next(x["prefs"] for x in camera_state if "prefs" in x)
    check(any(p.get("template_for_dispvms") is True for p in camera_prefs),
          "qr-camera app must be configured as a DisposableVM template")


def test_dom0_runtime_selection():
    case("dom0.sls: runtime selection narrows creation and targets")
    _, parsed = render_state("dom0", "dom0", Scenario(selection="brave"))
    check("seqs-clone-brave" in parsed, "selected brave should be created")
    check("seqs-clone-signal" not in parsed, "unselected signal must not be created")
    targets = state_arg(parsed, "seqs-targets", "file.managed", "contents")
    check("Z-brave" in targets and "A-brave" in targets,
          "targets should include the selected qube pair")
    check("Z-signal" not in targets and "A-signal" not in targets,
          "targets must exclude unselected catalogue entries")

    _, bad = render_state("dom0", "dom0", Scenario(selection="not-in-catalogue"))
    check("runtime selection names unknown catalogue entry 'not-in-catalogue'" in _errors(bad),
          "unknown runtime selections must fail pre-flight")

    # Instance names become qube names in dom0 shell states.
    for sel, msg, name in [
            ("brave brave-a;b", "contains unsafe recipe or instance name 'brave brave-a;b'", "brave-a;b"),
            ("a;b", "contains unsafe recipe or instance name 'a;b'", "a;b"),
            ("@all a;b", "contains unsafe postfix 'a;b'", "brave-a;b")]:
        _, unsafe = render_state("dom0", "dom0", Scenario(selection=sel))
        check("runtime selection " + msg in _errors(unsafe) and "seqs-clone-" + name not in unsafe,
              "an unsafe runtime selection must fail pre-flight: " + sel)

    _, postfixed = render_state(
        "dom0", "dom0",
        Scenario(selection="brave alpha\nsignal signal-alpha"))
    check("runtime instance 'alpha' is not derived from recipe 'brave'" in _errors(postfixed),
          "a malformed recipe/instance mapping must fail pre-flight")

    _, postfixed = render_state(
        "dom0", "dom0",
        Scenario(selection="brave brave-alpha\nsignal signal-alpha",
                 existing_qubes=["A-brave"], tagged_qubes=["A-brave"]))
    check("seqs-clone-brave-alpha" in postfixed
          and "seqs-clone-signal-alpha" in postfixed,
          "one postfix should create an instance of every selected recipe")
    targets = state_arg(postfixed, "seqs-targets", "file.managed", "contents")
    check("template Z-brave-alpha brave" in targets
          and "app A-signal-alpha signal" in targets,
          "targets must retain recipe identity for postfixed instances")

    # Beside a recipe brave-full, a brave instance named brave-full-x would get
    # brave-full's components from the pillar, so dom0 must refuse it.
    pillar = copy.deepcopy(render_pillar("dom0"))
    pillar["catalogue"]["brave-full"] = copy.deepcopy(pillar["catalogue"]["brave"])
    _, shadowed = render_state("dom0", "dom0", Scenario(selection="brave brave-full-x", existing_qubes=["A-brave"],
                                                        tagged_qubes=["A-brave"]), pillar_seqs=pillar)
    check("seqs-validation-failed" in shadowed and "collides with catalogue recipe 'brave-full'"
          in state_arg(shadowed, "seqs-validation-failed", "test.fail_without_changes", "comment"),
          "an instance name that resolves to a longer recipe must fail pre-flight")
    _, fine = render_state("dom0", "dom0", Scenario(selection="brave brave-alpha", existing_qubes=["A-brave"],
                                                    tagged_qubes=["A-brave"]), pillar_seqs=pillar)
    check("seqs-validation-failed" not in fine, "an ordinary postfix must still pass beside brave-full")


def test_dom0_names_record():
    case("dom0.sls: records the configured qube names for delete-vms.sh")
    _, parsed = render_state("dom0", "dom0", Scenario())
    names = state_arg(parsed, "seqs-names", "file.managed", "contents")
    check(names.splitlines()[2:] == ["prefix D-", "prefix A-", "prefix Z-",
                                     "usb-qube sys-usb-webcam", "qube seqs-qr-scanner"],
          "the record must list the default prefixes and QR qubes: %r" % names)
    pillar = copy.deepcopy(render_pillar("dom0"))
    # Without a named disposable, prefix_disposable may be empty.
    pillar["catalogue"] = {k: v for k, v in pillar["catalogue"].items() if not v.get("named_disposable")}
    pillar.update(prefix_template="tpl-", prefix_app="app-", prefix_disposable="", browser_vm="app-brave",
                  webcam_usb_qube="cam-usb", webcam_scanner_qube="cam-scan")
    top = "base:\n  'tpl-*':\n    - seqs.config\n  'app-*':\n    - seqs.config\n"
    _, parsed = render_state("dom0", "dom0", Scenario(top_content=top),
                             pillar_seqs=pillar)
    names = next((i["contents"] for i in parsed.get("seqs-names", {}).get("file.managed", [])
                  if "contents" in i), "")
    check(names.splitlines()[2:] == ["prefix app-", "prefix tpl-", "usb-qube cam-usb", "qube cam-scan"],
          "the record must follow the configured names: %r %s" % (names, _errors(parsed)))


def test_dom0_idempotent_rerun():
    case("dom0.sls: a fully-provisioned re-run is churn-free (no clone/tag states)")
    # Every qube already exists AND is tagged seqs-managed.
    dom0 = render_pillar("dom0")
    names = list(dom0["catalogue"].keys())
    existing = ["Z-" + n for n in names] + ["A-" + n for n in names]
    _, parsed = render_state(
        "dom0", "dom0",
        Scenario(existing_qubes=existing, tagged_qubes=existing))
    check(not ids_containing(parsed, "seqs-clone-"),
          "re-run over tagged qubes should not re-clone anything")
    check(not ids_containing(parsed, "seqs-tag-app-"),
          "re-run over tagged qubes should not re-tag anything")
    check("seqs-existing-template-gnosisvpn" in parsed
          and "seqs-existing-app-gnosisvpn" in parsed,
          "re-runs should explicitly report managed qubes that already exist")
    check("seqs-recipe-template-gnosisvpn" in parsed
          and "seqs-recipe-app-gnosisvpn" in parsed,
          "legacy managed qubes should converge their catalogue recipe metadata")
    check("seqs-targets" in parsed, "targets file is still (re)written on re-run")


def test_dom0_partial_run_tags_unselected_managed_qubes():
    case("dom0.sls: a partial run tags every managed qube from its recipe, selected or not")
    sc = Scenario(
        selection="xournalpp",
        existing_qubes=["A-brave", "A-keepass", "A-wallet-ledger", "A-signal", "D-qr-display", "A-unmanaged"],
        tagged_qubes=["A-brave", "A-keepass", "A-wallet-ledger", "A-signal", "D-qr-display"],
        recipes={"A-brave": "brave", "A-keepass": "keepass", "A-wallet-ledger": "wallet-ledger",
                 "A-signal": "signal", "D-qr-display": "qr-display"})
    _, parsed = render_state("dom0", "dom0", sc)
    for vm in ("A-keepass", "A-wallet-ledger", "D-qr-display"):
        sid = "seqs-handoff-tag-" + vm
        check(sid in parsed and "add seqs-no-handoff" in state_arg(parsed, sid, "cmd.run", "name"),
              "unselected managed %s must keep the seqs-no-handoff tag" % vm)
    check("del seqs-no-handoff" in state_arg(parsed, "seqs-handoff-tag-A-signal", "cmd.run", "name"),
          "an unselected handoff qube must not carry the tag")
    check("seqs-handoff-tag-A-unmanaged" not in parsed, "a qube SEQS does not manage is never tagged")
    check(not unresolved_requisites(parsed), "tag states of unselected qubes must not require absent states")
    policy_requires = state_arg(parsed, "seqs-policy-browser-suppress", "file.managed", "require")
    for vm in ("A-keepass", "A-wallet-ledger", "D-qr-display"):
        check({"cmd": "seqs-handoff-tag-" + vm} in policy_requires,
              "the tag policy must wait for the %s tag, or a failed tag leaves it unprotected" % vm)
    check({"cmd": "seqs-handoff-tag-A-signal"} not in policy_requires,
          "the policy must not wait for a tag removal")


def test_dom0_tags_managed_qube_without_recipe():
    case("dom0.sls: a managed qube built before recipes were recorded is tagged by its base name")
    sc = Scenario(selection="xournalpp", existing_qubes=["A-brave", "A-keepass"],
                  tagged_qubes=["A-brave", "A-keepass"], recipes={"A-brave": "brave"})
    _, parsed = render_state("dom0", "dom0", sc)
    check("add seqs-no-handoff" in state_arg(parsed, "seqs-handoff-tag-A-keepass", "cmd.run", "name"),
          "a recipe-less managed A-keepass must still be tagged")


def test_dom0_refuses_unmanaged_qube():
    case("dom0.sls: refuses to adopt a same-named qube that isn't seqs-managed")
    # A-brave exists but is NOT tagged and has no intent marker -> must refuse.
    _, parsed = render_state(
        "dom0", "dom0",
        Scenario(existing_qubes=["A-brave"]))  # exists, untagged, no intent
    check("qube 'A-brave' already exists but is not marked seqs-managed" in _errors(parsed),
          "an existing untagged A-brave must trip the no-clobber guard")


def test_dom0_inventory_fails_closed():
    case("dom0.sls: an unreadable qube inventory stops the run instead of reading as 'nothing exists'")
    # A-brave exists untagged. If the inventory query returned nothing, the
    # no-clobber guard would see no A-brave and adopt the unrelated qube.
    text, parsed = render_state(
        "dom0", "dom0",
        Scenario(existing_qubes=["A-brave"], qubesd_up=False))
    check("seqs-validation-failed" in parsed,
          "an empty inventory must fail validation")
    check("could not list the existing qubes" in text,
          "the failure must say that the qube list was unavailable")
    check(not ids_containing(parsed, "seqs-clone-") and not ids_containing(parsed, "seqs-app-"),
          "no qube may be created without an inventory")
    # A list cut short, such as by a qube removed while it is read, may miss
    # the existing A-brave although dom0 is in it.
    text, parsed = render_state("dom0", "dom0", Scenario(existing_qubes=["A-brave"], inventory_complete=False))
    check("the list of existing qubes ended early" in text and not ids_containing(parsed, "seqs-app-"),
          "an inventory without its END line must stop the run")


# Every service that gets data or code out of a qube into another qube or a
# disposable; listed independently of dom0.sls. An @anyvm deny also matches
# @dispvm and @dispvm:<template> (qrexec policy parser, AnyVM.match).
ESCAPE_ROUTES = [(s, "@anyvm") for s in (
    "qubes.OpenURL", "qubes.OpenInVM", "qubes.StartApp", "qubes.GetImageRGBA",
    "qubes.VMShell", "qubes.VMExec", "qubes.VMExecGUI", "qubes.PdfConvert")]


def policy_rules(text):
    """The rules of a qrexec policy file in order, as token tuples, ignoring spacing and comments."""
    return [tuple(line.split()) for line in text.splitlines() if line.strip() and not line.strip().startswith("#")]


def test_dom0_browser_required_only_for_handoff():
    case("dom0.sls: the browser qube is required only when a selected qube hands links to it")
    # Fresh dom0: A-brave does not exist. Offline and no_handoff qubes never
    # hand links off, and the browser qube does not hand off to itself.
    for selection in ["keepass", "wallet-ledger", "keepass\nqr-display", "brave", "signal\nbrave"]:
        _, parsed = render_state("dom0", "dom0", Scenario(selection=selection))
        check("seqs-validation-failed" not in parsed,
              "selection %r must not require an existing browser qube" % selection)
    text, parsed = render_state("dom0", "dom0", Scenario(selection="signal"))
    check("seqs-validation-failed" in parsed and "signal would hand links to it" in text,
          "signal hands links to A-brave, so it needs A-brave selected or existing")
    _, parsed = render_state("dom0", "dom0", Scenario(selection="signal", existing_qubes=["A-brave"]))
    check("seqs-validation-failed" not in parsed,
          "an existing A-brave satisfies a handoff qube")
    pillar = _bad_pillar(catalogue={"wallet": {"label": "gray", "components": ["brave"], "firewall": ["dns"]}})
    _, parsed = render_state("dom0", "dom0", Scenario(selection="wallet"), pillar_seqs=pillar)
    check("seqs-validation-failed" not in parsed,
          "a firewalled qube never hands links off, so it needs no browser qube")


def test_dom0_component_menu_entries():
    case("dom0.sls: a component's own menu entry is listed in its app qube and named disposable menus")
    _, parsed = render_state("dom0", "dom0", Scenario(selection="qr-display\nkeepass\nbrave"))
    for vm, entry in [("D-qr-display", "qr-display.desktop"), ("A-keepass", "keepass.desktop")]:
        sid = "seqs-menu-" + vm
        check(sid in parsed, "%s must get its component menu entry" % vm)
        if sid in parsed:
            name = state_arg(parsed, sid, "cmd.run", "name")
            check(entry in name and ("qvm-features -- %s menu-items" % vm) in name,
                  "%s must add %s to its menu-items feature" % (vm, entry))
    brave = state_arg(parsed, "seqs-menu-A-brave", "cmd.run", "name")
    check(all(e in brave for e in ("brave-browser.desktop", "xfce4-terminal.desktop", "thunar.desktop")),
          "a qube's main app, terminal and file manager must be in its menu")
    check("seqs-menu-A-qr-display" not in parsed and "seqs-launcher-items-A-qr-display" not in parsed,
          "a disposable template gets no menu entries and no launcher: they would run in it")


def test_dom0_launcher_items():
    case("dom0.sls: each app qube's launcher lists its main app, a terminal and a file manager")
    _, parsed = render_state("dom0", "dom0", Scenario(selection="qr-display\nkeepass\nbrave\nqr-staging"))
    for vm, items in (("A-brave", "brave-browser.desktop xfce4-terminal.desktop thunar.desktop"),
                      ("D-qr-display", "qr-display.desktop xfce4-terminal.desktop thunar.desktop"),
                      ("A-qr-staging", "xfce4-terminal.desktop thunar.desktop")):
        check(("seqs-launcher-items '%s'" % items) in state_arg(parsed, "seqs-launcher-items-" + vm, "cmd.run", "name"),
              "%s must get the launcher items %r" % (vm, items))
    pillar = copy.deepcopy(render_pillar("dom0"))
    for value in ("x.desktop'; id; '", "x.desktop\n", "signal", "-x.desktop", "../x.desktop", ["a.desktop"]):
        pillar["catalogue"]["signal"]["main_app"] = value
        # An unrefused value can break the rendered YAML: that counts as not refused.
        try:
            errors = _errors(render_state("dom0", "dom0", Scenario(selection="signal\nbrave"), pillar_seqs=pillar)[1])
        except yaml.YAMLError:
            errors = ""
        check("'main_app' must be a desktop file name" in errors, "main_app %r must be refused" % (value,))
    check("seqs-menu-A-qr-display" not in parsed,
          "a disposable template gets no entry: it would run the component in the template itself")
    check(not unresolved_requisites(parsed), "menu states must require rendered states only")
    _, parsed = render_state("qube", "Z-qr-display")
    check("seqs-appmenus-sync" in parsed and "qr-display" in state_arg(parsed, "seqs-appmenus-sync", "cmd.run", "onlyif"),
          "the template must report its applications to dom0 when a component ships a menu entry")


def test_dom0_refuses_recipe_change():
    case("dom0.sls: refuses to repurpose a managed qube recorded for another recipe")
    _, parsed = render_state(
        "dom0", "dom0",
        Scenario(selection="brave", existing_qubes=["A-brave"],
                 tagged_qubes=["A-brave"], recipes={"A-brave": "signal"}))
    check("seqs-validation-failed" in parsed,
          "a managed A-brave recorded as recipe 'signal' must not be rebuilt as brave")
    _, parsed = render_state(
        "dom0", "dom0",
        Scenario(selection="brave", existing_qubes=["A-brave"],
                 tagged_qubes=["A-brave"], recipes={"A-brave": "brave"}))
    check("seqs-validation-failed" not in parsed,
          "a managed A-brave recorded as recipe 'brave' is adopted")


def test_dom0_refuses_unmanaged_postfixed_qube():
    case("dom0.sls: the no-clobber guard also covers --postfix instances")
    # Selection line "<recipe> <instance>" is what the runner writes for --postfix.
    # A-brave exists so that the browser check passes and only no-clobber can fail.
    text, parsed = render_state("dom0", "dom0", Scenario(
        selection="xournalpp xournalpp-beta", existing_qubes=["A-brave", "A-xournalpp-beta"],
        tagged_qubes=["A-brave"]))
    check("seqs-validation-failed" in parsed and "A-xournalpp-beta\\u0027 already exists but is not marked" in text,
          "an existing untagged A-xournalpp-beta must trip the no-clobber guard")
    text, parsed = render_state("dom0", "dom0", Scenario(
        selection="xournalpp xournalpp-beta", existing_qubes=["A-brave", "A-xournalpp-beta"],
        tagged_qubes=["A-brave", "A-xournalpp-beta"], recipes={"A-xournalpp-beta": "signal"}))
    check("seqs-validation-failed" in parsed and "refusing to repurpose" in text,
          "a postfixed instance recorded for another recipe must not be repurposed")
    _, parsed = render_state("dom0", "dom0", Scenario(
        selection="xournalpp xournalpp-beta", existing_qubes=["A-brave"], tagged_qubes=["A-brave"]))
    check("seqs-validation-failed" not in parsed, "a fresh postfixed instance builds")


def test_dom0_adopts_via_intent_marker():
    case("dom0.sls: adopts an untagged qube that carries an interrupted-run intent marker")
    _, parsed = render_state(
        "dom0", "dom0",
        Scenario(existing_qubes=["A-brave"],
                 existing_files=["/var/lib/seqs/intents/A-brave"]))
    check("seqs-validation-failed" not in parsed,
          "an intent marker proves a prior interrupted SEQS run -- must adopt, not refuse")
    check(not ids_containing(parsed, "seqs-stale-intent-"),
          "the marker of an existing qube must be kept")
    intents = ["/var/lib/seqs/intents/" + n for n in ("A-gone", "A-brave", "Z-xournalpp")]
    _, parsed = render_state("dom0", "dom0", Scenario(selection="brave", existing_files=intents,
                                                      existing_qubes=["Z-xournalpp"]))
    check(ids_containing(parsed, "seqs-stale-intent-") == ["seqs-stale-intent-A-gone"],
          "only the marker of a qube that neither exists nor is built now is removed, got %r"
          % ids_containing(parsed, "seqs-stale-intent-"))


def _runner_policy_files():
    """The names in setup-qubes.sh's POLICY_FILES, and the runner's text."""
    with open(os.path.join(sr.REPO_ROOT, "setup-qubes.sh"), encoding="utf-8") as f:
        text = f.read()
    block = re.search(r"\nPOLICY_FILES=\(\n(.*?)\n\)\n", text, re.S)
    names = set(re.findall(r'"\$\{POLICY_DIR\}/([0-9a-z.-]+\.policy)"', block.group(1) if block else ""))
    check(block is not None and len(names) == len(block.group(1).splitlines()),
          "POLICY_FILES in setup-qubes.sh must be one quoted ${POLICY_DIR}/NAME.policy per line")
    return names, text


def test_dom0_policy_files_match_runner_takeover_list():
    case("dom0.sls: every qrexec policy file it writes is in the runner's POLICY_FILES")
    # seqs.dom0 overwrites its policy files without looking for the marker;
    # only the runner's takeover check, which reads POLICY_FILES, protects an
    # operator's unmarked file of the same name.
    runner, _ = _runner_policy_files()
    # Renders that write every conditional policy: QR sequential mode (00-,
    # 01-), Qubes 4.3 with sys-usb (30-), an audio qube in @all (50-).
    qr = copy.deepcopy(render_pillar("dom0"))
    qr.update({"webcam_usb_mode": "sequential", "webcam_usb_controller": "00_14.0"})
    managed, named = set(), set()
    for pillar in (None, qr):
        text, parsed = render_state("dom0", "dom0", Scenario(release="4.3", sys_usb=True), pillar_seqs=pillar)
        check("seqs-validation-failed" not in parsed, "policy render must pass validation: " + _errors(parsed))
        named |= set(re.findall(r"/etc/qubes/policy\.d/([^\s'\"]+)", text))
        for body in parsed.values():
            for arg in (body.get("file.managed") or []) if isinstance(body, dict) else []:
                if isinstance(arg, dict) and str(arg.get("name", "")).startswith("/etc/qubes/policy.d/"):
                    managed.add(arg["name"][len("/etc/qubes/policy.d/"):])
    check(managed == runner, "the policy files seqs.dom0 writes %s must be POLICY_FILES %s"
          % (sorted(managed), sorted(runner)))
    # A policy file written another way, such as by a cmd.run, needs the guard too.
    check(named <= runner, "policy files named in seqs.dom0 but not in POLICY_FILES: %s" % sorted(named - runner))


def test_reset_removes_every_seqs_policy_file():
    case("delete-vms.sh: --reset covers every policy file SEQS writes")
    # The reset removes only the marked files its POLICIES list names: those
    # of seqs.dom0, which the test above ties to POLICY_FILES, and the
    # runner's temporary GnosisVPN updates policy.
    runner, text = _runner_policy_files()
    gnosis = re.search(r'\nGNOSIS_UPDATE_POLICY="\$\{POLICY_DIR\}/([0-9a-z.-]+\.policy)"\n', text)
    check(gnosis is not None, "setup-qubes.sh must set GNOSIS_UPDATE_POLICY=\"${POLICY_DIR}/NAME.policy\"")
    with open(os.path.join(sr.REPO_ROOT, "delete-vms.sh"), encoding="utf-8") as f:
        block = re.search(r"\nPOLICIES=\(([^)]*)\)\n", f.read())
    names = block.group(1).split() if block else []
    check(names and all(re.fullmatch(r"[0-9a-z.-]+", n) for n in names) and len(set(names)) == len(names),
          "POLICIES in delete-vms.sh must be distinct bare policy names: %r" % names)
    expected = runner | ({gnosis.group(1)} if gnosis else set())
    got = {n + ".policy" for n in names}
    check(got == expected, "delete-vms.sh POLICIES %s must be POLICY_FILES plus GNOSIS_UPDATE_POLICY %s"
          % (sorted(got), sorted(expected)))


def test_dom0_usb_policy_release_gated():
    case("dom0.sls: USB-keyboard policy only on Qubes 4.3 + sys-usb")
    _, on = render_state("dom0", "dom0", Scenario(release="4.3", sys_usb=True))
    check("seqs-policy-usb-keyboard" in on,
          "4.3 + sys-usb should install the USB keyboard policy")
    _, off42 = render_state("dom0", "dom0", Scenario(release="4.2", sys_usb=True))
    check("seqs-policy-usb-keyboard" not in off42,
          "4.2 must not install the USB keyboard policy")
    _, offnousb = render_state("dom0", "dom0", Scenario(release="4.3", sys_usb=False))
    check("seqs-policy-usb-keyboard" not in offnousb,
          "4.3 without sys-usb must not install the USB keyboard policy")


def test_dom0_usb_policy_defers_to_qubes_rule():
    case("dom0.sls: no USB-keyboard override when 50-config-input.policy allows or asks")
    # An 'ask' rule is answered only inside a session, so on a computer whose
    # only keyboard is USB the override locks the login screen. The installer
    # writes 'allow' for such a computer; SEQS must then remove its own file.
    path = "/etc/qubes/policy.d/50-config-input.policy"
    for rule in ("qubes.InputKeyboard * sys-usb @adminvm allow",
                 "qubes.InputKeyboard  *  sys-usb  dom0  ask default_target=dom0"):
        sc = Scenario(release="4.3", sys_usb=True,
                      file_contents={path: "qubes.InputMouse * sys-usb @adminvm ask\n" + rule + "\n"})
        _, parsed = render_state("dom0", "dom0", sc)
        check("seqs-policy-usb-keyboard" not in parsed,
              "rule %r must stop the override" % rule)
        absent = parsed.get("seqs-policy-usb-keyboard-unneeded", {})
        check(absent.get("file.absent", [{}])[0].get("name") == "/etc/qubes/policy.d/30-user-input.policy",
              "rule %r must remove a SEQS-written 30-user-input.policy, got %r" % (rule, absent))
        guard = [d["onlyif"] for d in absent.get("file.absent", []) if "onlyif" in d]
        check(guard and "head -n 1 /etc/qubes/policy.d/30-user-input.policy" in guard[0]
              and "'^# Managed by SEQS'" in guard[0],
              "the removal must be guarded by the SEQS marker on the first line, got %r" % guard)
    for content in ("qubes.InputKeyboard * sys-usb @adminvm deny\n",
                    "qubes.InputMouse * sys-usb @adminvm ask\n",
                    "# qubes.InputKeyboard * sys-usb @adminvm allow\n",
                    "qubes.InputKeyboard * sys-usb A-brave allow\n"):
        sc = Scenario(release="4.3", sys_usb=True, file_contents={path: content})
        _, parsed = render_state("dom0", "dom0", sc)
        check("seqs-policy-usb-keyboard" in parsed and "seqs-policy-usb-keyboard-unneeded" not in parsed,
              "content %r is not a keyboard allow/ask for dom0, the override must be written" % content)


def test_dom0_usb_policy_setting():
    case("dom0.sls: usb_keyboard_prompt False keeps Qubes' refusal of USB keyboards")
    check(render_pillar("dom0").get("usb_keyboard_prompt") is True,
          "the shipped configuration should make dom0 ask for a USB keyboard")
    # A high-value receiving computer with a built-in keyboard keeps the
    # shipped deny: no override is written, and one written earlier goes.
    path = "/etc/qubes/policy.d/50-config-input.policy"
    deny = Scenario(release="4.3", sys_usb=True,
                    file_contents={path: "qubes.InputKeyboard * sys-usb @adminvm deny\n"})
    pillar = copy.deepcopy(render_pillar("dom0"))
    pillar["usb_keyboard_prompt"] = False
    _, parsed = render_state("dom0", "dom0", deny, pillar_seqs=pillar)
    check("seqs-validation-failed" not in parsed and "seqs-policy-usb-keyboard" not in parsed,
          "usb_keyboard_prompt False must not write the override")
    absent = parsed.get("seqs-policy-usb-keyboard-unneeded", {})
    check(absent.get("file.absent", [{}])[0].get("name") == "/etc/qubes/policy.d/30-user-input.policy",
          "usb_keyboard_prompt False must remove a SEQS-written 30-user-input.policy, got %r" % absent)
    guard = [d["onlyif"] for d in absent.get("file.absent", []) if "onlyif" in d]
    check(guard and "'^# Managed by SEQS'" in guard[0],
          "the removal must be guarded by the SEQS marker, got %r" % guard)
    for value in ("False", 0, None):
        pillar = copy.deepcopy(render_pillar("dom0"))
        pillar["usb_keyboard_prompt"] = value
        _, parsed = render_state("dom0", "dom0", deny, pillar_seqs=pillar)
        check("usb_keyboard_prompt '%s' must be True or False" % value in _errors(parsed),
              "usb_keyboard_prompt %r must fail pre-flight" % (value,))


def test_dom0_sys_usb_memory():
    case("dom0.sls: sys_usb_memory only raises sys-usb's memory, and only to a whole number")
    check(render_pillar("dom0").get("sys_usb_memory") == 600,
          "the shipped configuration should give sys-usb 600 MiB")
    _, parsed = render_state("dom0", "dom0", Scenario(sys_usb=True))
    st = parsed.get("seqs-sys-usb-memory")
    check(st is not None, "a build should raise sys-usb's memory")
    if st is not None:
        check(state_arg(parsed, "seqs-sys-usb-memory", "cmd.run", "name").startswith(
                  "qvm-prefs -- sys-usb memory 600 &&"),
              "the state should set sys-usb's memory to 600 MiB")
        check(state_arg(parsed, "seqs-sys-usb-memory", "cmd.run", "unless")
              == 'test "$(qvm-prefs -- sys-usb memory)" -ge 600',
              "a sys-usb that already has at least 600 MiB must be left alone")
    _, parsed = render_state("dom0", "dom0", Scenario(sys_usb=False))
    check("seqs-sys-usb-memory" not in parsed, "without sys-usb there is nothing to change")
    for value in (0, 400):
        pillar = copy.deepcopy(render_pillar("dom0"))
        pillar["sys_usb_memory"] = value
        _, parsed = render_state("dom0", "dom0", Scenario(sys_usb=True), pillar_seqs=pillar)
        check("seqs-validation-failed" not in parsed, "%r is a valid sys_usb_memory" % value)
        check(("seqs-sys-usb-memory" in parsed) == bool(value),
              "sys_usb_memory %r should %srender the state" % (value, "" if value else "not "))
    for value in ("600; reboot", True, -1, 600.5):
        pillar = copy.deepcopy(render_pillar("dom0"))
        pillar["sys_usb_memory"] = value
        _, parsed = render_state("dom0", "dom0", Scenario(sys_usb=True), pillar_seqs=pillar)
        check("must be a whole number of MiB" in _errors(parsed),
              "sys_usb_memory %r must fail pre-flight" % (value,))


def test_dom0_nuc11_headset_fix():
    case("dom0.sls: nuc11_headset_fix is on by default and only installs on a NUC 11 codec")
    def arg(parsed, state_id, function, key):  # None instead of an exception when absent
        try:
            return state_arg(parsed, state_id, function, key)
        except (KeyError, StopIteration):
            return None
    fw, conf = "/lib/firmware/seqs-nuc11-headset.fw", "/etc/modprobe.d/seqs-nuc11-headset.conf"
    nuc = Scenario(hda_codecs=["0x10ec0256 0x80863004", "0x80862812 0x80860101"])
    def removed(parsed):
        return (arg(parsed, "seqs-nuc11-headset-option", "file.absent", "name") == conf
                and arg(parsed, "seqs-nuc11-headset-patch", "file.absent", "name") == fw)
    check(render_pillar("dom0").get("nuc11_headset_fix") is True,
          "the shipped configuration should turn the fix on")
    pillar = copy.deepcopy(render_pillar("dom0"))
    pillar["nuc11_headset_fix"] = False
    _, parsed = render_state("dom0", "dom0", nuc, pillar_seqs=pillar)
    check(removed(parsed), "with the fix off, both files must be removed")
    pillar["nuc11_headset_fix"] = True
    _, parsed = render_state("dom0", "dom0", nuc, pillar_seqs=pillar)
    check("seqs-validation-failed" not in parsed, "a NUC 11 codec may enable the fix")
    contents = arg(parsed, "seqs-nuc11-headset-patch", "file.managed", "contents") or ""
    check(arg(parsed, "seqs-nuc11-headset-patch", "file.managed", "name") == fw
          and "[codec]\n0x10ec0256 0x80863004 0\n[pincfg]\n0x19 0x01a1913c\n[model]\nheadset-mode\n" in contents,
          "the patch file should set pin 0x19 as headset mic in headset mode")
    check("options snd-hda-intel patch=seqs-nuc11-headset.fw\n" in
          (arg(parsed, "seqs-nuc11-headset-option", "file.managed", "contents") or ""),
          "snd-hda-intel should load the patch file")
    for codecs in ([], ["0x10ec0256 0x103c8600"], ["0x10ec0257 0x80863004"]):
        _, parsed = render_state("dom0", "dom0", Scenario(hda_codecs=codecs), pillar_seqs=pillar)
        check("seqs-validation-failed" not in parsed and removed(parsed),
              "codecs %r must get neither file, without failing the build" % (codecs,))
    for value in ("yes", 1, "True"):
        pillar["nuc11_headset_fix"] = value
        _, parsed = render_state("dom0", "dom0", nuc, pillar_seqs=pillar)
        check("must be True or False" in _errors(parsed),
              "nuc11_headset_fix %r must fail pre-flight" % (value,))


def test_dom0_sequential_qr_mode():
    case("dom0.sls: sequential QR mode renders strict, staged, fail-closed machinery")
    pillar = copy.deepcopy(render_pillar("dom0"))
    pillar.update({
        "webcam_usb_mode": "sequential",
        "webcam_usb_controller": "00_14.0",
        "webcam_usb_strict_reset": True,
    })
    text, parsed = render_state(
        "dom0", "dom0", Scenario(sys_usb=True), pillar_seqs=pillar)
    check("seqs-validation-failed" not in parsed,
          "well-formed sequential configuration must pass validation")
    for state in ("seqs-policy-qr-input-deny", "seqs-policy-qr-filecopy",
                  "seqs-webcam-usb-backend", "seqs-qr-scanner",
                  "seqs-qr-sequential-config", "seqs-qr-sequential-script"):
        check(state in parsed, "sequential mode should render %s" % state)
    check("qubes.Filecopy" in text and "A-qr-staging" in text,
          "scanner filecopy must be restricted to offline staging")
    deny_text = state_arg(parsed, "seqs-policy-qr-input-deny", "file.managed", "contents")
    deny = policy_rules(deny_text)
    check("*  @dispvm:" not in deny_text, "a @dispvm:<template> source matches nothing on Qubes 4.3")
    for subject in ("sys-usb-webcam", "seqs-qr-scanner"):
        for service, target in ESCAPE_ROUTES:
            check((service, "*", subject, target, "deny") in deny,
                  "camera-side qube %s must not reach %s via %s" % (subject, target, service))
    for subject in ("sys-usb-webcam", "seqs-qr-scanner"):
        for service in ("qubes.InputKeyboard", "qubes.InputMouse", "qubes.InputTablet"):
            check((service, "*", subject, "@adminvm", "deny") in deny,
                  "camera-side qube %s must not send %s to dom0" % (subject, service))
    check(("qubes.Filecopy", "*", "sys-usb-webcam", "@anyvm", "deny") in deny,
          "the USB backend must not copy files anywhere")
    copy_rules = [r for r in policy_rules(state_arg(parsed, "seqs-policy-qr-filecopy", "file.managed", "contents"))
                  if r[0] == "qubes.Filecopy"]
    check(copy_rules == [("qubes.Filecopy", "*", "seqs-qr-scanner", "A-qr-staging", "allow"),
                         ("qubes.Filecopy", "*", "seqs-qr-scanner", "@anyvm", "deny")],
          "the scanner may copy files to the staging qube only, got %r" % copy_rules)
    for state in ("seqs-webcam-usb-backend", "seqs-qr-scanner"):
        check("default_dispvm none" in state_arg(parsed, state, "cmd.run", "name"),
              "%s must clear the default disposable" % state)
    check("no-strict-reset=true" not in text,
          "sequential mode must keep strict reset unless explicitly disabled")
    backend = state_arg(parsed, "seqs-webcam-usb-backend", "cmd.run", "name")
    check("qvm-pci list sys-usb" in backend,
          "sequential mode must verify the controller through qvm-pci")
    check("pcidevs" not in backend,
          "PCI ownership is not a qvm-prefs property")
    check("detach --persistent" not in text,
          "qvm-pci detach has no --persistent option on Qubes 4.2 or 4.3")
    unassign = backend.find("qvm-pci unassign sys-usb-webcam dom0:00_14.0")
    check(0 <= unassign < backend.find("qvm-pci attach --persistent"),
          "a rerun must drop the old webcam assignment before recreating it")
    check("qvm-pci unassign --port sys-usb-webcam dom0:00_14.0" in backend,
          "an assignment carried over from Qubes 4.2 matches only by port")
    check(unresolved_requisites(parsed) == [],
          "every requisite must resolve: %r" % unresolved_requisites(parsed))


def test_dom0_qr_mode_without_camera_in_selection():
    case("dom0.sls: a later run that does not select qr-camera still renders")
    pillar = copy.deepcopy(render_pillar("dom0"))
    pillar.update({
        "webcam_usb_mode": "sequential",
        "webcam_usb_controller": "00_14.0",
        "webcam_usb_strict_reset": True,
    })
    sc = Scenario(sys_usb=True, selection="qr-staging",
                  existing_qubes=["A-brave", "A-qr-camera"],
                  tagged_qubes=["A-brave", "A-qr-camera"])
    _, parsed = render_state("dom0", "dom0", sc, pillar_seqs=pillar)
    check("seqs-validation-failed" not in parsed,
          "an existing A-qr-camera satisfies the webcam pre-flight")
    check("seqs-app-qr-camera" not in parsed,
          "qr-camera is not built when it is not selected")
    check(unresolved_requisites(parsed) == [],
          "webcam states must not require the unrendered qr-camera state: %r"
          % unresolved_requisites(parsed))
    # A run for an unrelated qube, with the whole QR setup already built.
    sc = Scenario(sys_usb=True, selection="brave",
                  existing_qubes=["A-qr-camera", "A-qr-staging"],
                  tagged_qubes=["A-qr-camera", "A-qr-staging"])
    _, parsed = render_state("dom0", "dom0", sc, pillar_seqs=pillar)
    check("seqs-validation-failed" not in parsed,
          "existing QR qubes satisfy the webcam pre-flight for other runs")
    check(unresolved_requisites(parsed) == [],
          "webcam states must not require unrendered QR states: %r"
          % unresolved_requisites(parsed))


def test_dom0_qr_qubes_are_the_catalogue_qubes():
    case("dom0.sls: the QR template and staging qube are the catalogue's, built by SEQS")
    pillar = copy.deepcopy(render_pillar("dom0"))
    pillar.update({
        "webcam_usb_mode": "sequential",
        "webcam_usb_controller": "00_14.0",
        "webcam_usb_strict_reset": True,
    })
    # Former settings: the scanner must never copy to a qube they name.
    _, parsed = render_state("dom0", "dom0", Scenario(sys_usb=True, existing_qubes=["vault"]),
                             pillar_seqs=dict(pillar, webcam_staging_qube="vault", webcam_scanner_dvm="vault"))
    copy_rules = policy_rules(state_arg(parsed, "seqs-policy-qr-filecopy", "file.managed", "contents"))
    check(("qubes.Filecopy", "*", "seqs-qr-scanner", "A-qr-staging", "allow") in copy_rules
          and "STAGING_QUBE='A-qr-staging'" in state_arg(parsed, "seqs-qr-sequential-config", "file.managed", "contents")
          and "-t A-qr-camera " in state_arg(parsed, "seqs-qr-scanner", "cmd.run", "name"),
          "the QR qubes must be the catalogue's, whatever the pillar says")
    # Not selected, a same-named qube counts only if SEQS built it for that recipe.
    for name, message in (("qr-staging", "sequential webcam mode requires qube 'qr-staging': select it in this run or build it first"),
                          ("qr-camera", "webcam_usb_controller requires qube 'qr-camera': select it in this run or build it first")):
        other = "qr-camera" if name == "qr-staging" else "qr-staging"
        vm, built = "A-" + name, "A-" + other
        for tagged, recipes, what in (([built], {built: other}, "an unmanaged"),
                                      ([built, vm], {built: other, vm: "keepass"}, "a keepass")):
            _, parsed = render_state("dom0", "dom0", Scenario(
                sys_usb=True, selection="brave", existing_qubes=["A-brave", built, vm],
                tagged_qubes=["A-brave"] + tagged, recipes=recipes), pillar_seqs=pillar)
            check(message in _errors(parsed), "%s %s must not stand in for %s" % (what, vm, name))


def test_dom0_qr_special_qubes_are_their_own():
    case("dom0.sls: the camera-side qubes are never a catalogue qube or the normal USB qube")
    pillar = copy.deepcopy(render_pillar("dom0"))
    pillar.update(webcam_usb_mode="sequential", webcam_usb_controller="00_14.0", webcam_usb_strict_reset=True)
    built = ["A-brave", "A-qr-camera", "A-qr-staging", "A-keepass", "A-brave-old"]
    recipes = {"A-brave": "brave", "A-qr-camera": "qr-camera", "A-qr-staging": "qr-staging", "A-keepass": "keepass",
               "A-brave-old": "brave"}

    def errors(specials=(), **names):
        _, parsed = render_state("dom0", "dom0", Scenario(
            sys_usb=True, selection="brave", existing_qubes=built + list(specials),
            tagged_qubes=built + list(specials), recipes=recipes), pillar_seqs=dict(pillar, **names))
        return _errors(parsed)

    check(errors(["sys-usb-webcam", "seqs-qr-scanner"]) == "",
          "already-built camera-side qubes (managed, no recipe) must be adopted: %s"
          % errors(["sys-usb-webcam", "seqs-qr-scanner"]))
    for field, value, message in (
            ("webcam_usb_qube", "A-keepass", "is a qube SEQS builds from the catalogue"),  # built earlier
            ("webcam_usb_qube", "A-brave-old", "is a qube SEQS builds from the catalogue"),  # an instance built earlier
            ("webcam_scanner_qube", "Z-brave", "is a qube SEQS builds from the catalogue"),  # built in this run
            ("webcam_usb_qube", "A-signal", "is a qube SEQS builds from the catalogue"),  # not built yet
            ("webcam_usb_qube", "D-qr-display", "is a qube SEQS builds from the catalogue"),  # named disposable
            ("webcam_scanner_qube", "sys-usb", "is the normal USB qube (webcam_normal_usb_qube)")):
        check("%s '%s' %s -- choose another name" % (field, value, message) in errors(**{field: value}),
              "%s '%s' must be refused" % (field, value))
    # A qube built before SEQS recorded recipes has none, but keeps its catalogue name.
    _, parsed = render_state("dom0", "dom0", Scenario(
        sys_usb=True, selection="brave", existing_qubes=built, tagged_qubes=built,
        recipes={"A-brave": "brave", "A-qr-staging": "qr-staging", "A-brave-old": "brave"}),
        pillar_seqs=dict(pillar, webcam_usb_qube="A-qr-camera"))
    check("webcam_usb_qube 'A-qr-camera' is a qube SEQS builds from the catalogue -- choose another name"
          in _errors(parsed), "a recipe-less A-qr-camera must not become the camera USB qube")
    check("webcam_usb_qube and webcam_scanner_qube are both 'cam' -- they must name different qubes"
          in errors(webcam_usb_qube="cam", webcam_scanner_qube="cam"),
          "the two camera-side qubes must differ")


def test_dom0_sequential_qr_allows_explicit_weak_reset():
    case("dom0.sls: sequential QR mode accepts webcam_usb_strict_reset = False without a reset method")
    pillar = copy.deepcopy(render_pillar("dom0"))
    pillar.update({
        "webcam_usb_mode": "sequential",
        "webcam_usb_controller": "00_14.0",
        "webcam_usb_strict_reset": False,
    })
    for methods in ("", "acpi device_specific"):
        _, parsed = render_state(
            "dom0", "dom0", Scenario(sys_usb=True, pci_reset=methods), pillar_seqs=pillar)
        check("seqs-validation-failed" not in parsed,
              "sequential mode without a usable reset method (%r) must pass pre-flight" % methods)
    backend = state_arg(parsed, "seqs-webcam-usb-backend", "cmd.run", "name")
    check("qvm-pci attach --persistent --option no-strict-reset=true "
          "sys-usb-webcam dom0:00_14.0" in backend,
          "the option must apply to the webcam backend's assignment")
    check(backend.count("--option no-strict-reset") == 1,
          "no other assignment may be weakened")
    check("qvm-pci list sys-usb" in backend,
          "sequential mode must still require sys-usb to own the controller")


def test_dom0_qr_strict_reset_matches_controller():
    case("dom0.sls: webcam_usb_strict_reset must match the controller's reset methods")
    pillar = copy.deepcopy(render_pillar("dom0"))
    check(pillar.get("webcam_usb_strict_reset") is True,
          "the shipped configuration should require a strict reset")
    pillar.update({"webcam_usb_mode": "sequential", "webcam_usb_controller": "00_14.0"})
    def errors(strict, methods):
        pillar["webcam_usb_strict_reset"] = strict
        _, parsed = render_state(
            "dom0", "dom0", Scenario(sys_usb=True, pci_reset=methods), pillar_seqs=pillar)
        return _errors(parsed)
    check("webcam_usb_controller '00_14.0' has no strict reset, so the webcam qube "
          "could not start: set webcam_usb_strict_reset = False" in errors(True, ""),
          "a strict reset on a controller without one must fail pre-flight")
    check("has no strict reset" in errors(True, "acpi"),
          "a reset method that libvirt cannot use is no strict reset")
    check("webcam_usb_strict_reset is False, but webcam_usb_controller '00_14.0' "
          "supports a strict reset (pm): set it to True" in errors(False, "acpi pm"),
          "skipping an available strict reset must fail pre-flight")
    check("webcam_usb_controller '00_14.0' is not a PCI device of this computer"
          in errors(True, None),
          "a BDF without a PCI device must fail pre-flight")
    for value in ("False", 0, "no"):
        check("webcam_usb_strict_reset '%s' must be True or False" % value in errors(value, ""),
              "webcam_usb_strict_reset %r must fail pre-flight" % (value,))


# A fake qvm-pci over a file of "<device> <owner>" assignments, printed as
# qvm-pci list --assignments does: owner marked * before "(required". An
# unassign of the device KEEP fails silently, as the backend state allows.
_FAKE_QVM_PCI = r"""
qvm-check() { return 0; }; qvm-prefs() { :; }; qvm-features() { :; }
qvm-shutdown() { :; }; qvm-create() { :; }; qvm-start() { :; }
qvm-ls() { awk '{ print $2 }' "$A" | sort -u; }
qvm-pci() {
  case "$1 $2" in
    "list --assignments") awk '{ print $1 "  USB controller  *" $2 " (required: )" }' "$A" ;;
    "list "*) awk -v q="$2" '$2 == q { print $1 "  USB controller  " q " (attached: )" }' "$A" ;;
    "unassign --port"|"detach "*) ;;
    unassign*) [ "$3" = "$KEEP" ] || { grep -vxF "$3 $2" "$A" > "$A.n" || true; mv "$A.n" "$A"; } ;;
    "attach --persistent") echo "${*: -1} ${*: -2:1}" >> "$A" ;;
  esac
}
"""


def _run_webcam_backend(backend, assigned, keep=""):
    """Run the backend command against _FAKE_QVM_PCI; return it and the assignments left."""
    with tempfile.TemporaryDirectory() as d:
        a = os.path.join(d, "assignments")
        with open(a, "w") as f:
            f.write("".join("%s %s\n" % pair for pair in assigned))
        r = subprocess.run(["bash", "-c", _FAKE_QVM_PCI + backend], capture_output=True, text=True,
                           env={"PATH": "/usr/bin:/bin", "A": a, "KEEP": keep})
        with open(a) as f:
            return r, sorted(f.read().split("\n"))


def test_dom0_qr_backend_holds_only_the_configured_controller():
    case("dom0.sls: each build leaves the webcam backend only the configured controller")
    pillar = copy.deepcopy(render_pillar("dom0"))
    pillar.update({"webcam_usb_mode": "sequential", "webcam_usb_controller": "00_14.0"})
    _, parsed = render_state("dom0", "dom0", Scenario(sys_usb=True), pillar_seqs=pillar)
    backend = state_arg(parsed, "seqs-webcam-usb-backend", "cmd.run", "name")
    def run(assigned, keep=""):
        return _run_webcam_backend(backend, assigned, keep)
    check("still holds" not in backend, "sequential mode must let sys-usb keep its assignment")
    usb = [("dom0:00_14.0", "sys-usb"), ("dom0:00_0d.0", "sys-usb")]
    r, left = run(usb + [("dom0:00_0d.0", "sys-usb-webcam"), ("dom0:00_14.0", "sys-usb-webcam")])
    check(r.returncode == 0 and left == sorted(["", "dom0:00_14.0 sys-usb", "dom0:00_0d.0 sys-usb",
                                                "dom0:00_14.0 sys-usb-webcam"]),
          "a controller configured earlier must lose its webcam assignment, and only it: %r %r"
          % (left, r.stderr))
    r, _ = run(usb + [("dom0:00_0d.0", "sys-usb-webcam")], keep="dom0:00_0d.0")
    check(r.returncode != 0 and "ERROR: sys-usb-webcam must have exactly dom0:00_14.0 assigned" in r.stderr,
          "an assignment that does not go away must stop the build: %r" % r.stderr)
    r, _ = run(usb + [("dom0:00_0d.0;x", "sys-usb-webcam")])
    check(r.returncode != 0 and "has a PCI assignment that is not a BDF" in r.stderr,
          "an unexpected device name must stop the build: %r" % r.stderr)


def test_dom0_dedicated_qr_rejects_weak_reset():
    case("dom0.sls: dedicated QR mode rejects webcam_usb_strict_reset = False")
    pillar = copy.deepcopy(render_pillar("dom0"))
    pillar.update({
        "webcam_usb_mode": "dedicated",
        "webcam_usb_controller": "03_00.0",
        "webcam_usb_strict_reset": False,
    })
    _, parsed = render_state(
        "dom0", "dom0", Scenario(sys_usb=True, pci_reset=""), pillar_seqs=pillar)
    check("dedicated webcam mode requires webcam_usb_strict_reset = True" in _errors(parsed),
          "dedicated + no strict reset must fail pre-flight")
    pillar["webcam_usb_strict_reset"] = True
    _, parsed = render_state(
        "dom0", "dom0", Scenario(sys_usb=True, pci_reset=""), pillar_seqs=pillar)
    check("has no strict reset, so the webcam qube could not start; dedicated mode "
          "needs a controller with one" in _errors(parsed),
          "dedicated mode on a controller without a strict reset must fail pre-flight")


def test_dom0_dedicated_qr_uses_device_api():
    case("dom0.sls: dedicated QR mode manages PCI through qvm-pci")
    pillar = copy.deepcopy(render_pillar("dom0"))
    pillar.update({
        "webcam_usb_mode": "dedicated",
        "webcam_usb_controller": "03_00.0",
        "webcam_usb_strict_reset": True,
    })
    text, parsed = render_state(
        "dom0", "dom0", Scenario(sys_usb=True), pillar_seqs=pillar)
    backend = state_arg(parsed, "seqs-webcam-usb-backend", "cmd.run", "name")
    check("qvm-pci list" in backend and "qvm-pci unassign" in backend,
          "dedicated mode must inspect and remove PCI assignments with qvm-pci")
    check("pcidevs" not in backend,
          "dedicated mode must not query nonexistent qvm-prefs pcidevs")
    check('qvm-start -- "$current"' in backend
          and 'qvm-check --running -q -- "$current"' in backend,
          "dedicated mode must restart only the running qubes it stopped")
    check('[ "$current" = dom0 ] && continue' in backend,
          "dedicated mode must skip dom0, whose qvm-pci list shows every device")
    check('qvm-pci unassign --port "$current" dom0:03_00.0' in backend,
          "dedicated mode must also drop assignments carried over from 4.2")
    check("could not stop $current" in backend, "a former owner that keeps running must stop the state")
    # A removal that fails silently must still stop the state, and only
    # another owner of the camera controller does.
    usb = [("dom0:03_00.0", "sys-usb"), ("dom0:00_14.0", "sys-usb")]
    r, left = _run_webcam_backend(backend, usb)
    check(r.returncode == 0 and left == sorted(["", "dom0:00_14.0 sys-usb", "dom0:03_00.0 sys-usb-webcam"]),
          "dedicated mode must move the controller to the webcam backend: %r %r" % (left, r.stderr))
    r, _ = _run_webcam_backend(backend, usb, keep="dom0:03_00.0")
    check(r.returncode != 0 and "ERROR: sys-usb still holds dom0:03_00.0" in r.stderr,
          "dedicated mode must fail while another qube still holds the controller: %r" % r.stderr)
    # The owner list runs under the state's set -e: a failing or empty
    # qvm-ls must stop it before the camera is attached.
    has_listing = 'vms="$(qvm-ls' in backend and 'for current in $vms' in backend
    check(has_listing, "dedicated mode must list the qubes into a variable it can check")
    listing = backend[backend.index('vms="$(qvm-ls'):backend.index('for current in $vms')] if has_listing else ""
    for fake in ("exit 1", "true") if has_listing else ():
        r = subprocess.run(["bash", "-ec", "qvm-ls() { %s; }\n%secho ATTACHED" % (fake, listing)],
                           capture_output=True, text=True)
        check(r.returncode != 0 and "ATTACHED" not in r.stdout and "syntax" not in r.stderr.lower(),
              "dedicated mode must stop when qvm-ls %s" %
              ("fails" if fake == "exit 1" else "lists nothing"))
    unless = state_arg(parsed, "seqs-webcam-usb-backend", "cmd.run", "unless")
    check("exit !(mine && !other && !extra)" in unless,
          "the backend state may be skipped only while the webcam qube is the controller's sole owner"
          " and holds nothing else")
    for vm in ("sys-usb-webcam", "seqs-qr-scanner"):
        check("add seqs-no-handoff" in state_arg(parsed, "seqs-handoff-tag-" + vm, "cmd.run", "name"),
              "the webcam qube %s must be tagged" % vm)
    check(unresolved_requisites(parsed) == [],
          "every requisite must resolve: %r" % unresolved_requisites(parsed))
    deny = state_arg(parsed, "seqs-policy-qr-input-deny", "file.managed", "contents")
    check(("qubes.OpenURL", "*", "sys-usb-webcam", "@anyvm", "deny") in policy_rules(deny),
          "dedicated mode must also close the browser handoff for camera-side qubes")
    # Qubes 4.3 matches a @dispvm:<template> source against no running qube,
    # so the dedicated path scans in the named disposable, which rules can name.
    check("seqs-qr-scanner" in parsed,
          "dedicated mode must create the named scanner disposable")
    check(("qubes.OpenURL", "*", "seqs-qr-scanner", "@anyvm", "deny") in policy_rules(deny)
          and "qubes.InputKeyboard  *  seqs-qr-scanner  @adminvm  deny" in deny,
          "dedicated mode must deny the handoff and input from the named scanner")
    check("qubes.Filecopy  *  seqs-qr-scanner" not in text,
          "dedicated mode must leave the scanner's file copy at the default ask")
    check(unresolved_requisites(parsed) == [],
          "every requisite must resolve: %r" % unresolved_requisites(parsed))


def test_dom0_named_disposable():
    case("dom0.sls: a 'named_disposable' entry gets a launchable DispVM (D-*)")
    # qr-display is a named_disposable; A-brave must exist so browser_vm
    # validation passes when only qr-display is selected.
    sc = Scenario(selection="qr-display",
                  existing_qubes=["A-brave"], tagged_qubes=["A-brave"])
    text, parsed = render_state("dom0", "dom0", sc)
    check("seqs-validation-failed" not in parsed,
          "selecting a named_disposable qube must pass validation")
    for state in ("seqs-create-disposable-qr-display",
                  "seqs-disposable-prefs-qr-display",
                  "seqs-tag-disposable-qr-display"):
        check(state in parsed, "named_disposable should render %s" % state)
    create = state_arg(parsed, "seqs-create-disposable-qr-display",
                       "cmd.run", "name")
    check("qvm-create -C DispVM -t A-qr-display" in create
          and create.rstrip().endswith("D-qr-display"),
          "the disposable must be a DispVM derived from A-qr-display, named D-*")
    prefs = state_arg(parsed, "seqs-disposable-prefs-qr-display",
                      "cmd.run", "name")
    check("netvm none" in prefs,
          "the disposable of an offline dispvm template must have its netvm cleared")
    # qr-camera is a dispvm_template but NOT a named_disposable -> no D- qube.
    check("seqs-create-disposable-qr-camera" not in parsed,
          "a dispvm_template without named_disposable must not get a named DispVM")
    # The disposable is written to the targets file as its own kind + offline,
    # so the runner air-gap-verifies it without trying to provision it.
    targets = state_arg(parsed, "seqs-targets", "file.managed", "contents")
    check("disposable D-qr-display qr-display offline" in targets,
          "the named disposable must be listed for independent air-gap verification")
    check("app D-qr-display" not in targets,
          "the disposable must not be listed as an app (it is never provisioned)")
    # No-clobber: a pre-existing untagged D-qr-display must be refused, and an
    # interrupted-run intent marker must let it be adopted -- same as A-/Z-.
    _, refused = render_state("dom0", "dom0", Scenario(
        selection="qr-display", existing_qubes=["A-brave", "D-qr-display"],
        tagged_qubes=["A-brave"]))
    check("qube 'D-qr-display' already exists but is not marked seqs-managed" in _errors(refused),
          "an untagged pre-existing D- qube must trip the no-clobber guard")
    _, adopted = render_state("dom0", "dom0", Scenario(
        selection="qr-display", existing_qubes=["A-brave", "D-qr-display"],
        tagged_qubes=["A-brave"],
        existing_files=["/var/lib/seqs/intents/D-qr-display"]))
    check("seqs-validation-failed" not in adopted,
          "a D- qube with an interrupted-run intent marker must be adopted")


def test_dom0_netvm_key():
    case("dom0.sls: 'netvm' routes a qube and its named disposable through a network provider")
    # Until the provider was provisioned, which installs its killswitch, both
    # have no NetVM; the runner sets the provider after provisioning it.
    _, parsed = render_state("dom0", "dom0", Scenario(selection="gnosisvpn\nanon"))
    check("seqs-validation-failed" not in parsed, "anon with gnosisvpn must pass validation: " + _errors(parsed))
    app = parsed.get("seqs-app-anon", {}).get("qvm.vm", [])
    check(not [p for p in next((i["prefs"] for i in app if "prefs" in i), []) if "netvm" in p],
          "A-anon must get no NetVM before A-gnosisvpn was provisioned")
    check(state_arg(parsed, "seqs-netvm-pending-anon", "cmd.run", "name") == "qvm-prefs -- A-anon netvm none",
          "A-anon's NetVM must be cleared before A-gnosisvpn was provisioned")
    check("qvm-prefs -- D-anon netvm none\n" in state_arg(parsed, "seqs-disposable-prefs-anon", "cmd.run", "name"),
          "D-anon must get no NetVM before A-gnosisvpn was provisioned")
    # A provisioned provider is used, also when it is not selected.
    provisioned = dict(existing_qubes=["A-gnosisvpn"], tagged_qubes=["A-gnosisvpn"],
                       recipes={"A-gnosisvpn": "gnosisvpn"}, provisioned_qubes=["A-gnosisvpn"])
    _, parsed = render_state("dom0", "dom0", Scenario(selection="gnosisvpn\nanon", **provisioned))
    check("seqs-validation-failed" not in parsed, "anon with gnosisvpn must pass validation: " + _errors(parsed))
    check("seqs-netvm-pending-anon" not in parsed, "a provisioned provider must not clear A-anon's NetVM")
    app = parsed.get("seqs-app-anon", {}).get("qvm.vm", [])
    check({"netvm": "A-gnosisvpn"} in next((i["prefs"] for i in app if "prefs" in i), []),
          "A-anon must get A-gnosisvpn as NetVM")
    check({"cmd": "seqs-network-provider-gnosisvpn"} in next((i["require"] for i in app if "require" in i), []),
          "A-anon must wait until A-gnosisvpn provides network")
    dvm = parsed.get("seqs-disposable-prefs-anon", {}).get("cmd.run", [])
    check("qvm-prefs -- D-anon netvm A-gnosisvpn\n" in next((i["name"] for i in dvm if "name" in i), ""),
          "D-anon must get A-gnosisvpn as NetVM")
    check('$1 == "netvm" && $3 == "A-gnosisvpn"' in next((i["unless"] for i in dvm if "unless" in i), ""),
          "the disposable's NetVM must be rechecked as explicitly A-gnosisvpn")
    targets = next((i["contents"] for i in parsed.get("seqs-targets", {}).get("file.managed", []) if "contents" in i), "")
    check("app A-anon anon netvm=A-gnosisvpn nodispvm\n" in targets
          and "disposable D-anon anon netvm=A-gnosisvpn nodispvm\n" in targets,
          "the runner must be told to verify both NetVMs and that neither has a default disposable")
    _, parsed = render_state("dom0", "dom0", Scenario(selection="wallet-ledger\nkeepass\nbrave"))
    targets = state_arg(parsed, "seqs-targets", "file.managed", "contents")
    check("app A-wallet-ledger wallet-ledger nodispvm\n" in targets and "app A-keepass keepass offline\n" in targets
          and "app A-brave brave\n" in targets,
          "only a no_handoff qube that is not offline must be marked nodispvm: " + targets)
    check("qvm-prefs -- D-qr-display netvm none\n" in state_arg(
        render_state("dom0", "dom0", Scenario(selection="qr-display\nbrave"))[1], "seqs-disposable-prefs-qr-display", "cmd.run", "name"),
          "a disposable without 'netvm' must stay offline")
    # The provider must be selected or already built for its recipe.
    _, parsed = render_state("dom0", "dom0", Scenario(selection="anon"))
    check("qube 'anon' needs its netvm 'A-gnosisvpn': select 'gnosisvpn' in this run or provision it successfully first" in _errors(parsed),
          "anon without its provider must be refused")
    _, parsed = render_state("dom0", "dom0", Scenario(selection="anon", existing_qubes=["A-gnosisvpn"],
                                                      tagged_qubes=["A-gnosisvpn"], recipes={"A-gnosisvpn": "brave"},
                                                      provisioned_qubes=["A-gnosisvpn"]))
    check("needs its netvm 'A-gnosisvpn'" in _errors(parsed), "a provider built for another recipe must not count")
    _, parsed = render_state("dom0", "dom0", Scenario(selection="anon", existing_qubes=["A-gnosisvpn"],
                                                      tagged_qubes=["A-gnosisvpn"], recipes={"A-gnosisvpn": "gnosisvpn"}))
    check("needs its netvm 'A-gnosisvpn'" in _errors(parsed), "a provider never provisioned must not count")
    _, parsed = render_state("dom0", "dom0", Scenario(selection="anon", **provisioned))
    check("seqs-validation-failed" not in parsed, "anon with a provisioned A-gnosisvpn must pass: " + _errors(parsed))
    check("qvm-prefs -- D-anon netvm A-gnosisvpn\n" in state_arg(parsed, "seqs-disposable-prefs-anon", "cmd.run", "name"),
          "D-anon must use an unselected provisioned provider")
    check("seqs-network-provider-gnosisvpn" not in str(parsed.get("seqs-app-anon", "")),
          "an unselected provider has no state to wait for")
    for entry, why in [({"netvm": "brave"}, "a qube that provides no network"),
                       ({"netvm": "no-such"}, "an unknown entry"),
                       ({"netvm": ["gnosisvpn"]}, "a non-string")]:
        cat = {"brave": {"label": "red", "components": ["brave"]},
               "gnosisvpn": {"label": "purple", "components": ["gnosisvpn"], "network_provider": True},
               "x": dict({"label": "red", "components": ["brave"]}, **entry)}
        check(_rejected("qube 'x': 'netvm' must name a catalogue entry with 'network_provider'", _bad_pillar(catalogue=cat)),
              "'netvm' naming %s must be refused" % why)
    for flag in ("offline", "network_provider"):
        cat = {"brave": {"label": "red", "components": ["brave"]},
               "gnosisvpn": {"label": "purple", "components": ["gnosisvpn"], "network_provider": True},
               "x": {"label": "red", "components": ["brave"], "netvm": "gnosisvpn", flag: True}}
        check(_rejected("qube 'x' sets 'netvm' together with 'offline' or 'network_provider'", _bad_pillar(catalogue=cat)),
              "'netvm' with '%s' must be refused" % flag)


def test_dom0_protonvpn_network_manager():
    case("dom0.sls: the Proton VPN qube runs NetworkManager and the Qubes firewall")
    _, parsed = render_state("dom0", "dom0", Scenario(selection="protonvpn"))
    check("qvm-service --enable A-protonvpn network-manager" in str(parsed.get("seqs-network-manager-protonvpn", "")),
          "A-protonvpn must get the network-manager service")
    check("seqs-network-provider-protonvpn" in parsed, "A-protonvpn must run the Qubes firewall")
    # qvm-service prints "on", not "1": the guards read the feature itself.
    for state, svc in (("seqs-network-manager-protonvpn", "network-manager"), ("seqs-network-provider-protonvpn", "qubes-firewall")):
        check('test "$(qvm-features -- A-protonvpn service.%s 2>/dev/null)" = "1"' % svc in str(parsed.get(state, "")),
              "the %s state must be skipped once the service is on" % svc)
    _, parsed = render_state("dom0", "dom0", Scenario(selection="wireguard"))
    check("seqs-network-manager-wireguard" not in parsed, "only Proton VPN qubes get NetworkManager")


def test_protonvpn_fail_closed_hook():
    case("protonvpn: the app qube's firewall hook drops forwarding to eth0 for IPv4 and IPv6")
    d = os.path.join(sr.REPO_ROOT, "install-scripts", "components", "protonvpn")
    hook = app = ""
    for name in ("protonvpn-firewall.sh", "app-vm.sh"):
        path = os.path.join(d, name)
        check(os.path.isfile(path), "the protonvpn component must ship %s" % name)
        if os.path.isfile(path):
            with open(path, encoding="utf-8") as f:
                if name == "app-vm.sh":
                    app = f.read()
                else:
                    hook = f.read()
    for family in ("ip", "ip6"):
        check('\nnft add rule %s qubes custom-forward oifname "eth0" counter drop\n' % family in hook,
              "the hook must drop forwarded %s traffic to eth0" % family)
    check(hook.startswith("#!/bin/sh\n") and "\nset -e\n" in hook, "the hook must run directly and stop on a missing chain")
    check("entry=/rw/config/seqs-protonvpn-firewall.sh" in app and
          'printf \'%s\\n\' "${entry}"; } | sudo tee -a "${hook}"' in app and
          "hook=/rw/config/qubes-firewall-user-script" in app,
          "app-vm.sh must add the hook to qubes-firewall-user-script")


def test_vpn_fail_closed_hooks():
    case("VPN NetVMs: each firewall hook drops forwarding to eth0, IPv4 first, and stops on an error")
    comps = os.path.join(sr.REPO_ROOT, "install-scripts", "components")
    for path, shebang in (("protonvpn/protonvpn-firewall.sh", "#!/bin/sh"),
                          ("wireguard/wireguard-firewall.sh", "#!/usr/bin/env bash"),
                          ("gnosisvpn/seqs-gnosisvpn-firewall", "#!/usr/bin/env bash")):
        with open(os.path.join(comps, path), encoding="utf-8") as f:
            lines = f.read().splitlines()
        drops = ['nft add rule %s qubes custom-forward oifname "eth0" counter drop' % family
                 for family in ("ip", "ip6")]
        check(all(d in lines for d in drops), "%s must drop forwarded IPv4 and IPv6 traffic to eth0" % path)
        first = min((i for i, line in enumerate(lines) if line.startswith("nft ")), default=len(lines))
        check(lines[first:first + 1] == drops[:1], "%s must add the IPv4 drop first" % path)
        check(lines[:1] == [shebang] and any(line in ("set -e", "set -Eeuo pipefail") for line in lines[:first]),
              "%s must run under %s and stop on a missing chain" % (path, shebang))


def test_dom0_named_disposable_rerun_churn_free():
    case("dom0.sls: an already-built named disposable is churn-free on re-run")
    dom0 = render_pillar("dom0")
    names = list(dom0["catalogue"].keys())
    existing = (["Z-" + n for n in names] + ["A-" + n for n in names]
                + ["D-qr-display", "D-anon"])
    _, parsed = render_state(
        "dom0", "dom0",
        Scenario(existing_qubes=existing, tagged_qubes=existing))
    for state in ("seqs-create-disposable-qr-display",
                  "seqs-intent-disposable-qr-display",
                  "seqs-tag-disposable-qr-display"):
        check(state not in parsed,
              "re-run over a tagged disposable must not render %s" % state)
    check("seqs-disposable-prefs-qr-display" in parsed,
          "prefs stay (guarded by unless) so drift is still corrected")


# ---------------------------------------------------------------------------
# dom0.sls -- validation logic (feed hand-built bad pillars)
# ---------------------------------------------------------------------------
def _bad_pillar(**overrides):
    """A minimal-but-valid dom0 pillar, with fields overridden per test."""
    base = {
        "prefix_template": "Z-",
        "prefix_app": "A-",
        "base_template": "debian-13-xfce",
        "browser_vm": "A-brave",
        "browser_desktop": "open-links-in-browser-qube.desktop",
        "config_errors": [],
        "catalogue": {"brave": {"label": "red", "components": ["brave"]}},
        "brave_extensions": {"rabby": "acmacodkjbdgmoleebolmdjonilkdbch"},
        "cleanup_dirs": [],
    }
    base.update(overrides)
    return base


def _rejected(expected, pillar):
    """True if the pre-flight refuses PILLAR with an error containing EXPECTED."""
    return expected in _validation_error(pillar)


def _validation_error(pillar):
    """The pre-flight's error text for PILLAR, or '' if validation passes."""
    _, parsed = render_state("dom0", "dom0", Scenario(), pillar_seqs=pillar)
    if "seqs-validation-failed" not in parsed:
        return ""
    return state_arg(parsed, "seqs-validation-failed", "test.fail_without_changes", "comment")


def test_dom0_validation_catches_bad_config():
    case("dom0.sls: pre-flight validation rejects malformed pillar")
    check(_rejected("has unknown label 'chartreuse'", _bad_pillar(
        catalogue={"brave": {"label": "chartreuse", "components": ["brave"]}})),
        "unknown label must fail validation")
    check(_rejected("qube 'brave' has unknown key(s) ofline", _bad_pillar(
        catalogue={"brave": {"label": "red", "components": ["brave"], "ofline": True}})),
        "a misspelled flag must fail validation instead of being ignored")
    check(_rejected("qube 'brave': 'offline' must be True or False", _bad_pillar(
        catalogue={"brave": {"label": "red", "components": ["brave"], "offline": "no"}})),
        "a non-boolean flag must fail validation")
    check(_rejected("references unknown component 'does-not-exist'", _bad_pillar(
        catalogue={"brave": {"label": "red", "components": ["does-not-exist"]}})),
        "unknown component must fail validation")
    check(_rejected("qube name 'bad name' is unsafe", _bad_pillar(
        catalogue={"bad name": {"label": "red", "components": ["brave"]}})),
        "unsafe qube name must fail validation")
    check(_rejected("references unknown Brave extension 'nope'", _bad_pillar(
        catalogue={"brave": {"label": "red", "components": ["brave-extension-nope"]}})),
        "reference to an undefined Brave extension must fail validation")
    check(_rejected("sets both 'offline' and 'firewall'", _bad_pillar(
        catalogue={"x": {"label": "gray", "components": ["brave"],
                     "offline": True, "firewall": ["dns"]}})),
        "offline + firewall is contradictory and must fail validation")
    check(_rejected("sets both 'named_disposable' and 'firewall'", _bad_pillar(
        prefix_disposable="D-",
        catalogue={"x": {"label": "gray", "components": ["brave"], "netvm": "vpn",
                         "dispvm_template": True, "named_disposable": True, "firewall": ["dns"]},
                   "vpn": {"label": "purple", "components": ["wireguard"], "network_provider": True}})),
        "the named disposable would not carry the allowlist, so the pre-flight must refuse it")
    check(_rejected("invalid firewall entry 'not a host!!'", _bad_pillar(
        catalogue={"x": {"label": "gray", "components": ["brave"],
                     "firewall": ["not a host!!"]}})),
        "malformed firewall entry must fail validation")
    # A trailing newline passes a regex that ends in $ but not one that ends in \Z.
    check(_rejected("invalid firewall entry 'example.com\n'", _bad_pillar(
        catalogue={"x": {"label": "gray", "components": ["brave"],
                     "firewall": ["example.com\n"]}})),
        "a firewall entry with a trailing newline must fail validation")
    check(_rejected("has invalid Chrome Web Store ID", _bad_pillar(
        brave_extensions={"rabby": "a" * 32 + "\n"},
        catalogue={"brave": {"label": "red", "components": ["brave", "brave-extension-rabby"]}})),
        "an extension ID with a trailing newline must fail validation")
    check(_rejected("duplicate qube name 'brave'", _bad_pillar(
        config_errors=["duplicate qube name 'brave'"])),
        "config_errors from pillar compilation must abort the dom0 apply")
    for bdf in ("00_1A.0", "0000:00:14.0", "00:14.0", "00_14.8", "00_14.0\n"):
        check(_rejected("webcam_usb_controller '%s' is invalid" % bdf, _bad_pillar(
            webcam_usb_mode="sequential", webcam_usb_controller=bdf)),
            "controller '%s' is not a lowercase qvm-pci BDF and must fail" % bdf)
    # These names reach root shell commands and qrexec policy lines.
    for field in ("webcam_usb_qube", "webcam_normal_usb_qube", "webcam_scanner_qube"):
        for value in ("x;id", "x\n"):
            check(_rejected("%s '%s' has an unsafe name" % (field, value), _bad_pillar(
                webcam_usb_mode="sequential", webcam_usb_controller="00_14.0", **{field: value})),
                "%s %r must fail validation" % (field, value))
    check(_rejected("webcam_usb_controller is set while webcam_usb_mode is disabled", _bad_pillar(
        webcam_usb_mode="disabled", webcam_usb_controller="00_14.0")),
        "a controller with the mode disabled must fail validation")
    check(_rejected("base template 'no-such-template' does not exist", _bad_pillar(base_template="no-such-template")),
        "a missing base template must fail validation")
    check(_rejected("sets 'named_disposable' but not 'dispvm_template'", _bad_pillar(
        catalogue={"x": {"label": "black", "components": ["brave"],
                     "named_disposable": True}})),
        "named_disposable without dispvm_template must fail validation")
    check(_rejected("requests a named disposable but prefix_disposable is missing or unsafe", _bad_pillar(
        prefix_disposable="",
        catalogue={"x": {"label": "black", "components": ["brave"],
                     "offline": True, "dispvm_template": True,
                     "named_disposable": True}})),
        "named_disposable with no prefix_disposable configured must fail validation")
    # ...and a clean pillar must NOT trip validation (guards against a check
    # that fails everything).
    check(not _validation_error(_bad_pillar()),
          "a well-formed minimal pillar must PASS validation")
    check(_rejected("sets both 'network_provider' and 'offline'", _bad_pillar(
        catalogue={"x": {"label": "purple", "components": ["wireguard"],
                     "network_provider": True, "offline": True}})),
        "network_provider + offline is contradictory and must fail validation")
    check(_rejected("is a DisposableVM template but neither offline nor routed through a 'netvm' network provider", _bad_pillar(
        catalogue={"x": {"label": "black", "components": ["brave"], "dispvm_template": True}})),
        "a disposable template must be offline")
    seq = copy.deepcopy(render_pillar("dom0"))
    seq.update({"webcam_usb_mode": "sequential", "webcam_usb_controller": "00_14.0"})
    seq["catalogue"]["qr-staging"]["offline"] = False
    check(_rejected("sequential webcam mode requires qr-staging to be offline", seq),
          "sequential mode must refuse a networked staging qube")
    seq["catalogue"]["qr-staging"]["offline"] = True
    _, parsed = render_state("dom0", "dom0", Scenario(sys_usb=True, existing_qubes=["sys-usb-webcam"]),
                             pillar_seqs=seq)
    check("special qube 'sys-usb-webcam' already exists but is not marked seqs-managed"
          in state_arg(parsed, "seqs-validation-failed", "test.fail_without_changes", "comment"),
          "an existing sys-usb-webcam that SEQS did not build must not be adopted")
    check(_rejected("sets both 'network_provider' and 'dispvm_template'", _bad_pillar(
        catalogue={"x": {"label": "purple", "components": ["wireguard"],
                     "network_provider": True, "dispvm_template": True}})),
        "a persistent network provider must not be a disposable template")


def test_dom0_firewall_states():
    case("dom0.sls: a 'firewall' key emits a qvm-firewall state")
    pillar = _bad_pillar(catalogue={
        "wallet": {"label": "gray", "components": ["brave"],
                   "firewall": ["dns", "rpc.example.com:443"]}})
    # browser_vm is A-brave but 'brave' isn't in this minimal map, so make it
    # resolve to an already-existing qube (else browser_vm validation fires).
    sc = Scenario(existing_qubes=["A-brave"])
    _, parsed = render_state("dom0", "dom0", sc, pillar_seqs=pillar)
    check("seqs-firewall-wallet" in parsed,
          "a qube with a firewall allowlist should get a firewall state")
    txt, _ = render_state("dom0", "dom0", sc, pillar_seqs=pillar)
    check("rpc.example.com" in txt and "dstports=443" in txt,
          "firewall rule should translate host:port into a qvm-firewall accept")
    unless = state_arg(parsed, "seqs-firewall-wallet", "cmd.run", "unless")
    check("add seqs-no-handoff" in state_arg(parsed, "seqs-handoff-tag-A-wallet", "cmd.run", "name"),
          "a firewall key implies no_handoff: no way past the allowlist through handoff or a disposable")
    check("qvm-firewall --raw -- A-wallet list" in unless,
          "the skip test must compare the qube's current rules, so hand edits are reverted")
    name = state_arg(parsed, "seqs-firewall-wallet", "cmd.run", "name")
    check("qvm-firewall --raw -- A-wallet list; } > /var/lib/seqs/firewall/A-wallet" in name,
          "the marker must record the rules Qubes reports after applying them")
    check("reset" not in name and name.index("add --before 0 drop") < name.index("accept"),
          "egress must be closed before the rules are replaced, never reset to allow-all")
    check("qvm-prefs -- A-wallet default_dispvm none"
          in state_arg(parsed, "seqs-no-dispvm-wallet", "cmd.run", "name"),
          "a firewalled qube must not keep a networked default disposable")
    # Qubes would refuse these only at apply time, after egress is closed.
    for bad in ["h:0", "h:65536", "999.1.1.1", "256.1.1.1", "010.1.1.1", "1.2.3", "1.2.3.4.5"]:
        check(_rejected("invalid firewall entry '%s'" % bad, _bad_pillar(catalogue={
            "wallet": {"label": "gray", "components": ["brave"], "firewall": [bad]}})),
            "firewall entry %r must be refused in the pre-flight" % bad)
    for good in ["h:1", "h:65535", "255.255.255.255", "0.0.0.0", "10.0.0.1:443", "a-1.example", "1example.com"]:
        check(not _rejected("invalid firewall entry", _bad_pillar(catalogue={
            "wallet": {"label": "gray", "components": ["brave"], "firewall": [good]}})),
            "firewall entry %r must be accepted" % good)


def test_dom0_network_provider():
    case("dom0.sls: a network provider exposes networking and enables firewall")
    pillar = _bad_pillar(catalogue={
        "wireguard": {"label": "purple", "components": ["wireguard"],
                      "network_provider": True, "no_handoff": True}})
    sc = Scenario(existing_qubes=["A-brave"])
    txt, parsed = render_state("dom0", "dom0", sc, pillar_seqs=pillar)
    check("provides_network" in txt,
          "network-provider qvm prefs should expose networking")
    check("seqs-network-provider-wireguard" in parsed,
          "network provider should enable the Qubes firewall service")
    check("qvm-prefs -- A-wireguard default_dispvm none"
          in state_arg(parsed, "seqs-no-dispvm-wireguard", "cmd.run", "name"),
          "a no_handoff qube must not keep a networked default disposable")


def test_dom0_audio_provider():
    case("dom0.sls: an audio qube gets the audiovm service, no audio qube, and only Qubes' sys-audio rules")
    bt = {"label": "blue", "components": ["bluetooth"], "offline": True, "audio_provider": True}
    pillar = _bad_pillar(catalogue={"bluetooth": bt, "brave": {"label": "red", "components": ["brave"]}})
    _, parsed = render_state("dom0", "dom0", Scenario(), pillar_seqs=pillar)
    cmd = state_arg(parsed, "seqs-audio-provider-bluetooth", "cmd.run", "name")
    check("qvm-service --enable A-bluetooth audiovm" in cmd and "qvm-prefs -- A-bluetooth audiovm ''" in cmd,
          "an audio qube must get the audiovm service and no audio qube of its own")
    check(state_arg(parsed, "seqs-blueman-bluetooth", "cmd.run", "name") == "qvm-service --enable A-bluetooth blueman",
          "the bluetooth component's qube must get the blueman service, which starts its panel icon")
    policy = state_arg(parsed, "seqs-policy-audiovm", "file.managed", "contents")
    rules = [line.split() for line in policy.splitlines() if line and not line.startswith("#")]
    tag = "@tag:audiovm-A-bluetooth"
    want = [[s, "*", "A-bluetooth", t, "allow", "target=dom0"]
            for s in ("admin.Events", "admin.vm.CurrentState", "admin.vm.List")
            for t in ("A-bluetooth", "@adminvm", tag)]
    want += [["admin.vm.property.Get", "+" + p, "A-bluetooth", tag, "allow", "target=dom0"]
             for p in ("audiovm", "xid", "stubdom_xid", "virt_mode", "is_preload")]
    want += [["admin.vm.feature.CheckWithTemplate", "+" + f, "A-bluetooth", tag, "allow", "target=dom0"]
             for f in ("audio", "audio-model")]
    check(rules == want, "the audio policy must hold exactly Qubes' sys-audio rules, got %r" % rules)
    check(policy.startswith("# Managed by SEQS"), "the audio policy must carry the SEQS marker")

    case("dom0.sls: a built audio qube keeps its rules when another qube is built; none removes the file")
    sc = Scenario(existing_qubes=["A-bluetooth"], tagged_qubes=["A-bluetooth"],
                  recipes={"A-bluetooth": "bluetooth"}, selection="brave")
    _, parsed = render_state("dom0", "dom0", sc, pillar_seqs=pillar)
    check("A-bluetooth" in state_arg(parsed, "seqs-policy-audiovm", "file.managed", "contents"),
          "an unselected, built audio qube must keep its policy rules")
    _, parsed = render_state("dom0", "dom0", Scenario(), pillar_seqs=_bad_pillar())
    check("grep -q '^# Managed by SEQS'" in state_arg(parsed, "seqs-policy-audiovm", "cmd.run", "onlyif"),
          "without an audio qube, only a SEQS-written audio policy may be removed")

    case("dom0.sls: an audio qube must be an offline app qube")
    for extra in ({"offline": False}, {"dispvm_template": True}):
        cat = {"bluetooth": dict(bt, **extra)}
        check(_rejected("qube 'bluetooth' sets 'audio_provider' without 'offline' or with 'dispvm_template'",
                        _bad_pillar(catalogue=cat)), "audio_provider with %r must be refused" % extra)
    check(_validation_error(pillar) == "", "an offline audio qube must be accepted")


# ---------------------------------------------------------------------------
# qube.sls
# ---------------------------------------------------------------------------
def test_qube_template():
    case("qube.sls: a template minion stages + installs its components")
    _, parsed = render_state("qube", "Z-brave")
    check("seqs-stage-brave" in parsed, "brave component should be staged")
    check("seqs-install-brave" in parsed, "brave component should be installed")
    check("seqs-browser-handler" in parsed,
          "template should install the link-handoff .desktop handler")
    # brave is not in cleanup? cleanup_dirs is global -> present in every template
    check("seqs-cleanup-script" in parsed,
          "template should install the boot/shutdown cleanup script")


def test_qube_cleanup_gate():
    case("qube.sls: the cleanup deletes only in qubes whose root is discarded, network providers included")
    script = state_arg(render_state("qube", "Z-brave")[1], "seqs-cleanup-script", "file.managed", "contents")
    with tempfile.TemporaryDirectory() as d:
        for tool in ("rm", "find"):
            with open(os.path.join(d, tool), "w") as f:
                f.write('#!/bin/sh\necho "%s $*" >> "$LOG"\n' % tool)
        with open(os.path.join(d, "qubesdb-read"), "w") as f:
            f.write('#!/bin/sh\n[ "$1" = /qubes-vm-persistence ] && [ -n "$P" ] && echo "$P"\n')
        for tool in ("rm", "find", "qubesdb-read"):
            os.chmod(os.path.join(d, tool), 0o755)
        for persistence, deletes in (("rw-only", True), ("none", True), ("full", False), ("", False)):
            log = os.path.join(d, "log")
            open(log, "w").close()
            subprocess.run(["sh", "-c", script], env={"PATH": d + ":/usr/bin:/bin", "LOG": log, "P": persistence},
                           check=True)
            with open(log) as f:
                ran = "rm -rf -- /home/user/QubesIncoming" in f.read()
            check(ran == deletes, "persistence %r must %sdelete" % (persistence, "" if deletes else "not "))


def test_qube_vimrc():
    case("qube.sls: every template gets the SEQS vim settings; app qubes inherit them")
    for vm in ("Z-brave", "Z-keepass", "Z-qr-staging", "Z-qr-display"):
        _, parsed = render_state("qube", vm)
        check("seqs-vimrc" in parsed and state_arg(parsed, "seqs-vimrc", "file.managed", "name") == "/etc/vim/vimrc.local",
              "%s must get /etc/vim/vimrc.local" % vm)
        body = state_arg(parsed, "seqs-vimrc", "file.managed", "contents") if "seqs-vimrc" in parsed else ""
        check(all(line in body.splitlines() for line in (
            "set wrap", "set linebreak", "nnoremap <Down> gj", "nnoremap <Up> gk", "vnoremap <Down> gj",
            "vnoremap <Up> gk", "inoremap <Down> <C-o>gj", "inoremap <Up> <C-o>gk")),
              "%s: the vim settings must wrap at words and move by screen line" % vm)
    check("seqs-vimrc" not in render_state("qube", "A-brave")[1],
          "an app qube reads the file from its template's root and needs no copy")


def test_qube_markers_track_content():
    case("qube.sls: a completion marker skips a component only while its staged content is unchanged")
    for minion, state_id, staged in [("Z-gnosisvpn", "seqs-install-gnosisvpn", "gnosisvpn"),
                                     ("A-gnosisvpn", "seqs-install-gnosisvpn", "gnosisvpn"),
                                     ("Z-wallet-ledger", "seqs-install-brave-extension-rabby", "lib")]:
        _, parsed = render_state("qube", minion)
        args = parsed[state_id]["cmd.run"]
        check(not any("creates" in a for a in args if isinstance(a, dict)),
              "%s/%s: a bare marker file must not skip the install" % (minion, state_id))
        unless = state_arg(parsed, state_id, "cmd.run", "unless")
        name = state_arg(parsed, state_id, "cmd.run", "name")
        hash_cmd = "find %s -type f -print0" % staged
        check(hash_cmd in unless and "sha256sum" in unless,
              "%s/%s: the skip test must compare the staged content hash" % (minion, state_id))
        check(hash_cmd in name and name.rstrip().endswith(".done"),
              "%s/%s: the install must record the staged content hash" % (minion, state_id))
    # A changed library (a new Brave key or pin) reruns the extension state,
    # which must then reinstall Brave rather than skip an installed one.
    name = state_arg(render_state("qube", "Z-wallet-ledger")[1],
                     "seqs-install-brave-extension-rabby", "cmd.run", "name")
    check("install_brave; install_brave_extension" in name,
          "an extension state must run install_brave, which applies a changed pin or key")


def test_qube_app_offline_no_browser_default():
    case("qube.sls: an offline app qube gets no browser-default (no_handoff)")
    _, parsed = render_state("qube", "A-keepass")
    check("seqs-default-browser" not in parsed,
          "offline/no_handoff qube must not set a link-handoff default browser")
    check("seqs-marker-dir" in parsed, "app qube still gets the marker dir")


def test_qube_staging_preserves_incoming():
    case("qube.sls: qr-staging does not install transient incoming cleanup")
    _, template = render_state("qube", "Z-qr-staging")
    check("seqs-cleanup-script" not in template,
          "qr-staging template must not erase received ciphertext at shutdown")
    check("rm -f /usr/sbin/seqs-cleanup" in state_arg(template, "seqs-cleanup-removed", "cmd.run", "name"),
          "a cleanup installed by an earlier build must be removed from the qr-staging template")


def test_qube_app_sets_browser_default():
    case("qube.sls: a normal app qube sets the browser default")
    _, parsed = render_state("qube", "A-element")
    check("seqs-default-browser" in parsed,
          "a normal networked app qube should default its browser to the handoff")


def test_qube_wireguard_component():
    case("qube.sls: WireGuard component renders for template and app")
    _, template = render_state("qube", "Z-wireguard")
    _, app = render_state("qube", "A-wireguard")
    check("seqs-install-wireguard" in template,
          "WireGuard template installer should render")
    check("seqs-install-wireguard" in app,
          "WireGuard app hooks should render")
    check("seqs-default-browser" not in app,
          "the network provider's no_handoff flag should suppress browser handoff")
    installer = os.path.join(
        sr.REPO_ROOT, "install-scripts", "components", "wireguard",
        "template-vm.sh")
    with open(installer, encoding="utf-8") as f:
        installer_text = f.read()
    check("/usr/bin/seqs-wireguard-import" in installer_text,
          "WireGuard importer must be installed in template-inherited /usr")
    check("/usr/local" not in installer_text,
          "WireGuard importer must not be hidden by AppVM-private /usr/local")
    boot_script = os.path.join(
        sr.REPO_ROOT, "install-scripts", "components", "wireguard",
        "wireguard-boot.sh")
    with open(boot_script, encoding="utf-8") as f:
        boot_text = f.read()
    check("sed " in boot_text and "dns.sh" in boot_text,
          "WireGuard boot must omit DNS from wg-quick and update Qubes DNS")
    check(boot_text.index("wg-quick down") <
          boot_text.index("/rw/config/seqs-wireguard/dns.sh") <
          boot_text.index("wg-quick up"),
          "WireGuard boot must drop the local DNS translation before wg-quick up")
    firewall_script = os.path.join(
        sr.REPO_ROOT, "install-scripts", "components", "wireguard",
        "wireguard-firewall.sh")
    with open(firewall_script, encoding="utf-8") as f:
        firewall_text = f.read()
    check("dns.sh" not in firewall_text,
          "the firewall hook need not reassert DNS kept in its own table")
    dns_script = os.path.join(
        sr.REPO_ROOT, "install-scripts", "components", "wireguard",
        "wireguard-dns.sh")
    with open(dns_script, encoding="utf-8") as f:
        dns_text = f.read()
    check('delete table ip ${table}' in dns_text,
          "DNS updater must atomically replace its own table")
    check("/qubes-netvm-primary-dns" in dns_text,
          "DNS updater must obtain client resolver addresses from QubesDB")
    check("type nat hook output priority -101" in dns_text,
          "DNS updater must translate provider-qube-local resolver requests")


def test_qube_gnosisvpn_component():
    case("qube.sls: GnosisVPN component from its APT repository and Qubes hooks render")
    _, template = render_state("qube", "Z-gnosisvpn")
    _, app = render_state("qube", "A-gnosisvpn")
    _, postfixed_template = render_state("qube", "Z-gnosisvpn-alpha")
    check("seqs-install-gnosisvpn" in template,
          "GnosisVPN prerequisite template installer should render")
    check("seqs-install-gnosisvpn" in app,
          "GnosisVPN app hooks should render")
    check("seqs-install-gnosisvpn" in postfixed_template,
          "a postfixed GnosisVPN template must resolve to the original recipe")
    check("seqs-default-browser" not in app,
          "the GnosisVPN network provider should suppress browser handoff")

    component_dir = os.path.join(
        sr.REPO_ROOT, "install-scripts", "components", "gnosisvpn")
    with open(os.path.join(component_dir, "app-vm.sh"),
              encoding="utf-8") as f:
        app_installer_text = f.read()
    with open(os.path.join(component_dir, "template-vm.sh"),
              encoding="utf-8") as f:
        installer_text = f.read()
    with open(os.path.join(sr.REPO_ROOT, "setup-qubes.sh"),
              encoding="utf-8") as f:
        runner_text = f.read()
    check("openresolv wireguard-tools" in runner_text,
          "GnosisVPN preflight must include wg-quick and resolvconf prerequisites")
    check("dsthost=download.gnosisvpn.io proto=tcp dstports=443" in runner_text and
          "printf 'qubes.UpdatesProxy * %s @anyvm deny" in runner_text,
          "temporary proxy must be host-restricted and exact-source scoped")
    check("9A308031FD3BFE8EDBF5076D84F73FEA46D10972" in installer_text,
          "GnosisVPN installer must pin the signing-key fingerprint")
    keyring = "/usr/share/keyrings/seqs-gnosisvpn-archive-keyring.gpg"
    check(f'KEYRING="{keyring}"' in installer_text and
          'lock_keyring "${KEYRING}" "${GNOSISVPN_KEY_FPR}"' in installer_text and
          'Signed-By: %s\\n\' "$1" "${KEYRING}"' in installer_text,
          "apt must trust the GnosisVPN repository only through SEQS's locked keyring")
    check(installer_text.index('lock_keyring "${KEYRING}"') <
          installer_text.index("sudo apt-get update"),
          "the SEQS keyring must be checked and locked before apt reads the repository")
    check('sources "https://download.vpn.gnosis.eth.limo/linux/apt '
          'https://download.gnosisvpn.io/linux/apt"' in installer_text and
          "Suites: stable\\nComponents: main" in installer_text,
          "GnosisVPN sources must match upstream's stable suite and mirrors, "
          "or the package's postinst rewrites them to its own keyring")
    check("apt-mark hold" not in installer_text and
          "apt-mark unhold gnosisvpn" in installer_text,
          "GnosisVPN must not be held, so template updates upgrade it")
    check("sudo env GNOSISVPN_NETWORK=jura-prod apt-get install -y gnosisvpn"
          in installer_text,
          "GnosisVPN installer must select the jura-prod network")
    check('sudo "${ASSET_DIR}/seqs-gnosisvpn-prepare-app"'
          in app_installer_text,
          "AppVM provisioning must use the freshly staged preparation helper")

    with open(os.path.join(component_dir, "seqs-gnosisvpn-dns"),
              encoding="utf-8") as f:
        dns_text = f.read()
    check("/run/resolvconf/interfaces/${interface}" in dns_text,
          "DNS helper must prefer GnosisVPN's runtime openresolv data")
    check("fallback_dns=(1.1.1.1 8.8.8.8)" in dns_text,
          "DNS helper must survive missing GnosisVPN openresolv data")
    check("/qubes-primary-dns" in dns_text and
          "/qubes-netvm-primary-dns" in dns_text,
          "DNS helper must obtain local and client synthetic DNS from QubesDB")
    check('printf \'%s\\n\' "${local_dns[@]}"' in dns_text,
          "downstream DNS must fall back to the provider's Qubes DNS pair")
    check("table=seqs_gnosisvpn_dns" in dns_text and
          "delete table ip" in dns_text,
          "DNS helper must atomically own a separate replaceable table")
    check('ip daddr ${local_dns[$i]} udp dport 53 counter dnat' in dns_text,
          "local DNS translation must not depend on NAT-hook oifname matching")
    check('ip daddr ${address} udp dport 53 oifname != \\"${interface}\\"'
          in dns_text,
          "fallback DNS must be guarded against non-VPN output")
    check('route=$(ip -4 route get "$address"' in dns_text,
          "DNS destinations must be verified to route through the VPN")

    with open(os.path.join(component_dir, "seqs-gnosisvpn-dns.timer"),
              encoding="utf-8") as f:
        timer_text = f.read()
    check("OnUnitActiveSec=5s" in timer_text,
          "DNS integration must reconcile connections without openresolv data")
    check("seqs-gnosisvpn-dns.timer" in installer_text,
          "GnosisVPN installer must install and enable DNS reconciliation")

    with open(os.path.join(component_dir, "seqs-gnosisvpn-firewall"),
              encoding="utf-8") as f:
        firewall_text = f.read()
    check('oifname "eth0" counter drop' in firewall_text,
          "GnosisVPN forwarding must fail closed through the upstream interface")
    with open(os.path.join(component_dir, "seqs-gnosisvpn-prepare-app"),
              encoding="utf-8") as f:
        prepare_text = f.read()
    check("/rw/config/qubes-firewall-user-script" in prepare_text,
          "a manually created AppVM must have an explicit persistent setup path")
    check("/rw/config/qubes-bind-dirs.d/50-seqs-gnosisvpn.conf" in prepare_text
          and "binds+=( '/var/lib/gnosisvpn' )" in prepare_text,
          "GnosisVPN state must persist in the AppVM private volume")
    check("persistent_dir=/rw/bind-dirs/var/lib/gnosisvpn" in prepare_text
          and "cp -a -- /var/lib/gnosisvpn" in prepare_text,
          "GnosisVPN backing directory must be seeded during AppVM provisioning")


def test_qube_browser_itself_no_selfhandoff():
    case("qube.sls: the browser qube does not hand links off to itself")
    _, parsed = render_state("qube", "A-brave")
    check("seqs-default-browser" not in parsed,
          "the browser qube (grains id == browser_vm) must not hand off to itself")


def test_qube_stray_minion_is_noop():
    case("qube.sls: a Z-*/A-* minion with no spec renders to a single no-op")
    _, parsed = render_state("qube", "Z-not-a-seqs-qube")
    check("seqs-noop" in parsed,
          "a stray prefix-matching minion must render to a harmless no-op")
    check(len(parsed) == 1, "stray minion should render ONLY the no-op state")


def test_qube_validation_catches_bad_component():
    case("qube.sls: in-qube validation rejects unsafe pillar values")
    good = {"role": "template", "browser_vm": "A-brave",
            "browser_desktop": "open-links-in-browser-qube.desktop",
            "component_timeout": 900, "spec": {"components": ["brave"]},
            "brave_extensions": {}, "cleanup_dirs": []}
    _, parsed = render_state("qube", "Z-brave", pillar_seqs=good)
    check("seqs-qube-validation-failed" not in parsed, "a safe pillar must pass in-qube validation")
    for key, value, expected in [
            ("spec", {"components": ["../etc/passwd"]}, "unsafe component name '../etc/passwd'"),
            ("spec", {"components": ["brave-extension-x"]}, "missing or invalid extension ID for 'brave-extension-x'"),
            ("browser_vm", "A-brave;id", "unsafe browser_vm 'A-brave;id'"),
            ("browser_desktop", "x;id.desktop", "unsafe browser_desktop 'x;id.desktop'"),
            ("browser_desktop", "x.desktop\n", "unsafe browser_desktop 'x.desktop\n'"),
            ("component_timeout", "900\n    - shell: /bin/x", "component_timeout must be a number")]:
        bad = dict(good, **{key: value})
        _, parsed = render_state("qube", "Z-brave", pillar_seqs=bad)
        comment = (state_arg(parsed, "seqs-qube-validation-failed", "test.fail_without_changes", "comment")
                   if "seqs-qube-validation-failed" in parsed else "")
        check(expected in comment, "in-qube validation must report %r, got %r" % (expected, comment))
    bad = dict(good, spec={"components": ["brave-extension-x"]}, brave_extensions={"x": "a" * 32 + "\n"})
    _, parsed = render_state("qube", "Z-brave", pillar_seqs=bad)
    check("seqs-qube-validation-failed" in parsed and "missing or invalid extension ID for 'brave-extension-x'"
          in state_arg(parsed, "seqs-qube-validation-failed", "test.fail_without_changes", "comment"),
          "an extension ID with a trailing newline must fail in-qube validation")




def test_dom0_rejects_unsafe_prefix():
    case("dom0.sls: qube-name prefixes are validated before they reach shell commands")
    for field in ("prefix_template", "prefix_app", "prefix_disposable"):
        pillar = copy.deepcopy(render_pillar("dom0"))
        pillar[field] = "A;id;"
        _, parsed = render_state("dom0", "dom0", pillar_seqs=pillar)
        check("seqs-validation-failed" in parsed and "%s 'A;id;' must match" % field
              in state_arg(parsed, "seqs-validation-failed", "test.fail_without_changes", "comment"),
              "an unsafe %s must fail pre-flight with its own message" % field)
    pillar = copy.deepcopy(render_pillar("dom0"))
    pillar["prefix_disposable"] = "D-\n"
    _, parsed = render_state("dom0", "dom0", pillar_seqs=pillar)
    check("seqs-validation-failed" in parsed and "prefix_disposable 'D-\n' must match"
          in state_arg(parsed, "seqs-validation-failed", "test.fail_without_changes", "comment"),
          "a prefix with a trailing newline must fail the prefix check")


def test_qube_extension_marker_records_its_id():
    case("qube.sls: a Brave extension reinstalls when its Web Store ID changes")
    pillar = render_pillar("Z-wallet-ledger")
    eid = pillar["brave_extensions"]["rabby"]
    _, parsed = render_state("qube", "Z-wallet-ledger")
    unless = state_arg(parsed, "seqs-install-brave-extension-rabby", "cmd.run", "unless")
    check("echo %s;" % eid in unless, "the extension marker must record the extension ID")


def test_qube_template_repairs_interrupted_dpkg():
    case("qube.sls: a template finishes an interrupted package install first; an app qube does not")
    _, template = render_state("qube", "Z-keepass")
    check("dpkg --configure -a" in state_arg(template, "seqs-dpkg-repair", "cmd.run", "name"),
          "a template must repair an interrupted dpkg run before the components")
    _, app = render_state("qube", "A-keepass")
    check("seqs-dpkg-repair" not in app, "an app qube must not run the dpkg repair")


def _pinned(pin, sc=None):
    """Render dom0 with cpu_pinning set on signal (selected with brave)."""
    pillar = copy.deepcopy(render_pillar("dom0"))
    pillar["catalogue"]["signal"]["cpu_pinning"] = pin
    return render_state("dom0", "dom0", sc or Scenario(selection="signal\nbrave"), pillar_seqs=pillar)[1]


def _errors(parsed):
    if "seqs-validation-failed" not in parsed:
        return ""
    return state_arg(parsed, "seqs-validation-failed", "test.fail_without_changes", "comment")


PIN_FILE = "/etc/qubes/templates/libvirt/xen/by-name/A-signal.xml"


def test_dom0_cpu_pinning():
    case("dom0.sls: cpu_pinning writes a per-qube libvirt file and sets the vCPU count")
    parsed = _pinned({"cpus": [0, 2], "weight": 512})
    check("seqs-validation-failed" not in parsed, "a valid cpu_pinning must pass: %s" % _errors(parsed))
    body = state_arg(parsed, "seqs-cpu-pinning-signal", "file.managed", "contents")
    check(state_arg(parsed, "seqs-cpu-pinning-signal", "file.managed", "name") == PIN_FILE,
          "the file must be the qube's by-name libvirt template")
    check(body.startswith("{# Managed by SEQS") and "{% extends 'libvirt/xen.xml' %}" in body
          and "{{ super() }}" in body, "the file must carry the marker and extend Qubes' template")
    check("<vcpupin vcpu='0' cpuset='0'/>" in body and "<vcpupin vcpu='1' cpuset='2'/>" in body
          and "<shares>512</shares>" in body, "each vCPU must be pinned to its core, with the weight")
    prefs = state_arg(parsed, "seqs-app-signal", "qvm.vm", "prefs")
    check({"vcpus": 2} in prefs, "the qube must get one vCPU per pinned core")
    check(not unresolved_requisites(parsed), "the pinning state must require rendered states only")
    plain = _pinned({"cpus": [1]})
    check("<shares>" not in state_arg(plain, "seqs-cpu-pinning-signal", "file.managed", "contents"),
          "without a weight the file sets none")


def test_dom0_cpu_pinning_rejects_bad_values():
    case("dom0.sls: cpu_pinning values are validated before they reach the libvirt file")
    for pin, msg in (({"cpus": [4]}, "not one of this machine's cores"),
                     ({"cpus": [-1]}, "not one of this machine's cores"),
                     ({"cpus": ["0"]}, "not one of this machine's cores"),
                     ({"cpus": [0, 0]}, "lists a core twice"),
                     ({"cpus": []}, "must be {'cpus'"),
                     ({"cpus": "0,2"}, "must be {'cpus'"),
                     ([0, 2], "must be {'cpus'"),
                     ({"cpus": [0], "pin": 1}, "must be {'cpus'"),
                     ({"cpus": [0], "weight": 0}, "weight must be an integer"),
                     ({"cpus": [0], "weight": "512'/><x"}, "weight must be an integer")):
        check(msg in _errors(_pinned(pin)), "cpu_pinning %r must be refused with '%s'" % (pin, msg))
    check("could not read the number of CPUs" in _errors(
        _pinned({"cpus": [0]}, Scenario(selection="signal\nbrave", host_cpus=""))),
        "an unreadable xl info must fail closed")
    foreign = Scenario(selection="signal\nbrave", file_contents={PIN_FILE: "<!-- mine -->\n"})
    check("was not written by SEQS" in _errors(_pinned({"cpus": [0]}, foreign)),
          "an existing pinning file SEQS did not write must not be overwritten")


def test_dom0_cpu_pinning_removed():
    case("dom0.sls: removing cpu_pinning deletes only the file SEQS wrote")
    sc = Scenario(selection="signal\nbrave", existing_files=[PIN_FILE])
    _, parsed = render_state("dom0", "dom0", sc)
    clear = parsed.get("seqs-cpu-pinning-clear-signal")
    check(clear is not None and "grep -qF 'Managed by SEQS'" in state_arg(
        parsed, "seqs-cpu-pinning-clear-signal", "cmd.run", "onlyif"),
          "a leftover pinning file must be removed only if SEQS wrote it")

def test_dom0_vcpus():
    case("dom0.sls: the vcpus key sets the qube's vCPU count; GnosisVPN gets 4")
    _, parsed = render_state("dom0", "dom0", Scenario(selection="gnosisvpn"))
    check({"vcpus": 4} in state_arg(parsed, "seqs-app-gnosisvpn", "qvm.vm", "prefs"),
          "A-gnosisvpn must get the 4 vCPUs its catalogue entry sets")
    pillar = copy.deepcopy(render_pillar("dom0"))
    for value in (0, -1, "4", "4\n      - netvm: none", True, 2.5):
        pillar["catalogue"]["signal"]["vcpus"] = value
        errors = _errors(render_state("dom0", "dom0", Scenario(selection="signal"), pillar_seqs=pillar)[1])
        check("'vcpus' must be a positive integer" in errors, "vcpus %r must be refused" % (value,))
    pillar["catalogue"]["signal"]["vcpus"] = 2
    pillar["catalogue"]["signal"]["cpu_pinning"] = {"cpus": [0]}
    check("set either 'vcpus' or 'cpu_pinning'" in _errors(
        render_state("dom0", "dom0", Scenario(selection="signal"), pillar_seqs=pillar)[1]),
          "vcpus together with cpu_pinning must be refused")


def test_gnosisvpn_panel_monitor():
    case("dom0.sls + gnosisvpn: the VPN panel monitor is installed in dom0, its qube marked, its reporter in the template")
    _, parsed = render_state("dom0", "dom0", Scenario(selection="gnosisvpn"))
    check(state_arg(parsed, "seqs-vpn-monitor", "file.managed", "name") == "/usr/local/bin/seqs-vpn-monitor"
          and state_arg(parsed, "seqs-vpn-monitor", "file.managed", "source") == "salt://seqs/files/seqs-vpn-monitor",
          "dom0 must get the monitor script while the catalogue has a GnosisVPN qube")
    check("qvm-features -- A-gnosisvpn seqs-vpn-monitor 1" in state_arg(parsed, "seqs-vpn-monitor-gnosisvpn", "cmd.run", "name"),
          "A-gnosisvpn must be marked for a panel monitor")
    check("seqs-vpn-monitor-brave" not in render_state("dom0", "dom0", Scenario(selection="brave"))[1],
          "only GnosisVPN qubes get a monitor")
    pillar = copy.deepcopy(render_pillar("dom0"))
    del pillar["catalogue"]["gnosisvpn"]
    pillar["catalogue"].pop("anon", None)
    _, parsed = render_state("dom0", "dom0", Scenario(selection="brave"), pillar_seqs=pillar)
    check("Managed by SEQS" in state_arg(parsed, "seqs-vpn-monitor", "cmd.run", "onlyif"),
          "without GnosisVPN in the catalogue, dom0 removes only the monitor SEQS wrote")
    with open(os.path.join(sr.REPO_ROOT, "install-scripts", "components", "gnosisvpn", "template-vm.sh"), encoding="utf-8") as f:
        check('"${ASSET_DIR}/seqs-gnosisvpn-rates" /usr/bin/seqs-gnosisvpn-rates' in f.read(),
              "the template must install the traffic reporter the monitor calls")


def test_gnosisvpn_receive_buffer():
    case("gnosisvpn: the template raises the default UDP receive buffer to 4 MiB")
    component_dir = os.path.join(sr.REPO_ROOT, "install-scripts", "components", "gnosisvpn")
    with open(os.path.join(component_dir, "99-seqs-gnosisvpn-rmem.conf"), encoding="utf-8") as f:
        conf = f.read()
    with open(os.path.join(component_dir, "template-vm.sh"), encoding="utf-8") as f:
        installer = f.read()
    check("\nnet.core.rmem_default = 4194304\n" in conf, "the sysctl file must set 4 MiB")
    check('"${ASSET_DIR}/99-seqs-gnosisvpn-rmem.conf" /etc/sysctl.d/99-seqs-gnosisvpn-rmem.conf' in installer,
          "the template installer must install it into /etc/sysctl.d")


BAD_CLEANUP_PATHS = ["/home/user", "/home/user/", "/home/user//", "/home/user/.", "/home/user/./",
                     "/home/user/a/..", "/home/user/a//b", "/home/user/a b", "/root/x", "/home/user/$(id)",
                     "/home/user/Downloads\n"]


def test_cleanup_paths_never_name_home():
    case("dom0.sls + qube.sls: cleanup paths must name something strictly inside /home/user")
    for path in BAD_CLEANUP_PATHS:
        pillar = copy.deepcopy(render_pillar("dom0"))
        pillar["cleanup_dirs"] = [{"mode": "folder", "path": path}]
        _, parsed = render_state("dom0", "dom0", pillar_seqs=pillar)
        check("cleanup_dirs path '%s' must be strictly under /home/user/" % path in _errors(parsed),
              "dom0 must reject cleanup path %r" % path)
        qube = copy.deepcopy(render_pillar("Z-brave"))
        qube["cleanup_dirs"] = [{"mode": "folder", "path": path}]
        _, parsed = render_state("qube", "Z-brave", pillar_seqs=qube)
        check("seqs-qube-validation-failed" in parsed
              and "unsafe cleanup_dirs entry" in state_arg(parsed, "seqs-qube-validation-failed",
                                                          "test.fail_without_changes", "comment"),
              "the qube must reject cleanup path %r" % path)
    for path in ("/home/user/Downloads", "/home/user/.cache/x"):
        pillar = copy.deepcopy(render_pillar("dom0"))
        pillar["cleanup_dirs"] = [{"mode": "contents", "path": path}]
        _, parsed = render_state("dom0", "dom0", pillar_seqs=pillar)
        check("seqs-validation-failed" not in parsed, "dom0 must accept cleanup path %r" % path)


def test_dom0_desktop_settings():
    case("dom0.sls: dom0 launchers and tiling keys are validated and handed to the runner")
    _, parsed = render_state("dom0", "dom0")
    contents = state_arg(parsed, "seqs-desktop", "file.managed", "contents")
    check(state_arg(parsed, "seqs-desktop", "file.managed", "name") == "/var/lib/seqs/desktop"
          and "launcher qubes-qube-manager.desktop\n" in contents
          and "key <Super>Up tile_up_key\n" in contents
          and "key <Alt>Right tile_down_right_key\n" in contents,
          "the shipped launchers and tiling keys must reach the desktop file")
    check(contents.index("launcher qubes-qube-manager.desktop") < contents.index("launcher xfce4-terminal.desktop"),
          "launchers keep their configured order")
    for bad in ("../x.desktop", "x.desktop y", "qubes-qube-manager", "a;b.desktop", "x.desktop\n"):
        pillar = copy.deepcopy(render_pillar("dom0"))
        pillar["dom0_launchers"] = [bad]
        _, parsed = render_state("dom0", "dom0", pillar_seqs=pillar)
        check("dom0_launchers entry" in _errors(parsed), "a launcher %r must be rejected" % bad)
    for shortcut, action in (("<Super>Up;x", "tile_up_key"), ("Up", "tile_up_key"),
                             ("<Super>Up", "rm -rf"), ("<Super>Up", "tile_up_key\n"), ("<Win>Up", "tile_up_key")):
        pillar = copy.deepcopy(render_pillar("dom0"))
        pillar["window_tiling_keys"] = {shortcut: action}
        _, parsed = render_state("dom0", "dom0", pillar_seqs=pillar)
        check("window_tiling_keys entry" in _errors(parsed), "a shortcut %r: %r must be rejected" % (shortcut, action))
    pillar = copy.deepcopy(render_pillar("dom0"))
    pillar["dom0_launchers"] = []
    pillar["window_tiling_keys"] = {}
    _, parsed = render_state("dom0", "dom0", pillar_seqs=pillar)
    check("seqs-validation-failed" not in parsed
          and "\nlauncher " not in state_arg(parsed, "seqs-desktop", "file.managed", "contents"),
          "empty settings render an empty desktop file")


def main():
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for t in tests:
        t()
    print()
    print("render tests: %d passed, %d failed" % (_PASS, _FAIL))
    if _FAIL:
        print("\nFAILURES:")
        for f in _FAILURES:
            print("  - " + f)
        sys.exit(1)


if __name__ == "__main__":
    main()
