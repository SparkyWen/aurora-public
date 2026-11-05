#!/usr/bin/env bash
#
# The whole user journey on a clean Linux machine, with nothing mocked that can be real:
# the README's install command from the public URL, the released .deb, real systemd units,
# a real TUN device, and a real UPnP router.
#
# A runner has one public IP and accepts no inbound traffic, so this builds a small internet
# out of network namespaces, all routed through the host:
#
#   client ------+
#   relay  ------+-- host --(NAT)--> the real internet
#   router ------+
#     \-- home (a LAN behind the router, reachable only through its port forwards)
#
# Egress is always the runner's one real IP, so an IP check alone cannot tell a tunnel from
# a leak. The proof is isolation instead: the client's direct route to the internet is
# blocked, and only the node's ports are open. Then a working `curl` can only have gone
# through the tunnel, and the drop counter shows whether anything tried to go around it.
#
# Destructive: it reconfigures the machine's firewall and DNS. Only run it on a throwaway
# machine, as root:
#
#   sudo bash deploy/test/full-flow-linux.sh vps|home|gui|delivery /path/to/aurora.deb
set -uo pipefail

SCENARIO="${1:?usage: full-flow-linux.sh vps|home|gui|delivery /path/to/aurora.deb}"
DEB="${2:?usage: full-flow-linux.sh vps|home|gui|delivery /path/to/aurora.deb}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RAW_URL="https://raw.githubusercontent.com/SparkyWen/aurora-public/main/install.sh"
OUT="${FULL_FLOW_OUT:-/tmp/full-flow}"
mkdir -p "$OUT"
DESKTOP_USER="${SUDO_USER:-runner}"

GATEWAY=198.51.100.1
CLIENT_IP=198.51.100.30
RELAY_IP=198.51.100.20
EDGE_IP=198.51.100.40
LAN_ROUTER=192.168.77.1
LAN_HOME=192.168.77.10
WORK="$(mktemp -d)"
# dnsmasq and nginx workers drop privileges and still have to read what is in here.
chmod 755 "$WORK"
export DEBIAN_FRONTEND=noninteractive

PASS=0
FAIL=0
section() { printf '\n=== %s\n' "$1"; }
pass() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check() {
  local name="$1"
  shift
  if "$@" >>"$OUT/checks.log" 2>&1; then pass "$name"; else fail "$name"; fi
}
log_has() { grep -qF -- "$2" "$1"; }
log_lacks() { ! grep -qF -- "$2" "$1"; }

# ---------------------------------------------------------------------------
# The small internet
# ---------------------------------------------------------------------------

world_up() {
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq dnsmasq-base >/dev/null 2>&1
  UPLINK="$(ip -4 route get 1.1.1.1 | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n 1)"
  sysctl -qw net.ipv4.ip_forward=1 net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.default.rp_filter=0
  ip addr add "$GATEWAY/32" dev lo

  iptables -t nat -A POSTROUTING -o "$UPLINK" -j MASQUERADE
  iptables -N WORLD
  iptables -I FORWARD 1 -j WORLD
  # Home routers have no cloud metadata service. It would make a home look like a VPS.
  iptables -A WORLD -d 169.254.169.254 -j REJECT
  for chain in CLIENT RELAY; do
    iptables -N "$chain"
    iptables -A "$chain" -j ACCEPT
  done
  iptables -A WORLD -s "$CLIENT_IP" -j CLIENT
  iptables -I INPUT 1 -s "$CLIENT_IP" -j CLIENT
  iptables -A WORLD -s "$RELAY_IP" -j RELAY
  iptables -A WORLD -j ACCEPT
  # The app looks up server names at a fixed public resolver before the tunnel exists. The
  # test's names are not on the public internet, so that address answers from dnsmasq here.
  iptables -t nat -A PREROUTING -s "$CLIENT_IP" -d 223.5.5.5 -p udp --dport 53 -j DNAT --to-destination "$GATEWAY:53"

  # dnsmasq answers the test's own names and forwards the rest, on the host only.
  cat >"$WORK/dnsmasq.conf" <<EOF
no-resolv
server=1.1.1.1
server=8.8.8.8
listen-address=$GATEWAY
bind-interfaces
addn-hosts=$WORK/hosts
pid-file=$WORK/dnsmasq.pid
EOF
  : >"$WORK/hosts"
  dnsmasq --conf-file="$WORK/dnsmasq.conf"
  # A plain resolv.conf, because systemd-resolved's 127.0.0.53 does not exist inside a namespace.
  rm -f /etc/resolv.conf
  printf 'nameserver %s\n' "$GATEWAY" >/etc/resolv.conf
}

add_namespace() {
  local ns="$1" address="$2" host_side="v-$1"
  ip netns add "$ns"
  ip link add "$host_side" type veth peer name eth0 netns "$ns"
  ip link set "$host_side" up
  sysctl -qw "net.ipv4.conf.$host_side.rp_filter=0"
  ip addr add "$GATEWAY/32" dev "$host_side"
  ip route add "$address/32" dev "$host_side" src "$GATEWAY"
  ip netns exec "$ns" sysctl -qw net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.default.rp_filter=0
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip link set eth0 up
  ip netns exec "$ns" ip addr add "$address/32" dev eth0
  ip netns exec "$ns" ip route add "$GATEWAY/32" dev eth0
  ip netns exec "$ns" ip route add default via "$GATEWAY" dev eth0 onlink
}

