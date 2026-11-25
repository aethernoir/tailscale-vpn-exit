# tailscale-vpn-exit

A Tailscale exit node that sends its traffic out through a commercial VPN (Proton, Mullvad, anything [Gluetun supports](https://github.com/qdm12/gluetun-wiki/tree/main/setup/providers)). Run it on any always-on Linux box with Docker. Your phone and laptop keep Tailscale on as their only VPN; when you want the commercial VPN, pick this node as the exit.

Why: phones run one VPN at a time, so Tailscale and a privacy VPN fight over the slot. This moves the privacy VPN onto a box at home and lets Tailscale carry it.

```
phone ──Tailscale (direct, WireGuard)──▶ this box ──Gluetun / WireGuard──▶ VPN provider ──▶ internet
```

Companion write-up: [How to run Tailscale and Proton VPN at the same time](https://aether.noir.box/blog/tailscale-proton-vpn-exit-node/).

## What you need

- A Tailscale account with your devices on it (free tier is fine).
- A VPN subscription that gives you a WireGuard private key. For Proton: [account → Downloads → WireGuard configuration](https://account.protonvpn.com/downloads); any server; you need only the `PrivateKey` and `Address` lines.
- A Linux box that stays on, with Docker Compose v2 and `/dev/net/tun`.
- A free IP on the box's LAN for the stack (see macvlan below).

## Install

```sh
sudo mkdir -p /opt/vpn-exit/status && cd /opt/vpn-exit
sudo git clone https://github.com/aethernoir/tailscale-vpn-exit.git .
sudo cp .env.example .env && sudo chmod 600 .env
sudo nano .env            # provider, country, key, LAN address, parent interface, paths
sudo docker compose up -d
sudo docker compose logs tailscale   # follow the login URL once
```

Then in the [Tailscale admin console](https://login.tailscale.com/admin/machines): approve the node as an exit node. On your phone: Tailscale → Exit Node → pick it. Open an IP checker; your location should be the VPN's.

Check it any time:

```sh
sudo ./exit-check              # UP / SLOW / DOWN: reason -> fix
sudo ./exit-check --reconnect  # recreate the stack on a different server, then check
```

## How it works

Four containers share one network namespace.

**vpn** (Gluetun) holds the WireGuard tunnel, picks a server from your provider's list in `SERVER_COUNTRIES`, reconnects when one dies, and runs a firewall that drops anything trying to leave outside the tunnel.

**tailscale** runs with `--advertise-exit-node` and `--netfilter-mode=off` (Gluetun owns iptables). State lives in `./tailscale-state` so the node keeps its identity.

**fixup** reapplies, every 5 s, the routing and firewall rules Gluetun wipes on reconnect ([apply-exit-fix.sh](apply-exit-fix.sh)):

- Exit traffic arriving on `tailscale0` → policy rule → table 51820 → `tun0`.
- Tailscale's own packets (fwmark `0x80000`) → **main table → LAN**, at priority 40, ahead of Gluetun's catch-all. This is the line most setups get wrong: route the underlay into the VPN and the node is only reachable via a relay, every packet makes two VPN trips, and the link drops whenever the VPN changes servers.
- Return route for `100.64.0.0/10`, MASQUERADE on `tun0`, TCP MSS clamp, `tailscale0` MTU 1280.
- `FORWARD` policy DROP with only `tailscale0 ↔ tun0` allowed. `OUTPUT` on the LAN interface allowed only for the Tailscale mark.

**updater** runs nightly ([update.sh](update.sh)): snapshot current images as rollback tags, pull `tailscale:stable` and `gluetun:v3`, recreate if anything changed, then verify for up to 180 s (VPN egress differs from the home IP; Tailscale `Running` and advertising; routing rules present; `FORWARD DROP`). On failure it retags the previous images and recreates. It writes `status/update-status.json` for whatever monitoring you have. Manual run: `sudo docker compose exec updater sh update.sh once`.

### macvlan: why the stack has its own LAN address

On Docker's default bridge, the only addresses Tailscale can advertise are an internal `172.x` one your devices can't reach and your public IP, which most routers won't loop back to from inside the house. Devices at home then talk to the exit node via a Tailscale relay even though it's in the next room. With macvlan the `vpn` container is a real device on your LAN at `EXIT_LAN_IP`, advertises `EXIT_LAN_IP:41641`, and peers connect directly.

- `EXIT_PARENT_IF` is the box's wired NIC (`ip -br link`).
- Keep `EXIT_LAN_IP` outside your DHCP pool, or reserve it on the router for `EXIT_MAC`. The MAC is pinned so the reservation survives recreates.
- The host itself cannot reach a macvlan container. Nothing here needs it to.

## Limits

- The kill switch is rule-level (FORWARD DROP, Gluetun's OUTPUT policy). It has not been tested by dropping the tunnel under live traffic and watching packets. Treat it as a strong default, not a certified guarantee.
- Gluetun picks a server at random within the country, not by load. Slow server: `./exit-check --reconnect`.
- On mobile data a carrier's NAT can still force a relay; nothing on the box side can prevent that.
- With an exit node selected, your device can't reach printers etc. on its local Wi-Fi unless you enable Tailscale's [Allow Local Network Access](https://tailscale.com/docs/features/exit-nodes#local-network-access). That setting only exempts the subnet the device is on; a server on another VLAN still goes through the exit. Use its Tailscale address instead.
- Verification was done on one Debian/Umbrel host. Interface names, DHCP ranges and router behaviour differ; read `.env.example` carefully.

## Files

| File | Purpose |
|---|---|
| `compose.yaml` | The stack |
| `.env.example` | Every site-specific value; copy to `.env` |
| `apply-exit-fix.sh` | Routing/firewall fixup, run every 5 s |
| `update.sh` | Nightly pull / verify / rollback |
| `exit-check` | One-line health verdict, `--reconnect` |

## Security notes

- The WireGuard private key lives only in `.env` (mode 600) on the box. Don't paste it anywhere else.
- `tailscale-state/` is the node's identity. Back it up like a key; don't commit it.
- Run the stack as its own compose project. Don't point the whole host's default route at the VPN; that's a different design with different failure modes.

MIT. Built by [Aether Noir](https://aether.noir.box).
