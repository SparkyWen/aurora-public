#!/usr/bin/env bash
#
# Redirect a UDP port range to this node's Hysteria2 port, so clients can hop across
# destination ports. Optional, Linux only, and independent of install.sh.
#
#   sudo bash deploy/extras/hy2-port-hopping.sh --range 20000-29999
#   sudo bash deploy/extras/hy2-port-hopping.sh --uninstall
#   bash deploy/extras/hy2-port-hopping.sh --range 20000-29999 --dry-run
#
# Why hop at all: some carriers throttle UDP per flow. In one side-by-side test on such
# a network, a client keeping its 5-tuple for 240 s moved 2.5 MB with 30 s stalls, while
# one changing it every 10 s moved 97.5 MB and never stalled for more than 1.2 s. The
# client opens a fresh UDP socket every hop_interval and sends to a random port from
# server_ports; the server follows the new address at once, because sing-quic disables
# quic-go's path validation for this.
#
# You may not need this script. Links from install.sh already hop the SOURCE port
# against the one known-open port ("443:443"), which needs no server change and gives
# every hop a new flow. A destination range only helps if a network also targets the
# destination port.
#
# WARNING: never advertise a range you have not verified from OUTSIDE. The client hops
# blindly, with no health check. Many cloud providers run a firewall in front of the VM,
# where a blocked packet never reaches the NIC, so nothing on this machine can tell you
# whether the range is open. One blocked port in server_ports is a periodic outage, and
# a blocked range is a dead leg. This script only installs the redirect: it never
# changes what clients are told, and it prints how to verify and advertise the range.
#
# nftables only: the redirect lives in its own table, and a host firewall such as ufw
# needs no new rule because it sees the post-NAT port.
set -euo pipefail

NODE_ENV="${AURORA_NODE_ENV:-/etc/aurora-node/node.env}"
NFT_TABLE=aurora_hy2_hop
NFT_FILE=/etc/aurora-hy2-hop.nft
UNIT_NAME=aurora-hy2-hop.service
UNIT_FILE="/etc/systemd/system/$UNIT_NAME"
# tailscaled takes new inbound peer packets on this port. Redirecting it would cut any
# tailnet path running through this machine.
TAILSCALE_PORT=41641

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: hy2-port-hopping.sh --range <start-end> [--dry-run]
       hy2-port-hopping.sh --uninstall [--dry-run]

  --range <start-end>  UDP ports to redirect, for example 20000-29999
  --uninstall          Remove the redirect
  --dry-run            Print the plan and the verification steps, change nothing
  -h, --help           Show this help

The target port is read from S_HY2_PORT in /etc/aurora-node/node.env.
USAGE
}

# One value, not `source`: this file holds every credential of the node, and none of
# them should enter this script's environment.
state_value() {
  sed -n "s/^$1='\([0-9]*\)'\$/\1/p" "$NODE_ENV" | head -n 1
}

