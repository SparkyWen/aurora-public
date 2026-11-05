#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERIFY="$ROOT/scripts/verify-path-egress.sh"
TMP="$(mktemp -d)"
SERVER_PID=''
trap '[[ -z "$SERVER_PID" ]] || kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT INT TERM

fail() {
  printf 'FAIL %s\n' "$1" >&2
  exit 1
}

[[ -x "$VERIFY" ]] || fail 'path egress verifier missing or not executable'
printf '%s\n' 'selector-test-secret' >"$TMP/secret"
chmod 600 "$TMP/secret"
printf '%s\t%s\n' \
  'verify-public' 'home-via-relay-public-reality' \
  'verify-tailnet' 'home-via-relay-tailnet-hy2' \
  'verify-home' 'home-direct-ss' >"$TMP/paths"
chmod 600 "$TMP/paths"
node - "$TMP/lease.json" "$TMP/public.json" <<'NODE'
const crypto = require('node:crypto');
const fs = require('node:fs');
const [leasePath, publicPath] = process.argv.slice(2);
const {publicKey, privateKey} = crypto.generateKeyPairSync('ed25519');
const issued = new Date(Date.now() - 60_000);
const expires = new Date(issued.getTime() + 120 * 60_000);
const timestamp = value => value.toISOString().replace(/\.\d{3}Z$/, 'Z');
const unsigned = {
  expires_at: timestamp(expires),
  home_name: 'home.example.net',
  ipv4: '8.8.4.4',
  issued_at: timestamp(issued),
  key_id: 'test-key',
  sequence: 12,
  version: 1,
};
const signature = crypto.sign(null, Buffer.from(JSON.stringify(unsigned)), privateKey).toString('base64');
fs.writeFileSync(leasePath, JSON.stringify({
  version: 1,
  key_id: unsigned.key_id,
  home_name: unsigned.home_name,
  ipv4: unsigned.ipv4,
  sequence: unsigned.sequence,
  issued_at: unsigned.issued_at,
  expires_at: unsigned.expires_at,
  signature,
}));
const der = publicKey.export({format: 'der', type: 'spki'});
fs.writeFileSync(publicPath, JSON.stringify({
  algorithm: 'ed25519',
  key_id: unsigned.key_id,
  public_key: der.subarray(der.length - 32).toString('base64'),
}));
NODE
chmod 600 "$TMP/lease.json"
chmod 644 "$TMP/public.json"

node - "$TMP/port" "$TMP/state" <<'NODE' &
const http = require('node:http');
const fs = require('node:fs');
const [portFile, stateFile] = process.argv.slice(2);
const groups = {
  'verify-public': {selected: 'public-original', all: ['public-original', 'home-via-relay-public-reality']},
  'verify-tailnet': {selected: 'tailnet-original', all: ['tailnet-original', 'home-via-relay-tailnet-hy2']},
  'verify-home': {selected: 'home-original', all: ['home-original', 'home-direct-ss']},
};
function record(value) { fs.appendFileSync(stateFile, `${value}\n`); }
const server = http.createServer((request, response) => {
  const match = request.url.match(/^\/selector\/([A-Za-z0-9._-]+)$/);
  const groupName = match && match[1];
  const group = groupName && groups[groupName];
  if (group && request.method === 'GET') {
    response.setHeader('content-type', 'application/json');
    response.end(JSON.stringify({name: groupName, now: group.selected, all: group.all}));
    return;
  }
  if (group && request.method === 'PUT') {
    if (request.headers.authorization !== 'Bearer selector-test-secret') {
      response.writeHead(401).end();
      return;
    }
    let body = '';
    request.on('data', chunk => { body += chunk; });
    request.on('end', () => {
      const selected = JSON.parse(body).name;
      if (!group.all.includes(selected)) {
        response.writeHead(400).end();
        return;
      }
      group.selected = selected;
      record(`select:${groupName}:${selected}`);
      response.writeHead(204).end();
    });
    return;
  }
  if (request.url === '/reflector-a' || request.url === '/reflector-b') {
    response.end('8.8.4.4\n');
    return;
  }
  if (request.url === '/204') {
    response.writeHead(204).end();
    return;
  }
  if (request.url === '/github') {
    response.writeHead(200, {'content-type': 'image/png'}).end('png');
    return;
  }
  if (request.url === '/download') {
    record(`range:${request.headers.range || 'missing'}`);
    const bytes = Buffer.alloc(1024 * 1024, 7);
    response.writeHead(206, {
      'content-type': 'application/octet-stream',
      'content-length': bytes.length,
      'content-range': `bytes 0-${bytes.length - 1}/${bytes.length * 2}`,
    }).end(bytes);
    return;
  }
  if (request.url === '/slow') {
    setTimeout(() => response.end('8.8.4.4\n'), 1800);
    return;
  }
  response.writeHead(404).end();
});
server.listen(0, '127.0.0.1', () => {
  fs.writeFileSync(portFile, String(server.address().port));
});
NODE
SERVER_PID=$!
for _ in $(seq 1 50); do [[ -s "$TMP/port" ]] && break; sleep 0.05; done
[[ -s "$TMP/port" ]] || fail 'fake server did not start'
PORT="$(cat "$TMP/port")"
BASE="http://127.0.0.1:$PORT"

