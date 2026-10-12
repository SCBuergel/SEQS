# Using the GnosisVPN NetVM

SEQS builds `A-gnosisvpn`, a network-provider AppVM with a pinned GnosisVPN
stable release for the `jura-prod` network and Qubes-aware DNS/fail-closed
integration.

## Build the prepared qube

After fetching, reviewing, and staging this revision (see
[first install](first-install.md) or [upgrading](upgrading.md)), run in dom0:

```bash
~/s.sh --build-only --qubes gnosisvpn
```

This creates `Z-gnosisvpn` and `A-gnosisvpn`, enables
`provides_network=True`, and enables the Qubes firewall service.
After a newer revision is fetched and staged, rerunning the same command
upgrades an existing instance in place: when the
pinned release or any other part of the component changed, its installers run
again, and the AppVM's private VPN state in `/var/lib/gnosisvpn` is kept. Use
`~/d.sh gnosisvpn` (see [Deleting SEQS qubes](deleting-vms.md)) only to destroy the instance and rebuild it from
scratch; that also destroys the private VPN state, so back up anything that
must survive first.

For an independent second managed template and AppVM:

```bash
~/s.sh --build-only --qubes gnosisvpn --postfix alpha
```

This creates and prepares `Z-gnosisvpn-alpha` and `A-gnosisvpn-alpha`. Each
AppVM has independent private VPN state: `/var/lib/gnosisvpn` is mapped into
its private volume at `/rw/bind-dirs/var/lib/gnosisvpn` through Qubes
bind-dirs, so that directory survives AppVM restarts and template updates.
SEQS creates and seeds the private-volume directory during AppVM provisioning;
the bind becomes active on the next boot. The temporary update-proxy policy is
generated with exact source rules for every selected GnosisVPN instance and is
removed after template provisioning.

The template contains:

- `wireguard-tools`, including `wg` and `wg-quick`;
- `openresolv`, including the `resolvconf` command GnosisVPN expects.
- GnosisVPN `0.95.2` for `amd64`, configured with
  `GNOSISVPN_NETWORK=jura-prod`.

Do not install `openresolv` or GnosisVPN manually.

Before provisioning `Z-gnosisvpn`, the runner installs Debian dependencies
through the ordinary configured UpdateVM. It then creates a temporary AppVM
named `seqs-gnosisvpn-update-proxy`, enables `qubes-updates-proxy`, and applies
a default-deny firewall allowing only DNS and TCP 443 to
`download.vpn.gnosis.eth.limo`. A temporary exact-source qrexec rule directs only
`Z-gnosisvpn` to that proxy. If the configured UpdateVM is a DispVM, the
runner follows its validated DispVM-to-AppVM template chain to the underlying
TemplateVM used to create the temporary AppVM. The temporary AppVM uses the
UpdateVM as its NetVM when the UpdateVM provides network itself, such as
`sys-firewall`, and otherwise the UpdateVM's NetVM. With a Whonix gateway as
UpdateVM (updates over Tor) the runner refuses to build GnosisVPN: behind the
gateway the temporary AppVM's firewall is not enforced, and the download
fails. To build it anyway, set `sys-firewall` as UpdateVM for that run; the
download then leaves without Tor.

Upstream currently recommends piping
`https://download.vpn.gnosis.eth.limo/linux/install.sh` to root. That mutable
installer downloads the repository keyring, writes a stable or snapshot APT
source, refreshes APT metadata, and installs the channel's current candidate.
SEQS does not execute that mutable root script. Instead, it downloads the
package that the stable channel's signed APT index listed when the pin was
last reviewed, retaining an exact version and content pin. Upstream removes
superseded packages from that repository, so an old pin stops downloading
(HTTP 404) and the SEQS pin must then be reviewed and updated.

The template downloads the pinned `.deb` and detached signature through
`127.0.0.1:8082`, checks the embedded signing-key fingerprint
`9A308031FD3BFE8EDBF5076D84F73FEA46D10972`, verifies the detached signature,
and checks SHA-256
`87294d45d382d22181089c2f7f0a25330c75b77ef22b3989d399abf4027d3bdb`
before installation. After template provisioning—even on failure—the runner
removes the temporary policy and marked proxy qube; a run killed before that
leaves them until the next build, which removes them first. Qubes' default
UpdateVM policy then applies again.

`A-gnosisvpn` is already the prepared AppVM and is the shortest path for the
test below. For a second GnosisVPN qube, use `--postfix` as shown above rather
than creating one by hand from `Z-gnosisvpn`: a hand-made qube lacks the dom0
policy that stops `A-gnosisvpn` from handing links to the browser qube, and the
private-state and firewall preparation that the SEQS build performs.

## Test GnosisVPN

Start `A-gnosisvpn` and launch the installed GnosisVPN application. Do not
attach sensitive client qubes until completing the checks below.

Do not replace or relink `/etc/resolv.conf`. It should remain Qubes-managed:

