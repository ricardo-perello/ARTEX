#!/usr/bin/env bash
# Egress firewall for a VM that runs ARTEX (fork hardening, see HARDENING.md).
#
# The agent's shell can try any address the VM can route to. Behind NAT that
# includes the host machine, its LAN and any VPN the host is connected to. This
# script limits what leaves the VM's uplink interface:
#
#   allowed   DNS (and DHCP) to the VM's own gateway
#   allowed   public IPv4 addresses
#   rejected  private, CGNAT (Tailscale), link-local, multicast and broadcast IPv4
#   rejected  all IPv6
#
# Traffic that stays inside the VM (loopback, Docker bridges) is not touched, so
# containers still reach each other and a lab target in the same VM.
#
# The rules sit on both the output and the forward hook: Docker containers leave
# through the forward path, the VM's own processes through output.
#
# Usage (as root, inside the VM, after the network is up and BEFORE starting ARTEX):
#   scripts/vm-egress-firewall.sh           apply, persist across reboots, self-test
#   scripts/vm-egress-firewall.sh --check   self-test only
#
# Run it again if the VM's uplink interface or gateway changes.
set -euo pipefail

info() { printf '[*] %s\n' "$*"; }
ok()   { printf '[+] %s\n' "$*"; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (sudo $0)"
command -v nft >/dev/null 2>&1 || die "nft not found (apt-get install nftables)"
command -v ip >/dev/null 2>&1 || die "ip not found (apt-get install iproute2)"

UPLINK="$(ip -4 route show default | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}')"
GATEWAY="$(ip -4 route show default | awk '{for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit }}')"
[ -n "$UPLINK" ] || die "no IPv4 default route: bring the network up first"
[ -n "$GATEWAY" ] || die "the default route has no gateway address"
case "$UPLINK" in (*[!A-Za-z0-9_.-]*) die "unexpected interface name: $UPLINK" ;; esac
case "$GATEWAY" in (*[!0-9.]*) die "unexpected gateway address: $GATEWAY" ;; esac

# connects HOST PORT: succeeds when a TCP connection opens within 3 seconds.
connects() { timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }

# rejected_packets prints the packet counter of the IPv4 reject rule.
rejected_packets() {
  nft list chain inet artex_egress uplink | awk '/@blocked4 counter packets/ { print $6; exit }'
}

self_test() {
  local failed=0 addr before after
  nft list table inet artex_egress >/dev/null 2>&1 || die "table inet artex_egress is not loaded"
  before="$(rejected_packets)"
  for addr in "$GATEWAY:22" "$GATEWAY:445" 10.0.0.1:80 100.100.100.100:80 192.168.1.1:80 169.254.169.254:80; do
    if connects "${addr%:*}" "${addr#*:}"; then
      printf '[x] reached %s, which must be blocked\n' "$addr" >&2
      failed=1
    fi
  done
  # Not connecting is not proof on its own (the address may simply be down), so
  # also require that the reject rule counted the probes.
  after="$(rejected_packets)"
  if [ "${after:-0}" -le "${before:-0}" ]; then
    printf '[x] the reject rule did not count the probes (%s -> %s)\n' "${before:-?}" "${after:-?}" >&2
    failed=1
  fi
  [ "$failed" = 0 ] && ok "private, CGNAT and link-local destinations are blocked"
  if connects 1.1.1.1 443; then
    ok "public internet is reachable"
  else
    printf '[!] could not reach 1.1.1.1:443 (no internet access, or blocked upstream)\n' >&2
  fi
  [ "$failed" = 0 ] || die "self-test failed"
}

if [ "${1:-}" = "--check" ]; then
  self_test
  exit 0
fi
[ "$#" = 0 ] || die "unknown argument: $1 (only --check is accepted)"

info "uplink $UPLINK, gateway $GATEWAY"
umask 022
cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
# Written by ARTEX scripts/vm-egress-firewall.sh. Do not add "flush ruleset":
# it would also remove the rules Docker manages.
table inet artex_egress
delete table inet artex_egress

table inet artex_egress {
	set blocked4 {
		type ipv4_addr
		flags interval
		elements = { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16,
			     172.16.0.0/12, 192.168.0.0/16, 198.18.0.0/15,
			     224.0.0.0/4, 240.0.0.0/4 }
	}

	chain uplink {
		ct state established,related accept
		ip daddr $GATEWAY udp dport { 53, 67 } accept
		ip daddr $GATEWAY tcp dport 53 accept
		udp sport 68 udp dport 67 accept
		ip daddr @blocked4 counter reject with icmp type admin-prohibited
		meta nfproto ipv6 counter reject with icmpv6 type admin-prohibited
	}

	chain output {
		type filter hook output priority filter; policy accept;
		oifname "$UPLINK" jump uplink
	}

	chain forward {
		type filter hook forward priority filter; policy accept;
		oifname "$UPLINK" jump uplink
	}
}
EOF
chmod 0644 /etc/nftables.conf
nft -c -f /etc/nftables.conf || die "generated ruleset does not parse"
nft -f /etc/nftables.conf
ok "rules loaded"

if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  systemctl enable nftables.service >/dev/null 2>&1 || die "could not enable nftables.service"
  ok "nftables.service enabled: the rules load at boot, before the network comes up"
else
  printf '[!] no systemd: the rules are loaded now but will not survive a reboot\n' >&2
fi

self_test
