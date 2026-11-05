#!/usr/bin/env bash
#
# Aurora node installer: turn a VPS or a home machine into an Aurora node with
# one command.
#
#   curl -fsSL https://raw.githubusercontent.com/SparkyWen/aurora-public/main/install.sh | sudo bash
#
# It installs a pinned, checksum-verified sing-box, generates fresh credentials,
# serves three protocols behind one address (REALITY, Hysteria2, Shadowsocks
# 2022), opens the local firewall, proves the node really forwards traffic, and
# prints one `aurora://` link (and QR code) to add to the Aurora app.
#
# Common commands:
#
#   install.sh                         auto-detect VPS or home network
#   install.sh --home                  force home mode (NAT, UPnP, DDNS upkeep)
#   install.sh --vps --name tokyo      force VPS mode with a custom label
#   install.sh relay '<aurora://...>'  entry VPS that only forwards to a home node
#
#   aurora-node link | status | verify | rotate | uninstall [--purge]
#
# Run `install.sh --help` for every option. The script is idempotent: re-running
# it keeps existing credentials, so connected clients are not kicked.
#
# Everything sits inside functions and `main` is called on the last line, so a
# download truncated mid-way by `curl | bash` cannot execute half an installer.

set -euo pipefail
umask 077

readonly AURORA_NODE_VERSION="1.0.0"
readonly SING_BOX_VERSION="1.13.14"
readonly AURORA_RAW_URL="https://raw.githubusercontent.com/SparkyWen/aurora-public/main/install.sh"

# SHA-256 of the official sing-box release archives. An upgrade changes the
# version and these pins together, so a tampered download cannot be installed.
sing_box_sha256() {
  case "$1" in
    linux-amd64) printf 'f48703461a15476951ac4967cdad339d986f4b8096b4eb3ff0829a500502d697' ;;
    linux-arm64) printf '4742df6a4314e8ecc41736849fca6d73b8f9e91b6e8b06ee794ff17ba180579e' ;;
    linux-armv7) printf 'e01a58d28512b1447ab6156017afdeeaa306169a95d27abc00e112599e4ae46c' ;;
    darwin-amd64) printf '5245d645e847f90bb708da74bc020ae078c28489690756419685c04f56b4e3bb' ;;
    darwin-arm64) printf '73e8967b0fc08e17bce4263ca56ebc394822401a16497a1c4e02316c888202ab' ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
  C_BOLD=$'\033[1m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_RESET=$'\033[0m'
else
  C_BOLD=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_RESET=''
fi

say() { printf '%s\n' "$*"; }
step() { printf '%s==>%s %s\n' "$C_BOLD" "$C_RESET" "$*"; }
ok() { printf '  %s[ok]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '  %s[!!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die() { printf '%sError:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Aurora node installer

Usage:
  install.sh [install] [options]        Set up this machine as an exit node
  install.sh relay '<aurora://link>' [options]
                                        Set up this VPS as an entry that can only
                                        forward to the home node in the link
  aurora-node link                      Print the import link and QR code again
  aurora-node status                    Show service state, ports and address
  aurora-node verify                    Re-run the end-to-end traffic self-test
  aurora-node rotate                    Replace all credentials (clients re-import)
  aurora-node maintain                  Refresh UPnP and DDNS (runs on a timer)
  aurora-node uninstall [--purge]       Remove the node (--purge also deletes keys)

Placement:
  --vps                 Public server. Defaults: TCP 443, UDP 443, TCP 8443
  --home                Behind a home router. Defaults: TCP 8443, UDP 8443, TCP 2053
                        (home ISPs commonly block inbound 80/443). Adds UPnP and
                        a maintenance timer. Without either flag it is detected.
  --name <label>        Label shown in the app (a-z, 0-9, dashes; max 16 chars)
  --host <address>      Address clients dial (IPv4 or DNS name). Default: public IP

Ports (a free fallback is chosen when a default is taken; an explicit port is
never silently changed):
  --reality-port <n>    REALITY over TCP
  --hy2-port <n>        Hysteria2 over UDP
  --ss-port <n>         Shadowsocks-2022 over TCP

Camouflage:
  --reality-sni <name>  Real TLS 1.3 site REALITY borrows (default: the first of
                        a built-in list that passes a live handshake test here)
  --hy2-sni <name>      Name in the self-signed Hysteria2 cert (default www.bing.com)

Home network:
  --no-upnp             Do not ask the router to open ports
  --allow-lan           Let tunnel traffic reach this machine's LAN (default: blocked)

Dynamic DNS (home IPs change; set --host to the name you are updating):
  --cf-token <token>    Keep --host pointed here with a Cloudflare API token
                        (also read from AURORA_CF_TOKEN; scope: Zone.DNS edit)
  --duckdns-token <t>   Keep --host (<name>.duckdns.org) updated with DuckDNS
                        (also read from AURORA_DUCKDNS_TOKEN)

CDN fronting (survives a block of your server's IP):
  --cdn-domain <name>   Add a VLESS+WebSocket+TLS inbound. Point a proxied (orange
                        cloud) Cloudflare record at this server, SSL mode "Full"
  --cdn-port <n>        Cloudflare-proxied HTTPS port (default 2083)

Other:
  --rotate              Generate new credentials during this install
  --no-self-test        Skip the end-to-end traffic test
  --no-firewall         Do not touch the local firewall
  -h, --help            Show this help

Examples:
  curl -fsSL https://raw.githubusercontent.com/SparkyWen/aurora-public/main/install.sh | sudo bash
  curl -fsSL .../install.sh | sudo bash -s -- --home --host home.example.com --cf-token "$TOKEN"
  curl -fsSL .../install.sh | sudo bash -s -- relay 'aurora://v1/...'
EOF
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

is_ipv4() {
  local value="$1" part
  [[ "$value" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  local IFS=.
  # shellcheck disable=SC2086
  set -- $value
  for part in "$@"; do
    [[ "$part" == "0" || ! "$part" =~ ^0 ]] || return 1
    ((10#$part <= 255)) || return 1
  done
}

# The last label must contain a letter, so an IPv4 address is never a DNS name.
is_dns_name() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] &&
    [[ "${1##*.}" =~ [A-Za-z] ]]
}

is_port() {
  [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

is_label() {
  [[ "$1" =~ ^[a-z][a-z0-9-]{0,15}$ && "$1" != *- ]]
}

# 100.64.0.0/10 (carrier-grade NAT, also the Tailscale range).
is_cgnat_ipv4() {
  is_ipv4 "$1" || return 1
  local a b rest
  a="${1%%.*}"; rest="${1#*.}"; b="${rest%%.*}"
  [[ "$a" == "100" ]] && ((b >= 64 && b <= 127))
}

is_private_ipv4() {
  is_ipv4 "$1" || return 1
  local a b rest
  a="${1%%.*}"; rest="${1#*.}"; b="${rest%%.*}"
  [[ "$a" == "10" ]] && return 0
  [[ "$a" == "192" && "$b" == "168" ]] && return 0
  [[ "$a" == "172" ]] && ((b >= 16 && b <= 31)) && return 0
  return 1
}

# ---------------------------------------------------------------------------
# Paths. AURORA_PREFIX + AURORA_TEST_MODE let the test suite exercise the whole
# flow without root and without touching services, firewalls or the router.
# ---------------------------------------------------------------------------

init_paths() {
  OS_NAME="$(uname -s)"
  case "$OS_NAME" in
    Linux) PLATFORM=linux ;;
    Darwin) PLATFORM=darwin ;;
    *) die "unsupported system: $OS_NAME (Aurora nodes run on Linux and macOS)" ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64) SB_ARCH=amd64 ;;
    aarch64 | arm64) SB_ARCH=arm64 ;;
    armv7l | armv7) SB_ARCH=armv7 ;;
    *) die "unsupported CPU architecture: $(uname -m)" ;;
  esac

  local prefix="${AURORA_PREFIX:-}"
  if [[ "$PLATFORM" == linux ]]; then
    ETC_DIR="$prefix/etc/aurora-node"
    LOG_DIR="$prefix/var/log/aurora-node"
  else
    ETC_DIR="$prefix/usr/local/etc/aurora-node"
    LOG_DIR="$prefix/usr/local/var/log/aurora-node"
  fi
  LIB_DIR="$prefix/usr/local/lib/aurora-node"
  BIN_LINK="$prefix/usr/local/bin/aurora-node"
  SB_BIN="${AURORA_SING_BOX:-$LIB_DIR/sing-box}"
  STATE_FILE="$ETC_DIR/node.env"
  SB_CONFIG="$ETC_DIR/sing-box.json"
  LINK_FILE="$ETC_DIR/link.txt"
  SHARE_FILE="$ETC_DIR/share-links.txt"
  CERT_FILE="$ETC_DIR/hy2.crt"
  KEY_FILE="$ETC_DIR/hy2.key"
  CDN_CERT_FILE="$ETC_DIR/cdn.crt"
  CDN_KEY_FILE="$ETC_DIR/cdn.key"
  SERVICE_USER=aurora-node
  TEST_MODE="${AURORA_TEST_MODE:-0}"
}

require_root() {
  [[ "$TEST_MODE" == 1 ]] && return 0
  [[ "$(id -u)" -eq 0 ]] || die "run as root, for example: curl -fsSL $AURORA_RAW_URL | sudo bash"
}

# ---------------------------------------------------------------------------
# Network facts
# ---------------------------------------------------------------------------

detect_public_ip() {
  if [[ -n "${AURORA_PUBLIC_IP:-}" ]]; then
    printf '%s' "$AURORA_PUBLIC_IP"
    return 0
  fi
  local url ip
  for url in https://api.ipify.org https://ifconfig.me/ip https://ipv4.icanhazip.com https://checkip.amazonaws.com; do
    ip="$(curl -fsS4 --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]')" || continue
    if is_ipv4 "$ip"; then
      printf '%s' "$ip"
      return 0
    fi
  done
  return 1
}

detect_lan_ip() {
  if [[ -n "${AURORA_LAN_IP:-}" ]]; then
    printf '%s' "$AURORA_LAN_IP"
    return 0
  fi
  local iface ip
  if [[ "$PLATFORM" == linux ]]; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)"
  else
    iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
    [[ -n "$iface" ]] && ip="$(ipconfig getifaddr "$iface" 2>/dev/null || true)"
  fi
  [[ -n "${ip:-}" ]] && is_ipv4 "$ip" && printf '%s' "$ip"
}

ip_on_local_interface() {
  [[ "$PLATFORM" == linux ]] || return 1
  ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qxF "$1"
}

# Cloud instances with 1:1 NAT (AWS, GCP, Oracle, ...) do not carry the public IP
# on an interface, so the metadata endpoint separates them from a home router.
has_cloud_metadata() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 http://169.254.169.254/ 2>/dev/null || true)"
  [[ -n "$code" && "$code" != "000" ]]
}

