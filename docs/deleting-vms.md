# Deleting SEQS qubes

`delete-vms.sh` permanently deletes the app and template qubes belonging to a
SEQS base name, including the data stored in them, and removes the corresponding
SEQS-managed browser-suppression rule. Use it when intentionally removing a
configured qube or when a clean rebuild is required; ordinary upgrades do not
require deletion.

## How to use it

Deletion is destructive. Back up any data that must survive and close work in
the affected qubes first.

The argument is a **base name** available in `qube_catalog`, not a complete VM
name. For example, use `keepass` to target both `A-keepass` and `Z-keepass`.

Review what would happen without changing anything:

```bash
./delete-vms.sh --dry-run keepass
```

The output lists the matching qubes and any browser-policy entry that would be
removed. Check every name, then perform the deletion:

```bash
./delete-vms.sh keepass
```

Multiple base names can be handled in one invocation:

```bash
./delete-vms.sh keepass telegram wallet-ledger
```

When running the helper in dom0, first copy it from the reviewed repository
source and inspect it:

```bash
qvm-run -p disp1234 'cat /home/user/SEQS/delete-vms.sh' 2>/dev/null > ./d.sh && chmod 700 ./d.sh
./d.sh --dry-run keepass
./d.sh keepass
```

Replace `disp1234` with the disposable's name and adjust the repository path if
needed. Keep
`2>/dev/null`: source-qube stderr must not reach the dom0 terminal during this
copy.

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
2. Looks for exactly `A-<name>` and `Z-<name>`; unrelated qubes are ignored.
3. Calls `qvm-kill` for matches, then waits up to 30 seconds for them to stop.
4. Calls `qvm-remove -f` for each match, permanently removing the qube and its
   volumes. A removal failure stops the script.
5. Only after `A-<name>` is absent, removes its exact rule from
   `/etc/qubes/policy.d/28-browser-suppress.policy`:

   ```text
   qubes.OpenURL  *  A-<name>  @anyvm  deny
   ```

The policy edit occurs only when the file contains the `Managed by SEQS`
marker. The helper rewrites it through a same-directory temporary, preserves
its ownership, permissions, and security context when supported, and replaces
it atomically. It never removes arbitrary policy lines or modifies an unmarked
file; an unmarked stale rule produces a warning for manual review. If the qubes
are already absent, running the helper still cleans an exact stale rule from a
marked policy.

`--dry-run` performs the same discovery but does not kill qubes, remove volumes,
or rewrite policy files.
