#!/bin/sh
# Idempotent exit-node fixups for Gluetun + Tailscale.
# Must run in the Gluetun netns (real iproute2 + iptables-legacy).
# Used by the fixup sidecar every ~5s (Gluetun rewrites rules on reconnect).
#
# Design:
#   - Forwarded exit traffic (iif tailscale0) -> table 51820 -> tun0 (the VPN).
#   - Tailscale's OWN underlay (tailscaled marks its sockets 0x80000) -> main
#     table -> eth0 (home connection), not nested inside the VPN. Allows direct
#     peer connections and survives VPN reconnects.
#   - FORWARD default DROP: exit traffic may only leave via tun0 (kill switch).

# Wait until both interfaces exist
if ! ip link show tun0 >/dev/null 2>&1; then
  echo "tun0 not ready"
  exit 0
fi
if ! ip link show tailscale0 >/dev/null 2>&1; then
  echo "tailscale0 not ready"
  exit 0
fi

# Standard Tailscale MTU (not nested in the VPN). >=1280 keeps HTTP/3 working.
ip link set dev tailscale0 mtu 1280 2>/dev/null || true

# Underlay: tailscaled's marked packets use the main table (eth0), not the VPN.
while ip rule show | grep -q 'fwmark 0x80000/0xff0000 lookup 51820'; do
  ip rule del fwmark 0x80000/0xff0000 lookup 51820 2>/dev/null || break
done
# Must be priority 40: tailscaled's own 5210 rule sits AFTER Gluetun's 101
# catch-all, so match on the priority, not just the rule text.
if ! ip rule show | grep -q '^40:.*fwmark 0x80000/0xff0000 lookup main'; then
  ip rule add fwmark 0x80000/0xff0000 lookup main priority 40 2>/dev/null || true
fi
# Exit traffic: into the VPN table 51820.
if ! ip rule show | grep -q 'iif tailscale0 lookup 51820'; then
  ip rule add iif tailscale0 table 51820 priority 50 2>/dev/null || true
fi

# Return path for Tailscale CGNAT
ip route replace 100.64.0.0/10 dev tailscale0 2>/dev/null || true
ip route replace 100.64.0.0/10 dev tailscale0 table 199 2>/dev/null || true

# Apply on both stacks; Gluetun mainly uses iptables-legacy
for ipt in iptables-legacy iptables; do
  command -v "$ipt" >/dev/null 2>&1 || continue

  # Kill switch: nothing forwards except tailscale0 <-> tun0.
  $ipt -P FORWARD DROP 2>/dev/null || true

  $ipt -C FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
    || $ipt -I FORWARD 1 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

  $ipt -C FORWARD -i tailscale0 -o tun0 -j ACCEPT 2>/dev/null \
    || $ipt -I FORWARD 1 -i tailscale0 -o tun0 -j ACCEPT 2>/dev/null || true

  $ipt -C FORWARD -i tun0 -o tailscale0 -j ACCEPT 2>/dev/null \
    || $ipt -I FORWARD 1 -i tun0 -o tailscale0 -j ACCEPT 2>/dev/null || true

  # Gluetun's OUTPUT allows only tun0 (+ VPN endpoint). Let tailscaled's
  # marked underlay out eth0; nothing else.
  $ipt -C OUTPUT -o eth0 -m mark --mark 0x80000/0xff0000 -j ACCEPT 2>/dev/null \
    || $ipt -I OUTPUT 1 -o eth0 -m mark --mark 0x80000/0xff0000 -j ACCEPT 2>/dev/null || true

  $ipt -t nat -C POSTROUTING -o tun0 -j MASQUERADE 2>/dev/null \
    || $ipt -t nat -A POSTROUTING -o tun0 -j MASQUERADE 2>/dev/null || true

  $ipt -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
    || $ipt -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

  $ipt -t mangle -C OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
    || $ipt -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
done

echo "apply-exit-fix ok $(date -Iseconds 2>/dev/null || date)"