detect_mode() {
  [[ "$PLATFORM" == darwin ]] && { printf 'home'; return 0; }
  if ip_on_local_interface "$1" || has_cloud_metadata; then
    printf 'vps'
    return 0
  fi
  printf 'home'
}

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

pkg_install() {
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q "$@" >/dev/null 2>&1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q "$@" >/dev/null 2>&1
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm "$@" >/dev/null 2>&1
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install "$@" >/dev/null 2>&1
  else
    return 1
  fi
}

ensure_prereqs() {
  local missing=() tool
  for tool in curl tar gzip openssl; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if ((${#missing[@]} > 0)); then
    [[ "$TEST_MODE" == 1 ]] && die "missing tools: ${missing[*]}"
    step "Installing ${missing[*]}"
    pkg_install "${missing[@]}" || die "please install ${missing[*]} and re-run"
  fi
  # The QR code is a convenience; the printed link always works without it.
  if [[ "$TEST_MODE" != 1 ]] && ! command -v qrencode >/dev/null 2>&1; then
    pkg_install qrencode || true
  fi
}

install_sing_box() {
  if [[ -n "${AURORA_SING_BOX:-}" ]]; then
    "$SB_BIN" version >/dev/null 2>&1 || die "AURORA_SING_BOX is not runnable: $SB_BIN"
    return 0
  fi
  if [[ -x "$SB_BIN" ]] && "$SB_BIN" version 2>/dev/null | head -n 1 | grep -qF "$SING_BOX_VERSION"; then
    ok "sing-box $SING_BOX_VERSION already installed"
    return 0
  fi
  local slug="$PLATFORM-$SB_ARCH" expected actual tmp archive
  expected="$(sing_box_sha256 "$slug")" || die "no pinned sing-box build for $slug"
  step "Downloading sing-box $SING_BOX_VERSION ($slug)"
  tmp="$(mktemp -d)"
  archive="$tmp/sing-box.tar.gz"
  curl -fsSL --retry 3 --max-time 180 -o "$archive" \
    "https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/sing-box-${SING_BOX_VERSION}-${slug}.tar.gz" ||
    { rm -rf "$tmp"; die "could not download sing-box (is github.com reachable from here?)"; }
  actual="$(file_sha256 "$archive")"
  if [[ "$actual" != "$expected" ]]; then
    rm -rf "$tmp"
    die "sing-box checksum mismatch: expected $expected, got $actual"
  fi
  tar -xzf "$archive" -C "$tmp"
  install -m 0755 "$tmp/sing-box-${SING_BOX_VERSION}-${slug}/sing-box" "$SB_BIN"
  rm -rf "$tmp"
  ok "sing-box $SING_BOX_VERSION verified and installed"
}

file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# Copies this script to a stable command. Under `curl | bash` there is no script
# file to copy, so it is fetched again; a failure only costs the convenience.
install_self() {
  (umask 022; mkdir -p "$(dirname "$BIN_LINK")")
  local source="${BASH_SOURCE[0]:-}"
  if [[ -n "$source" && -f "$source" ]]; then
    if [[ "$source" != "$BIN_LINK" ]]; then
      install -m 0755 "$source" "$BIN_LINK"
    fi
    return 0
  fi
  [[ "$TEST_MODE" == 1 ]] && return 0
  local tmp
  tmp="$(mktemp)"
  if curl -fsSL --max-time 30 -o "$tmp" "$AURORA_RAW_URL"; then
    install -m 0755 "$tmp" "$BIN_LINK"
  else
    warn "could not install the aurora-node command; re-run this installer to manage the node"
  fi
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Port selection
# ---------------------------------------------------------------------------

port_in_use() {
  local proto="$1" port="$2"
  if [[ "$PLATFORM" == linux ]] && command -v ss >/dev/null 2>&1; then
    local flag=-ltn
    [[ "$proto" == udp ]] && flag=-lun
    ss "$flag" 2>/dev/null | awk 'NR>1{print $4}' | grep -qE "[:.]${port}\$"
  elif command -v lsof >/dev/null 2>&1; then
    if [[ "$proto" == udp ]]; then
      lsof -nP -iUDP:"$port" >/dev/null 2>&1
    else
      lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    fi
  else
    return 1
  fi
}

# choose_port <proto> <explicit-or-empty> <saved-or-empty> <candidates...>
# Sets CHOSEN_PORT rather than printing it, because a `$(...)` subshell would
# lose the ports claimed earlier in the same run.
CLAIMED_PORTS=""
choose_port() {
  local proto="$1" explicit="$2" saved="$3" candidate
  shift 3
  CHOSEN_PORT=""
  if [[ -n "$explicit" ]]; then
    is_port "$explicit" || die "invalid port: $explicit"
    # An explicit port wins, unless it belongs to something else on this box.
    if [[ "$explicit" != "$saved" ]] && port_in_use "$proto" "$explicit"; then
      die "$proto port $explicit is already in use. Stop that service or pick another port."
    fi
    CHOSEN_PORT="$explicit"
  elif [[ -n "$saved" ]]; then
    # Keep the published port across re-runs. Our own service is listening on it.
    CHOSEN_PORT="$saved"
  else
    for candidate in "$@"; do
      case " $CLAIMED_PORTS " in *" $proto/$candidate "*) continue ;; esac
      if ! port_in_use "$proto" "$candidate"; then
        CHOSEN_PORT="$candidate"
        break
      fi
    done
    [[ -n "$CHOSEN_PORT" ]] ||
      die "no free $proto port among: $*. Pick one explicitly with the --*-port options."
  fi
  CLAIMED_PORTS="$CLAIMED_PORTS $proto/$CHOSEN_PORT"
}

# ---------------------------------------------------------------------------
# Credentials and persisted settings
# ---------------------------------------------------------------------------

load_state() {
  if [[ -r "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
  fi
}

save_state() {
  local tmp
  tmp="$(mktemp "$STATE_FILE.XXXXXX")"
  {
    local name
    for name in S_MODE S_NAME S_HOST S_HOST_IS_AUTO S_REALITY_PORT S_HY2_PORT S_SS_PORT \
      S_REALITY_SNI S_HY2_SNI S_UUID S_PRIVATE_KEY S_PUBLIC_KEY S_SHORT_ID S_HY2_PASS \
      S_SS_PASS S_UPNP S_ALLOW_LAN S_CF_TOKEN S_DUCKDNS_TOKEN S_CDN_DOMAIN S_CDN_PORT \
      S_CDN_UUID S_CDN_PATH S_EXIT_NAME S_EXIT_HOST S_EXIT_PORT S_EXIT_PASS S_LAST_IP; do
      printf "%s='%s'\n" "$name" "${!name:-}"
    done
  } >"$tmp"
  chmod 600 "$tmp"
  # These secrets exist nowhere else: a crash mid-write must not destroy them.
  mv -f "$tmp" "$STATE_FILE"
}

sb_generate_keypair() {
  local output
  output="$("$SB_BIN" generate reality-keypair)"
  S_PRIVATE_KEY="$(printf '%s\n' "$output" | awk 'tolower($1) ~ /private/ {print $2; exit}')"
  S_PUBLIC_KEY="$(printf '%s\n' "$output" | awk 'tolower($1) ~ /public/ {print $2; exit}')"
  [[ -n "$S_PRIVATE_KEY" && -n "$S_PUBLIC_KEY" ]] || die "could not generate the REALITY keypair"
}

ensure_credentials() {
  local force="$1"
  if [[ "$force" == 1 || -z "${S_UUID:-}" ]]; then
    S_UUID="$("$SB_BIN" generate uuid)"
    sb_generate_keypair
    S_SHORT_ID="$(openssl rand -hex 8)"
    S_HY2_PASS="$(openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-32)"
    # Shadowsocks-2022 with aes-128-gcm requires exactly 16 random bytes.
    S_SS_PASS="$(openssl rand -base64 16 | tr -d '\n')"
    S_CDN_UUID=""
  fi
  if [[ -n "${S_CDN_DOMAIN:-}" && -z "${S_CDN_UUID:-}" ]]; then
    S_CDN_UUID="$("$SB_BIN" generate uuid)"
    S_CDN_PATH="/$(openssl rand -hex 8)"
  fi
}

ensure_certificates() {
  local force="$1"
  if [[ "$force" == 1 || ! -s "$CERT_FILE" || ! -s "$KEY_FILE" ]]; then
    openssl ecparam -genkey -name prime256v1 -out "$KEY_FILE" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "$KEY_FILE" -out "$CERT_FILE" \
      -subj "/CN=$S_HY2_SNI" -addext "subjectAltName=DNS:$S_HY2_SNI" 2>/dev/null
  fi
  if [[ -n "${S_CDN_DOMAIN:-}" ]] && [[ "$force" == 1 || ! -s "$CDN_CERT_FILE" || ! -s "$CDN_KEY_FILE" ]]; then
    # Only protects the Cloudflare-to-origin hop (SSL mode "Full").
    openssl ecparam -genkey -name prime256v1 -out "$CDN_KEY_FILE" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "$CDN_KEY_FILE" -out "$CDN_CERT_FILE" \
      -subj "/CN=$S_CDN_DOMAIN" -addext "subjectAltName=DNS:$S_CDN_DOMAIN" 2>/dev/null
  fi
  HY2_SPKI="$(
    openssl x509 -in "$CERT_FILE" -pubkey -noout |
      openssl pkey -pubin -outform der 2>/dev/null |
      openssl dgst -sha256 -binary |
      openssl enc -base64 | tr -d '\r\n'
  )"
  [[ "$HY2_SPKI" =~ ^[A-Za-z0-9+/]{43}=$ ]] || die "could not derive the Hysteria2 certificate pin"
  HY2_CERT_SHA256="$(
    openssl x509 -in "$CERT_FILE" -outform der | openssl dgst -sha256 -binary |
      od -An -tx1 | tr -d ' \n'
  )"
}

# ---------------------------------------------------------------------------
# sing-box server configuration
# ---------------------------------------------------------------------------

inbounds_json() {
  cat <<EOF
    {
      "type": "vless", "tag": "reality-in", "listen": "0.0.0.0", "listen_port": $S_REALITY_PORT,
      "users": [ { "uuid": "$S_UUID", "flow": "xtls-rprx-vision" } ],
      "tls": { "enabled": true, "server_name": "$S_REALITY_SNI",
        "reality": { "enabled": true,
          "handshake": { "server": "$S_REALITY_SNI", "server_port": 443 },
          "private_key": "$S_PRIVATE_KEY", "short_id": [ "$S_SHORT_ID" ] } }
    },
    {
      "type": "hysteria2", "tag": "hy2-in", "listen": "0.0.0.0", "listen_port": $S_HY2_PORT,
      "users": [ { "password": "$S_HY2_PASS" } ],
      "masquerade": { "type": "string", "status_code": 404,
        "headers": { "server": "nginx" }, "content": "Not Found" },
      "tls": { "enabled": true, "alpn": [ "h3" ],
        "certificate_path": "$CERT_FILE", "key_path": "$KEY_FILE" }
    },
    {
      "type": "shadowsocks", "tag": "ss-in", "listen": "0.0.0.0", "listen_port": $S_SS_PORT,
      "method": "2022-blake3-aes-128-gcm", "password": "$S_SS_PASS"
    }
EOF
  if [[ -n "${S_CDN_DOMAIN:-}" ]]; then
    # No `flow`: xtls-rprx-vision cannot ride a WebSocket.
    cat <<EOF
    ,{
      "type": "vless", "tag": "cdn-in", "listen": "0.0.0.0", "listen_port": $S_CDN_PORT,
      "users": [ { "uuid": "$S_CDN_UUID" } ],
      "tls": { "enabled": true, "certificate_path": "$CDN_CERT_FILE", "key_path": "$CDN_KEY_FILE" },
      "transport": { "type": "ws", "path": "$S_CDN_PATH" }
    }
EOF
  fi
}

# Exit node: reach the public internet over IPv4 only. Datacenter IPv6 ranges
# have poor reputation and trip captcha walls; the client blocks IPv6 anyway.
# Domain targets are resolved first so the private-address rule sees real IPs,
# otherwise `localhost` or a cloud metadata name would walk straight past it.
exit_route_json() {
  local lan_rule=''
  if [[ "${S_ALLOW_LAN:-0}" != 1 ]]; then
    lan_rule='{ "ip_is_private": true, "action": "reject" },'
  fi
  cat <<EOF
  "outbounds": [ { "type": "direct", "tag": "direct" } ],
  "route": {
    "rules": [
      { "ip_version": 6, "action": "reject" },
      { "action": "resolve", "server": "dns-local", "strategy": "ipv4_only" },
      $lan_rule
      { "port": [ 25 ], "action": "reject" }
    ],
    "default_domain_resolver": { "server": "dns-local", "strategy": "ipv4_only" },
    "final": "direct"
  }
EOF
}

# Relay node: there is deliberately no general internet outbound. The only thing
# a client can reach through it is the home node's Shadowsocks port, so leaked
# relay credentials cannot be used as an open proxy, and a misconfiguration
# fails closed instead of quietly exiting from the relay's IP.
relay_route_json() {
  local target_rule
  if is_ipv4 "$S_EXIT_HOST"; then
    target_rule="\"ip_cidr\": [ \"$S_EXIT_HOST/32\" ]"
  else
    target_rule="\"domain\": [ \"$S_EXIT_HOST\" ]"
  fi
  cat <<EOF
  "outbounds": [ { "type": "direct", "tag": "exit-target", "domain_resolver": { "server": "dns-local", "strategy": "ipv4_only" } } ],
  "route": {
    "rules": [
      { "network": "tcp", $target_rule, "port": $S_EXIT_PORT, "action": "route", "outbound": "exit-target" },
      { "action": "reject", "method": "default", "no_drop": true }
    ],
    "final": "exit-target",
    "default_domain_resolver": { "server": "dns-local", "strategy": "ipv4_only" }
  }
EOF
}

write_singbox_config() {
  local stage route
  stage="$(mktemp "$SB_CONFIG.XXXXXX")"
  if [[ "$S_MODE" == relay ]]; then
    route="$(relay_route_json)"
  else
    route="$(exit_route_json)"
  fi
  cat >"$stage" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "dns": {
    "servers": [ { "type": "local", "tag": "dns-local" } ],
    "strategy": "ipv4_only"
  },
  "inbounds": [
$(inbounds_json)
  ],
$route
}
EOF
  # A broken config would take every connected client down with the service.
  if ! "$SB_BIN" check -c "$stage" >/dev/null 2>&1; then
    local detail
    detail="$("$SB_BIN" check -c "$stage" 2>&1 | tail -n 3 || true)"
    rm -f "$stage"
    die "generated configuration failed sing-box check: $detail"
  fi
  chmod 640 "$stage"
  mv -f "$stage" "$SB_CONFIG"
}

# ---------------------------------------------------------------------------
# Service management
# ---------------------------------------------------------------------------

service_user_setup() {
  [[ "$TEST_MODE" == 1 ]] && return 0
  if [[ "$PLATFORM" == linux ]]; then
    if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
      useradd --system --home-dir /nonexistent --no-create-home \
        --shell /usr/sbin/nologin "$SERVICE_USER" 2>/dev/null ||
        useradd -r -M -s /sbin/nologin "$SERVICE_USER"
    fi
    chown -R "root:$SERVICE_USER" "$ETC_DIR"
    chmod 750 "$ETC_DIR"
  else
    chown -R root:wheel "$ETC_DIR"
    chmod 700 "$ETC_DIR"
  fi
  # The service reads its config and keys, but never the master state file.
  chmod 600 "$STATE_FILE"
  chmod 640 "$SB_CONFIG" "$CERT_FILE" "$KEY_FILE"
  [[ -f "$CDN_KEY_FILE" ]] && chmod 640 "$CDN_CERT_FILE" "$CDN_KEY_FILE"
  return 0
}

write_systemd_units() {
  cat >/etc/systemd/system/aurora-node.service <<EOF
[Unit]
Description=Aurora node (sing-box)
Documentation=https://github.com/SparkyWen/aurora-public
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
ExecStart=$SB_BIN run -c $SB_CONFIG
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 /etc/systemd/system/aurora-node.service
  # Hysteria2/QUIC needs large UDP socket buffers. The Linux default (208 KB)
  # throttles quic-go under bursty load: single streams pass while real browsing
  # stutters, which is miserable to diagnose after the fact.
  if [[ -d /etc/sysctl.d ]]; then
    cat >/etc/sysctl.d/99-aurora-node.conf <<'EOF'
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF
    chmod 644 /etc/sysctl.d/99-aurora-node.conf
    sysctl --load=/etc/sysctl.d/99-aurora-node.conf >/dev/null 2>&1 || true
  fi
  if needs_maintain; then
    cat >/etc/systemd/system/aurora-node-maintain.service <<EOF
[Unit]
Description=Aurora node upkeep (UPnP and dynamic DNS)
After=network-online.target

[Service]
Type=oneshot
ExecStart=$BIN_LINK maintain
EOF
    cat >/etc/systemd/system/aurora-node-maintain.timer <<'EOF'
[Unit]
Description=Run Aurora node upkeep every five minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
Unit=aurora-node-maintain.service

[Install]
WantedBy=timers.target
EOF
    chmod 644 /etc/systemd/system/aurora-node-maintain.service /etc/systemd/system/aurora-node-maintain.timer
  fi
}

write_launchd_plists() {
  mkdir -p "$LOG_DIR"
  cat >/Library/LaunchDaemons/org.aurora.node.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>org.aurora.node</string>
  <key>ProgramArguments</key><array>
    <string>$SB_BIN</string><string>run</string><string>-c</string><string>$SB_CONFIG</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardErrorPath</key><string>$LOG_DIR/sing-box.log</string>
  <key>StandardOutPath</key><string>$LOG_DIR/sing-box.log</string>
</dict></plist>
EOF
  chmod 644 /Library/LaunchDaemons/org.aurora.node.plist
  if needs_maintain; then
    cat >/Library/LaunchDaemons/org.aurora.node.maintain.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>org.aurora.node.maintain</string>
  <key>ProgramArguments</key><array>
    <string>$BIN_LINK</string><string>maintain</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>300</integer>
  <key>StandardErrorPath</key><string>$LOG_DIR/maintain.log</string>
  <key>StandardOutPath</key><string>$LOG_DIR/maintain.log</string>
</dict></plist>
EOF
    chmod 644 /Library/LaunchDaemons/org.aurora.node.maintain.plist
  fi
}

launchd_restart() {
  local label="$1" plist="/Library/LaunchDaemons/$1.plist" attempt
  launchctl bootout "system/$label" 2>/dev/null || true
  # bootstrap can fail with an I/O error just after bootout while launchd settles.
  for attempt in 1 2 3 4 5; do
    launchctl bootstrap system "$plist" 2>/dev/null && return 0
    sleep "$attempt"
  done
  die "launchd could not load $label"
}

needs_maintain() {
  [[ "${S_UPNP:-0}" == 1 || -n "${S_CF_TOKEN:-}" || -n "${S_DUCKDNS_TOKEN:-}" ]]
}

# Test mode runs the real sing-box as a plain child process on high ports.
test_service_pid_file() { printf '%s/test-service.pid' "$ETC_DIR"; }

service_restart() {
  if [[ "$TEST_MODE" == 1 ]]; then
    service_stop
    "$SB_BIN" run -c "$SB_CONFIG" >"$ETC_DIR/test-service.log" 2>&1 &
    printf '%s' "$!" >"$(test_service_pid_file)"
    sleep 1
    return 0
  fi
  if [[ "$PLATFORM" == linux ]]; then
    if ! command -v systemctl >/dev/null 2>&1 || [[ ! -d /run/systemd/system ]]; then
      die "systemd was not found. Aurora nodes need systemd on Linux (OpenRC and containers without it are not supported)."
    fi
    write_systemd_units
    systemctl daemon-reload
    systemctl enable aurora-node >/dev/null 2>&1
    systemctl restart aurora-node
    if needs_maintain; then
      systemctl enable --now aurora-node-maintain.timer >/dev/null 2>&1 || true
    else
      systemctl disable --now aurora-node-maintain.timer >/dev/null 2>&1 || true
    fi
    sleep 1
    if ! systemctl is-active --quiet aurora-node; then
      journalctl -u aurora-node -n 20 --no-pager >&2 || true
      die "the aurora-node service did not start"
    fi
  else
    write_launchd_plists
    launchd_restart org.aurora.node
    if needs_maintain; then
      launchd_restart org.aurora.node.maintain
    else
      launchctl bootout system/org.aurora.node.maintain 2>/dev/null || true
      rm -f /Library/LaunchDaemons/org.aurora.node.maintain.plist
    fi
    sleep 1
  fi
}

service_stop() {
  if [[ "$TEST_MODE" == 1 ]]; then
    local pid_file pid
    pid_file="$(test_service_pid_file)"
    if [[ -f "$pid_file" ]]; then
      pid="$(cat "$pid_file")"
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rm -f "$pid_file"
    fi
    return 0
  fi
  if [[ "$PLATFORM" == linux ]]; then
    systemctl disable --now aurora-node-maintain.timer >/dev/null 2>&1 || true
    systemctl disable --now aurora-node >/dev/null 2>&1 || true
  else
    launchctl bootout system/org.aurora.node.maintain 2>/dev/null || true
    launchctl bootout system/org.aurora.node 2>/dev/null || true
  fi
}

check_listeners() {
  local failed=0
  if ! port_in_use tcp "$S_REALITY_PORT"; then warn "TCP $S_REALITY_PORT (REALITY) is not listening"; failed=1; fi
  if ! port_in_use udp "$S_HY2_PORT"; then warn "UDP $S_HY2_PORT (Hysteria2) is not listening"; failed=1; fi
  if ! port_in_use tcp "$S_SS_PORT"; then warn "TCP $S_SS_PORT (Shadowsocks) is not listening"; failed=1; fi
  return "$failed"
}

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------

firewall_port_list() {
  printf '%s/tcp %s/udp %s/tcp' "$S_REALITY_PORT" "$S_HY2_PORT" "$S_SS_PORT"
  [[ -n "${S_CDN_DOMAIN:-}" ]] && printf ' %s/tcp' "$S_CDN_PORT"
  return 0
}

open_firewall() {
  [[ "$TEST_MODE" == 1 ]] && return 0
  local entry port proto
  if [[ "$PLATFORM" == darwin ]]; then
    local fw=/usr/libexec/ApplicationFirewall/socketfilterfw
    if [[ -x "$fw" ]] && "$fw" --getglobalstate 2>/dev/null | grep -qi enabled; then
      "$fw" --add "$SB_BIN" >/dev/null 2>&1 || true
      "$fw" --unblockapp "$SB_BIN" >/dev/null 2>&1 || true
      ok "macOS application firewall allows sing-box"
    fi
    return 0
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    for entry in $(firewall_port_list); do
      ufw allow "$entry" comment 'aurora-node' >/dev/null 2>&1 || true
    done
    ok "ufw allows $(firewall_port_list)"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    for entry in $(firewall_port_list); do
      firewall-cmd --permanent --add-port="$entry" >/dev/null 2>&1 || true
    done
    firewall-cmd --reload >/dev/null 2>&1 || true
    ok "firewalld allows $(firewall_port_list)"
  elif command -v iptables >/dev/null 2>&1 && iptables -S INPUT 2>/dev/null | grep -qE -- '-j (REJECT|DROP)|-P INPUT DROP'; then
    # Common on Oracle Cloud images: a stock REJECT rule at the end of INPUT.
    for entry in $(firewall_port_list); do
      port="${entry%/*}"; proto="${entry#*/}"
      iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null ||
        iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
    done
    if command -v netfilter-persistent >/dev/null 2>&1; then
      netfilter-persistent save >/dev/null 2>&1 || true
    fi
    ok "iptables allows $(firewall_port_list)"
  fi
}

# ---------------------------------------------------------------------------
# UPnP (home mode). Standard library only; returns 3 when no router answers.
# ---------------------------------------------------------------------------

upnp_helper() {
  command -v python3 >/dev/null 2>&1 || return 3
  python3 - "$@" <<'PY'
import re, socket, sys, urllib.request, xml.etree.ElementTree as ET

UPNP = "urn:schemas-upnp-org:device-1-0"


def discover():
    targets = [
        "urn:schemas-upnp-org:device:InternetGatewayDevice:2",
        "urn:schemas-upnp-org:device:InternetGatewayDevice:1",
        "urn:schemas-upnp-org:service:WANIPConnection:1",
        "ssdp:all",
    ]
    for target in targets:
        locations = []
        request = (
            "M-SEARCH * HTTP/1.1\r\nHOST:239.255.255.250:1900\r\n"
            'MAN:"ssdp:discover"\r\nMX:2\r\nST:%s\r\n\r\n' % target
        ).encode()
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
        sock.settimeout(3)
        try:
            sock.sendto(request, ("239.255.255.250", 1900))
            while True:
                data, _ = sock.recvfrom(4096)
                match = re.search(rb"LOCATION:\s*(\S+)", data, re.I)
                if match and match.group(1).decode() not in locations:
                    locations.append(match.group(1).decode())
        except (socket.timeout, OSError):
            pass
        finally:
            sock.close()
        for location in locations:
            found = find_service(location)
            if found:
                return found
    return None


def find_service(url):
    try:
        root = ET.fromstring(urllib.request.urlopen(url, timeout=5).read())
    except Exception:
        return None
    base = re.match(r"(https?://[^/]+)", url).group(1)
    for service in root.iter("{%s}service" % UPNP):
        kind = service.findtext("{%s}serviceType" % UPNP, "")
        control = service.findtext("{%s}controlURL" % UPNP, "")
        if ("WANIPConnection" in kind or "WANPPPConnection" in kind) and control:
            if not control.startswith("http"):
                control = base + (control if control.startswith("/") else "/" + control)
            return control, kind
    return None


def soap(control, kind, action, args):
    fields = "".join("<%s>%s</%s>" % (k, v, k) for k, v in args)
    body = (
        '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
        '<u:%s xmlns:u="%s">%s</u:%s></s:Body></s:Envelope>' % (action, kind, fields, action)
    ).encode()
    request = urllib.request.Request(control, data=body, headers={
        "Content-Type": 'text/xml; charset="utf-8"',
        "SOAPAction": '"%s#%s"' % (kind, action),
    })
    return urllib.request.urlopen(request, timeout=6).read().decode(errors="replace")


def external_ip(control, kind):
    match = re.search(r"<NewExternalIPAddress>([^<]*)<", soap(control, kind, "GetExternalIPAddress", []))
    return match.group(1) if match else ""


def add_mapping(control, kind, proto, port, client):
    # Lease 0 means permanent, but some routers refuse it, so fall back to one hour.
    # The upkeep timer re-asserts well before an hour runs out.
    for lease in (0, 3600):
        try:
            soap(control, kind, "AddPortMapping", [
                ("NewRemoteHost", ""), ("NewExternalPort", port), ("NewProtocol", proto),
                ("NewInternalPort", port), ("NewInternalClient", client), ("NewEnabled", 1),
                ("NewPortMappingDescription", "aurora-node-%s-%s" % (proto.lower(), port)),
                ("NewLeaseDuration", lease),
            ])
            return True
        except Exception:
            continue
    return False


def main(argv):
    found = discover()
    if not found:
        return 3
    control, kind = found
    if argv[0] == "external-ip":
        try:
            print(external_ip(control, kind))
        except Exception:
            # Common router firmware (miniupnpd) answers with an error rather than name a
            # private WAN address, so "there is a router and it will not say" means something.
            print("unknown")
        return 0
    if argv[0] == "map":
        failed = 0
        client = argv[1]
        for spec in argv[2:]:
            port, proto = spec.split("/")
            if not add_mapping(control, kind, proto.upper(), int(port), client):
                print("failed %s" % spec)
                failed += 1
        return 4 if failed else 0
    if argv[0] == "unmap":
        for spec in argv[1:]:
            port, proto = spec.split("/")
            try:
                soap(control, kind, "DeletePortMapping", [
                    ("NewRemoteHost", ""), ("NewExternalPort", int(port)), ("NewProtocol", proto.upper()),
                ])
            except Exception:
                pass
        return 0
    return 2


sys.exit(main(sys.argv[1:]))
PY
}

upnp_apply() {
  [[ "${S_UPNP:-0}" == 1 && "$TEST_MODE" != 1 ]] || return 0
  local lan
  lan="$(detect_lan_ip || true)"
  if [[ -z "$lan" ]]; then
    warn "could not determine this machine's LAN address, skipping UPnP"
    return 1
  fi
  # shellcheck disable=SC2046
  if upnp_helper map "$lan" $(firewall_port_list) >/dev/null 2>&1; then
    ok "router forwards $(firewall_port_list) to $lan (UPnP)"
    return 0
  fi
  UPNP_FAILED=1
  return 1
}

# Compares what the router believes its WAN address is with what the internet
# sees. A mismatch or a private WAN address means the ISP is doing carrier-grade
# NAT, in which case no port forward on this router can ever work.
check_cgnat() {
  [[ "${S_UPNP:-0}" == 1 && "$TEST_MODE" != 1 ]] || return 0
  local wan
  wan="$(upnp_helper external-ip 2>/dev/null || true)"
  [[ -n "$wan" ]] || return 0
  # A router that will neither name its address nor forward a port. Telling this user to
  # forward ports by hand would send them after something that cannot work.
  if [[ "$wan" == unknown ]]; then
    if [[ "${UPNP_FAILED:-0}" == 1 ]]; then BEHIND_CGNAT=1; fi
    return 0
  fi
  if is_cgnat_ipv4 "$wan" || is_private_ipv4 "$wan" || [[ "$wan" != "$1" ]]; then
    BEHIND_CGNAT=1
  fi
}

# ---------------------------------------------------------------------------
# Dynamic DNS
# ---------------------------------------------------------------------------

ddns_duckdns() {
  local name="${S_HOST%.duckdns.org}" answer
  answer="$(curl -fsS --max-time 15 "https://www.duckdns.org/update?domains=$name&token=$S_DUCKDNS_TOKEN&ip=$1" 2>/dev/null || true)"
  [[ "$answer" == OK* ]]
}

# The first object in a Cloudflare result is what was asked for, and an empty result or an
# error holds no "id" at all. There is no JSON parser to rely on here, and the order of fields
# in the API's answers is not documented, so this does not assume "id" comes first.
first_json_id() {
  grep -Eo '"id" *: *"[a-f0-9]+"' | sed -n '1s/.*"\([a-f0-9]*\)"$/\1/p'
}

# Walks up the DNS name to find the zone, then creates or updates the A record.
# The record is never proxied: clients need the real address for REALITY and QUIC.
ddns_cloudflare() {
  local ip="$1" api=https://api.cloudflare.com/client/v4 auth candidate zone="" answer record
  auth="Authorization: Bearer $S_CF_TOKEN"
  candidate="$S_HOST"
  while [[ "$candidate" == *.* ]]; do
    answer="$(curl -fsS --max-time 15 -H "$auth" "$api/zones?name=$candidate" 2>/dev/null || true)"
    zone="$(printf '%s' "$answer" | first_json_id)"
    [[ -n "$zone" ]] && break
    candidate="${candidate#*.}"
  done
  [[ -n "$zone" ]] || return 1
  answer="$(curl -fsS --max-time 15 -H "$auth" "$api/zones/$zone/dns_records?type=A&name=$S_HOST" 2>/dev/null || true)"
  record="$(printf '%s' "$answer" | first_json_id)"
  local body="{\"type\":\"A\",\"name\":\"$S_HOST\",\"content\":\"$ip\",\"ttl\":60,\"proxied\":false}"
  if [[ -n "$record" ]]; then
    curl -fsS --max-time 15 -X PUT -H "$auth" -H 'Content-Type: application/json' \
      -d "$body" "$api/zones/$zone/dns_records/$record" >/dev/null 2>&1
  else
    curl -fsS --max-time 15 -X POST -H "$auth" -H 'Content-Type: application/json' \
      -d "$body" "$api/zones/$zone/dns_records" >/dev/null 2>&1
  fi
}

ddns_sync() {
  local ip="$1"
  if [[ -n "${S_CF_TOKEN:-}" ]]; then
    ddns_cloudflare "$ip"
  elif [[ -n "${S_DUCKDNS_TOKEN:-}" ]]; then
    ddns_duckdns "$ip"
  else
    return 0
  fi
}

# ---------------------------------------------------------------------------
# The import link
# ---------------------------------------------------------------------------

base64url() {
  openssl enc -base64 -A | tr '+/' '-_' | tr -d '='
}

base64url_decode() {
  local value="$1" pad
  value="$(printf '%s' "$value" | tr -- '-_' '+/')"
  pad=$(((4 - ${#value} % 4) % 4))
  while ((pad > 0)); do
    value="$value="
    pad=$((pad - 1))
  done
  printf '%s' "$value" | openssl enc -base64 -d -A 2>/dev/null
}

# Compact, stable JSON: this string ends up inside a QR code, so every byte costs
# module density. The app expands it into full contract nodes (server_bundle.dart).
bundle_json() {
  local kind="$S_MODE" json
  json="{\"v\":1,\"kind\":\"$kind\",\"name\":\"$S_NAME\",\"host\":\"$S_HOST\""
  json="$json,\"reality\":{\"port\":$S_REALITY_PORT,\"uuid\":\"$S_UUID\",\"pbk\":\"$S_PUBLIC_KEY\",\"sid\":\"$S_SHORT_ID\",\"sni\":\"$S_REALITY_SNI\"}"
  json="$json,\"hy2\":{\"port\":$S_HY2_PORT,\"password\":\"$S_HY2_PASS\",\"sni\":\"$S_HY2_SNI\",\"spki\":\"$HY2_SPKI\"}"
  json="$json,\"ss\":{\"port\":$S_SS_PORT,\"password\":\"$S_SS_PASS\"}"
  if [[ -n "${S_CDN_DOMAIN:-}" ]]; then
    json="$json,\"cdn\":{\"host\":\"$S_CDN_DOMAIN\",\"port\":$S_CDN_PORT,\"uuid\":\"$S_CDN_UUID\",\"path\":\"$S_CDN_PATH\"}"
  fi
  if [[ "$kind" == relay ]]; then
    json="$json,\"exit\":{\"name\":\"$S_EXIT_NAME\",\"host\":\"$S_EXIT_HOST\",\"port\":$S_EXIT_PORT,\"password\":\"$S_EXIT_PASS\"}"
  fi
  printf '%s}' "$json"
}

write_link_files() {
  local link ss_userinfo tmp
  # Compressed because the QR code has to fit an 80-column terminal, where a code one
  # module too wide wraps into something no camera can read.
  link="aurora://v1/$(bundle_json | gzip -9 -n -c | base64url)#$S_NAME"
  tmp="$(mktemp "$LINK_FILE.XXXXXX")"
  printf '%s\n' "$link" >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$LINK_FILE"

  ss_userinfo="$(printf '%s' "2022-blake3-aes-128-gcm:$S_SS_PASS" | openssl enc -base64 -A)"
  tmp="$(mktemp "$SHARE_FILE.XXXXXX")"
  {
    printf '# Standard share links for other clients (v2rayN, NekoBox, ...). Treat as passwords.\n'
    if [[ "$S_MODE" == relay ]]; then
      printf '# These only reach the home exit: a relay rejects every other destination.\n'
    fi
    printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#%s-reality\n' \
      "$S_UUID" "$S_HOST" "$S_REALITY_PORT" "$S_REALITY_SNI" "$S_PUBLIC_KEY" "$S_SHORT_ID" "$S_NAME"
    printf 'hysteria2://%s@%s:%s/?sni=%s&alpn=h3&insecure=1&pinSHA256=%s#%s-hy2\n' \
      "$S_HY2_PASS" "$S_HOST" "$S_HY2_PORT" "$S_HY2_SNI" "$HY2_CERT_SHA256" "$S_NAME"
    printf 'ss://%s@%s:%s#%s-ss\n' "$ss_userinfo" "$S_HOST" "$S_SS_PORT" "$S_NAME"
  } >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$SHARE_FILE"
}

print_link() {
  local link
  link="$(cat "$LINK_FILE")"
  say ""
  say "${C_BOLD}Add this server to the Aurora app${C_RESET} (get it from https://github.com/SparkyWen/aurora-public/releases):"
  say "  Phone:   scan the QR code with your camera"
  say "  Desktop: Add server, then paste the link"
  say "  CLI:     aurora import '<link>'"
  say ""
  say "$link"
  say ""
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 -m 1 "$link" 2>/dev/null || true
    say ""
    # A code wider than the terminal wraps and looks almost right, but no camera can
    # read it. The ASCII form spends two characters per module.
    local width columns
    width=$(($(qrencode -t ASCII -m 1 "$link" 2>/dev/null | sed -n 1p | wc -c) / 2))
    columns="$(tput cols 2>/dev/null || printf 0)"
    if [[ -t 1 && "$columns" -gt 0 && "$columns" -lt "$width" ]]; then
      warn "This QR code needs $width columns and your terminal has $columns. Widen the window, then run: sudo aurora-node link"
    fi
  else
    say "(Install qrencode to also get a QR code here: aurora-node link)"
  fi
  say "${C_YELLOW}This link contains your server's keys. Treat it like a password.${C_RESET}"
  say "Links for other clients: $SHARE_FILE"
}

# ---------------------------------------------------------------------------
# End-to-end self-test
#
# "The service is running" and "the port is open" prove little: a wrong key, a
# broken route or a dead upstream all pass those checks. So this pushes a real
# HTTPS request through each protocol over loopback and checks where it came out.
# ---------------------------------------------------------------------------

free_local_port() {
  local port
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    port=$((20000 + (RANDOM % 30000)))
    port_in_use tcp "$port" || { printf '%s' "$port"; return 0; }
  done
  return 1
}

fetch_ip_via() {
  local proxy="$1" url ip
  for url in https://api.ipify.org https://ifconfig.me/ip https://ipv4.icanhazip.com; do
    ip="$(curl -fsS4 --max-time 12 --proxy "socks5h://127.0.0.1:$proxy" "$url" 2>/dev/null | tr -d '[:space:]')" || continue
    if is_ipv4 "$ip"; then
      printf '%s' "$ip"
      return 0
    fi
  done
  return 1
}

selftest_outbounds() {
  local chain=''
  cat <<EOF
    { "type": "vless", "tag": "o-reality", "server": "127.0.0.1", "server_port": $S_REALITY_PORT,
      "uuid": "$S_UUID", "flow": "xtls-rprx-vision",
      "tls": { "enabled": true, "server_name": "$S_REALITY_SNI",
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": { "enabled": true, "public_key": "$S_PUBLIC_KEY", "short_id": "$S_SHORT_ID" } } },
    { "type": "hysteria2", "tag": "o-hy2", "server": "127.0.0.1", "server_port": $S_HY2_PORT,
      "password": "$S_HY2_PASS",
      "tls": { "enabled": true, "server_name": "$S_HY2_SNI", "alpn": [ "h3" ],
        "certificate_public_key_sha256": [ "$HY2_SPKI" ] } },
    { "type": "shadowsocks", "tag": "o-ss", "server": "127.0.0.1", "server_port": $S_SS_PORT,
      "method": "2022-blake3-aes-128-gcm", "password": "$S_SS_PASS", "udp_over_tcp": true }
EOF
  if [[ "$S_MODE" == relay ]]; then
    for chain in reality hy2 ss; do
      cat <<EOF
    ,{ "type": "shadowsocks", "tag": "x-$chain", "server": "$S_EXIT_HOST", "server_port": $S_EXIT_PORT,
      "method": "2022-blake3-aes-128-gcm", "password": "$S_EXIT_PASS", "udp_over_tcp": true, "detour": "o-$chain" }
EOF
    done
  fi
}

self_test() {
  local expected="$1" config client_log client_pid p_reality p_hy2 p_ss p_open name target_tag failures=0 egress
  if ! { p_reality="$(free_local_port)" && p_hy2="$(free_local_port)" && p_ss="$(free_local_port)" && p_open="$(free_local_port)"; }; then
    warn "self-test skipped: no free local ports"
    return 0
  fi

  local prefix='o-'
  if [[ "$S_MODE" == relay ]]; then prefix='x-'; fi
  config="$(mktemp "$ETC_DIR/selftest.XXXXXX")"
  client_log="$(mktemp "$ETC_DIR/selftest-log.XXXXXX")"
  cat >"$config" <<EOF
{
  "log": { "level": "error" },
  "dns": { "servers": [ { "type": "local", "tag": "dns-local" } ], "strategy": "ipv4_only" },
  "inbounds": [
    { "type": "socks", "tag": "t-reality", "listen": "127.0.0.1", "listen_port": $p_reality },
    { "type": "socks", "tag": "t-hy2", "listen": "127.0.0.1", "listen_port": $p_hy2 },
    { "type": "socks", "tag": "t-ss", "listen": "127.0.0.1", "listen_port": $p_ss },
    { "type": "socks", "tag": "t-open", "listen": "127.0.0.1", "listen_port": $p_open }
  ],
  "outbounds": [
$(selftest_outbounds)
    ,{ "type": "direct", "tag": "direct" }
  ],
  "route": {
    "rules": [
      { "inbound": [ "t-reality" ], "outbound": "${prefix}reality" },
      { "inbound": [ "t-hy2" ], "outbound": "${prefix}hy2" },
      { "inbound": [ "t-ss" ], "outbound": "${prefix}ss" },
      { "inbound": [ "t-open" ], "outbound": "o-reality" }
    ],
    "final": "direct",
    "default_domain_resolver": { "server": "dns-local", "strategy": "ipv4_only" }
  }
}
EOF
  "$SB_BIN" run -c "$config" >"$client_log" 2>&1 &
  client_pid=$!
  sleep 2

  for name in reality hy2 ss; do
    case "$name" in
      reality) target_tag="$p_reality" ;;
      hy2) target_tag="$p_hy2" ;;
      ss) target_tag="$p_ss" ;;
    esac
    if egress="$(fetch_ip_via "$target_tag")"; then
      if [[ -n "$expected" && "$egress" != "$expected" ]]; then
        warn "$name works, but traffic exits from $egress instead of $expected"
        failures=$((failures + 1))
      else
        ok "$name carries traffic, exit $egress"
      fi
    else
      warn "$name carried no traffic"
      failures=$((failures + 1))
    fi
  done

  # The security property of a relay is what it refuses to do.
  if [[ "$S_MODE" == relay ]]; then
    if fetch_ip_via "$p_open" >/dev/null 2>&1; then
      warn "this relay forwarded a request to the open internet; it should only reach the home node"
      failures=$((failures + 1))
    else
      ok "relay rejects everything except the home node"
    fi
  fi

  kill "$client_pid" 2>/dev/null || true
  wait "$client_pid" 2>/dev/null || true
  rm -f "$config" "$client_log"
  return "$failures"
}

# ---------------------------------------------------------------------------
# REALITY camouflage target
#
# REALITY relays a real site's TLS handshake, and not every site survives that:
# sing-box's REALITY server fails against www.microsoft.com with "processed invalid
# connection" even though the site is healthy and speaks TLS 1.3 + X25519. Which
# sites work also varies by region and over time, so a hard-coded default is a
# latent outage. Candidates are tested for real on this machine instead.
# ---------------------------------------------------------------------------

readonly REALITY_SNI_CANDIDATES="www.apple.com www.amazon.com www.samsung.com www.nvidia.com www.oracle.com"

probe_reality_target() {
  local sni="$1" work server_port client_port keys private public uuid short_id server_pid client_pid code
  server_port="$(free_local_port)" || return 1
  client_port="$(free_local_port)" || return 1
  [[ "$server_port" != "$client_port" ]] || return 1
  work="$(mktemp -d "$ETC_DIR/probe.XXXXXX")"
  keys="$("$SB_BIN" generate reality-keypair)"
  private="$(printf '%s\n' "$keys" | awk 'tolower($1) ~ /private/ {print $2; exit}')"
  public="$(printf '%s\n' "$keys" | awk 'tolower($1) ~ /public/ {print $2; exit}')"
  uuid="$("$SB_BIN" generate uuid)"
  short_id="$(openssl rand -hex 8)"
  cat >"$work/server.json" <<EOF
{ "log": { "level": "error" },
  "inbounds": [ { "type": "vless", "listen": "127.0.0.1", "listen_port": $server_port,
    "users": [ { "uuid": "$uuid", "flow": "xtls-rprx-vision" } ],
    "tls": { "enabled": true, "server_name": "$sni",
      "reality": { "enabled": true, "handshake": { "server": "$sni", "server_port": 443 },
        "private_key": "$private", "short_id": [ "$short_id" ] } } } ],
  "outbounds": [ { "type": "direct" } ] }
EOF
  cat >"$work/client.json" <<EOF
{ "log": { "level": "error" },
  "inbounds": [ { "type": "socks", "listen": "127.0.0.1", "listen_port": $client_port } ],
  "outbounds": [ { "type": "vless", "server": "127.0.0.1", "server_port": $server_port,
    "uuid": "$uuid", "flow": "xtls-rprx-vision",
    "tls": { "enabled": true, "server_name": "$sni",
      "utls": { "enabled": true, "fingerprint": "chrome" },
      "reality": { "enabled": true, "public_key": "$public", "short_id": "$short_id" } } } ] }
EOF
  "$SB_BIN" run -c "$work/server.json" >/dev/null 2>&1 &
  server_pid=$!
  "$SB_BIN" run -c "$work/client.json" >/dev/null 2>&1 &
  client_pid=$!
  sleep 1
  code="$(curl -sS4 --max-time 10 --proxy "socks5h://127.0.0.1:$client_port" -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 2>/dev/null || true)"
  kill "$server_pid" "$client_pid" 2>/dev/null || true
  wait "$server_pid" "$client_pid" 2>/dev/null || true
  rm -rf "$work"
  [[ "$code" == 204 ]]
}

choose_reality_sni() {
  local candidate
  for candidate in $REALITY_SNI_CANDIDATES; do
    if probe_reality_target "$candidate"; then
      S_REALITY_SNI="$candidate"
      ok "REALITY camouflage target: $candidate"
      return 0
    fi
    warn "$candidate does not work as a REALITY target from here, trying the next one"
  done
  S_REALITY_SNI="${REALITY_SNI_CANDIDATES%% *}"
  warn "no camouflage target passed the test; is this machine online? Falling back to $S_REALITY_SNI"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

parse_relay_link() {
  local link="$1" encoded json
  [[ "$link" == aurora://v1/* ]] || die "expected an aurora://v1/... link from the home node"
  encoded="${link#aurora://v1/}"
  encoded="${encoded%%#*}"
  # `gzip -dc` fails on anything damaged or uncompressed, which falls through to plain JSON.
  json="$(base64url_decode "$encoded" | gzip -dc 2>/dev/null || true)"
  [[ -n "$json" ]] || json="$(base64url_decode "$encoded" || true)"
  [[ -n "$json" ]] || die "that link could not be decoded. Copy the whole line from the home node."
  case "$json" in
    *'"kind":"relay"'*) die "that is a relay's link. Use the link printed by the home node." ;;
  esac
  S_EXIT_NAME="$(printf '%s' "$json" | sed -n 's/.*"name":"\([a-z0-9-]*\)","host".*/\1/p')"
  S_EXIT_HOST="$(printf '%s' "$json" | sed -n 's/.*"host":"\([A-Za-z0-9.-]*\)","reality".*/\1/p')"
  S_EXIT_PORT="$(printf '%s' "$json" | sed -n 's/.*"ss":{"port":\([0-9]*\),.*/\1/p')"
  S_EXIT_PASS="$(printf '%s' "$json" | sed -n 's/.*"ss":{"port":[0-9]*,"password":"\([A-Za-z0-9+/=]*\)".*/\1/p')"
  is_label "$S_EXIT_NAME" || die "the home link has no valid name"
  is_ipv4 "$S_EXIT_HOST" || is_dns_name "$S_EXIT_HOST" || die "the home link has no valid address"
  is_port "$S_EXIT_PORT" || die "the home link has no valid Shadowsocks port"
  [[ -n "$S_EXIT_PASS" ]] || die "the home link has no Shadowsocks password"
}

cmd_install() {
  local command="$1"
  shift
  local arg_mode="" arg_name="" arg_host="" arg_reality="" arg_hy2="" arg_ss="" arg_reality_sni="" arg_hy2_sni=""
  local arg_upnp="" arg_allow_lan="" arg_cf="${AURORA_CF_TOKEN:-}" arg_duck="${AURORA_DUCKDNS_TOKEN:-}"
  local arg_cdn="" arg_cdn_port="" rotate=0 run_self_test=1 firewall=1 relay_link=""

  if [[ "$command" == relay ]]; then
    arg_mode=relay
    [[ $# -gt 0 && "$1" != -* ]] || die "usage: install.sh relay '<aurora://link from the home node>'"
    relay_link="$1"
    shift
  fi

  need_value() { [[ $# -ge 2 && -n "$2" ]] || die "$1 needs a value"; }
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --vps) arg_mode=vps ;;
      --home) arg_mode=home ;;
      --name) need_value "$@"; arg_name="$2"; shift ;;
      --host) need_value "$@"; arg_host="$2"; shift ;;
      --reality-port) need_value "$@"; arg_reality="$2"; shift ;;
      --hy2-port) need_value "$@"; arg_hy2="$2"; shift ;;
      --ss-port) need_value "$@"; arg_ss="$2"; shift ;;
      --reality-sni) need_value "$@"; arg_reality_sni="$2"; shift ;;
      --hy2-sni) need_value "$@"; arg_hy2_sni="$2"; shift ;;
      --no-upnp) arg_upnp=0 ;;
      --allow-lan) arg_allow_lan=1 ;;
      --cf-token) need_value "$@"; arg_cf="$2"; shift ;;
      --duckdns-token) need_value "$@"; arg_duck="$2"; shift ;;
      --cdn-domain) need_value "$@"; arg_cdn="$2"; shift ;;
      --cdn-port) need_value "$@"; arg_cdn_port="$2"; shift ;;
      --rotate) rotate=1 ;;
      --no-self-test) run_self_test=0 ;;
      --no-firewall) firewall=0 ;;
      -h | --help) usage; exit 0 ;;
      *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
  done

  require_root
  ensure_prereqs
  mkdir -p "$ETC_DIR" "$LOG_DIR"
  chmod 750 "$ETC_DIR"
  # Created under the script's umask 077 this would be 0700, and the unprivileged
  # service user could not traverse it to execute sing-box.
  (umask 022; mkdir -p "$LIB_DIR")
  load_state

  # The address the internet sees. Only fatal when no --host was given.
  local public_ip
  public_ip="$(detect_public_ip || true)"

  # Placement: explicit flag, then the previous install, then detection.
  S_MODE="${arg_mode:-${S_MODE:-}}"
  if [[ -z "$S_MODE" ]]; then
    [[ -n "$public_ip" ]] || die "could not determine this machine's public IPv4. Pass --vps or --home and --host <address>."
    S_MODE="$(detect_mode "$public_ip")"
    say "Detected a ${C_BOLD}$S_MODE${C_RESET} environment (override with --vps or --home)."
  fi

  if [[ "$S_MODE" == relay ]]; then
    # A re-run keeps the exit it already knows. Only a first install needs the link.
    if [[ -n "$relay_link" ]]; then
      parse_relay_link "$relay_link"
    elif [[ -z "${S_EXIT_HOST:-}" ]]; then
      die "a relay needs the home node's link: install.sh relay '<aurora://link>'"
    fi
  elif [[ -n "${S_EXIT_HOST:-}" ]]; then
    # Turning a relay back into an exit node: forget the old forwarding target.
    S_EXIT_NAME=""; S_EXIT_HOST=""; S_EXIT_PORT=""; S_EXIT_PASS=""
  fi

  # Name
  S_NAME="${arg_name:-${S_NAME:-$S_MODE}}"
  is_label "$S_NAME" || die "invalid --name '$S_NAME': use lowercase letters, digits and dashes (max 16, starting with a letter)"

  # Address clients dial. A value the user set stays pinned; a detected one follows
  # the public IP on re-runs.
  if [[ -n "$arg_host" ]]; then
    S_HOST="$arg_host"
    S_HOST_IS_AUTO=0
  elif [[ -z "${S_HOST:-}" || "${S_HOST_IS_AUTO:-1}" == 1 ]]; then
    [[ -n "$public_ip" ]] || die "could not determine the public IPv4. Pass --host <address>."
    S_HOST="$public_ip"
    S_HOST_IS_AUTO=1
  fi
  is_ipv4 "$S_HOST" || is_dns_name "$S_HOST" || die "invalid --host '$S_HOST'"

  # Camouflage
  # An empty REALITY target is resolved by a live test once sing-box is installed.
  S_REALITY_SNI="${arg_reality_sni:-${S_REALITY_SNI:-}}"
  S_HY2_SNI="${arg_hy2_sni:-${S_HY2_SNI:-www.bing.com}}"
  if [[ -n "$S_REALITY_SNI" ]]; then
    is_dns_name "$S_REALITY_SNI" || die "invalid --reality-sni '$S_REALITY_SNI'"
  fi
  is_dns_name "$S_HY2_SNI" || die "invalid --hy2-sni '$S_HY2_SNI'"

  # Home extras
  if [[ -n "$arg_upnp" ]]; then
    S_UPNP="$arg_upnp"
  elif [[ -z "${S_UPNP:-}" ]]; then
    if [[ "$S_MODE" == home ]]; then S_UPNP=1; else S_UPNP=0; fi
  fi
  S_ALLOW_LAN="${arg_allow_lan:-${S_ALLOW_LAN:-0}}"
  S_CF_TOKEN="${arg_cf:-${S_CF_TOKEN:-}}"
  S_DUCKDNS_TOKEN="${arg_duck:-${S_DUCKDNS_TOKEN:-}}"
  # These end up in a root-owned file that is sourced later, so only a token's
  # expected alphabet is accepted.
  [[ "$S_CF_TOKEN$S_DUCKDNS_TOKEN" =~ ^[A-Za-z0-9_-]*$ ]] || die "that DNS token contains unexpected characters"
  if [[ -n "$S_CF_TOKEN" || -n "$S_DUCKDNS_TOKEN" ]]; then
    is_dns_name "$S_HOST" || die "dynamic DNS needs --host to be the DNS name it should keep updated"
    [[ -z "$S_DUCKDNS_TOKEN" || "$S_HOST" == *.duckdns.org ]] || die "--duckdns-token needs --host <name>.duckdns.org"
  fi

  # CDN
  S_CDN_DOMAIN="${arg_cdn:-${S_CDN_DOMAIN:-}}"
  if [[ -n "$S_CDN_DOMAIN" ]]; then
    is_dns_name "$S_CDN_DOMAIN" || die "invalid --cdn-domain '$S_CDN_DOMAIN'"
  fi

  # Ports. Home routers and ISPs commonly block inbound 80/443.
  # shellcheck disable=SC2034  # read indirectly by save_state
  if [[ "$S_MODE" == home ]]; then
    choose_port tcp "$arg_reality" "${S_REALITY_PORT:-}" 8443 9443 10443 18443
    S_REALITY_PORT="$CHOSEN_PORT"
    choose_port udp "$arg_hy2" "${S_HY2_PORT:-}" 8443 9443 10443 18443
    S_HY2_PORT="$CHOSEN_PORT"
    choose_port tcp "$arg_ss" "${S_SS_PORT:-}" 2053 2083 2087 12053
    S_SS_PORT="$CHOSEN_PORT"
  else
    choose_port tcp "$arg_reality" "${S_REALITY_PORT:-}" 443 8443 9443 2096
    S_REALITY_PORT="$CHOSEN_PORT"
    choose_port udp "$arg_hy2" "${S_HY2_PORT:-}" 443 8443 9443 2096
    S_HY2_PORT="$CHOSEN_PORT"
    choose_port tcp "$arg_ss" "${S_SS_PORT:-}" 8443 2053 2083 2087
    S_SS_PORT="$CHOSEN_PORT"
  fi
  if [[ -n "$S_CDN_DOMAIN" ]]; then
    choose_port tcp "$arg_cdn_port" "${S_CDN_PORT:-}" 2083 2087 2096 8443
    S_CDN_PORT="$CHOSEN_PORT"
    case "$S_CDN_PORT" in
      443 | 2053 | 2083 | 2087 | 2096 | 8443) ;;
      *) die "--cdn-port $S_CDN_PORT is not a port Cloudflare proxies over HTTPS (use 443, 2053, 2083, 2087, 2096 or 8443)" ;;
    esac
  fi

  install_sing_box
  install_self

  if [[ -z "$S_REALITY_SNI" ]]; then
    step "Choosing a REALITY camouflage target"
    choose_reality_sni
  fi

  step "Preparing credentials"
  local had_credentials=0
  [[ -n "${S_UUID:-}" && "$rotate" != 1 ]] && had_credentials=1
  ensure_credentials "$rotate"
  ensure_certificates "$rotate"
  if [[ "$had_credentials" == 1 ]]; then
    ok "reusing existing credentials (connected clients keep working)"
  else
    ok "generated new credentials"
  fi

  step "Writing configuration"
  write_singbox_config
  S_LAST_IP="${public_ip:-${S_LAST_IP:-}}"
  save_state
  write_link_files
  service_user_setup
  ok "sing-box accepted the configuration"

  if [[ "$firewall" == 1 ]]; then
    open_firewall
  fi

  # Router and DNS before the service, so the self-test sees the final network.
  UPNP_FAILED=0
  BEHIND_CGNAT=0
  if [[ "$S_MODE" == home ]]; then
    step "Checking the home network"
    upnp_apply || true
    [[ -n "$public_ip" ]] && check_cgnat "$public_ip"
  fi
  if [[ -n "$S_CF_TOKEN$S_DUCKDNS_TOKEN" && -n "$public_ip" ]]; then
    if ddns_sync "$public_ip"; then
      ok "dynamic DNS: $S_HOST now points here"
    else
      warn "dynamic DNS update failed for $S_HOST (check the token); the timer will retry"
    fi
  fi

  step "Starting the service"
  service_restart
  if check_listeners; then
    ok "listening on TCP $S_REALITY_PORT, UDP $S_HY2_PORT and TCP $S_SS_PORT"
  fi

  local self_test_failed=0
  if [[ "$run_self_test" == 1 ]]; then
    step "Testing real traffic through each protocol"
    # A relay's exit is the home node, whose IP it cannot know for sure (DDNS).
    local expected=""
    [[ "$S_MODE" != relay ]] && expected="$public_ip"
    self_test "$expected" || self_test_failed=1
  fi

  print_summary "$self_test_failed"
  print_link
  [[ "$self_test_failed" == 0 ]] || exit 3
}

