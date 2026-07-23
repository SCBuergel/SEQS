# Using the WireGuard NetVM

SEQS can build `A-wireguard`, an optional Qubes network-provider AppVM. Qubes
assigned to it send their network traffic through the imported WireGuard
tunnel. The WireGuard private key stays inside `A-wireguard`; it is never
copied into dom0 or committed to this repository.

## How to use it

### 1. Build the qube

Select `wireguard` during a normal SEQS build:

```bash
~/s.sh --build-only --qubes wireguard
```

This creates the `Z-wireguard` TemplateVM and `A-wireguard` AppVM. The latter
has `provides_network` enabled, but it does not have a VPN configuration yet.

### 2. Transfer a WireGuard configuration

Use Qubes' **Copy to Other AppVM** action to copy a provider `.conf` file to
`A-wireguard`. From a source qube's terminal, the equivalent command is:

```bash
qvm-copy-to-vm A-wireguard provider.conf
```

Qubes creates `~/QubesIncoming/SOURCE_QUBE/` in `A-wireguard` when the file
arrives. SEQS deletes `QubesIncoming` at boot and shutdown, so the directory
does not normally exist before a transfer.

Move the file into the persistent drop directory:

```bash
mv ~/QubesIncoming/SOURCE_QUBE/provider.conf ~/WireGuard/
```

### 3. Import and start the tunnel

Inside `A-wireguard`, run:

```bash
seqs-wireguard-import ~/WireGuard/provider.conf
```

The importer validates that the file contains a full-tunnel IPv4 route and an
IPv4 DNS server. It rejects executable `PreUp`, `PostUp`, `PreDown`, and
`PostDown` directives. On success, it stores a root-only copy and starts the
tunnel immediately.

Confirm the connection:

```bash
sudo wg show
getent hosts example.com
```

`wg show` should report a recent handshake after traffic has crossed the
tunnel. `getent` confirms that DNS works inside the network-provider qube.

### 4. Assign client qubes

In each client qube's Qubes settings, set **Networking** to `A-wireguard`.
Restart the client if it was already running.

Do not edit the client's `/etc/resolv.conf`. Qubes should continue to provide:

```text
nameserver 10.139.1.1
nameserver 10.139.1.2
```

Verify both routing and DNS from a non-sensitive test client:

```bash
curl https://ifconfig.co
getent hosts example.com
```

The reported public IP should belong to the VPN connection. Only after this
check should other qubes use `A-wireguard`.

### Switching configurations

Transfer or place another provider file in `~/WireGuard`, then import it:

```bash
seqs-wireguard-import ~/WireGuard/another-provider.conf
```

The importer replaces the active persistent configuration, tears down the old
`wg0`, and starts the new one. Keep only the provider files you intend to
retain: files in `~/WireGuard` are private AppVM data and persist across
reboots.

### Stopping and restarting

To stop the tunnel:

```bash
sudo wg-quick down /run/seqs-wireguard/wg0.conf
```

To start it again:

```bash
sudo /rw/config/seqs-wireguard/boot.sh
```

Client qubes fail closed while `wg0` is down. `A-wireguard` itself retains
upstream access because it needs that path to establish the VPN.

### Troubleshooting

Check the tunnel, DNS translations, and firewall service inside
`A-wireguard`:

```bash
sudo wg show
sudo nft list chain ip qubes dnat-dns
sudo nft list chain ip qubes seqs-wireguard-dns-output
sudo systemctl status qubes-firewall.service
sudo journalctl -b
```

The two nftables chains should translate Qubes' synthetic DNS addresses to the
IPv4 DNS server from the imported configuration. If IP traffic works but names
do not resolve, do not replace `/etc/resolv.conf`; inspect these chains and the
provider configuration's `DNS=` value.

For repository upgrades to an already-provisioned WireGuard qube, see
[upgrading](upgrading.md#deliberately-rerunning-a-changed-component). Changed
component scripts are intentionally not rerun until their completion marker is
removed.

## What it does under the hood

At a high level, the network path is:

```text
client qube → A-wireguard → wg0 → VPN provider → Internet
                         ↘ eth0 → upstream NetVM (tunnel setup only)
```

### Qube creation

The catalogue marks `wireguard` as a `network_provider`. The dom0 Salt state
creates `Z-wireguard` and `A-wireguard`, enables `provides_network`, and enables
Qubes' `qubes-firewall` service. It also disables browser-link handoff for the
provider qube.

The template installs Debian's `wireguard-tools` package and the
`seqs-wireguard-import` helper. Per-AppVM hooks and private configuration live
under `/rw/config/seqs-wireguard`, which persists across AppVM restarts.

### Configuration and startup

The importer validates the user-supplied file and copies it to:

```text
/rw/config/seqs-wireguard/wg0.conf
```

The copy is owned by root with mode `0600`. At startup, SEQS creates a temporary
configuration under `/run/seqs-wireguard`. It removes `DNS=` only from this
temporary copy before passing it to `wg-quick`; the persistent provider file is
not modified.

This split is necessary because Qubes owns `/etc/resolv.conf`, while normal
`wg-quick` DNS handling expects to manage that file through `resolvconf`.

### DNS handling

Client qubes always query Qubes' synthetic resolver addresses
`10.139.1.1` and `10.139.1.2`. SEQS reads the actual synthetic addresses from
QubesDB and the provider DNS from the imported WireGuard file.

It then atomically installs two narrowly scoped translations:

- Qubes' native `dnat-dns` prerouting chain handles requests arriving from
  client qubes.
- `seqs-wireguard-dns-output` handles requests generated locally by
  `A-wireguard`.

Both TCP and UDP port 53 are translated to the provider's IPv4 DNS server.
The firewall hook reapplies these mappings whenever Qubes rebuilds its firewall
tables.

### Fail-closed forwarding

Qubes' firewall user hook drops forwarded IPv4 and IPv6 traffic whose outgoing
interface is `eth0`. Normal client traffic must therefore leave through `wg0`.
If the tunnel fails or is stopped, client traffic cannot silently fall back to
the upstream NetVM.

This forwarding protection applies to qubes using `A-wireguard` as their
NetVM. It deliberately does not prevent locally generated traffic in
`A-wireguard` from reaching the upstream network, since WireGuard must resolve
and contact its endpoint before the tunnel exists.

### Trust boundary

The VPN provider can observe tunnel metadata and traffic leaving its VPN
endpoint. The upstream network can observe the VPN endpoint. A compromised
`A-wireguard` can alter its own routing and firewall state; use a separate
downstream firewall qube if the threat model requires enforcement outside the
VPN qube itself. See [TRUST.md](../TRUST.md#wireguard-netvm) for the complete
residual-risk statement.