```text
nameserver 10.139.1.1
nameserver 10.139.1.2
```

When GnosisVPN brings up `wg0_gnosisvpn`, it may register resolver addresses
under `/run/resolvconf/interfaces/wg0_gnosisvpn`. A systemd path unit reacts
to that runtime change, while a five-second reconciliation timer also handles
connections that publish no openresolv file. `/usr/sbin/seqs-gnosisvpn-dns`
prefers registered IPv4 resolvers and otherwise uses the built-in fallback
pair `1.1.1.1` and `8.8.8.8`. It refuses to activate unless the chosen
resolvers route through `wg0_gnosisvpn`.

The helper validates QubesDB addresses and atomically maintains a separately
owned `ip seqs_gnosisvpn_dns` nftables table:

- the output chain translates DNS generated by `A-gnosisvpn`;
- the prerouting chain translates DNS arriving from downstream client qubes;
- an output filter prevents the chosen resolver destinations from leaking over
  a non-VPN interface between reconciliation runs.

The translation matches Qubes' synthetic DNS destinations rather than relying
on an output-interface value at the nftables NAT hook. On disconnect, the
reconciler removes its table within five seconds. The Qubes firewall hook also
blocks forwarded IPv4 and IPv6 fallback through `eth0`, so attached clients
fail closed while the VPN is unavailable. The GnosisVPN qube itself retains
ordinary upstream access so the VPN software can discover and establish its
tunnel.

## Verify before attaching clients

In a terminal of `A-gnosisvpn`, with GnosisVPN disconnected:

```bash
getent hosts example.com
sudo nft list table ip seqs_gnosisvpn_dns
```

Ordinary Qubes DNS should work; the nft command should report that the table
does not exist.

Connect GnosisVPN, then verify:

```bash
sudo wg show wg0_gnosisvpn
sudo resolvconf -l
cat /etc/resolv.conf
getent hosts example.com
sudo nft list table ip seqs_gnosisvpn_dns
```

The WireGuard interface should have a recent handshake. `resolvconf -l` may
show one or two IPv4 resolvers for `wg0_gnosisvpn`; if it does not, the nft
table should target `1.1.1.1` and `8.8.8.8`. `/etc/resolv.conf` should still
contain Qubes' synthetic addresses, name resolution should succeed, and the
nftables counters should increase.

Next, confirm that translated DNS crosses the tunnel. `tcpdump` is not in the
template; install it in `A-gnosisvpn` (this lasts until the qube restarts):

```bash
sudo apt-get install -y tcpdump
```

Then run each capture in its own new `A-gnosisvpn` terminal:

```bash
sudo tcpdump -ni wg0_gnosisvpn 'port 53'
```

```bash
sudo tcpdump -ni eth0 'port 53'
```

Run `getent hosts example.com` in the terminal where you installed `tcpdump`. Provider DNS should
appear on `wg0_gnosisvpn`, not `eth0`.

Only then attach a non-sensitive disposable test client: in its Qubes settings,
set **Networking** to `A-gnosisvpn`. Inside that client:

```bash
cat /etc/resolv.conf
getent hosts example.com
curl https://ifconfig.co
```

The client should retain Qubes' synthetic resolver addresses, resolve names,
and report the VPN egress address. Disconnect GnosisVPN and confirm that the
client loses both DNS and IP connectivity instead of falling back to the
upstream NetVM. Reconnect and repeat the checks before attaching other qubes.

## Caveats

- The stable release is version- and hash-pinned and its detached signature is
  checked against an embedded key, but the key was sourced from the GnosisVPN
  project. Review the fingerprint through an independent channel.
- The package configures upstream's APT repository on two mirrors. SEQS pins
  both so that only the `gnosisvpn` package can come from them, checks that
  the repository keyring holds exactly the pinned key, and locks that keyring.
  Once the temporary policy is removed, later `gnosisvpn` updates use the
  normal Qubes UpdateVM, are not restricted by the temporary domain-only
  proxy, and can move past the version SEQS pinned.
- The DNS helper expects the interface to be named `wg0_gnosisvpn`. A future
  GnosisVPN release that renames it requires a reviewed component update.
- Only IPv4 DNS servers are accepted. Missing or unusable openresolv data uses
  Cloudflare `1.1.1.1` and Google `8.8.8.8`; those operators can observe the
  DNS queries, although routing validation keeps the traffic inside the VPN.
- Forwarded IPv6 is fail-closed through `eth0`. This setup does not claim
  working IPv6 through GnosisVPN.
- The DNS path unit reacts to openresolv changes and the timer reconciles
  interface state every five seconds. Check
  `systemctl status seqs-gnosisvpn-dns.path seqs-gnosisvpn-dns.timer` and
  `journalctl -u seqs-gnosisvpn-dns.service` if the VPN connects but the table
  is absent.
- A compromised GnosisVPN qube can change its own routes and nftables rules.
  Put a separate firewall qube downstream if enforcement must remain outside
  the VPN qube's trust boundary.