# Runs a unit inside a namespace. The only departure from a real machine: nothing in the
# unit itself changes, and the drop-in has to exist before the unit first starts.
service_in_namespace() {
  local unit="$1" ns="$2"
  mkdir -p "/etc/systemd/system/$unit.service.d"
  printf '[Service]\nNetworkNamespacePath=/run/netns/%s\n' "$ns" >"/etc/systemd/system/$unit.service.d/netns.conf"
  systemctl daemon-reload
}

# Each argument is ip:proto:port. Everything else from the client is dropped and counted.
client_allow() {
  iptables -F CLIENT
  local spec ip proto port
  for spec in "$@"; do
    IFS=: read -r ip proto port <<<"$spec"
    iptables -A CLIENT -d "$ip" -p "$proto" --dport "$port" -j ACCEPT
  done
  iptables -A CLIENT -j DROP
}

leaked_packets() {
  iptables -L CLIENT -vnx | awk '$3 == "DROP" { print $1 }'
}

# Issues <prefix>.crt and <prefix>.key for the given names, under a throwaway CA that this
# machine trusts for the duration of the test.
issue_cert() {
  local prefix="$1" first="$2" san="" name
  shift
  for name in "$@"; do san="$san,DNS:$name"; done
  if [[ ! -f "$WORK/ca.crt" ]]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=Aurora Test CA" \
      -keyout "$WORK/ca.key" -out "$WORK/ca.crt" 2>/dev/null
    install -m 0644 "$WORK/ca.crt" /usr/local/share/ca-certificates/aurora-test.crt
    update-ca-certificates >/dev/null 2>&1
  fi
  openssl req -newkey rsa:2048 -nodes -subj "/CN=$first" -keyout "$WORK/$prefix.key" -out "$WORK/$prefix.csr" 2>/dev/null
  printf 'subjectAltName=%s\n' "${san#,}" >"$WORK/$prefix.ext"
  openssl x509 -req -in "$WORK/$prefix.csr" -CA "$WORK/ca.crt" -CAkey "$WORK/ca.key" -CAcreateserial -days 2 \
    -extfile "$WORK/$prefix.ext" -out "$WORK/$prefix.crt" 2>/dev/null
}

add_name() {
  printf '%s %s\n' "$1" "$2" >>"$WORK/hosts"
  kill -HUP "$(cat "$WORK/dnsmasq.pid")"
  sleep 1
}

# ---------------------------------------------------------------------------
# The client, exactly as a user runs it
# ---------------------------------------------------------------------------

client_install() {
  apt-get install -y -qq "$DEB" >"$OUT/apt-deb.log" 2>&1
  check "the .deb installs on a clean machine" test -x /usr/bin/aurora
  check "the .deb's service starts by itself" systemctl is-active aurora-svc
  add_namespace client "$CLIENT_IP"
  service_in_namespace aurora-svc client
  systemctl restart aurora-svc
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    ip netns exec client ss -ltn 2>/dev/null | grep -q 53421 && break
    sleep 1
  done
}

aurora() {
  ip netns exec client sudo -u "$DESKTOP_USER" env HOME="/home/$DESKTOP_USER" /usr/bin/aurora "$@"
}

client_curl() {
  local url
  for url in https://api.ipify.org https://checkip.amazonaws.com https://ipv4.icanhazip.com; do
    ip netns exec client curl -4 -fsS --max-time 12 "$url" 2>>"$OUT/client-curl.log" | tr -d '[:space:]' && return 0
  done
  return 1
}

# Passes once real HTTPS through the tunnel exits from the expected address.
egress_within() {
  local seconds="$1" expected="$2" deadline got
  deadline=$((SECONDS + seconds))
  while ((SECONDS < deadline)); do
    got="$(client_curl || true)"
    if [[ "$got" == "$expected" ]]; then
      printf '%s' "$got"
      return 0
    fi
    sleep 2
  done
  return 1
}

no_direct_internet() {
  ! ip netns exec client curl -4 -fsS --max-time 6 https://1.1.1.1/cdn-cgi/trace >/dev/null 2>&1
}

tunnel_up() { ip netns exec client ip link show aurora0 >/dev/null 2>&1; }
tunnel_gone() { ! tunnel_up; }

connect_and_prove() {
  local label="$1" expected="$2"
  shift 2
  local started
  iptables -Z CLIENT
  if aurora connect "$@" >"$OUT/connect-$label.log" 2>&1; then
    pass "$label: aurora connect succeeds"
  else
    fail "$label: aurora connect failed: $(tail -n 2 "$OUT/connect-$label.log" | tr '\n' ' ')"
    systemctl status aurora-svc --no-pager >>"$OUT/connect-$label.log" 2>&1
    return 1
  fi
  check "$label: the TUN device exists" tunnel_up
  started=$SECONDS
  if egress_within 45 "$expected" >/dev/null; then
    pass "$label: real HTTPS exits from $expected through the tunnel ($((SECONDS - started))s)"
  else
    fail "$label: no traffic through the tunnel; got '$(client_curl || true)'"
    aurora status >>"$OUT/connect-$label.log" 2>&1
    return 1
  fi
}

disconnect_and_prove() {
  local label="$1"
  aurora disconnect >"$OUT/disconnect-$label.log" 2>&1
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    tunnel_gone && break
    sleep 1
  done
  check "$label: disconnect removes the TUN device" tunnel_gone
  check "$label: traffic stops after disconnect" no_direct_internet
}

