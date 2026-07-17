# Seb's QubesOS Scripts (SEQS)

SEQS builds a set of purpose-specific qubes (chat, wallets, dev, USB transfer, …)
on a fresh Qubes OS install. A thin dom0 runner (`setup-qubes.sh`) fetches this
repo **once**, installs a Salt state/pillar tree into `/srv`, and then
`qubesctl` creates every qube and installs its software declaratively.
Re-running converges — finished work is skipped, existing qubes are reconfigured
in place. Template VMs are prefixed `Z-[AppName]`; the app VMs you actually use
are prefixed `A-[AppName]`, to keep the Qubes menu tidy.

> **⚠️ WARNING — this runs code in dom0.** Bootstrapping copies one file from an
> app VM into dom0 and runs it, which exposes dom0 to scripts whose safety is not
> guaranteed. **Read every file yourself and only proceed if you understand and
> trust it.** Start with [VERIFY-HUMAN.md](VERIFY-HUMAN.md) and
> [TRUST.md](TRUST.md).

## Install in three steps

1. **[Install Qubes OS](docs/install-qubes.md)** — download, *verify*, and flash
   the ISO (essentials in §1).
2. **Configure** what gets built — two edits (§2).
3. **Run the installer** from dom0 (§3).

## Further reading

| Topic | Where |
|---|---|
| Full Qubes OS install + ISO verification | [docs/install-qubes.md](docs/install-qubes.md) |
| How the runner works, trust story        | [docs/architecture.md](docs/architecture.md), [TRUST.md](TRUST.md) |
| Components, flags, air gaps, adding your own | [docs/configuration.md](docs/configuration.md) |
| Verify before you trust the qubes        | [VERIFY-HUMAN.md](VERIFY-HUMAN.md), [VERIFY-LLM.md](VERIFY-LLM.md) |
| Extra recipes (VPN tray, firewall, ADB…) | [docs/recipes.md](docs/recipes.md) |
| Secure air-gapped QR transfer + webcam USB isolation | [docs/secure-qr-transfer.md](docs/secure-qr-transfer.md) |
| Testing changes offline                   | [test/README.md](test/README.md) |

---

## 1. Install Qubes OS

Full walkthrough incl. ISO verification: [docs/install-qubes.md](docs/install-qubes.md).
Essentials:

1. Download the latest [Qubes OS ISO](https://www.qubes-os.org/downloads/) onto a
   dedicated ≥8 GB USB stick (Ventoy is [not supported](https://github.com/QubesOS/qubes-issues/issues/8846)).
2. **Verify the ISO** before flashing — a tampered ISO compromises every qube you
   later build. Cross-check the Qubes Master Signing Key fingerprint
   `427F 11FD 0FAA 4B08 0123 F01C DDFA 1A3E 3687 9494` against three independent
   sources, then `gpg --verify` ([how](docs/install-qubes.md#2-verify-the-iso-before-flashing-it)).
3. Install, then run all system updates and reboot.

## 2. Configure what gets built

Two edits before your first run.

### 2.1 Point the runner at your repo qube — `setup-qubes.sh`

At the top of `setup-qubes.sh` (or via env vars):

```bash
REPO_VM="${SEQS_REPO_VM:-personal}"             # qube dom0 fetches the repo from
REPO_PATH="${SEQS_REPO_PATH:-/home/user/SEQS}"  # where the repo lives in it
```

`REPO_VM` is the **root of trust for the whole build** — dom0 runs whatever it
serves. On an **absolutely fresh** Qubes install the stock `personal` qube is a
fine default. But if your `personal` qube is **actually in use** (browses the
web, opens documents, holds files), host the repo in a **dedicated, minimal,
network-light qube** instead and set `REPO_VM` to it. Change `REPO_PATH` if you
cloned the repo somewhere other than `/home/user/SEQS`.

### 2.2 Choose your qubes (`salt/pillar/seqs/config.sls`)

**All software configuration lives in one file:** `salt/pillar/seqs/config.sls`.
Each qube is one entry in `qube_list`, built from a list of **components**:

```
{%- set qube_list = [
  {'name': 'keepass',       'label': 'black',  'components': ['keepass'], 'offline': True},
  {'name': 'dev-full',      'label': 'orange', 'components': ['docker', 'python', 'node', 'vscode', 'claude-code']},
  {'name': 'wallet-ledger', 'label': 'gray',   'components': ['ledger', 'brave-extension-rabby'], 'no_handoff': True},
] %}
```

Add an entry to spin up a new qube; edit an entry to add/remove components. The
**full component list**, per-qube flags (`offline`, `no_handoff`), wallet
extensions, and how to add your own component are in
[docs/configuration.md](docs/configuration.md).

## 3. Run the installer

1. Copy this repo into the home directory of your repo qube (default
   `/home/user/SEQS` in `personal` — match `REPO_VM` / `REPO_PATH`).
2. Open a **dom0** terminal and run the one-liner (a [standard way to copy a file
   from an app VM into dom0](https://www.qubes-os.org/doc/how-to-copy-from-dom0/#copying-to-dom0)):
   ```
   qvm-run -p personal 'cat /home/user/SEQS/setup-qubes.sh' 2>/dev/null > s.sh && chmod +x s.sh && ./s.sh
   ```
   If you changed `REPO_VM` / `REPO_PATH`, update `personal` and
   `/home/user/SEQS` here too. The `2>/dev/null` is deliberate — it closes a
   terminal-injection window before the runner's own sanitizer exists
   ([why](docs/architecture.md#bootstrap-window)).
3. Review the fetched tree when prompted and type `CONTINUE`. Some software
   packages need a one-time reboot of their app VM to work.

**Re-runs and flags** — re-running `./setup-qubes.sh` converges (edit
`config.sls` and re-run to change what's built):

```
./setup-qubes.sh --fetch-only    # fetch + install to /srv, then stop for review
./setup-qubes.sh --skip-fetch    # apply from /srv without contacting REPO_VM
./setup-qubes.sh --verbose       # show full per-state qubesctl output (debug)
```

See [docs/architecture.md](docs/architecture.md) for exactly what each phase does.
