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

The script has been checked by the repository's unit tests but has not yet run
on Qubes, so expect to fix details on the first real run.

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
  equivalents), wired to your home network.
- A USB webcam for the test machine.
- Your laptop on the same network, with a qube that you will use to control
  the test machine. Any Debian- or Fedora-based qube with network access
  works; a dedicated one keeps the test key apart from everything else.

## 1. Prepare the test machine

These settings let the machine restart without anyone at the keyboard.

1. In the firmware (BIOS/UEFI) settings, enable VT-x and VT-d, and set the
   behaviour after a power loss to "power on". A smart plug can then restart
   the machine by switching its power off and on.
2. In your router, give the test machine a fixed address, so that the address
   you note in step 4 stays valid.
3. Install Qubes OS from the [official ISO](https://www.qubes-os.org/downloads/)
   with the installer's defaults, which include a normal (not disposable)
   `sys-net`, `sys-usb`, and a Debian template. If the installer lets you skip
   disk encryption, do so; otherwise every boot stops at the passphrase prompt
   until someone types it.
4. Plug the webcam into the test machine.

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

Everything in this step happens on the test machine. Dom0 has no clipboard,
so you type the command.

Open a dom0 terminal: in the Qubes menu, open the gear (settings) section and
choose the Xfce terminal. Type:

```bash
qvm-run -p --dispvm=default-dvm 'curl -fsSL https://raw.githubusercontent.com/SCBuergel/SEQS/main/test/hardware/setup-test-machine.sh' > t.sh; bash t.sh
```

The first part starts a disposable qube (one that is deleted when it closes),
downloads the script there, and saves it in dom0 as `t.sh`; dom0 itself never
touches the network. `bash t.sh` then runs it. The script:

1. Finds the network's address range and asks you to type `TEST MACHINE`.
   Type it exactly and press Enter.
2. Creates `test-ctl` and installs the SSH server and the QR scanner in it.
   This downloads packages and takes a few minutes.
3. Connects the webcam to `test-ctl`. If it cannot tell which USB device is
   the webcam, it lists the devices and asks for a number.
4. Asks you to hold the QR code in front of the webcam. Turn your laptop's
   screen toward the webcam at a distance of about 20-40 cm until the script
   continues; it waits up to two minutes.
5. Shows the fingerprint of the key it read and asks `Allow these keys?`.
   Answer `y` only if the `SHA256:` value matches the one on your laptop.
6. Sets up the forwarding rule, the qrexec service and policy, and the
   automatic login, then checks that `test-ctl` can reach dom0.

It ends with:

```text
==> Done. Write these down for your laptop:
      address   192.168.1.50
      port      2222
      host key  SHA256:...
```

Note the address and the host key (the fingerprint that proves to your laptop
that it reached `test-ctl` and not another machine). Then reboot the test
machine once, so that the automatic login takes effect.

If a step fails, the script stops with an `ERROR:` line that says why. Fix the
cause and run `bash t.sh` again; each rerun resumes and replaces earlier
settings. Without a webcam, the script can instead read keys from an HTTPS
URL, such as the list GitHub publishes at
`https://github.com/<account>.keys`:
`bash t.sh --ssh-keys-url https://github.com/<account>.keys`.

## 4. Connect from your laptop

An entry in your SSH configuration lets every later command refer to the test
machine as `seqs-test`.

In the terminal of the controlling qube on your laptop, set the address that
the test machine showed, then paste the rest:

```bash
ADDR=192.168.1.50
mkdir -p ~/.ssh && grep -qx 'Host seqs-test' ~/.ssh/config 2>/dev/null || cat >> ~/.ssh/config <<EOF
Host seqs-test
  HostName $ADDR
  Port 2222
  User user
  IdentityFile ~/.ssh/seqs-test
  IdentitiesOnly yes
EOF
ssh seqs-test dom0 qvm-ls --running
```

On the first connection, SSH shows a host key fingerprint and asks whether to
continue. Type `yes` only if it matches the host key the test machine showed.
The output is the list of running qubes on the test machine, produced by dom0.

If the test machine's address changes later, edit the `HostName` line in
`~/.ssh/config`.

## 5. Run tests from your laptop

`dom0` runs either its arguments or a whole script in the test machine's
dom0, and returns the output and exit status. These examples run in the
controlling qube on your laptop:

```bash
ssh seqs-test dom0 qvm-ls --running
ssh seqs-test dom0 < my-test.sh
```

The second form runs the local file `my-test.sh` in dom0, for example a
sequence of `qvm-run --pass-io <qube> '<check>'` calls that test the qubes
SEQS built.

There is no terminal (TTY) on the dom0 side. Commands that wait for typed
confirmation, such as the SEQS runner's `[y/N]` prompts, cannot be answered
this way yet.

To reset between test runs, remove the qubes SEQS built with `delete-vms.sh`,
as on any SEQS machine. If dom0 itself gets into a bad state, reinstall Qubes
and repeat this guide from the Qubes installation in
[1. Prepare the test machine](#1-prepare-the-test-machine).

## Removing the remote control

In a dom0 terminal on the test machine:

```bash
bash t.sh --remove
```

This removes `test-ctl`, the forwarding rule, the qrexec service and policy,
and the automatic login. It refuses to remove a file or qube that the script
did not create. Reboot afterwards to end the automatic desktop session.

## Options

`bash t.sh --help` lists every option. The ones you might need:

| Option | Effect |
|---|---|
| `--ssh-keys-url URL` | Read the allowed keys from an HTTPS URL instead of a QR code. |
| `--ssh-key-file PATH` | Read the allowed keys from a file in dom0. |
| `--allow-from CIDR` | Accept connections from this range instead of the test machine's own network, e.g. `192.168.0.0/16`. |
| `--port PORT` | The port your laptop connects to (default 2222). |
| `--template NAME` | Create `test-ctl` from this Debian template instead of the newest installed one. |
| `--no-autologin` | Keep the dom0 login screen. |