print_summary() {
  local self_test_failed="$1"
  say ""
  say "${C_BOLD}Aurora node '$S_NAME' ($S_MODE) is up.${C_RESET}"
  say "  Address:  $S_HOST"
  say "  Ports:    TCP $S_REALITY_PORT (REALITY), UDP $S_HY2_PORT (Hysteria2), TCP $S_SS_PORT (Shadowsocks)"
  if [[ -n "${S_CDN_DOMAIN:-}" ]]; then
    say "  CDN:      $S_CDN_DOMAIN:$S_CDN_PORT (needs a proxied Cloudflare record, SSL mode Full)"
  fi
  if [[ "$S_MODE" == relay ]]; then
    say "  Forwards: only to $S_EXIT_NAME ($S_EXIT_HOST:$S_EXIT_PORT)"
  fi
  [[ "$self_test_failed" == 0 ]] || warn "the traffic self-test failed; see the lines above"

  say ""
  say "${C_BOLD}Before connecting:${C_RESET}"
  if [[ "$S_MODE" == home ]]; then
    if [[ "${BEHIND_CGNAT:-0}" == 1 ]]; then
      warn "Your ISP appears to use carrier-grade NAT: the router's WAN address is not your public IP."
      warn "No port forward can work here. Ask the ISP for a public IPv4, or use a relay VPS over"
      warn "Tailscale: run this installer with --host <tailscale-ip> --no-upnp, then install a relay"
      warn "on a VPS that is on the same tailnet. See docs/self-hosting.md."
    elif [[ "${UPNP_FAILED:-0}" == 1 ]]; then
      say "  - Your router did not accept UPnP. Forward these ports to this machine by hand:"
      say "      $(firewall_port_list)  ->  $(detect_lan_ip || printf 'this machine')"
    elif [[ "${S_UPNP:-0}" != 1 ]]; then
      say "  - Forward these ports to this machine on your router: $(firewall_port_list)"
    fi
    if is_ipv4 "$S_HOST"; then
      say "  - Home IPs change. A DNS name keeps your link valid: re-run with"
      say "    --host <name> --cf-token <token>, or use --duckdns-token. See docs/self-hosting.md."
    fi
    say "  - Test from OUTSIDE your home (phone on mobile data). Testing your own public IP from"
    say "    inside the LAN is unreliable: routers can answer for ports that are closed outside."
  else
    say "  - Allow these in your cloud provider's firewall or security group: $(firewall_port_list)"
  fi
  return 0
}

