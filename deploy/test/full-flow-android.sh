#!/usr/bin/env bash
#
# The phone half of the journey, on a real Android emulator with the real app: first-run
# screen, opening an aurora:// link the way a camera does, the confirmation tap, the system
# VPN consent dialog, a real tun0, and traffic through it.
#
# Expects an emulator on adb, and a node installed on this machine by the README's command.
# Both share one public IP, so an egress check cannot tell a tunnel from a leak. The proof is a
# sentinel: a web server this firewall only lets the node's own user reach. The emulator gets
# the sentinel page only if its traffic really came out of the node.
#
#   bash deploy/test/full-flow-android.sh <aurora.apk> <link> <public-ip> <sentinel-ip> <out-dir>
set -uo pipefail

APK="$1"
LINK="$2"
PUBLIC="$3"
SENTINEL="$4"
OUT="$5"
PACKAGE=com.aurora.aurora
mkdir -p "$OUT"

PASS=0
FAIL=0
section() { printf '\n=== %s\n' "$1"; }
pass() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

shot() { adb exec-out screencap -p >"$OUT/$1.png"; }

dump_ui() {
  local attempt
  for attempt in 1 2 3 4 5; do
    if adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1 && adb pull /sdcard/ui.xml "$OUT/ui.xml" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# Prints "x y" for the first element whose text or content description is the label. With a
# trailing "*" the label is matched as a substring, so "Connect" alone never means "Connected".
find_center() {
  python3 - "$OUT/ui.xml" "$1" <<'PY'
import re
import sys
import xml.etree.ElementTree as ET

label = sys.argv[2]
partial = label.endswith("*")
label = label.rstrip("*")
for node in ET.parse(sys.argv[1]).iter("node"):
    values = (node.get("text", ""), node.get("content-desc", ""))
    if any(label in value if partial else label == value for value in values):
        x1, y1, x2, y2 = map(int, re.findall(r"\d+", node.get("bounds")))
        print((x1 + x2) // 2, (y1 + y2) // 2)
        break
PY
}

see() {
  dump_ui || return 1
  [[ -n "$(find_center "$1")" ]]
}

wait_for() {
  local label="$1" seconds="${2:-30}" deadline=$((SECONDS + ${2:-30}))
  while ((SECONDS < deadline)); do
    see "$label" && return 0
    sleep 1
  done
  return 1
}

tap() {
  wait_for "$1" "${2:-30}" || return 1
  local position
  position="$(find_center "$1")"
  # shellcheck disable=SC2086
  adb shell input tap $position
}

expect() {
  local name="$1"
  shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}

# Android ships no HTTP client for the shell, so a static busybox is pushed for the probes.
BUSYBOX=/data/local/tmp/busybox
fetch() { adb shell "$BUSYBOX wget -q -T 8 -O - $*" 2>/dev/null; }

sentinel_reachable() { fetch "http://$SENTINEL/sentinel.txt" | grep -q 'came through the node'; }
sentinel_unreachable() { ! sentinel_reachable; }

sentinel_within() {
  local seconds="$1" deadline=$((SECONDS + $1))
  while ((SECONDS < deadline)); do
    sentinel_reachable && return 0
    sleep 2
  done
  return 1
}

# Android 13 asks for notification permission the first time the app opens.
allow_notifications() {
  if wait_for "ALLOW" 12; then
    tap "ALLOW" 3
    sleep 1
  fi
}

# `ip link` is denied to the shell user. ConnectivityService knows what it brought up, but only
# its "Current Networks" section is current: the rest of the dump also keeps recent history.
tun_present() {
  adb shell dumpsys connectivity 2>/dev/null |
    sed -n '/^Current Networks:/,/^Status for known UIDs/p' | grep -q 'ni{VPN CONNECTED'
}
tun_absent() { ! tun_present; }

adb push "$(command -v busybox)" "$BUSYBOX" >/dev/null
adb shell chmod 755 "$BUSYBOX"

section "First run"
expect "the sentinel is unreachable without the tunnel" sentinel_unreachable
expect "the APK installs" adb install -r "$APK"
adb logcat -c
adb shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
allow_notifications
expect "the app opens on the first-run screen" wait_for "Add your first server" 60
shot 01-first-run
expect "the first-run screen offers to add a server" see "Add a server"

section "The add-server page"
tap "Add a server"
expect "the add-server page opens" wait_for "Paste" 15
shot 02-add-server-page
adb shell input keyevent KEYCODE_BACK
wait_for "Add your first server" 15 >/dev/null

# Quoted for the device shell: the fragment and any special characters must survive it.
open_link() { adb shell "am start -a android.intent.action.VIEW -d '$LINK'" >"$OUT/am-start.log" 2>&1; }

section "A link while the app is open"
open_link
expect "the link opens the app and asks first" wait_for "Add this server?*" 30
shot 03-deep-link-running
expect "it says which server, by name and address" see "vps ($PUBLIC)*"
expect "it warns about what a server can see" see "Only add links you created yourself*"
tap "Cancel" 5
adb shell input keyevent KEYCODE_BACK
expect "a link nobody confirmed adds nothing" wait_for "Add your first server" 15

section "A link while the app is closed, which is what scanning a QR code usually is"
adb shell am force-stop "$PACKAGE"
sleep 1
open_link
expect "the link starts the app and asks first" wait_for "Add this server?*" 60
shot 04-deep-link-cold-start
expect "the link is not called damaged" test -z "$(find_center 'This link is damaged*')"
expect "it says which server here too" see "vps ($PUBLIC)*"
tap "Add server*" 10
expect "the tap adds the server and leads to Connect" wait_for "Connect" 30
sleep 2
shot 05-server-added
if see "Add your first server"; then fail "the first-run screen is still showing"; else pass "the first-run screen is gone"; fi

section "Connecting"
tap "Connect" 15
# The system's own consent dialog appears once, and only the first time.
if wait_for "OK" 15; then
  shot 06-vpn-consent
  tap "OK" 5
  pass "the system asks for VPN consent, and the app takes the answer"
else
  fail "no VPN consent dialog appeared"
fi
expect "the app reports connected" wait_for "Connected" 60
sleep 3
shot 07-connected
expect "a real tun0 exists" tun_present
adb shell dumpsys connectivity >"$OUT/connectivity.txt" 2>&1
expect "Android has a VPN network up" grep -qE 'VPN.*CONNECTED|type: VPN' "$OUT/connectivity.txt"
expect "the tunnel carries traffic out of the node" sentinel_within 45
# ping resolves through the phone's real resolver before it sends anything, and that resolver
# is the tunnel's now. Its ICMP may well go unanswered; the name is what this is after.
resolved="$(adb shell ping -c 1 -W 3 api.ipify.org 2>/dev/null | sed -n 's/^PING [^ ]* (\([0-9.]*\)).*/\1/p')"
printf 'api.ipify.org resolved to: %s\n' "$resolved"
expect "a name resolves through the tunnel" test -n "$resolved"
answer="$(fetch --header "'Host: api.ipify.org'" "http://$resolved/")"
printf 'egress through the tunnel: %s\n' "$answer"
if grep -qF "$PUBLIC" <<<"$answer"; then
  pass "real traffic exits from the server's address"
else
  fail "traffic through the tunnel did not exit from $PUBLIC"
fi
sleep 20
shot 07b-network-check
expect "the app's own check agrees" wait_for "Exit: verified and usable*" 60

section "Failover: the app is left with one protocol mid-session"
started=$SECONDS
sudo iptables -I INPUT 1 -d "$PUBLIC" -p tcp --dport 443 -j REJECT
sudo iptables -I INPUT 1 -d "$PUBLIC" -p udp --dport 443 -j DROP
if sentinel_within 180; then
  pass "traffic came back through Shadowsocks after $((SECONDS - started))s"
else
  fail "traffic did not recover within 180s"
fi
shot 08-after-failover
sudo iptables -D INPUT -d "$PUBLIC" -p tcp --dport 443 -j REJECT
sudo iptables -D INPUT -d "$PUBLIC" -p udp --dport 443 -j DROP

section "Disconnecting"
wait_for "Disconnect" 15 >/dev/null
tap "Disconnect" 10
sleep 5
shot 09-disconnected
expect "tun0 goes away" tun_absent
expect "the sentinel is unreachable again" sentinel_unreachable

section "The server survives a restart"
adb shell am force-stop "$PACKAGE"
adb shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
expect "the app opens straight on Connect" wait_for "Connect" 60
if see "Add your first server"; then fail "the app forgot the server"; else pass "the app remembers the server"; fi
shot 10-restarted
tap "Connect" 10
expect "it reconnects without asking for consent again" wait_for "Connected" 60
expect "and carries traffic" sentinel_within 45
wait_for "Disconnect" 15 >/dev/null
tap "Disconnect" 10
sleep 3
adb logcat -d >"$OUT/logcat.txt" 2>&1

section "Result"
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
