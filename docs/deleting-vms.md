# Deleting SEQS qubes

`delete-vms.sh` permanently deletes the app and template qubes belonging to a
SEQS base name, including the data stored in them, and removes the deny rules
SEQS wrote for them. Use it when intentionally removing a
configured qube or when a clean rebuild is required; ordinary upgrades do not
require deletion.

## How to use it

Deletion is destructive. Back up any data that must survive and close work in
the affected qubes first.

The argument is a **base name** available in `qube_catalog`, not a complete VM
name. For example, use `keepass` to target both `A-keepass` and `Z-keepass`.
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
disconnected, and the policy entries that would be removed. Check every name,
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
per-run selection. A later build that explicitly selects the name will recreate
the qubes.

To rebuild from scratch, leave the catalogue entry in place, delete the qubes,
and rerun a build that explicitly selects the base name. Fetch and stage again
only when the reviewed repository tree itself changed.

## What it does under the hood

For each supplied base name, the helper:

1. Rejects unsafe names instead of treating arguments as patterns or options.
2. Looks for exactly `D-<name>`, `A-<name>`, and `Z-<name>`; unrelated qubes are
   ignored. (`D-<name>` exists only for a `named_disposable` entry.)
3. Finds qubes whose `netvm` property points to a match and sets that property
   to `none`. This preserves the dependent qubes and their data while
   disconnecting their network; Qubes otherwise refuses to remove a NetVM that
   is in use. Dry-run lists every dependency it would disconnect.
4. Calls `qvm-kill` for matches, then waits up to 30 seconds for them to stop.
5. Calls `qvm-remove -f` for each match in dependency order — the disposable
   (`D-`) before the `A-` template it derives from, and `A-` before its `Z-`
   template — permanently removing the qube and its volumes. A removal failure
   stops the script.
6. Only after `A-<name>` is absent, removes from
   `/etc/qubes/policy.d/28-browser-suppress.policy` the `deny` rules that SEQS
   wrote for `A-<name>`, `@dispvm:A-<name>`, and `D-<name>`, such as:

   ```text
   qubes.OpenURL  *  A-<name>  @anyvm  deny
   ```

The policy edit occurs only when the file contains the `Managed by SEQS`
marker. The helper rewrites it through a same-directory temporary, preserves
its ownership, permissions, and security context when supported, and replaces
it atomically. It never removes arbitrary policy lines or modifies an unmarked
file; an unmarked stale rule produces a warning for manual review. If the qubes
are already absent, running the helper still cleans stale rules from a marked
policy.

`--dry-run` performs the same discovery but does not kill qubes, remove volumes,
or rewrite policy files.
