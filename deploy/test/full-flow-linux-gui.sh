#!/usr/bin/env bash
#
# Runs inside the X session that full-flow-linux.sh prepares: the real window, a real secret
# service, and real clicks. The Linux GUI has no other way to be exercised without a desktop.
set -uo pipefail

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
shot() { import -window root "$OUT/gui-$1.png"; }

openbox >/dev/null 2>&1 &
sleep 1
# flutter_secure_storage needs an unlocked collection, which a desktop login normally provides.
eval "$(printf 'test\n' | gnome-keyring-daemon --unlock --components=secrets 2>/dev/null)"
export GNOME_KEYRING_CONTROL SSH_AUTH_SOCK
printf '%s' "$LINK" | xclip -selection clipboard

/usr/bin/aurora >"$OUT/gui-stdout.log" 2>&1 &
APP=$!
sleep 15
if kill -0 "$APP" 2>/dev/null; then pass "the window opens and stays open"; else fail "the app exited: $(tail -n 3 "$OUT/gui-stdout.log")"; fi
WINDOW="$(xdotool search --onlyvisible --name '^Aurora$' | head -n 1)"
printf 'window: %s\n' "$WINDOW"
xdotool getwindowgeometry "$WINDOW" 2>/dev/null
shot 01-first-run

tunnel_up() { ip link show aurora0 >/dev/null 2>&1; }
egress() { curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null; }

# Flutter takes keyboard focus traversal on Linux, which unlike coordinates survives layout
# changes: back button, copy button, then the link field.
xdotool mousemove 640 548 click 1
sleep 3
shot 02-add-server
xdotool key Tab
sleep 0.3
xdotool key Tab
sleep 0.3
xdotool key Tab
sleep 0.5
xdotool key ctrl+v
sleep 1
shot 03-pasted
xdotool key Tab
sleep 0.3
xdotool key Return
sleep 4
shot 04-added

# Desktop apps connect as soon as they have a server.
deadline=$((SECONDS + 60))
until tunnel_up || ((SECONDS >= deadline)); do sleep 1; done
if tunnel_up; then pass "the window adds the server and brings up a real TUN device"; else fail "no TUN device after adding the server"; fi
got=""
deadline=$((SECONDS + 45))
until [[ "$got" == "$PUBLIC_IP" ]] || ((SECONDS >= deadline)); do
  got="$(egress || true)"
  sleep 2
done
if [[ "$got" == "$PUBLIC_IP" ]]; then pass "real HTTPS goes through the tunnel"; else fail "no traffic through the tunnel: '$got'"; fi
sleep 3
shot 05-connected

close_app() {
  kill "$APP" 2>/dev/null
  local deadline=$((SECONDS + 30))
  while tunnel_up && ((SECONDS < deadline)); do sleep 1; done
}

close_app
if tunnel_up; then fail "the tunnel outlived the app"; else pass "closing the app takes the tunnel with it"; fi

# Desktop apps connect on opening, after refreshing from the control plane if there is one.
open_and_expect_traffic() {
  /usr/bin/aurora >>"$OUT/gui-stdout.log" 2>&1 &
  APP=$!
  local deadline=$((SECONDS + 90)) got=""
  until [[ "$got" == "$PUBLIC_IP" ]] || ((SECONDS >= deadline)); do
    got="$(egress || true)"
    sleep 2
  done
  [[ "$got" == "$PUBLIC_IP" ]]
}

if [[ -n "${DELIVERY_HOOK:-}" ]]; then
  # The node's keys change, so the contract this device holds no longer works at all.
  sudo nsenter -t 1 -n bash "$DELIVERY_HOOK" update
  if open_and_expect_traffic; then pass "a signed update reaches the device and works"; else fail "the published update did not reach the device"; fi
  shot 05b-updated
  close_app
  sudo nsenter -t 1 -n bash "$DELIVERY_HOOK" tamper
  # Accepting this would point every route at an address that does not answer.
  if open_and_expect_traffic; then pass "a tampered contract is refused and the device stays connected"; else fail "the device took a contract with a bad signature"; fi
  shot 05c-tampered
  close_app
fi

/usr/bin/aurora >>"$OUT/gui-stdout.log" 2>&1 &
APP=$!
sleep 12
shot 06-restarted
if kill -0 "$APP" 2>/dev/null; then pass "the app restarts"; else fail "the app did not restart"; fi
kill "$APP" 2>/dev/null
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
