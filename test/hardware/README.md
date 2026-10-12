# Hardware test machine

This guide turns a spare computer into a SEQS test machine that you control
from your laptop over SSH. Afterwards, SEQS installs and per-qube checks can
run on real Qubes OS hardware without you sitting at that computer, and an AI
coding assistant on your laptop can drive them too.

Setting it up takes one Qubes OS installation and one command typed on the
test machine. Your laptop proves who it is by showing a QR code to a USB
webcam plugged into the test machine, so you never type a key or a password
there.

## Read this first: the test machine gives up Qubes' protection

Qubes OS normally keeps dom0 (the administrative domain that controls every
other qube) away from the network. This setup deliberately breaks that rule:
anyone who holds your laptop's test key and can reach the test machine on your
network can run any command in its dom0.

That is acceptable only on a computer that exists for testing. Keep no real
keys, passwords, or personal data on it, and never run the setup on a Qubes
installation you use for real work. The setup script itself is fetched from
the `main` branch on GitHub without checking its commit, which is also
acceptable only because the machine holds nothing of value.

## How your laptop reaches dom0

The script builds this chain on the test machine:

```text
laptop --SSH, port 2222--> sys-net --forwards--> test-ctl --qrexec--> dom0
```

- **`sys-net`** is the qube that owns the network card. The script adds a rule
  to it that forwards port 2222 to `test-ctl`, but only for connections from
  your local network.
- **`test-ctl`** is a new qube that runs an SSH server. It accepts only the key
  your laptop showed as a QR code. It is a StandaloneVM (a qube with its own
  copy of the operating system), so the software installed in it survives
  reboots.
- **qrexec** is Qubes' mechanism for one qube to call a service in another,
  allowed or denied by policy files in dom0. The script adds a service,
  `seqs.TestShell`, that runs whatever script it receives as your dom0 user,
  and a policy that lets only `test-ctl` call it. Inside `test-ctl`, the
  command `dom0` sends its input to that service.

The script also makes dom0 log in to the desktop automatically and stop
blanking the screen, because qubes can show windows, such as a QR code under
test, only while a desktop session is running.

## What you need

- The test machine: a computer with Intel VT-x and VT-d (or the AMD
  equivalents), connected to your home network by cable or Wi-Fi.
- A USB webcam for the test machine.
- Your laptop on the same network, with a qube that you will use to control
  the test machine. Any Debian- or Fedora-based qube with network access
  works; a dedicated one keeps the test key apart from everything else.

## 1. Prepare the test machine

These settings let the machine restart without anyone at the keyboard.

1. In the firmware (BIOS/UEFI) settings, enable VT-x and VT-d, and set the
   behaviour after a power loss to "power on". A smart plug can then restart
   the machine by switching its power off and on.