# ---------------------------------------------------------------------------
# VPS: the README's command, then every protocol, failover, rotation, removal, CDN
# ---------------------------------------------------------------------------

readme_install() {
  local log="$1"
  shift
  curl -fsSL "$RAW_URL" | bash -s -- "$@" 2>&1 | tee "$log"
  return "${PIPESTATUS[1]}"
}

link_from() { grep -Eo 'aurora://v1/[A-Za-z0-9_-]+#[a-z0-9-]+' "$1" | head -n 1; }

run_vps() {
  section "README command on a clean machine, no flags"
  local log="$OUT/install-vps.log" link public
  # The bare form, piped into plain bash as under `| sudo bash`. No -s and no arguments.
  curl -fsSL "$RAW_URL" | bash 2>&1 | tee "$log"
  local status="${PIPESTATUS[1]}"
  check "the install exits 0" test "$status" = 0
  check "it recognizes a cloud machine by itself" log_has "$log" "Detected a vps environment"
  for protocol in reality hy2 ss; do
    check "its self-test passes: $protocol" log_has "$log" "$protocol carries traffic"
  done
  link="$(link_from "$log")"
  check "it prints a link" test -n "$link"
  check "it prints a QR code" log_has "$log" "█"
  check "the management command is installed" test -x /usr/local/bin/aurora-node
  check "aurora-node link agrees with what was printed" test "$(aurora-node link | grep -Eo 'aurora://v1/[A-Za-z0-9_-]+#[a-z0-9-]+' | head -n 1)" = "$link"

  section "The QR code a camera would see"
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq zbar-tools >/dev/null 2>&1
  qrencode -t PNG -m 1 -s 6 -o "$OUT/qr.png" "$link"
  check "the QR code decodes back to exactly the link" test "$(zbarimg -q --raw "$OUT/qr.png" 2>/dev/null)" = "$link"
  local width
  width=$(($(qrencode -t ASCII -m 1 "$link" | sed -n 1p | wc -c) / 2))
  printf 'QR code width: %s columns\n' "$width"
  check "the QR code fits an 80-column terminal ($width)" test "$width" -le 80

  public="$(aurora-node status | sed -n 's/^ *Address: *//p' | head -n 1)"
  [[ -n "$public" ]] || public="$(curl -fsS4 https://api.ipify.org)"
  # The world goes up after the install, so the install above saw the real, untouched network.
  world_up
  ip addr add "$public/32" dev lo
  client_install
  # Only the node. Not even DNS: the tunnel has to carry that too.
  client_allow "$public:tcp:443" "$public:udp:443" "$public:tcp:8443"

  section "Add the server and connect"
  check "the client starts blocked from the internet" no_direct_internet
  local servers
  servers="$(aurora servers 2>&1)"
  check "no servers yet, and it says what to do" grep -q 'aurora import' <<<"$servers"
  check "aurora import takes the link" aurora import "$link"
  servers="$(aurora servers 2>&1)"
  printf '%s\n' "$servers"
  check "the server is listed" grep -q "^vps  $public" <<<"$servers"

  connect_and_prove "default" "$public"
  check "the tunnel sent nothing around itself" test "$(leaked_packets)" = 0
  printf 'packets dropped while connected: %s\n' "$(leaked_packets)"
  local state
  state="$(aurora status --json 2>&1)"
  printf '%s\n' "$state"
  check "aurora status reports connected" grep -q '"state":"connected"' <<<"$state"
  disconnect_and_prove "default"

  section "Each protocol alone, as when a network blocks the others"
  connect_and_prove_only() {
    local label="$1"
    shift
    client_allow "$@"
    connect_and_prove "$label" "$public"
    disconnect_and_prove "$label"
  }
  connect_and_prove_only "reality-only" "$public:tcp:443"
  connect_and_prove_only "hysteria2-only" "$public:udp:443"
  connect_and_prove_only "shadowsocks-only" "$public:tcp:8443"

  section "Smart mode"
  client_allow "$public:tcp:443" "$public:udp:443" "$public:tcp:8443"
  connect_and_prove "smart" "$public" --mode smart
  disconnect_and_prove "smart"

  section "Failover: the protocol in use gets blocked mid-session"
  connect_and_prove "failover" "$public"
  # Block both of the protocols that could be in use and leave one, whichever was chosen.
  local started=$SECONDS
  client_allow "$public:tcp:8443"
  if egress_within 180 "$public" >/dev/null; then
    pass "traffic comes back through the remaining protocol after $((SECONDS - started))s"
  else
    fail "traffic did not recover within 180s after blocking two protocols"
  fi
  disconnect_and_prove "failover"
  client_allow "$public:tcp:443" "$public:udp:443" "$public:tcp:8443"

  section "Rotating keys"
  aurora-node rotate >"$OUT/rotate.log" 2>&1
  check "aurora-node rotate succeeds" test "$?" = 0
  local new_link
  new_link="$(link_from "$OUT/rotate.log")"
  check "rotation produces a different link" test "$new_link" != "$link"
  iptables -Z CLIENT
  aurora connect >"$OUT/connect-stale.log" 2>&1
  if egress_within 15 "$public" >/dev/null; then
    fail "the old keys still work after rotation"
  else
    pass "the old keys stop working after rotation"
  fi
  aurora disconnect >/dev/null 2>&1
  check "re-importing the new link is accepted" aurora import "$new_link"
  servers="$(aurora servers 2>&1)"
  check "importing the same server replaces it" test "$(grep -c '^vps ' <<<"$servers")" = 1
  connect_and_prove "rotated" "$public"
  disconnect_and_prove "rotated"

  section "Removing a server"
  check "aurora remove succeeds" aurora remove vps
  servers="$(aurora servers 2>&1)"
  check "the server is gone" grep -q 'No servers yet' <<<"$servers"
  aurora connect >"$OUT/connect-empty.log" 2>&1
  check "connecting with no servers fails" test "$?" != 0
  check "and says what to do" log_has "$OUT/connect-empty.log" "aurora import"
  check "connecting with no servers leaves no tunnel" tunnel_gone

  section "CDN fronting: the server's own address is blocked outright"
  aurora-node uninstall --purge >"$OUT/uninstall-vps.log" 2>&1
  check "uninstall removes the node" test ! -e /etc/aurora-node
  run_cdn "$public"

  section "Uninstall leaves nothing behind"
  aurora-node uninstall --purge >>"$OUT/uninstall-vps.log" 2>&1
  check "no config" test ! -e /etc/aurora-node
  check "no binary" test ! -e /usr/local/lib/aurora-node
  check "no command" test ! -e /usr/local/bin/aurora-node
  check "no unit" test ! -e /etc/systemd/system/aurora-node.service
  check "no timer" test ! -e /etc/systemd/system/aurora-node-maintain.timer
  check "no service user" bash -c '! id aurora-node'
}