covers() {
  [[ -n "$3" ]] && ((10#$1 <= 10#$3 && 10#$3 <= 10#$2))
}

parse_range() {
  [[ "$1" =~ ^([0-9]{4,5})-([0-9]{4,5})$ ]] || die "--range must look like 20000-29999, got: $1"
  HOP_START="${BASH_REMATCH[1]}"
  HOP_END="${BASH_REMATCH[2]}"
  ((10#$HOP_START >= 1024 && 10#$HOP_START <= 10#$HOP_END && 10#$HOP_END <= 65535)) ||
    die "--range must be ascending and within 1024-65535"
  covers "$HOP_START" "$HOP_END" "$TAILSCALE_PORT" &&
    die "--range must not cover Tailscale's port $TAILSCALE_PORT/udp"
  return 0
}

read_node_ports() {
  [[ -r "$NODE_ENV" ]] || die "cannot read $NODE_ENV. Install a node with install.sh first."
  HY2_PORT="$(state_value S_HY2_PORT)"
  [[ "$HY2_PORT" =~ ^[0-9]+$ ]] && ((HY2_PORT >= 1 && HY2_PORT <= 65535)) ||
    die "no valid S_HY2_PORT in $NODE_ENV"
  covers "$HOP_START" "$HOP_END" "$HY2_PORT" &&
    die "--range must not cover the Hysteria2 port $HY2_PORT itself"
  # Shadowsocks also listens on UDP, so redirecting its port would break it.
  covers "$HOP_START" "$HOP_END" "$(state_value S_SS_PORT)" &&
    die "--range must not cover this node's Shadowsocks port"
  return 0
}

render_nft() {
  cat <<NFT
table inet $NFT_TABLE
flush table inet $NFT_TABLE
table inet $NFT_TABLE {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    udp dport $HOP_START-$HOP_END redirect to :$HY2_PORT
  }
}
NFT
}

render_unit() {
  local nft_bin="$1"
  cat <<UNIT
[Unit]
Description=Aurora Hysteria2 port-hopping redirect
Wants=network-pre.target
After=network-pre.target nftables.service
Before=aurora-node.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$nft_bin -f $NFT_FILE
ExecStop=$nft_bin delete table inet $NFT_TABLE

[Install]
WantedBy=multi-user.target
UNIT
}

print_verification() {
  cat <<VERIFY

Clients are still NOT using this range. Verify it from OUTSIDE before advertising it.

1. Open UDP $HOP_START-$HOP_END in your cloud provider's firewall or security group, if it
   has one.

2. On this server, capture on the public interface (find it with: ip route get 1.1.1.1):

     sudo tcpdump -ni eth0 'udp and portrange $HOP_START-$HOP_END'

3. On a machine OUTSIDE this provider's network, send to several ports across the range:

     for p in $HOP_START $(((10#$HOP_START + 10#$HOP_END) / 2)) $HOP_END; do
       printf probe | nc -u -w1 YOUR_SERVER_ADDRESS "\$p"
     done

   Probing from this server or from the same cloud network proves nothing: that traffic
   may never cross the firewall you are testing.

4. Every port you probed must appear in the capture. A missing one never reached this
   machine, so the range is blocked: do not advertise it. Hysteria2 will not answer a
   plain probe, and that is expected. The capture is the test.

5. Only then advertise it. In your contract, set this on the Hysteria2 node's params:

     "server_ports": ["$HY2_PORT:$HY2_PORT", "$HOP_START:$HOP_END"],
     "hop_interval": "10s"

   Then import the whole contract in the app, or publish it through your control plane
   (control-plane/README.md). Re-importing the install.sh link for this server resets
   server_ports, so apply the change again afterwards.

Remove the redirect with: sudo bash $0 --uninstall
VERIFY
}

do_uninstall() {
  if ((DRY_RUN)); then
    printf 'PLAN stop-and-remove=%s\n' "$UNIT_FILE"
    printf 'PLAN remove=%s\n' "$NFT_FILE"
    printf 'PLAN delete-nft-table=inet/%s\n' "$NFT_TABLE"
    return 0
  fi
  require_system
  systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
  # The unit may be gone or broken; the rule must still not outlive this command.
  nft delete table inet "$NFT_TABLE" >/dev/null 2>&1 || true
  rm -f "$UNIT_FILE" "$NFT_FILE"
  systemctl daemon-reload
  printf 'Removed the redirect. If you advertised the range, remove it from your contract\n'
  printf 'first: clients hopping onto these ports now reach nothing.\n'
}

do_install() {
  read_node_ports
  if ((DRY_RUN)); then
    printf 'PLAN redirect=udp/%s-%s->%s nft-table=inet/%s\n' "$HOP_START" "$HOP_END" "$HY2_PORT" "$NFT_TABLE"
    printf 'PLAN nft-file=%s\n' "$NFT_FILE"
    printf 'PLAN unit=%s\n' "$UNIT_FILE"
    render_nft
    print_verification
    return 0
  fi
  require_system
  local stage nft_bin
  nft_bin="$(command -v nft)"
  stage="$(mktemp)"
  render_nft >"$stage"
  # A bad ruleset must not get as far as the boot sequence.
  nft -c -f "$stage" || {
    rm -f "$stage"
    die "nft rejected the generated ruleset"
  }
  install -m 0644 "$stage" "$NFT_FILE"
  rm -f "$stage"
  render_unit "$nft_bin" >"$UNIT_FILE"
  chmod 0644 "$UNIT_FILE"
  systemctl daemon-reload
  systemctl enable "$UNIT_NAME" >/dev/null
  # restart, not start: a rerun with a new range must reload the table.
  systemctl restart "$UNIT_NAME"
  nft list table inet "$NFT_TABLE" | grep -q "udp dport $HOP_START-$HOP_END redirect to :$HY2_PORT" ||
    die "the redirect rule did not load"
  printf 'Redirect active: udp/%s-%s -> %s.\n' "$HOP_START" "$HOP_END" "$HY2_PORT"
  printf 'If the Hysteria2 port ever changes, run this script again.\n'
  print_verification
}

require_system() {
  [[ "$(uname -s)" == Linux ]] || die "this needs Linux and nftables"
  [[ "$(id -u)" -eq 0 ]] || die "run as root"
  local command
  for command in nft systemctl install; do
    command -v "$command" >/dev/null 2>&1 || die "missing required command: $command"
  done
}

main() {
  local range='' uninstall=0
  DRY_RUN=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --range)
        [[ $# -ge 2 ]] || die "--range needs a value such as 20000-29999"
        range="$2"
        shift 2
        ;;
      --uninstall) uninstall=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      -h | --help) usage; exit 0 ;;
      *) usage >&2; exit 64 ;;
    esac
  done
  if ((uninstall)); then
    [[ -z "$range" ]] || die "--uninstall takes no range"
    do_uninstall
    return 0
  fi
  [[ -n "$range" ]] || { usage >&2; exit 64; }
  parse_range "$range"
  do_install
}

main "$@"