2. Install Qubes OS from the [official ISO](https://www.qubes-os.org/downloads/)
   with the installer's defaults. They include a Debian template and a
   `sys-net` that is a normal qube, which the setup requires; `sys-firewall`
   and `sys-usb` may be disposables. If the installer lets you skip disk
   encryption, do so; otherwise every boot stops at the passphrase prompt
   until someone types it.
3. Plug the webcam into the test machine.

## 2. Show your laptop's test key as a QR code

The test machine allows exactly one SSH key: a new key that exists only for
this purpose. You create it on your laptop and show its public half as a QR
code. The key has no passphrase, so that scripts can use it; it can do nothing
except control the test machine.

In a terminal of the controlling qube on your laptop, install the QR code
program (Debian-based qube shown; in a Fedora-based qube use
`sudo dnf install -y qrencode`), then create the key and show the code:

```bash
sudo apt-get install -y qrencode
[ -f ~/.ssh/seqs-test ] || ssh-keygen -t ed25519 -N '' -C seqs-test -f ~/.ssh/seqs-test
ssh-keygen -lf ~/.ssh/seqs-test.pub
qrencode -t ansiutf8 "seqs-test-v1 $(cat ~/.ssh/seqs-test.pub)"
```

The `ssh-keygen -lf` line prints the key's fingerprint, starting with
`256 SHA256:`; you compare it with the test machine's screen in the next
step. Below it, a QR code appears in the terminal. Leave it on screen. In a
qube based on a template, the `qrencode` installation disappears at the next
reboot, which does not matter here.

## 3. Run the setup on the test machine

Everything in this step happens on the test machine. You download the setup
script in a disposable qube (one that is deleted when it closes), where you
can paste commands, and then copy it into dom0, which has no clipboard and no
network.

Start a terminal in a disposable: in the Qubes menu, open the disposables
section and choose the terminal of the default disposable template
(`default-dvm`). To paste instead of type, start a browser in the same
disposable by running `firefox &` in its terminal, open this README there, and
copy the commands from it; a browser started from the Qubes menu would open in
a different disposable. In the disposable's terminal:

```bash
curl -fsSLo t.sh https://raw.githubusercontent.com/SCBuergel/SEQS/main/test/hardware/setup-test-machine.sh
hostname
```

`hostname` prints the disposable's name, for example `disp1234`. Keep the
disposable open until the script is in dom0.

Open a dom0 terminal: in the Qubes menu, open the gear (settings) section and
choose the Xfce terminal. Type, with the disposable's name:

```bash
qvm-run -p disp1234 'cat t.sh' > t.sh; bash t.sh
```

This copies the script into dom0 as `t.sh` and runs it. The script:

1. Finds the network's address range and asks you to type `TEST MACHINE`.
   Type it exactly and press Enter.
2. Creates `test-ctl` and installs the SSH server and the QR scanner in it.
   This downloads packages and takes a few minutes.
3. Connects the webcam to `test-ctl`. If it cannot tell which USB device is
   the webcam, it lists the devices and asks for a number. If the webcam is
   not in the list, plug it into another USB socket and press Enter to look
   again: `sys-usb` (the qube that owns the USB controllers) sees only devices
   on its own controllers.
4. Asks you to hold the QR code in front of the webcam. Turn your laptop's
   screen toward the webcam at a distance of about 20-40 cm until the script
   continues; it waits up to two minutes.
5. Shows the fingerprint of the key it read and asks `Allow these keys?`.
   Answer `y` only if the `SHA256:` value matches the one on your laptop.
6. Sets up the forwarding rule, the qrexec service and policy, and the
   automatic login, then checks that `test-ctl` can reach dom0. It also fixes
   the MAC address (the network card's hardware address, as your router sees
   it) that `sys-net` uses: by default, Qubes may present a different one
   after each reboot, and the router would then hand out a new address.

It ends with:

```text
==> Done. Write these down for your laptop:
      address   192.168.1.50
      port      2222
      host key  SHA256:...
      MAC       aa:bb:cc:dd:ee:ff  (reserve the address for it in your router)
```

Note the address and the host key (the fingerprint that proves to your laptop
that it reached `test-ctl` and not another machine).

Then, in your router's DHCP settings, reserve the shown address for the shown
MAC address. Without this reservation, the router may give the test machine a
different address after a reboot, and your laptop no longer finds it.

Do not reboot anything yet; step 4 includes a reboot of the test machine once
the connection works.

If a step fails, the script stops with an `ERROR:` line that says why. Fix the
cause and run `bash t.sh` again; each rerun resumes and replaces earlier
settings. A rerun first waits for any package installation still running in
`test-ctl`, for example after you stopped the script with Ctrl+C.

Without a webcam, the script can instead read keys from an HTTPS URL, such as
the list GitHub publishes at `https://github.com/<account>.keys`:
`bash t.sh --ssh-keys-url https://github.com/<account>.keys`.

## 4. Connect from your laptop

This step connects your laptop to the test machine, then reboots the test
machine once to check that the connection comes back without anyone at its
keyboard.

### Connect

An entry in your SSH configuration lets every later command refer to the test
machine as `seqs-test`.

In the terminal of the controlling qube on your laptop, set the address that
the test machine showed, then paste the rest:

```bash
ADDR=192.168.1.50
mkdir -p ~/.ssh && grep -qx 'Host seqs-test' ~/.ssh/config 2>/dev/null || cat >> ~/.ssh/config <<EOF
Host seqs-test
  HostName $ADDR
  HostKeyAlias seqs-test
  Port 2222
  User user
  IdentityFile ~/.ssh/seqs-test
  IdentitiesOnly yes
EOF
ssh seqs-test dom0 qvm-ls --running
```

On the first connection, SSH shows a host key fingerprint and asks whether to
continue. Type `yes` only if it matches the host key the test machine showed.
The output is the list of running qubes on the test machine, produced by its
dom0.

`HostKeyAlias seqs-test` makes SSH remember the host key under the name
`seqs-test` instead of under the address. If the address changes, you edit
only the `HostName` line in `~/.ssh/config`, and SSH still checks that it
reaches the same `test-ctl`.

### Reboot the test machine once

The setup is meant to survive restarts, including an unattended one such as
switching a smart plug off and on: `test-ctl` starts by itself, `sys-net`
restores the forwarding rule, and dom0 logs in to the desktop without a
password. The automatic login takes effect only at the next boot, so this
reboot both activates it and checks all three.

Reboot the whole test machine, for example from its Qubes menu (log out, then
restart) or in its dom0 terminal:

```bash
sudo reboot
```

Wait until the test machine shows its desktop without asking for a password,
then run the same command again in the controlling qube on your laptop:

```bash
ssh seqs-test dom0 qvm-ls --running
```

It should list the running qubes as before.

If `ssh` instead reports `No route to host`, the test machine is either still
starting or has a new address because the router reservation is missing. To
find it, run this in the controlling qube on your laptop, with the first three
parts of your network's addresses:

```bash
for i in $(seq 1 254); do (timeout 1 bash -c "exec 3<>/dev/tcp/192.168.1.$i/2222" 2>/dev/null && echo "192.168.1.$i") & done; wait
```

It prints each address that accepts connections on port 2222. Put the
address in the `HostName` line, and reserve it in your router as described in
[3. Run the setup on the test machine](#3-run-the-setup-on-the-test-machine).

If the test machine stops at the disk passphrase prompt, it was installed
with disk encryption (see
[1. Prepare the test machine](#1-prepare-the-test-machine)): type the
passphrase, and expect to do so after every restart.

## 5. Run the system test

The system test installs SEQS on the test machine from scratch and reports
everything that went wrong, how long each step took, and how large the
installer is. It runs on your laptop, from a clone of this repository in the
controlling qube, and tests your working copy, including changes you have
not committed yet (untracked files are left out, and the test says so).

It is the measuring step of an improvement loop for the installer: each run
shows whether the installer works and how long it takes, and counts its lines
as a measure of how auditable it is; a person or an AI coding assistant reads
the results, changes the code, and runs the test again.

### What one run does

| Phase | Where it runs | What happens |
|---|---|---|
| sync | laptop to `test-ctl` | Pushes the commit under test into `test-ctl`'s `/home/user/SEQS`, which serves as the runner's repository qube (`--repo-vm test-ctl`). |
| reset | dom0 | Deletes every SEQS qube (all `D-`, `A-`, and `Z-` qubes and those tagged by SEQS) and all SEQS files in dom0, then verifies that none are left. |
| install | dom0 | Runs the SEQS runner from the commit under test for the selected qubes, answering each `[y/N]` prompt with `y`. |
| check | dom0 | Verifies what was built: see below. |
| lifecycle | dom0 | Restarts the app qubes and checks that the cleanup service has not failed, that the boot and shutdown cleanup ran (and did not, with `preserve_incoming`) and that state kept through bind-dirs survived. |
| invalidate | dom0 | Only with `--force-rerun`: empties every completion marker. |
| rerun-install, rerun-check | dom0 | Runs install and check again. A second run must succeed and should be much faster, because finished components are skipped. |
| update, update-check | dom0 | Only with `--update`: updates the templates as a user would, then checks again. |
| reboot, reboot-check | laptop, dom0 | Only with `--reboot`: reboots the test machine, waits until it answers again, then checks again. |

The reset keeps `test-ctl`, `sys-net`, and every other qube that SEQS did not
create, including the stock Qubes qubes and templates the installer builds on
(`sys-firewall`, `sys-usb`, `debian-13-xfce`, and so on). A clean SEQS install
needs them, and recreating them would mean reinstalling Qubes.

The check phase verifies, for every qube the runner was asked to build, that:

- it exists, has the expected kind (template, app qube, or disposable), and is
  tagged as managed by SEQS;
- every component recorded its completion marker
  (`/rw/config/seqs/<component>.<role>.done` inside the qube, holding the hash
  of the files installed for it);
- templates are shut down after the install, and each app qube is based on
  its own SEQS template;
- each app qube and named disposable carries exactly the handoff tag its
  catalogue entry calls for;
- offline qubes have no network qube and no default disposable, and an
  offline app qube really cannot open a connection to the internet;
- networked app qubes have a network qube;
- a network-provider qube (WireGuard, GnosisVPN) gives a throwaway client
  qube, `seqs-test-client`, no internet without a working tunnel, while the
  same client reaches it through the default network qube. For WireGuard, the
  importer must refuse a `PostUp` hook, and a tunnel whose peer never answers
  must still block the client. For GnosisVPN, a stand-in tunnel interface
  must get the DNS translation only while it is up and routes the resolvers.

It also checks that the runner recorded success, that every SEQS policy file
in dom0 carries the SEQS marker, and that no temporary qube, policy, file, or
creation marker was left behind.

### Running it

In a terminal of the controlling qube on your laptop, in your clone of this
repository:

```bash
test/hardware/system-test.sh
```

The output of every phase scrolls by as it happens. A run of the
default selection (`keepass`, `qr-display`, and `brave`) takes a while, mostly
for downloading packages into the new templates. At the end, a summary
appears, similar to this (`N` stands for the measured seconds):

```text
phase     result  time
sync      ok        Ns
reset     ok        Ns
install   ok        Ns
check     ok        Ns
lifecycle ok        Ns
rerun-install ok    Ns
rerun-check ok      Ns

Runner steps (install):
<time> ==> <each step the runner announced>

Findings (errors, warnings, failed checks):
<matching lines from each phase log>

Product size (lines, for auditability):
<lines in setup-qubes.sh, delete-vms.sh, salt/, and install-scripts/>
```

The script exits with status 0 only if every phase succeeded. Everything is
also saved under `test/hardware/results/<date-time>/`: `summary.txt` and one
log per phase, with `test/hardware/results/latest` pointing to the newest
run. The results directory is not committed. `progress.log` there gets one
line when each phase starts and ends; once a run with the same options has
finished, the start lines also estimate when the run will end:

```text
23:10 start install (last time 217s); run ends about 23:18
```

For a short check after each change, `--quick` builds one qube of each kind
(offline, handing links to the browser, the browser, and a disposable template
with its named disposable) without the second install. To test other qubes,
name them, or build the whole catalogue:

```bash
test/hardware/system-test.sh --quick
test/hardware/system-test.sh --qubes keepass,signal
test/hardware/system-test.sh --all
test/hardware/system-test.sh --no-rerun
test/hardware/system-test.sh --host other-test   # an SSH host other than seqs-test
```

`--no-rerun` skips the second install, which saves time while you work on a
problem in the first one.

```bash
test/hardware/system-test.sh --force-rerun
```

`--force-rerun` empties every completion marker before the second install, so
it runs every component script again instead of skipping finished ones. That
is what happens on a real machine whenever a component's files or the shared
libraries change, so this run checks that every script can safely run over
its earlier installation.

```bash
test/hardware/system-test.sh --update
test/hardware/system-test.sh --reboot
```

`--update` updates every SEQS template with the Qubes updater, as a user
would, and checks the result: pinned repositories and locked keyrings must not
break a later update. `--reboot` checks that what SEQS set up survives a
restart. Use it only on a test machine that boots unattended: a disk
passphrase prompt keeps it offline until someone types it.

### Running your own commands in dom0

`dom0` in `test-ctl` runs either its arguments or a whole script in the test
machine's dom0 and returns the output. In the controlling qube on your
laptop:

```bash
ssh seqs-test dom0 qvm-ls --running
ssh seqs-test dom0 < my-check.sh
```

The second form runs the local file `my-check.sh` in dom0. Use it for anything
with quotes, `;`, or pipes: in the first form, the shell in `test-ctl` splits
the command before `dom0` receives it, so `ssh seqs-test dom0 'a; b'` runs `b`
in `test-ctl`, not in dom0. There is no
terminal on the dom0 side, so a command that waits for typed input cannot be
answered this way; the system test gives the runner a terminal for this
reason.

If dom0 itself gets into a bad state, reinstall Qubes and repeat this guide
from the Qubes installation in
[1. Prepare the test machine](#1-prepare-the-test-machine).

## Removing the remote control

In a dom0 terminal on the test machine:

```bash
bash t.sh --remove
```

This removes `test-ctl`, the forwarding rule, the qrexec service and policy,
and the automatic login, and returns `sys-net`'s MAC address to the Qubes
default. It refuses to remove a file or qube that the script
did not create. Reboot afterwards to end the automatic desktop session.

## Options

`bash t.sh --help` lists every option. The ones you might need:

| Option | Effect |
|---|---|
| `--ssh-keys-url URL` | Read the allowed keys from an HTTPS URL instead of a QR code. |
| `--ssh-key-file PATH` | Read the allowed keys from a file in dom0. |
| `--allow-from CIDR` | Accept connections from this range instead of the test machine's own network, e.g. `192.168.0.0/16`. |
| `--port PORT` | The port your laptop connects to (default 2222). |
| `--template NAME` | Create `test-ctl` from this template instead of `debian-13-xfce` (or, without it, the newest installed `debian-N`). |
| `--no-autologin` | Keep the dom0 login screen. |