cmd_link() {
  [[ -r "$LINK_FILE" ]] || die "no node is installed here (or run with sudo)"
  print_link
}

cmd_status() {
  require_root
  [[ -r "$STATE_FILE" ]] || die "no node is installed here"
  load_state
  say "Aurora node '$S_NAME' ($S_MODE), node script $AURORA_NODE_VERSION, sing-box $SING_BOX_VERSION"
  say "  Address: $S_HOST"
  say "  Ports:   TCP $S_REALITY_PORT (REALITY), UDP $S_HY2_PORT (Hysteria2), TCP $S_SS_PORT (Shadowsocks)"
  if [[ "$TEST_MODE" != 1 ]]; then
    if [[ "$PLATFORM" == linux ]]; then
      say "  Service: $(systemctl is-active aurora-node 2>/dev/null || true)"
    else
      if launchctl print system/org.aurora.node >/dev/null 2>&1; then
        say "  Service: active"
      else
        say "  Service: inactive"
      fi
    fi
  fi
  check_listeners && ok "all ports listening"
}

cmd_verify() {
  require_root
  [[ -r "$STATE_FILE" ]] || die "no node is installed here"
  load_state
  ensure_certificates 0
  local public_ip expected=""
  public_ip="$(detect_public_ip || true)"
  [[ "$S_MODE" != relay ]] && expected="$public_ip"
  step "Testing real traffic through each protocol"
  self_test "$expected" || die "the self-test failed; check 'aurora-node status' and the service log"
  ok "all protocols carry traffic"
}

