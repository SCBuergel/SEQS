"""Offline renderer for the SEQS Salt states and pillar.

Qubes' Salt states are Jinja-templated YAML. Almost every way you can break
them while "modifying the installer setup" -- a stray `{% endif %}`, a bad
filter, a name that no longer resolves, a state key that stops appearing --
shows up the moment the template is *rendered*, long before anything touches a
real qube. Rendering needs a running dom0 + the Qubes salt stack, which is
exactly what we do NOT want to spin up on every edit.

This module renders those same templates with a Jinja environment that stands
in for Salt: it provides the `salt[...]` execution-module dict, `grains`,
`pillar`, and the handful of custom filters (`regex_match`, `tojson`) the
states use. The `salt[...]` calls (qvm-check, qvm-features, file existence,
/etc/qubes-release, ...) are answered from a `Scenario` object so a single
template can be exercised against many simulated dom0 states.

It is NOT a bit-for-bit Salt oracle -- it will not catch a bug that only
manifests in Salt's own state *execution* (e.g. a require-ordering cycle that
Salt would reject at runtime). What it DOES catch, in well under a second and
with no Qubes at all:

  * Jinja syntax / logic errors in dom0.sls, qube.sls, config.sls
  * YAML that no longer parses after rendering
  * the pre-flight validation logic in dom0.sls / qube.sls (bad label,
    unknown component, unsafe name, duplicate qube, offline+firewall, ...)
  * config <-> repo drift (a component referenced with no directory, an
    undefined Brave extension, a prefix that no longer matches the top files)
  * per-minion pillar slicing (dom0 sees the whole map; an app qube only sees
    its own slice)

See test/README.md for how the layers fit together.
"""

import json
import os
import re

from jinja2 import Environment, BaseLoader, StrictUndefined

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _regex_match(value, pattern):
    """Salt's `regex_match` filter: re.match, returning the match or None.

    States use it as `x | regex_match(re) is none`, so returning None on no
    match (and a truthy Match otherwise) is all that matters.
    """
    return re.match(pattern, "" if value is None else str(value))


def _make_env():
    env = Environment(
        loader=BaseLoader(),
        extensions=["jinja2.ext.do"],
        undefined=StrictUndefined,  # surface typos as errors, not silent ''
        keep_trailing_newline=True,
    )
    env.filters["regex_match"] = _regex_match
    # Jinja3 ships `tojson`; Salt's output is JSON too (a subset of YAML), so
    # the built-in is a faithful enough stand-in for the states' `| tojson`.
    return env


class Scenario:
    """Simulated dom0 / minion state that answers the `salt[...]` calls.

    Everything defaults to a *fresh* dom0: the base template exists, no SEQS
    qubes exist yet, no markers, release 4.2 without sys-usb. Override just the
    fields a given test cares about.
    """

    def __init__(
        self,
        existing_qubes=None,     # names for which `qvm-check` returns 0
        tagged_qubes=None,       # names whose `seqs-managed` feature is '1'
        existing_files=None,     # paths for which file.file_exists is True
        file_contents=None,      # path -> contents returned by file.read
        component_dirs=None,     # component names present under files/components/
        release="4.2",           # /etc/qubes-release version, '' = unreadable
        sys_usb=False,           # does a `sys-usb` qube exist?
        base_template="debian-13-xfce",
        top_content=None,        # contents of /srv/pillar/seqs/config.top
        selection="@all",        # runtime catalogue selection, one name per line
    ):
        self.existing_qubes = set(existing_qubes or [])
        # The base template is expected to exist on any real dom0 running SEQS.
        if base_template:
            self.existing_qubes.add(base_template)
        if sys_usb:
            self.existing_qubes.add("sys-usb")
        self.tagged_qubes = set(tagged_qubes or [])
        self.file_contents = dict(file_contents or {})
        self.existing_files = set(existing_files or []) | set(self.file_contents)
        if component_dirs is None:
            component_dirs = _repo_component_dirs()
        self.component_dirs = set(component_dirs)
        self.release = release
        if top_content is None:
            top_content = _read_repo("salt/pillar/seqs/config.top")
        self.top_content = top_content
        self.selection = selection

    # -- individual salt[...] handlers ------------------------------------
    def cmd_retcode(self, cmd, **_):
        m = re.search(r"qvm-check\s+-q\s+--\s+(\S+)", cmd)
        if m:
            return 0 if m.group(1) in self.existing_qubes else 1
        return 0

    def cmd_shell(self, cmd, **_):
        if "/var/lib/seqs/selection" in cmd:
            return self.selection
        if "config.top" in cmd:
            return self.top_content
        if "qubes-release" in cmd:
            return self.release
        m = re.search(r"qvm-features\s+--\s+(\S+)\s+seqs-managed", cmd)
        if m:
            return "1" if m.group(1) in self.tagged_qubes else ""
        return ""

    def file_directory_exists(self, path):
        p = path.rstrip("/")
        marker = "/files/components/"
        if marker in p:
            return p.split(marker, 1)[1] in self.component_dirs
        return False

    def file_file_exists(self, path):
        return path in self.existing_files

    def file_read(self, path):
        return self.file_contents.get(path, "")