run_verify() {
  AURORA_VERIFY_ALLOW_HTTP=1 \
  AURORA_REFLECTOR_A_URL="$BASE/reflector-a" \
  AURORA_REFLECTOR_B_URL="$BASE/reflector-b" \
  AURORA_HTTPS_204_URL="$BASE/204" \
  AURORA_GITHUB_ASSET_URL="$BASE/github" \
  AURORA_DOWNLOAD_URL="$BASE/download" \
    "$VERIFY" \
      --selector-url "$BASE/selector" \
      --selector-secret-file "$TMP/secret" \
      --path-list-file "$TMP/paths" \
      --lease-file "$TMP/lease.json" \
      --lease-public-key-file "$TMP/public.json" \
      --home-name home.example.net \
      --report "$1"
}

run_verify "$TMP/report.md" >"$TMP/output"
grep -Fq 'Overall: **PASS**' "$TMP/report.md" || fail 'successful report missing'
grep -Fq 'home-via-relay-public-reality' "$TMP/report.md" || fail 'path row missing'
grep -Fq 'range:bytes=0-1048575' "$TMP/state" || fail 'download was not bounded'
for restored in \
  'select:verify-public:public-original' \
  'select:verify-tailnet:tailnet-original' \
  'select:verify-home:home-original'; do
  grep -Fq "$restored" "$TMP/state" || fail "normal cleanup did not restore $restored"
done
if grep -Eq 'selector-test-secret|8\.8\.4\.4' "$TMP/report.md" "$TMP/output"; then
  fail 'secret or raw address leaked'
fi

jq '.ipv4 = "8.8.8.8"' "$TMP/lease.json" >"$TMP/tampered-lease.json"
chmod 600 "$TMP/tampered-lease.json"
if AURORA_VERIFY_ALLOW_HTTP=1 "$VERIFY" \
  --selector-url "$BASE/selector" --selector-secret-file "$TMP/secret" \
  --path-list-file "$TMP/paths" --lease-file "$TMP/tampered-lease.json" \
  --lease-public-key-file "$TMP/public.json" \
  --home-name home.example.net --report "$TMP/tampered.md" \
  >"$TMP/tampered.out" 2>&1; then
  fail 'tampered signed lease unexpectedly passed'
fi
grep -Fq 'FAIL lease signature' "$TMP/tampered.out" ||
  fail 'tampered lease was not rejected by signature'

printf '%s\t%s\n' 'verify-home' 'home-via-relay-public-reality' >"$TMP/wrong-owner-paths"
chmod 600 "$TMP/wrong-owner-paths"
if AURORA_VERIFY_ALLOW_HTTP=1 "$VERIFY" \
  --selector-url "$BASE/selector" --selector-secret-file "$TMP/secret" \
  --path-list-file "$TMP/wrong-owner-paths" --lease-file "$TMP/lease.json" \
  --lease-public-key-file "$TMP/public.json" \
  --home-name home.example.net --report "$TMP/wrong-owner.md" \
  >"$TMP/wrong-owner.out" 2>&1; then
  fail 'node outside its owning selector unexpectedly passed'
fi
grep -Fq 'FAIL selector ownership' "$TMP/wrong-owner.out" ||
  fail 'wrong selector ownership was not identified'

if AURORA_VERIFY_ALLOW_HTTP=1 \
  AURORA_REFLECTOR_A_URL="$BASE/slow" \
  AURORA_REFLECTOR_B_URL="$BASE/reflector-b" \
  AURORA_HTTPS_204_URL="$BASE/204" \
  AURORA_GITHUB_ASSET_URL="$BASE/github" \
  AURORA_DOWNLOAD_URL="$BASE/download" \
  AURORA_REQUEST_TIMEOUT=1 \
    "$VERIFY" --selector-url "$BASE/selector" \
      --selector-secret-file "$TMP/secret" --path-list-file "$TMP/paths" \
      --lease-file "$TMP/lease.json" \
      --lease-public-key-file "$TMP/public.json" \
      --home-name home.example.net --report "$TMP/timeout.md" \
      >"$TMP/timeout.out" 2>&1; then
  fail 'timeout unexpectedly passed'
fi
grep -Fq 'Overall: **FAIL**' "$TMP/timeout.md" || fail 'timeout report missing failure'
if grep -Eq 'selector-test-secret|8\.8\.4\.4' "$TMP/timeout.md" "$TMP/timeout.out"; then
  fail 'timeout output leaked sensitive material'
fi

if AURORA_VERIFY_ALLOW_HTTP=1 \
  AURORA_REFLECTOR_A_URL="$BASE/reflector-a" \
  AURORA_REFLECTOR_B_URL="$BASE/reflector-b" \
  AURORA_HTTPS_204_URL="$BASE/204" \
  AURORA_GITHUB_ASSET_URL="$BASE/github" \
  AURORA_DOWNLOAD_URL="$BASE/download" \
  AURORA_TEST_INTERRUPT_AFTER_SELECT=1 \
    "$VERIFY" --selector-url "$BASE/selector" \
      --selector-secret-file "$TMP/secret" --path-list-file "$TMP/paths" \
      --lease-file "$TMP/lease.json" \
      --lease-public-key-file "$TMP/public.json" \
      --home-name home.example.net --report "$TMP/interrupted.md" \
      >"$TMP/interrupted.out" 2>&1; then
  fail 'interrupt unexpectedly passed'
fi
for restored in \
  'select:verify-public:public-original' \
  'select:verify-tailnet:tailnet-original' \
  'select:verify-home:home-original'; do
  grep -Fq "$restored" "$TMP/state" || fail "interrupt cleanup did not restore $restored"
done

printf 'PASS isolated path verifier pins, bounds, redacts, times out, and restores\n'