cmd_rotate() {
  require_root
  [[ -r "$STATE_FILE" ]] || die "no node is installed here"
  load_state
  ensure_credentials 1
  ensure_certificates 1
  write_singbox_config
  save_state
  write_link_files
  service_user_setup
  service_restart
  ok "credentials replaced. Existing clients stop working until they import the new link."
  print_link
}

cmd_maintain() {
  require_root
  [[ -r "$STATE_FILE" ]] || exit 0
  load_state
  UPNP_FAILED=0
  upnp_apply >/dev/null 2>&1 || true
  local public_ip
  public_ip="$(detect_public_ip || true)"
  [[ -n "$public_ip" ]] || exit 0
  if [[ "$public_ip" != "${S_LAST_IP:-}" ]]; then
    if ddns_sync "$public_ip"; then
      S_LAST_IP="$public_ip"
      if [[ "${S_HOST_IS_AUTO:-0}" == 1 ]]; then
        # No DNS name to update: the published link is now stale. Refresh it so
        # `aurora-node link` is correct and say so where the owner will look.
        S_HOST="$public_ip"
        ensure_certificates 0
        write_link_files
        say "public IP changed; run 'aurora-node link' and re-import the link in the app"
      fi
      save_state
    fi
  elif [[ -n "${S_CF_TOKEN:-}${S_DUCKDNS_TOKEN:-}" ]]; then
    # Re-assert in case the record was edited or an earlier update was lost.
    ddns_sync "$public_ip" || true
  fi
}