class _MockSalt(dict):
    """Stand-in for Salt's `__salt__` execution-module dict.

    `salt['pillar.get']`, `salt['cmd.retcode']`, ... resolve to callables
    backed by the pillar and Scenario. An unrecognised module returns a
    no-op that yields '' so a newly introduced call fails loud (KeyError-free)
    but visibly empty rather than crashing the whole render.
    """

    def __init__(self, pillar, scenario):
        super().__init__()
        self._pillar = pillar
        self._sc = scenario

    def __getitem__(self, key):
        sc = self._sc
        table = {
            "pillar.get": lambda k, default=None: self._pillar.get(k, default),
            "cmd.retcode": sc.cmd_retcode,
            "cmd.shell": sc.cmd_shell,
            "cmd.run": sc.cmd_shell,
            "file.directory_exists": sc.file_directory_exists,
            "file.file_exists": sc.file_file_exists,
            "file.read": sc.file_read,
        }
        if key in table:
            return table[key]
        return lambda *a, **k: ""


def _read_repo(rel):
    with open(os.path.join(REPO_ROOT, rel)) as fh:
        return fh.read()


def _repo_component_dirs():
    comp = os.path.join(REPO_ROOT, "install-scripts", "components")
    return [d for d in os.listdir(comp) if os.path.isdir(os.path.join(comp, d))]


def render_pillar(minion_id):
    """Render salt/pillar/seqs/config.sls as it would compile for `minion_id`.

    Returns the parsed `seqs:` mapping (an empty dict for a qube that matches
    the Z-*/A-* glob but has no spec).
    """
    import yaml

    env = _make_env()
    src = _read_repo("salt/pillar/seqs/config.sls")
    out = env.from_string(src).render(grains={"id": minion_id})
    data = yaml.safe_load(out) or {}
    return data.get("seqs", {})


def render_state(state, minion_id, scenario=None, pillar_seqs=None):
    """Render salt/seqs/<state>.sls and return (rendered_text, parsed_yaml).

    `state` is 'dom0' or 'qube'. When `pillar_seqs` is omitted it is compiled
    from config.sls for `minion_id`, matching what Salt would deliver.
    """
    import yaml

    if pillar_seqs is None:
        pillar_seqs = render_pillar(minion_id)
    if scenario is None:
        scenario = Scenario()

    env = _make_env()
    src = _read_repo("salt/seqs/%s.sls" % state)
    pillar = {"seqs": pillar_seqs}
    salt = _MockSalt(pillar, scenario)
    text = env.from_string(src).render(
        grains={"id": minion_id}, pillar=pillar, salt=salt
    )
    parsed = yaml.safe_load(text) or {}
    return text, parsed
