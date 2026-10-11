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
import sys
import copy

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
    # keepass is offline + wallets are no_handoff -> a suppress policy exists
    check("seqs-policy-browser-suppress" in parsed,
          "suppress policy expected (offline/no_handoff qubes are configured)")
    # every configured qube gets a clone + app + tag state on a fresh dom0
    for name in ("brave", "keepass", "claude-code", "dev-full", "wallet-ledger"):
        check("seqs-clone-%s" % name in parsed, "expected clone state for %s" % name)
        check("seqs-app-%s" % name in parsed, "expected app state for %s" % name)
        check("seqs-tag-app-%s" % name in parsed, "expected app tag state for %s" % name)
    # keepass air-gap state
    check("seqs-offline-keepass" in parsed, "keepass should get an offline state")
    check("seqs-offline-brave" not in parsed, "brave must NOT be air-gapped")
    # netvm=none does not gate qrexec, and a rule for A-x does not match a
    # disposable spawned from it or the named disposable D-x. Every offline
    # dispvm template must therefore deny OpenURL for all three subjects.
    suppress = state_arg(parsed, "seqs-policy-browser-suppress", "file.managed", "contents")
    for subject in ("A-qr-camera", "@dispvm:A-qr-camera", "A-qr-display",
                    "@dispvm:A-qr-display", "D-qr-display", "A-qr-staging"):
        check("qubes.OpenURL  *  %s  @anyvm  deny" % subject in suppress,
              "browser handoff must be denied for %s" % subject)
        for target in ("@anyvm", "@dispvm"):
            check("qubes.OpenInVM  *  %s  %s  deny" % (subject, target) in suppress,
                  "open-in-qube handoff to %s must be denied for %s" % (target, subject))
        for service in ("qubes.StartApp", "qubes.GetImageRGBA", "qubes.VMShell",
                        "qubes.VMExec", "qubes.VMExecGUI", "qubes.PdfConvert"):
            check("%s  *  %s  @dispvm  deny" % (service, subject) in suppress,
                  "%s to a disposable must be denied for %s" % (service, subject))
    check("qubes.OpenURL  *  A-wallet-ledger  @dispvm  deny" in suppress
          and "qubes.OpenInVM  *  A-wallet-ledger  @anyvm  deny" in suppress
          and "qubes.VMShell  *  A-wallet-ledger  @dispvm  deny" in suppress
          and "qubes.PdfConvert  *  A-wallet-ledger  @dispvm  deny" in suppress,
          "networked no_handoff qubes must not reach a networked disposable either")
    offline = state_arg(parsed, "seqs-offline-keepass", "cmd.run", "name")
    check("default_dispvm none" in offline,
          "an offline qube must lose its (networked) default disposable")
    named = state_arg(parsed, "seqs-disposable-prefs-qr-display", "cmd.run", "name")
    check("default_dispvm none" in named,
          "a named offline disposable must lose its default disposable")
    check("@dispvm:A-keepass" not in suppress and "D-keepass" not in suppress,
          "non-disposable offline qubes get only their own deny")
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
    check("seqs-validation-failed" in bad,
          "unknown runtime selections must fail pre-flight")

    _, postfixed = render_state(
        "dom0", "dom0",
        Scenario(selection="brave alpha\nsignal signal-alpha"))
    check("seqs-validation-failed" in postfixed,
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


def test_dom0_partial_upgrade_preserves_strict_browser_denies():
    case("dom0.sls: partial upgrades preserve only strict denies for managed qubes")
    policy = "/etc/qubes/policy.d/28-browser-suppress.policy"
    old = """\
qubes.OpenURL * A-keepass @anyvm deny
qubes.OpenURL * A-old-wallet @anyvm deny
qubes.OpenURL * @dispvm:A-old-wallet @anyvm deny
qubes.OpenURL * D-old-wallet @anyvm deny
qubes.OpenURL * @dispvm:A-unmanaged @anyvm deny
qubes.OpenURL * A-unmanaged @anyvm deny
qubes.OpenURL * A-danger @anyvm allow
not.a.valid policy line
"""
    pillar = _bad_pillar(
        qubes={"qr-display": {"label": "black", "components": ["qr-display"],
                              "offline": True, "dispvm_template": True}},
        browser_suppress_prune=[])
    sc = Scenario(
        existing_qubes=["A-brave", "A-keepass", "A-old-wallet", "A-unmanaged"],
        tagged_qubes=["A-keepass", "A-old-wallet"],
        file_contents={policy: old})
    _, parsed = render_state("dom0", "dom0", sc, pillar_seqs=pillar)
    contents = state_arg(parsed, "seqs-policy-browser-suppress", "file.managed", "contents")
    check("A-qr-display" in contents, "new offline qube deny must be emitted")
    check("A-keepass" in contents and "A-old-wallet" in contents,
          "strict denies for existing managed qubes must survive a partial upgrade")
    check("@dispvm:A-old-wallet" in contents,
          "a preserved @dispvm: deny must survive when its template is managed")
    check("qubes.VMShell  *  A-old-wallet  @dispvm  deny" in contents,
          "a preserved networked no_handoff qube keeps its disposable denies")
    check("D-old-wallet" not in contents,
          "a D- deny must not be preserved when that disposable does not exist")
    check("A-unmanaged" not in contents,
          "deny for an untagged qube must not be imported")
    check("A-danger" not in contents and "not.a.valid" not in contents,
          "allow and arbitrary policy lines must not be imported")

    pillar["browser_suppress_prune"] = ["old-wallet"]
    _, parsed = render_state("dom0", "dom0", sc, pillar_seqs=pillar)
    contents = state_arg(parsed, "seqs-policy-browser-suppress", "file.managed", "contents")
    check("A-keepass" in contents and "A-old-wallet" not in contents,
          "explicit prune must remove only the named preserved deny")


def test_dom0_partial_upgrade_keeps_disposable_denies():
    case("dom0.sls: a partial run keeps every deny of a preserved qube, whatever its netvm")
    policy = "/etc/qubes/policy.d/28-browser-suppress.policy"
    sc = Scenario(
        selection="xournalpp", existing_qubes=["A-brave", "A-keepass"],
        tagged_qubes=["A-brave", "A-keepass"], recipes={"A-keepass": "keepass"},
        file_contents={policy: "qubes.OpenURL * A-keepass @anyvm deny\n"})
    _, parsed = render_state("dom0", "dom0", sc)
    contents = state_arg(parsed, "seqs-policy-browser-suppress", "file.managed", "contents")
    check("qubes.VMShell  *  A-keepass  @dispvm  deny" in contents,
          "a preserved qube keeps its disposable denies")


def test_dom0_refuses_unmanaged_qube():
    case("dom0.sls: refuses to adopt a same-named qube that isn't seqs-managed")
    # A-brave exists but is NOT tagged and has no intent marker -> must refuse.
    _, parsed = render_state(
        "dom0", "dom0",
        Scenario(existing_qubes=["A-brave"]))  # exists, untagged, no intent
    check("seqs-validation-failed" in parsed,
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
    check("seqs-menu-A-brave" not in parsed, "brave ships no menu.desktop, so no menu state")
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


def test_dom0_sequential_qr_mode():
    case("dom0.sls: sequential QR mode renders strict, staged, fail-closed machinery")
    pillar = copy.deepcopy(render_pillar("dom0"))
    pillar.update({
        "webcam_usb_mode": "sequential",
        "webcam_usb_controller": "00_14.0",
        "webcam_usb_no_strict_reset": False,
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
    deny = state_arg(parsed, "seqs-policy-qr-input-deny", "file.managed", "contents")
    for subject in ("sys-usb-webcam", "seqs-qr-scanner", "@dispvm:A-qr-camera"):
        check("qubes.OpenURL        *  %s  @anyvm    deny" % subject in deny,
              "camera-side qube %s must not reach the browser handoff" % subject)
    check("qubes.InputKeyboard  *  @dispvm:A-qr-camera  @adminvm  deny" in deny,
          "camera disposables must be denied dom0 input")
    for subject in ("sys-usb-webcam", "seqs-qr-scanner"):
        for service in ("qubes.OpenInVM ", "qubes.StartApp ", "qubes.GetImageRGBA",
                        "qubes.VMShell  ", "qubes.VMExec   ", "qubes.VMExecGUI",
                        "qubes.PdfConvert"):
            check("%s   *  %s  @dispvm   deny" % (service.ljust(18), subject) in deny,
                  "camera-side qube %s must not reach a disposable via %s" % (subject, service.strip()))
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
        "webcam_usb_no_strict_reset": False,
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


def test_dom0_sequential_qr_allows_explicit_weak_reset():
    case("dom0.sls: sequential QR mode accepts an explicit no-strict-reset")
    pillar = copy.deepcopy(render_pillar("dom0"))
    pillar.update({
        "webcam_usb_mode": "sequential",
        "webcam_usb_controller": "00_14.0",
        "webcam_usb_no_strict_reset": True,
    })
    _, parsed = render_state(
        "dom0", "dom0", Scenario(sys_usb=True), pillar_seqs=pillar)
    check("seqs-validation-failed" not in parsed,
          "sequential + no-strict-reset must pass pre-flight")
    backend = state_arg(parsed, "seqs-webcam-usb-backend", "cmd.run", "name")
    check("qvm-pci attach --persistent --option no-strict-reset=true "
          "sys-usb-webcam dom0:00_14.0" in backend,
          "the option must apply to the webcam backend's assignment")
    check(backend.count("--option no-strict-reset") == 1,
          "no other assignment may be weakened")
    check("qvm-pci list sys-usb" in backend,
          "sequential mode must still require sys-usb to own the controller")


def test_dom0_dedicated_qr_rejects_weak_reset():
    case("dom0.sls: dedicated QR mode rejects no-strict-reset")
    pillar = copy.deepcopy(render_pillar("dom0"))
    pillar.update({
        "webcam_usb_mode": "dedicated",
        "webcam_usb_controller": "03_00.0",
        "webcam_usb_no_strict_reset": True,
    })
    _, parsed = render_state(
        "dom0", "dom0", Scenario(sys_usb=True), pillar_seqs=pillar)
    check("seqs-validation-failed" in parsed,
          "dedicated + no-strict-reset must fail pre-flight")


def test_dom0_dedicated_qr_uses_device_api():
    case("dom0.sls: dedicated QR mode manages PCI through qvm-pci")
    pillar = copy.deepcopy(render_pillar("dom0"))
    pillar.update({
        "webcam_usb_mode": "dedicated",
        "webcam_usb_controller": "03_00.0",
        "webcam_usb_no_strict_reset": False,
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
    check(unresolved_requisites(parsed) == [],
          "every requisite must resolve: %r" % unresolved_requisites(parsed))
    deny = state_arg(parsed, "seqs-policy-qr-input-deny", "file.managed", "contents")
    check("qubes.OpenURL        *  sys-usb-webcam  @anyvm    deny" in deny
          and "qubes.OpenURL        *  @dispvm:A-qr-camera  @anyvm    deny" in deny,
          "dedicated mode must also close the browser handoff for camera-side qubes")
    # Qubes 4.3 matches a @dispvm:<template> source against no running qube,
    # so the dedicated path scans in the named disposable, which rules can name.
    check("seqs-qr-scanner" in parsed,
          "dedicated mode must create the named scanner disposable")
    check("qubes.OpenURL        *  seqs-qr-scanner  @anyvm    deny" in deny
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
    check("seqs-validation-failed" in refused,
          "an untagged pre-existing D- qube must trip the no-clobber guard")
    _, adopted = render_state("dom0", "dom0", Scenario(
        selection="qr-display", existing_qubes=["A-brave", "D-qr-display"],
        tagged_qubes=["A-brave"],
        existing_files=["/var/lib/seqs/intents/D-qr-display"]))
    check("seqs-validation-failed" not in adopted,
          "a D- qube with an interrupted-run intent marker must be adopted")


def test_dom0_named_disposable_rerun_churn_free():
    case("dom0.sls: an already-built named disposable is churn-free on re-run")
    dom0 = render_pillar("dom0")
    names = list(dom0["catalogue"].keys())
    existing = (["Z-" + n for n in names] + ["A-" + n for n in names]
                + ["D-qr-display"])
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
        "component_timeout": 900,
        "config_errors": [],
        "qubes": {"brave": {"label": "red", "components": ["brave"]}},
        "brave_extensions": {"rabby": "acmacodkjbdgmoleebolmdjonilkdbch"},
        "cleanup_dirs": [],
    }
    base.update(overrides)
    return base


def _validation_fails(pillar):
    _, parsed = render_state("dom0", "dom0", Scenario(), pillar_seqs=pillar)
    return "seqs-validation-failed" in parsed


def test_dom0_validation_catches_bad_config():
    case("dom0.sls: pre-flight validation rejects malformed pillar")
    check(_validation_fails(_bad_pillar(
        qubes={"brave": {"label": "chartreuse", "components": ["brave"]}})),
        "unknown label must fail validation")
    check(_validation_fails(_bad_pillar(
        qubes={"brave": {"label": "red", "components": ["does-not-exist"]}})),
        "unknown component must fail validation")
    check(_validation_fails(_bad_pillar(
        qubes={"bad name": {"label": "red", "components": ["brave"]}})),
        "unsafe qube name must fail validation")
    check(_validation_fails(_bad_pillar(
        qubes={"brave": {"label": "red", "components": ["brave-extension-nope"]}})),
        "reference to an undefined Brave extension must fail validation")
    check(_validation_fails(_bad_pillar(
        qubes={"x": {"label": "gray", "components": ["brave"],
                     "offline": True, "firewall": ["dns"]}})),
        "offline + firewall is contradictory and must fail validation")
    check(_validation_fails(_bad_pillar(
        qubes={"x": {"label": "gray", "components": ["brave"],
                     "firewall": ["not a host!!"]}})),
        "malformed firewall entry must fail validation")
    check(_validation_fails(_bad_pillar(
        config_errors=["duplicate qube name 'brave'"])),
        "config_errors from pillar compilation must abort the dom0 apply")
    check(_validation_fails(_bad_pillar(browser_suppress_prune=["bad name"])),
          "unsafe browser-suppression prune name must fail validation")
    for bdf in ("00_1A.0", "0000:00:14.0", "00:14.0", "00_14.8"):
        check(_validation_fails(_bad_pillar(
            webcam_usb_mode="sequential", webcam_usb_controller=bdf,
            webcam_scanner_dvm="A-qr-camera")),
            "controller '%s' is not a lowercase qvm-pci BDF and must fail" % bdf)
    check(_validation_fails(_bad_pillar(
        webcam_usb_mode="disabled", webcam_usb_controller="00_14.0")),
        "a controller with the mode disabled must fail validation")
    check(_validation_fails(_bad_pillar(base_template="no-such-template")),
        "a missing base template must fail validation")
    check(_validation_fails(_bad_pillar(
        qubes={"x": {"label": "black", "components": ["brave"],
                     "named_disposable": True}})),
        "named_disposable without dispvm_template must fail validation")
    check(_validation_fails(_bad_pillar(
        prefix_disposable="",
        qubes={"x": {"label": "black", "components": ["brave"],
                     "offline": True, "dispvm_template": True,
                     "named_disposable": True}})),
        "named_disposable with no prefix_disposable configured must fail validation")
    # ...and a clean pillar must NOT trip validation (guards against a check
    # that fails everything).
    check(not _validation_fails(_bad_pillar()),
          "a well-formed minimal pillar must PASS validation")
    check(_validation_fails(_bad_pillar(
        qubes={"x": {"label": "purple", "components": ["wireguard"],
                     "network_provider": True, "offline": True}})),
        "network_provider + offline is contradictory and must fail validation")
    check(_validation_fails(_bad_pillar(
        qubes={"x": {"label": "purple", "components": ["wireguard"],
                     "network_provider": True, "dispvm_template": True}})),
        "a persistent network provider must not be a disposable template")


def test_dom0_firewall_states():
    case("dom0.sls: a 'firewall' key emits a qvm-firewall state")
    pillar = _bad_pillar(qubes={
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
    suppress = state_arg(parsed, "seqs-policy-browser-suppress", "file.managed", "contents")
    check("qubes.VMShell  *  A-wallet  @dispvm  deny" in suppress and "qubes.OpenURL  *  A-wallet  @anyvm  deny" in suppress,
          "a firewall key implies no_handoff: no way past the allowlist through handoff or a disposable")
    check("qvm-firewall --raw -- A-wallet list" in unless,
          "the skip test must compare the qube's current rules, so hand edits are reverted")
    name = state_arg(parsed, "seqs-firewall-wallet", "cmd.run", "name")
    check("qvm-firewall --raw -- A-wallet list; } > /var/lib/seqs/firewall/A-wallet" in name,
          "the marker must record the rules Qubes reports after applying them")
    check("reset" not in name and name.index("add --before 0 drop") < name.index("accept"),
          "egress must be closed before the rules are replaced, never reset to allow-all")


def test_dom0_network_provider():
    case("dom0.sls: a network provider exposes networking and enables firewall")
    pillar = _bad_pillar(qubes={
        "wireguard": {"label": "purple", "components": ["wireguard"],
                      "network_provider": True, "no_handoff": True}})
    sc = Scenario(existing_qubes=["A-brave"])
    txt, parsed = render_state("dom0", "dom0", sc, pillar_seqs=pillar)
    check("provides_network" in txt,
          "network-provider qvm prefs should expose networking")
    check("seqs-network-provider-wireguard" in parsed,
          "network provider should enable the Qubes firewall service")


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
    firewall_script = os.path.join(
        sr.REPO_ROOT, "install-scripts", "components", "wireguard",
        "wireguard-firewall.sh")
    with open(firewall_script, encoding="utf-8") as f:
        firewall_text = f.read()
    check("dns.sh" in firewall_text and "seqs-dns" not in firewall_text,
          "firewall refresh must reassert Qubes dnat-dns, not a custom chain")
    dns_script = os.path.join(
        sr.REPO_ROOT, "install-scripts", "components", "wireguard",
        "wireguard-dns.sh")
    with open(dns_script, encoding="utf-8") as f:
        dns_text = f.read()
    check("delete chain ip qubes dnat-dns" in dns_text,
          "DNS updater must atomically replace Qubes' native dnat-dns chain")
    check("/qubes-netvm-primary-dns" in dns_text,
          "DNS updater must obtain client resolver addresses from QubesDB")
    check("type nat hook output priority dstnat" in dns_text,
          "DNS updater must translate provider-qube-local resolver requests")
    check("seqs-wireguard-dns-output" in dns_text,
          "provider-qube DNS output must use its own narrowly scoped chain")


def test_qube_gnosisvpn_component():
    case("qube.sls: pinned GnosisVPN component and Qubes hooks render")
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
    check("download.vpn.gnosis.eth.limo proto=tcp dstports=443" in runner_text and
          "printf 'qubes.UpdatesProxy * %s @anyvm deny" in runner_text,
          "temporary proxy must be host-restricted and exact-source scoped")
    check("gnosisvpn_0.95.2_amd64.deb" in installer_text,
          "GnosisVPN installer must pin the requested stable release")
    check("87294d45d382d22181089c2f7f0a25330c75b77ef22b3989d399abf4027d3bdb"
          in installer_text,
          "GnosisVPN installer must pin the stable release SHA-256")
    check("9A308031FD3BFE8EDBF5076D84F73FEA46D10972" in installer_text,
          "GnosisVPN installer must pin the signing-key fingerprint")
    check("GNOSISVPN_NETWORK=jura-prod apt install ./g.deb -y" in installer_text,
          "GnosisVPN installer must select the jura-prod network")
    check("curl --proxy 127.0.0.1:8082" in installer_text,
          "GnosisVPN download must use the Qubes updates proxy")
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
    case("qube.sls: in-qube validation rejects an unsafe component name")
    bad = {"role": "template", "browser_vm": "A-brave",
           "browser_desktop": "open-links-in-browser-qube.desktop",
           "component_timeout": 900,
           "spec": {"components": ["../etc/passwd"]},
           "brave_extensions": {}, "cleanup_dirs": []}
    _, parsed = render_state("qube", "Z-brave", pillar_seqs=bad)
    check("seqs-qube-validation-failed" in parsed,
          "an unsafe component name must fail in-qube validation")


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
