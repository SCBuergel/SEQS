# Deleting SEQS qubes

`delete-vms.sh` permanently deletes the app and template qubes belonging to a
SEQS base name, including the data stored in them. Use it when intentionally removing a
configured qube or when a clean rebuild is required; ordinary upgrades do not
require deletion.

## How to use it

Deletion is destructive. Back up any data that must survive and close work in
the affected qubes first.

The argument is a **base name**, such as an entry of `qube_catalog`, not a
complete VM name. For example, use `keepass` to target both `A-keepass` and `Z-keepass`.
For a postfixed instance, pass its full generated base name: `gnosisvpn-alpha`
targets `A-gnosisvpn-alpha` and `Z-gnosisvpn-alpha`, while leaving the
canonical `gnosisvpn` instance untouched.

The helper runs in dom0. Copy the committed version from the repository qube
and read it; replace `disp1234` with that qube's name. Keep `2>/dev/null`, so
that the source qube's error output cannot reach the dom0 terminal:

```bash
qvm-run -p disp1234 'git -C /home/user/SEQS show HEAD:delete-vms.sh' 2>/dev/null > ~/d.sh && chmod 700 ~/d.sh
less ~/d.sh
```

Review what would happen without changing anything:

```bash
~/d.sh --dry-run keepass
```

The output lists the matching qubes, the qubes whose network would be
disconnected, and any qube that blocks the deletion. Check every name,
then perform the deletion:

```bash
~/d.sh keepass
```

Multiple base names can be handled in one invocation:

```bash
~/d.sh keepass telegram wallet-ledger
```

For permanent removal from this machine, do not select that base name in later
builds. The catalogue may remain unchanged: availability is separate from the
per-run selection. A later build that selects the name, or uses `--all`, will
recreate the qubes.

To rebuild from scratch, leave the catalogue entry in place, delete the qubes,
and rerun a build that explicitly selects the base name. Fetch and stage again
only when the reviewed repository tree itself changed.

## What it does under the hood

For each supplied base name, the helper:

1. Rejects unsafe names instead of treating arguments as patterns or options.
2. Looks for exactly `D-<name>`, `A-<name>`, and `Z-<name>`; unrelated qubes are
   ignored. (`D-<name>` exists only for a `named_disposable` entry.) A match
   without the `seqs-managed` feature, such as a qube you made yourself, is
   skipped and reported, unless an interrupted SEQS build left a creation
   marker for it.
3. Stops, before changing anything for any name, if another qube uses a match
   as its template, default or management disposable, or audio or GUI qube,
   such as `sys-usb-webcam` on `A-qr-camera`, or a match is a global default
   such as the UpdateVM; it names the reference, which you then remove or
   change first.
4. Finds qubes whose `netvm` property points to a match and sets that property
   to `none`. This preserves the dependent qubes and their data while
   disconnecting their network; Qubes otherwise refuses to remove a NetVM that
   is in use. Dry-run lists every dependency it would disconnect.
5. Calls `qvm-kill` for matches, then waits up to 30 seconds for them to stop.
6. Calls `qvm-remove -f` for each match in dependency order — the disposable
   (`D-`) before the `A-` template it derives from, and `A-` before its `Z-`
   template — permanently removing the qube and its volumes. A removal failure
   stops the script.
7. Deletes the dom0 files SEQS wrote for each removed qube: its CPU pinning
   (`/etc/qubes/templates/libvirt/xen/by-name/<qube>.xml`, which would
   otherwise apply to a later qube of the same name) and its recorded firewall
   rules under `/var/lib/seqs/firewall/`.

The helper changes no policy file: the dom0 handoff rules match the qubes'
tags, which disappear with them. Deleting the browser qube (`brave`) leaves
the rule that lets `seqs-handoff` qubes open links in `A-brave`, so a qube you
later create under that name receives those links without a prompt; change
`browser_vm` in `config.sls` and rebuild before you do.

`--dry-run` performs the same discovery but does not kill qubes, remove volumes,
or change any `netvm` property.
