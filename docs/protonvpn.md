# Using the Proton VPN NetVM

SEQS builds `A-protonvpn`, a network-provider AppVM (a qube that other qubes
can select as their NetVM, the qube their traffic goes through) running the
official [Proton VPN](https://protonvpn.com/support/linux-vpn-setup/) app.
Client qubes that use it reach nothing while Proton VPN is disconnected.

## Build the qube

In dom0, after fetching, reviewing, and staging this revision (see
[first install](first-install.md) or [upgrading](upgrading.md)):

```bash
~/s.sh --build-only --qubes protonvpn
```

This creates `Z-protonvpn` and `A-protonvpn`. The template gets the Proton VPN
app (`proton-vpn-gnome-desktop`) from Proton's apt repository, which apt
trusts only through the embedded Proton key and only for the app and its
Proton libraries; see [TRUST.md](../TRUST.md). `A-protonvpn` gets
`provides_network`, the Qubes firewall service, and the Qubes
`network-manager` service: the app connects through
[NetworkManager](https://networkmanager.dev/).

## Connect

Start **Proton VPN** in `A-protonvpn` from the Qubes menu or its panel
launcher, sign in, and connect. The app keeps the sign-in in a keyring (a
password store in the qube's home directory); the first time, a prompt asks
for that keyring's password. An empty password leaves the stored sign-in
readable by anything running as the user in `A-protonvpn`; a password must be
typed at every start of the qube.

## Attach client qubes

In a client qube's Qubes settings, set **Networking** to `A-protonvpn`. A
firewall hook (`/rw/config/seqs-protonvpn-firewall.sh`, which
`qubes-firewall` runs) drops forwarded traffic that would leave through
`eth0`, the qube's upstream link, for IPv4 and IPv6. Clients therefore reach
the internet only through the tunnel, whatever the app's own kill switch is
set to. `A-protonvpn`'s own traffic, such as the sign-in, still uses `eth0`.

Before attaching sensitive qubes, check with a disposable test client: with
Proton VPN connected, in the client:

```bash
curl https://ifconfig.co
```

It should print the VPN's address. Disconnect in the app and run it again: it
should fail instead of printing your own address.

## Caveats

- Packages from Proton's repository update with the template, like Debian's,
  and run as root in the VPN qube when installed.
- The embedded Proton key expires on 2027-03-03. After that date the template
  can no longer update Proton VPN until a reviewed SEQS update embeds the
  extended key.
- A compromised `A-protonvpn` can change its own routes and firewall rules.
  Put a separate firewall qube downstream if enforcement must remain outside
  the VPN qube's trust boundary.