cmd_uninstall() {
  require_root
  local purge=0
  [[ "${1:-}" == --purge ]] && purge=1
  load_state
  service_stop
  if [[ "${S_UPNP:-0}" == 1 && "$TEST_MODE" != 1 && -n "${S_REALITY_PORT:-}" ]]; then
    # shellcheck disable=SC2046
    upnp_helper unmap $(firewall_port_list) >/dev/null 2>&1 || true
  fi
  if [[ "$TEST_MODE" != 1 ]]; then
    if [[ "$PLATFORM" == linux ]]; then
      rm -f /etc/systemd/system/aurora-node.service /etc/systemd/system/aurora-node-maintain.service \
        /etc/systemd/system/aurora-node-maintain.timer /etc/sysctl.d/99-aurora-node.conf
      systemctl daemon-reload >/dev/null 2>&1 || true
      userdel "$SERVICE_USER" >/dev/null 2>&1 || true
    else
      rm -f /Library/LaunchDaemons/org.aurora.node.plist /Library/LaunchDaemons/org.aurora.node.maintain.plist
    fi
  fi
  rm -rf "$LIB_DIR" "$LOG_DIR"
  rm -f "$BIN_LINK"
  if [[ "$purge" == 1 ]]; then
    rm -rf "$ETC_DIR"
    ok "node removed, including its keys"
  else
    ok "node removed. Keys kept in $ETC_DIR so a re-install keeps the same link (--purge deletes them)."
  fi
  say "Firewall rules were left in place; close the ports yourself if nothing else uses them."
}

main() {
  init_paths
  # No arguments means a plain install, the command in the README. Normalise it here
  # because `shift` with nothing to shift fails, and under `set -e` that ends the
  # script silently.
  if [[ $# -eq 0 ]]; then set -- install; fi
  local command="$1"
  case "$command" in
    -h | --help | help) usage; exit 0 ;;
    version | --version) say "aurora-node $AURORA_NODE_VERSION (sing-box $SING_BOX_VERSION)"; exit 0 ;;
    install) shift; cmd_install install "$@" ;;
    relay) shift; cmd_install relay "$@" ;;
    link) cmd_link ;;
    status) cmd_status ;;
    verify) cmd_verify ;;
    rotate) cmd_rotate ;;
    maintain) cmd_maintain ;;
    uninstall) shift; cmd_uninstall "$@" ;;
    -*) cmd_install install "$@" ;;
    *) die "unknown command: $command (see --help)" ;;
  esac
}

main "$@"