# A local stand-in for Cloudflare: it terminates TLS under a CA the machine trusts for the
# test, and proxies the WebSocket to the origin over TLS without verifying it, which is what
# the SSL mode the docs ask for ("Full") does. Everything on the client is what a user runs.
run_cdn() {
  local public="$1" domain=cdn.aurora.test log="$OUT/install-cdn.log" link
  readme_install "$log" --name cdn1 --cdn-domain "$domain"
  check "the install with --cdn-domain exits 0" test "$?" = 0
  link="$(link_from "$log")"

  apt-get install -y -qq nginx >/dev/null 2>&1
  systemctl stop nginx 2>/dev/null
  add_namespace edge "$EDGE_IP"
  issue_cert edge "$domain"
  cat >"$WORK/nginx.conf" <<EOF
pid $WORK/nginx.pid;
error_log $OUT/nginx-error.log;
events {}
http {
  access_log $OUT/nginx-access.log;
  map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
  server {
    listen 2083 ssl;
    server_name $domain;
    ssl_certificate $WORK/edge.crt;
    ssl_certificate_key $WORK/edge.key;
    location / {
      proxy_pass https://$public:2083;
      proxy_http_version 1.1;
      proxy_ssl_server_name on;
      proxy_ssl_name $domain;
      proxy_ssl_verify off;
      proxy_set_header Host \$host;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection \$connection_upgrade;
      proxy_read_timeout 300s;
    }
  }
}
EOF
  ip netns exec edge nginx -c "$WORK/nginx.conf" 2>"$OUT/nginx-start.log"
  add_name "$EDGE_IP" "$domain"

  # The CDN name has to resolve before the tunnel exists, so DNS stays reachable here.
  client_allow "$EDGE_IP:tcp:2083" "$GATEWAY:udp:53"
  check "aurora import takes the CDN link" aurora import "$link"
  # Every direct protocol is unreachable, so only the CDN leg can possibly carry this.
  connect_and_prove "cdn" "$public"
  check "the requests really crossed the stand-in CDN" test -s "$OUT/nginx-access.log"
  disconnect_and_prove "cdn"
  aurora remove cdn1 >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Home: a real UPnP router, a home node behind it, a relay in front, CGNAT, DDNS
# ---------------------------------------------------------------------------

router_up() {
  local wan="$1"
  add_namespace router "$wan"
  ip netns add home
  ip link add lan0 netns router type veth peer name eth0 netns home
  ip netns exec router ip addr add "$LAN_ROUTER/24" dev lan0
  ip netns exec router ip link set lan0 up
  ip netns exec router sysctl -qw net.ipv4.ip_forward=1
  ip netns exec router iptables -t nat -A POSTROUTING -o eth0 -s 192.168.77.0/24 -j MASQUERADE
  ip netns exec home ip link set lo up
  ip netns exec home ip link set eth0 up
  ip netns exec home ip addr add "$LAN_HOME/24" dev eth0
  ip netns exec home ip route add default via "$LAN_ROUTER"
  # SSDP is multicast: discovery reaches the router only with this route on the LAN.
  ip netns exec home ip route add 239.255.255.250/32 dev eth0
  ip netns exec router ip route add 239.255.255.250/32 dev lan0
}

upnp_start() {
  # The chains are this script's own instead of the package's nft_init.sh, whose forward chain
  # drops by default, which would need a firewall the test has no other use for.
  ip netns exec router nft list table inet filter >/dev/null 2>&1 || ip netns exec router nft -f - <<'EOF'
table inet filter {
  chain miniupnpd {}
  chain prerouting_miniupnpd {}
  chain postrouting_miniupnpd {}
  chain forward { type filter hook forward priority 0; policy accept; jump miniupnpd; }
  chain prerouting { type nat hook prerouting priority -100; policy accept; jump prerouting_miniupnpd; }
  chain postrouting { type nat hook postrouting priority 100; policy accept; jump postrouting_miniupnpd; }
}
EOF
  cat >"$WORK/miniupnpd.conf" <<EOF
ext_ifname=eth0
upnp_table_name=filter
upnp_nat_table_name=filter
upnp_forward_chain=miniupnpd
upnp_nat_chain=prerouting_miniupnpd
upnp_nat_postrouting_chain=postrouting_miniupnpd
listening_ip=lan0
http_port=5000
enable_upnp=yes
enable_natpmp=no
secure_mode=yes
system_uptime=yes
uuid=00000000-0000-4000-8000-00000000a0a0
allow 1024-65535 192.168.77.0/24 1024-65535
deny 0-65535 0.0.0.0/0 0-65535
EOF
  ip netns exec router miniupnpd -f "$WORK/miniupnpd.conf" -P "$WORK/miniupnpd.pid" -d >"$OUT/miniupnpd.log" 2>&1 &
  sleep 2
}

upnp_stop() {
  [[ -f "$WORK/miniupnpd.pid" ]] && kill "$(cat "$WORK/miniupnpd.pid")" 2>/dev/null
  pkill -f "miniupnpd -f $WORK" 2>/dev/null
  sleep 1
}

router_forwards() {
  ip netns exec router nft list chain inet filter prerouting_miniupnpd 2>/dev/null | grep -c "dnat.*$LAN_HOME" || true
}

node_cmd() { ip netns exec home aurora-node "$@"; }

# A purge may take the namespace drop-in with it, so put it back for the next install.
home_purge() {
  node_cmd uninstall --purge >>"$OUT/uninstall-home.log" 2>&1
  local status=$?
  service_in_namespace aurora-node home
  return "$status"
}

home_install() {
  local log="$1"
  shift
  ip netns exec home bash -c 'curl -fsSL "$1" | bash -s -- "${@:2}"' _ "$RAW_URL" "$@" 2>&1 | tee "$log"
  return "${PIPESTATUS[0]}"
}

run_home() {
  local public log="$OUT/install-home.log" link
  public="$(curl -fsS4 https://api.ipify.org)"
  world_up
  apt-get install -y -qq miniupnpd nftables >"$OUT/apt-upnp.log" 2>&1 </dev/null
  systemctl stop miniupnpd 2>/dev/null
  # The router's WAN address is the machine's real public IP, so the address the internet
  # sees, the address the router reports and the address clients dial all agree, as at home.
  router_up "$public"
  upnp_start
  service_in_namespace aurora-node home
  client_install

  section "README command behind a home router, no flags"
  ip netns exec home bash -c 'curl -fsSL "$1" | bash' _ "$RAW_URL" 2>&1 | tee "$log"
  check "the install exits 0" test "${PIPESTATUS[0]}" = 0
  check "it recognizes a home network by itself" log_has "$log" "Detected a home environment"
  check "it reports the router accepted UPnP" log_has "$log" "(UPnP)"
  check "it does not cry CGNAT" log_lacks "$log" "carrier-grade"
  for protocol in reality hy2 ss; do
    check "its self-test passes behind the router: $protocol" log_has "$log" "$protocol carries traffic, exit $public"
  done
  check "it warns to test from outside the LAN" log_has "$log" "Test from OUTSIDE"
  check "the router really holds the port forwards" test "$(router_forwards)" -ge 3
  ip netns exec router nft list table inet filter >>"$OUT/checks.log" 2>&1
  link="$(link_from "$log")"
  check "the node reports the public address" grep -q "$public" <<<"$(node_cmd status)"

  section "A client outside reaches home through the port forwards"
  client_allow "$public:tcp:8443" "$public:udp:8443" "$public:tcp:2053"
  check "the client starts blocked from the internet" no_direct_internet
  check "aurora import takes the home link" aurora import "$link"
  connect_and_prove "home" "$public"
  check "the tunnel sent nothing around itself" test "$(leaked_packets)" = 0
  disconnect_and_prove "home"
  client_allow "$public:tcp:8443"
  connect_and_prove "home-reality-only" "$public"
  disconnect_and_prove "home-reality-only"
  client_allow "$public:udp:8443"
  connect_and_prove "home-hysteria2-only" "$public"
  disconnect_and_prove "home-hysteria2-only"
  client_allow "$public:tcp:2053"
  connect_and_prove "home-shadowsocks-only" "$public"
  disconnect_and_prove "home-shadowsocks-only"

  section "Upkeep: a router that forgets its forwards"
  upnp_stop
  ip netns exec router nft flush chain inet filter prerouting_miniupnpd
  ip netns exec router nft flush chain inet filter postrouting_miniupnpd
  ip netns exec router nft flush chain inet filter miniupnpd
  upnp_start
  check "the forwards are gone" test "$(router_forwards)" = 0
  node_cmd maintain >"$OUT/maintain.log" 2>&1
  check "aurora-node maintain succeeds" test "$?" = 0
  check "it puts the forwards back" test "$(router_forwards)" -ge 3
  check "the upkeep timer is enabled" systemctl is-enabled aurora-node-maintain.timer

  section "Upkeep: the home IP changes"
  cp /etc/aurora-node/node.env "$WORK/node.env.bak"
  sed -i -e "s/^S_HOST=.*/S_HOST=203.0.113.200/" -e "s/^S_LAST_IP=.*/S_LAST_IP=203.0.113.200/" /etc/aurora-node/node.env
  node_cmd maintain >"$OUT/maintain-ip.log" 2>&1
  check "maintain notices and says so" log_has "$OUT/maintain-ip.log" "public IP changed"
  check "the link now holds the new address" grep -q "^S_HOST=.*$public" /etc/aurora-node/node.env
  link="$(node_cmd link | grep -Eo 'aurora://v1/[A-Za-z0-9_-]+#[a-z0-9-]+' | head -n 1)"

  section "A relay VPS in front of the home node"
  add_namespace relay "$RELAY_IP"
  local relay_log="$OUT/install-relay.log" relay_link sb=/usr/local/lib/aurora-node/sing-box
  ip netns exec relay env AURORA_TEST_MODE=1 AURORA_PREFIX=/opt/relay AURORA_SING_BOX="$sb" \
    bash "$ROOT/install.sh" relay "$link" --name edge --host "$RELAY_IP" \
    --reality-port 443 --hy2-port 443 --ss-port 8443 2>&1 | tee "$relay_log"
  check "the relay install exits 0" test "${PIPESTATUS[0]}" = 0
  for protocol in reality hy2 ss; do
    check "the relay's self-test passes: $protocol" log_has "$relay_log" "$protocol carries traffic"
  done
  check "the relay refuses the open internet" log_has "$relay_log" "relay rejects everything except the home node"
  relay_link="$(link_from "$relay_log")"
  # From here the relay reaches nothing but the home node, and the client nothing but the
  # relay. So traffic that comes out went client -> relay -> router -> home -> internet.
  iptables -F RELAY
  iptables -A RELAY -d "$public" -p tcp --dport 2053 -j ACCEPT
  iptables -A RELAY -d "$CLIENT_IP" -j ACCEPT
  iptables -A RELAY -j DROP
  client_allow "$RELAY_IP:tcp:443" "$RELAY_IP:udp:443" "$RELAY_IP:tcp:8443"
  check "aurora import takes the relay link" aurora import "$relay_link"
  aurora servers | tee -a "$OUT/checks.log"
  check "both servers are listed" test "$(aurora servers | wc -l)" = 2
  connect_and_prove "relay" "$public" --line edge
  disconnect_and_prove "relay"
  client_allow "$RELAY_IP:tcp:443"
  # REALITY relays the handshake of a real site, so a relay must be able to reach that one
  # site. Its own route still refuses anything but the home node, as its self-test showed.
  iptables -I RELAY 1 -p tcp --dport 443 -j ACCEPT
  connect_and_prove "relay-reality-only" "$public" --line edge
  disconnect_and_prove "relay-reality-only"
  iptables -D RELAY -p tcp --dport 443 -j ACCEPT
  client_allow "$RELAY_IP:udp:443"
  connect_and_prove "relay-hysteria2-only" "$public" --line edge
  disconnect_and_prove "relay-hysteria2-only"
  client_allow "$RELAY_IP:tcp:8443"
  connect_and_prove "relay-shadowsocks-only" "$public" --line edge
  disconnect_and_prove "relay-shadowsocks-only"
  # Direct to home is blocked for the client, so naming that route must not work.
  client_allow "$RELAY_IP:tcp:443" "$RELAY_IP:udp:443" "$RELAY_IP:tcp:8443"
  aurora connect --line home >"$OUT/connect-home-blocked.log" 2>&1
  if egress_within 12 "$public" >/dev/null; then
    fail "the direct home route carried traffic while the client could only reach the relay"
  else
    pass "the direct home route is not secretly using the relay"
  fi
  aurora disconnect >/dev/null 2>&1
  AURORA_TEST_MODE=1 AURORA_PREFIX=/opt/relay AURORA_SING_BOX="$sb" bash "$ROOT/install.sh" uninstall --purge >/dev/null 2>&1
  aurora remove edge >/dev/null 2>&1
  aurora remove home >/dev/null 2>&1

  section "Dynamic DNS against a stand-in API, and a client dialing the name"
  home_purge
  check "uninstall asks the router to drop its forwards" test "$(router_forwards)" = 0
  run_ddns "$public"

  section "The router refuses UPnP"
  home_purge
  upnp_stop
  log="$OUT/install-no-upnp.log"
  home_install "$log" --home --no-self-test
  check "the install still exits 0" test "$?" = 0
  check "it tells the user which ports to forward by hand" log_has "$log" "Forward these ports to this machine by hand"
  check "and to which machine" log_has "$log" "$LAN_HOME"

  section "Carrier-grade NAT"
  home_purge
  # The router now sits on the ISP's shared address space, so its WAN address is not what
  # the internet sees. No port forward here could ever work, and the user must be told.
  ip netns exec router ip addr replace 100.64.7.2/32 dev eth0
  ip netns exec router ip addr del "$public/32" dev eth0
  ip route add 100.64.7.2/32 dev v-router src "$GATEWAY"
  ip netns exec router ip route replace default via "$GATEWAY" dev eth0 onlink
  upnp_start
  log="$OUT/install-cgnat.log"
  home_install "$log" --home --no-self-test
  check "the install still exits 0" test "$?" = 0
  check "it names carrier-grade NAT" log_has "$log" "carrier-grade NAT"
  check "it points at the way out" log_has "$log" "relay VPS"
}

# Stands in for the Cloudflare and DuckDNS APIs at their real hostnames, behind a CA the
# machine trusts for the test, and records what the installer asked for.
run_ddns() {
  local public="$1" name=home.aurora.test requests="$OUT/ddns-requests.jsonl"
  issue_cert api api.cloudflare.com www.duckdns.org
  python3 "$ROOT/deploy/test/ddns-stand-in.py" "$GATEWAY" "$WORK/api.crt" "$WORK/api.key" "$requests" &
  local stand_in=$!
  sleep 1
  add_name "$GATEWAY" api.cloudflare.com
  add_name "$GATEWAY" www.duckdns.org
  add_name "$public" "$name"

  local log="$OUT/install-ddns.log" link
  home_install "$log" --home --host "$name" --cf-token test-token-123
  check "the install with --cf-token exits 0" test "$?" = 0
  check "it reports the record updated" log_has "$log" "dynamic DNS: $name now points here"
  check "it sends the token as a bearer header" grep -q 'Bearer test-token-123' "$requests"
  check "it finds the zone by walking up the name" grep -q 'zones?name=aurora.test' "$requests"
  check "it creates the A record with the public IP, unproxied" \
    grep -q "\"POST\".*\"content\": *\"$public\".*\"proxied\": *false" "$requests"
  node_cmd maintain >>"$OUT/maintain.log" 2>&1
  check "upkeep updates that record instead of duplicating it" grep -q '"PUT"' "$requests"
  link="$(link_from "$log")"

  # The client resolves the name before the tunnel exists, as with any dynamic DNS name.
  client_allow "$public:tcp:8443" "$public:udp:8443" "$public:tcp:2053" "$GATEWAY:udp:53"
  check "aurora import takes a link with a DNS name" aurora import "$link"
  connect_and_prove "ddns-name" "$public"
  disconnect_and_prove "ddns-name"
  aurora remove home >/dev/null 2>&1

  home_purge
  : >"$requests"
  log="$OUT/install-duckdns.log"
  home_install "$log" --home --host myhome.duckdns.org --duckdns-token duck-token-456 --no-self-test
  check "the install with --duckdns-token exits 0" test "$?" = 0
  check "it updates DuckDNS with the public IP" grep -q "domains=myhome&token=duck-token-456&ip=$public" "$requests"
  kill "$stand_in" 2>/dev/null
}

# ---------------------------------------------------------------------------
# The Linux window: a real X session, a real keyring, a real click path
# ---------------------------------------------------------------------------

run_gui() {
  local log="$OUT/install-gui.log" link public
  readme_install "$log" --vps --name vps
  link="$(link_from "$log")"
  public="$(curl -fsS4 https://api.ipify.org)"
  world_up
  ip addr add "$public/32" dev lo
  apt-get install -y -qq xvfb xdotool imagemagick openbox gnome-keyring xclip dbus-x11 mesa-utils libgl1-mesa-dri >"$OUT/apt-gui.log" 2>&1
  client_install
  client_allow "$public:tcp:443" "$public:udp:443" "$public:tcp:8443"
  check "the client starts blocked from the internet" no_direct_internet

  Xvfb :99 -screen 0 1280x800x24 -ac >"$OUT/xvfb.log" 2>&1 &
  sleep 2
  run_window "$public" "$link"
}

run_window() {
  chown -R "$DESKTOP_USER" "$OUT"
  section "The window"
  if ip netns exec client sudo -u "$DESKTOP_USER" env HOME="/home/$DESKTOP_USER" DISPLAY=:99 LIBGL_ALWAYS_SOFTWARE=1 \
    PUBLIC_IP="$1" LINK="$2" OUT="$OUT" DELIVERY_HOOK="${3:-}" dbus-run-session -- bash "$ROOT/deploy/test/full-flow-linux-gui.sh"; then
    pass "the window's journey"
  else
    fail "the window's journey"
  fi
}

# ---------------------------------------------------------------------------
# The optional control plane: the real Worker on the real runtime, locally, reached over TLS
# through a stand-in for Cloudflare's edge. The one thing not real is the account: the
# publisher's `--remote` and `wrangler secret put` are redirected to local storage.
# ---------------------------------------------------------------------------

run_delivery() {
  local log="$OUT/install-delivery.log" link public domain=cp.aurora.test state=/tmp/aurora-delivery
  readme_install "$log" --vps --name vps
  link="$(link_from "$log")"
  public="$(curl -fsS4 https://api.ipify.org)"
  world_up
  ip addr add "$public/32" dev lo
  apt-get install -y -qq xvfb xdotool imagemagick openbox gnome-keyring xclip dbus-x11 mesa-utils libgl1-mesa-dri nginx >"$OUT/apt-gui.log" 2>&1
  systemctl stop nginx 2>/dev/null
  client_install
  mkdir -p "$state/bin"
  chmod 777 "$state"

  section "Publishing to the Worker"
  cat >"$state/bin/npx" <<'EOF'
#!/usr/bin/env bash
# `npx wrangler secret put NAME`, with the value on stdin, becomes .dev.vars. Everything else
# runs as written, with --remote turned into --local.
if [[ "$2 $3" == "secret put" ]]; then
  printf '%s=%s\n' "$4" "$(cat)" >.dev.vars
  exit 0
fi
shift
args=()
for arg in "$@"; do
  if [[ "$arg" == --remote ]]; then args+=(--local); else args+=("$arg"); fi
done
exec wrangler "${args[@]}"
EOF
  chmod +x "$state/bin/npx"
  export WRANGLER_SEND_METRICS=false
  (cd "$ROOT/app" && sudo -u "$DESKTOP_USER" env PATH="$PATH" HOME="/home/$DESKTOP_USER" PUB_CACHE="${PUB_CACHE:-}" \
    dart run tool/link_to_contract.dart "$state/contract.json" "$link") >>"$OUT/delivery.log" 2>&1
  PATH="$state/bin:$PATH" node "$ROOT/control-plane/scripts/publish-contract.mjs" \
    --contract "$state/contract.json" --base "https://$domain" \
    --output "$state/contract.json" --link-output "$state/delivery-link.txt" >>"$OUT/delivery.log" 2>&1
  check "the publisher signs and uploads the contract" test -s "$state/delivery-link.txt"
  check "the signing key is kept private" test "$(stat -c '%a' "$ROOT/secrets/aurora-contract-signing.pem")" = 600

  (cd "$ROOT/control-plane" && nohup wrangler dev --local --ip "$GATEWAY" --port 8787 \
    --var "DELIVERY_DOMAINS:[\"https://$domain\"]" >"$OUT/wrangler.log" 2>&1 &)
  local _
  for _ in $(seq 1 30); do
    curl -fsS --max-time 2 "http://$GATEWAY:8787/health" >/dev/null 2>&1 && break
    sleep 2
  done
  check "the Worker runs" curl -fsS --max-time 3 "http://$GATEWAY:8787/health"

  # In its own namespace because the node on this machine already holds port 443.
  issue_cert cp "$domain"
  add_namespace edge "$EDGE_IP"
  cat >"$WORK/nginx.conf" <<EOF
pid $WORK/nginx.pid;
error_log $OUT/nginx-error.log;
events {}
http {
  access_log $OUT/nginx-access.log;
  server {
    listen 443 ssl;
    server_name $domain;
    ssl_certificate $WORK/cp.crt;
    ssl_certificate_key $WORK/cp.key;
    location / { proxy_pass http://$GATEWAY:8787; }
  }
}
EOF
  ip netns exec edge nginx -c "$WORK/nginx.conf" 2>"$OUT/nginx-start.log"
  add_name "$EDGE_IP" "$domain"
  local token
  token="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["delivery"]["token"])' "$state/contract.json")"
  check "the contract needs the read token" test "$(curl -s -o /dev/null -w '%{http_code}' "https://$domain/v2/contract")" != 200
  check "and is served with it" curl -fsS --max-time 5 -o /dev/null "https://$domain/v2/contract?token=$token"

  # Called from inside the window's session, between its launches.
  cat >"$state/hook.sh" <<EOF
#!/usr/bin/env bash
export PATH="$PATH" PUB_CACHE="${PUB_CACHE:-}" WRANGLER_SEND_METRICS=false
cd "$ROOT/control-plane"
case "\$1" in
  update)
    # Change what the contract says, as its owner would: new keys on the node, then publish.
    aurora-node rotate >"$OUT/delivery-rotate.log" 2>&1
    new_link="\$(grep -Eo 'aurora://v1/[A-Za-z0-9_-]+#[a-z0-9-]+' "$OUT/delivery-rotate.log" | head -n 1)"
    (cd "$ROOT/app" && sudo -u "$DESKTOP_USER" env PATH="$PATH" HOME="/home/$DESKTOP_USER" PUB_CACHE="${PUB_CACHE:-}" \
      dart run tool/link_to_contract.dart "$state/new.json" "\$new_link") >>"$OUT/delivery.log" 2>&1
    python3 -c '
import json, sys
contract, fresh = (json.load(open(path)) for path in sys.argv[1:3])
contract["nodes"] = fresh["nodes"]
json.dump(contract, open(sys.argv[1], "w"))
' "$state/contract.json" "$state/new.json"
    PATH="$state/bin:\$PATH" node "$ROOT/control-plane/scripts/publish-contract.mjs" \
      --contract "$state/contract.json" --base "https://$domain" \
      --output "$state/contract.json" --link-output "$state/delivery-link.txt" >>"$OUT/delivery.log" 2>&1
    ;;
  tamper)
    # What a compromised Worker could do: a newer revision, every server replaced, no way to sign.
    python3 -c '
import json, sys
contract = json.load(open(sys.argv[1]))
contract["revision"] = contract["revision"] + 1000
for node in contract["nodes"]:
    node["server"] = "192.0.2.1"
json.dump(contract, open(sys.argv[2], "w"))
' "$state/contract.json" "$state/tampered.json"
    wrangler kv key put --binding AURORA_KV contract --path "$state/tampered.json" --local >>"$OUT/delivery.log" 2>&1
    ;;
esac
EOF
  chmod +x "$state/hook.sh"

  # DNS and the Worker stay open because the app refreshes before the tunnel exists.
  client_allow "$public:tcp:443" "$public:udp:443" "$public:tcp:8443" "$EDGE_IP:tcp:443" "$GATEWAY:udp:53"
  Xvfb :99 -screen 0 1280x800x24 -ac >"$OUT/xvfb.log" 2>&1 &
  sleep 2
  run_window "$public" "$(cat "$state/delivery-link.txt")" "$state/hook.sh"
}

case "$SCENARIO" in
  vps) run_vps ;;
  home) run_home ;;
  gui) run_gui ;;
  delivery) run_delivery ;;
  *) echo "unknown scenario: $SCENARIO" >&2; exit 2 ;;
esac

section "Result"
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
