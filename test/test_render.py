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
    for name in ("brave", "keepass", "dev-full", "wallet-ledger"):
        check("seqs-clone-%s" % name in parsed, "expected clone state for %s" % name)
        check("seqs-app-%s" % name in parsed, "expected app state for %s" % name)
        check("seqs-tag-app-%s" % name in parsed, "expected app tag state for %s" % name)
    # keepass air-gap state
    check("seqs-offline-keepass" in parsed, "keepass should get an offline state")
    check("seqs-offline-brave" not in parsed, "brave must NOT be air-gapped")
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
    check("seqs-targets" in parsed, "targets file is still (re)written on re-run")


def test_dom0_partial_upgrade_preserves_strict_browser_denies():
    case("dom0.sls: partial upgrades preserve only strict denies for managed qubes")
    policy = "/etc/qubes/policy.d/28-browser-suppress.policy"
    old = """\
qubes.OpenURL * A-keepass @anyvm deny
qubes.OpenURL * A-old-wallet @anyvm deny
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
    check("A-unmanaged" not in contents,
          "deny for an untagged qube must not be imported")
    check("A-danger" not in contents and "not.a.valid" not in contents,
          "allow and arbitrary policy lines must not be imported")

    pillar["browser_suppress_prune"] = ["old-wallet"]
    _, parsed = render_state("dom0", "dom0", sc, pillar_seqs=pillar)
    contents = state_arg(parsed, "seqs-policy-browser-suppress", "file.managed", "contents")
    check("A-keepass" in contents and "A-old-wallet" not in contents,
          "explicit prune must remove only the named preserved deny")


def test_dom0_refuses_unmanaged_qube():
    case("dom0.sls: refuses to adopt a same-named qube that isn't seqs-managed")
    # A-brave exists but is NOT tagged and has no intent marker -> must refuse.
    _, parsed = render_state(
        "dom0", "dom0",
        Scenario(existing_qubes=["A-brave"]))  # exists, untagged, no intent
    check("seqs-validation-failed" in parsed,
          "an existing untagged A-brave must trip the no-clobber guard")


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
                  "seqs-webcam-usb-backend", "seqs-qr-sequential-scanner",
                  "seqs-qr-sequential-config", "seqs-qr-sequential-script"):
        check(state in parsed, "sequential mode should render %s" % state)
    check("qubes.Filecopy" in text and "A-qr-staging" in text,
          "scanner filecopy must be restricted to offline staging")
    check("no-strict-reset=true" not in text,
          "sequential mode must never render no-strict-reset")


def test_dom0_sequential_qr_rejects_weak_reset():
    case("dom0.sls: sequential QR mode rejects no-strict-reset")
    pillar = copy.deepcopy(render_pillar("dom0"))
    pillar.update({
        "webcam_usb_mode": "sequential",
        "webcam_usb_controller": "00_14.0",
        "webcam_usb_no_strict_reset": True,
    })
    _, parsed = render_state(
        "dom0", "dom0", Scenario(sys_usb=True), pillar_seqs=pillar)
    check("seqs-validation-failed" in parsed,
          "sequential + no-strict-reset must fail pre-flight")


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
    check("disposable D-qr-display offline" in targets,
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
