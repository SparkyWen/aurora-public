#!/usr/bin/env bash
# Prove that every path of a signed-egress setup really exits at the home node's leased
# address. See docs/advanced-signed-egress.md. For ordinary setups, scripts/verify-egress.sh
# is simpler and needs no running tunnel.
#
# Usage:
#   scripts/verify-path-egress.sh --selector-url <base-url> --selector-secret-file <file> \
#     --path-list-file <file> --lease-file <file> --lease-public-key-file <file> \
#     --home-name <fqdn> --report <file>
#
#   --selector-url            Clash API proxies URL of the sing-box this machine's traffic
#                             runs through. https://, or http://127.0.0.1:<port>/proxies
#                             with AURORA_VERIFY_ALLOW_HTTP=1 in the environment
#   --selector-secret-file    Clash API secret
#   --path-list-file          Tab-separated lines of "<selector group>\t<outbound tag>"
#   --lease-file              A lease fetched from GET /v2/egress-lease
#   --lease-public-key-file   The metadata file from `aurora-home-agent keygen`
#   --home-name               The lease's home_name
#   --report                  Where to write the Markdown report
#
# The secret, path list and lease files must not be accessible to group or others.
#
# It verifies the lease signature and identity first, then pins each listed outbound in
# its selector, runs DNS, HTTPS, two reflector, warm-request and bounded-download probes
# through it, and restores the original selection on every exit path, including an
# interrupt. Reports and output never contain a raw address or a credential.
#
# Needs curl, jq, shasum, and either OpenSSL 3 or Node.js for Ed25519 verification (the
# LibreSSL that macOS ships as openssl cannot do it).
set -uo pipefail

usage() {
  printf 'usage: %s --selector-url <base-url> --selector-secret-file <file> --path-list-file <file> --lease-file <file> --lease-public-key-file <file> --home-name <fqdn> --report <file>\n' "$0" >&2
  exit 64
}

is_ipv4() {
  local value="$1" part
  local -a parts
  IFS=. read -r -a parts <<<"$value"
  [[ ${#parts[@]} -eq 4 ]] || return 1
  for part in "${parts[@]}"; do
    [[ "$part" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
    ((10#$part <= 255)) || return 1
  done
}

is_dns_name() {
  local value="$1" label
  local -a labels
  [[ -n "$value" && ${#value} -le 253 && "$value" == "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" && "$value" != *. ]] || return 1
  [[ "$value" == *.* ]] || return 1
  IFS=. read -r -a labels <<<"$value"
  for label in "${labels[@]}"; do
    [[ -n "$label" && ${#label} -le 63 && "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
  case "$value" in
    invalid|*.invalid|test|*.test|example|*.example|localhost|*.localhost) return 1 ;;
  esac
}

# Captured once rather than piped into `grep -q`: grep's early exit can kill openssl with
# SIGPIPE, and under pipefail that would read as "unsupported".
OPENSSL_PKEYUTL_HELP="$(openssl pkeyutl -help 2>&1 || true)"

# macOS's openssl is LibreSSL, whose pkeyutl has no -rawin and so cannot verify Ed25519.
verify_ed25519() {
  local public_der="$1" signature="$2" message="$3"
  if [[ "$OPENSSL_PKEYUTL_HELP" == *-rawin* ]]; then
    openssl pkeyutl -verify -pubin -keyform DER -inkey "$public_der" \
      -rawin -in "$message" -sigfile "$signature" >/dev/null 2>&1
    return
  fi
  node -e '
    const crypto = require("node:crypto");
    const fs = require("node:fs");
    const [der, signature, message] = process.argv.slice(1);
    const key = crypto.createPublicKey({key: fs.readFileSync(der), format: "der", type: "spki"});
    process.exit(crypto.verify(null, fs.readFileSync(message), key, fs.readFileSync(signature)) ? 0 : 1);
  ' "$public_der" "$signature" "$message" >/dev/null 2>&1
}

SELECTOR_URL=''
SECRET_FILE=''
PATH_LIST_FILE=''
LEASE_FILE=''
LEASE_PUBLIC_KEY_FILE=''
HOME_NAME=''
REPORT=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --selector-url) SELECTOR_URL="${2:-}"; shift 2 ;;
    --selector-secret-file) SECRET_FILE="${2:-}"; shift 2 ;;
    --path-list-file) PATH_LIST_FILE="${2:-}"; shift 2 ;;
    --lease-file) LEASE_FILE="${2:-}"; shift 2 ;;
    --lease-public-key-file) LEASE_PUBLIC_KEY_FILE="${2:-}"; shift 2 ;;
    --home-name) HOME_NAME="${2:-}"; shift 2 ;;
    --report) REPORT="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$SELECTOR_URL" && -n "$SECRET_FILE" && -n "$PATH_LIST_FILE" && -n "$LEASE_FILE" && -n "$LEASE_PUBLIC_KEY_FILE" && -n "$HOME_NAME" && -n "$REPORT" ]] || usage
is_dns_name "$HOME_NAME" || usage

for dependency in curl jq openssl shasum; do
  command -v "$dependency" >/dev/null 2>&1 || {
    printf 'FAIL missing dependency\n' >&2
    exit 69
  }
done
[[ "$OPENSSL_PKEYUTL_HELP" == *-rawin* ]] || command -v node >/dev/null 2>&1 || {
  printf 'FAIL missing dependency: Ed25519 verification needs OpenSSL 3 or Node.js\n' >&2
  exit 69
}

# Not `stat -f ... || stat -c ...`: on Linux, `stat -f` queries the filesystem and exits
# 0, so the fallback never runs and the "mode" is garbage.
file_mode() {
  if [[ "$(uname -s)" == Darwin ]]; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

require_protected_file() {
  local protected_file="$1" mode
  [[ -f "$protected_file" && ! -L "$protected_file" ]] || return 1
  mode="$(file_mode "$protected_file")" || return 1
  mode="${mode#0}"
  [[ -n "$mode" ]] || mode=0
  (( 10#$mode % 100 == 0 ))
}

if ! require_protected_file "$SECRET_FILE" ||
   ! require_protected_file "$PATH_LIST_FILE" ||
   ! require_protected_file "$LEASE_FILE"; then
  printf 'FAIL protected input mode\n' >&2
  exit 65
fi
[[ -f "$LEASE_PUBLIC_KEY_FILE" && ! -L "$LEASE_PUBLIC_KEY_FILE" ]] || {
  printf 'FAIL lease trust root\n' >&2
  exit 65
}

ALLOW_HTTP="${AURORA_VERIFY_ALLOW_HTTP:-0}"
case "$SELECTOR_URL" in
  https://*) ;;
  http://127.0.0.1:*|http://localhost:*) [[ "$ALLOW_HTTP" == 1 ]] || usage ;;
  *) usage ;;
esac
[[ "$SELECTOR_URL" != *'?'* && "$SELECTOR_URL" != *'#'* && "$SELECTOR_URL" != *'@'* ]] || usage

REFLECTOR_A="${AURORA_REFLECTOR_A_URL:-https://api.ipify.org}"
REFLECTOR_B="${AURORA_REFLECTOR_B_URL:-https://ifconfig.me/ip}"
HTTPS_204="${AURORA_HTTPS_204_URL:-https://www.gstatic.com/generate_204}"
GITHUB_ASSET="${AURORA_GITHUB_ASSET_URL:-https://github.githubassets.com/favicons/favicon.png}"
DOWNLOAD_URL="${AURORA_DOWNLOAD_URL:-https://speed.cloudflare.com/__down?bytes=1048576}"
REQUEST_TIMEOUT="${AURORA_REQUEST_TIMEOUT:-12}"
[[ "$REQUEST_TIMEOUT" =~ ^[1-9][0-9]?$ ]] || usage
for target_url in "$REFLECTOR_A" "$REFLECTOR_B" "$HTTPS_204" "$GITHUB_ASSET" "$DOWNLOAD_URL"; do
  case "$target_url" in
    https://*) ;;
    http://127.0.0.1:*|http://localhost:*) [[ "$ALLOW_HTTP" == 1 ]] || usage ;;
    *) usage ;;
  esac
done

TMP="$(mktemp -d)"
umask 077
CURL_SELECTOR_CONFIG="$TMP/selector.curl"
SECRET="$(tr -d '\r\n' <"$SECRET_FILE")"
[[ -n "$SECRET" && ${#SECRET} -le 512 ]] || {
  printf 'FAIL selector authentication\n' >&2
  rm -rf "$TMP"
  exit 65
}
printf 'header = "Authorization: Bearer %s"\n' "$SECRET" >"$CURL_SELECTOR_CONFIG"
unset SECRET

SELECTOR_URL="${SELECTOR_URL%/}"
ORIGINAL_SELECTIONS="$TMP/original-selections.tsv"
: >"$ORIGINAL_SELECTIONS"
CLEANUP_READY=0
restore_selector() {
  local selector_group original_selection restore_failed=0
  [[ "$CLEANUP_READY" == 1 ]] || return 0
  while IFS=$'\t' read -r selector_group original_selection; do
    [[ -n "$selector_group" && -n "$original_selection" ]] || continue
    printf '%s' "$original_selection" | jq -R '{name:.}' >"$TMP/selection.json"
    curl --config "$CURL_SELECTOR_CONFIG" --silent --show-error --fail \
      --max-time "$REQUEST_TIMEOUT" --request PUT \
      --header 'content-type: application/json' \
      --data-binary "@$TMP/selection.json" \
      "$SELECTOR_URL/$selector_group" >/dev/null 2>&1 || restore_failed=1
  done <"$ORIGINAL_SELECTIONS"
  ((restore_failed == 0))
}
cleanup() {
  local task_exit="$?"
  trap - EXIT
  restore_selector || true
  rm -rf "$TMP"
  exit "$task_exit"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# Verify the exact trust-root identity and Ed25519 signature before touching a
# selector. The public metadata is generated by aurora-home-agent keygen.
EXPECTED_KEY_ID="$(jq -er '
  select(type == "object") |
  select((keys | sort) == ["algorithm","key_id","public_key"]) |
  select(.algorithm == "ed25519") |
  .key_id | select(type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"))
' "$LEASE_PUBLIC_KEY_FILE" 2>/dev/null || true)"
PUBLIC_KEY_B64="$(jq -er '.public_key | select(type == "string")' "$LEASE_PUBLIC_KEY_FILE" 2>/dev/null || true)"
if [[ -z "$EXPECTED_KEY_ID" || -z "$PUBLIC_KEY_B64" ]] || ! jq -e \
  --arg key_id "$EXPECTED_KEY_ID" --arg home_name "$HOME_NAME" '
    select(type == "object") |
    select((keys | sort) == ["expires_at","home_name","ipv4","issued_at","key_id","sequence","signature","version"]) |
    .version == 1 and .key_id == $key_id and .home_name == $home_name and
    (.ipv4 | type == "string" and test("^(?:0|[1-9][0-9]{0,2})(?:\\.(?:0|[1-9][0-9]{0,2})){3}$")) and
    (.sequence | type == "number" and . > 0 and . <= 9007199254740991 and floor == .) and
    (.issued_at | type == "string") and (.expires_at | type == "string") and
    (.signature | type == "string" and length > 0)
  ' "$LEASE_FILE" >/dev/null 2>&1; then
  printf 'FAIL lease artifact\n' >&2
  exit 1
fi
printf '\060\052\060\005\006\003\053\145\160\003\041\000' >"$TMP/public.der"
if ! printf '%s' "$PUBLIC_KEY_B64" | openssl base64 -d -A >>"$TMP/public.der" 2>/dev/null ||
   [[ "$(wc -c <"$TMP/public.der" | tr -d '[:space:]')" != 44 ]]; then
  printf 'FAIL lease trust root\n' >&2
  exit 1
fi
if ! jq -er '.signature' "$LEASE_FILE" | openssl base64 -d -A >"$TMP/signature.bin" 2>/dev/null ||
   [[ "$(wc -c <"$TMP/signature.bin" | tr -d '[:space:]')" != 64 ]]; then
  printf 'FAIL lease signature\n' >&2
  exit 1
fi
jq -cS 'del(.signature)' "$LEASE_FILE" | tr -d '\n' >"$TMP/unsigned.json"
if ! verify_ed25519 "$TMP/public.der" "$TMP/signature.bin" "$TMP/unsigned.json"; then
  printf 'FAIL lease signature\n' >&2
  exit 1
fi
EXPECTED_IP="$(jq -r '.ipv4' "$LEASE_FILE")"
if ! is_ipv4 "$EXPECTED_IP" || ! awk -F. '
  NF != 4 { exit 1 }
  {
    if ($1 == 0 || $1 == 10 || $1 == 127 || $1 >= 224) exit 1
    if ($1 == 100 && $2 >= 64 && $2 <= 127) exit 1
    if ($1 == 169 && $2 == 254) exit 1
    if ($1 == 172 && $2 >= 16 && $2 <= 31) exit 1
    if ($1 == 192 && ($2 == 168 || ($2 == 0 && ($3 == 0 || $3 == 2)) || ($2 == 88 && $3 == 99))) exit 1
    if ($1 == 198 && ($2 == 18 || $2 == 19 || ($2 == 51 && $3 == 100))) exit 1
    if ($1 == 203 && $2 == 0 && $3 == 113) exit 1
  }
' <<<"$EXPECTED_IP"; then
  printf 'FAIL lease artifact\n' >&2
  exit 1
fi
ISSUED_EPOCH="$(jq -er '.issued_at | fromdateiso8601' "$LEASE_FILE" 2>/dev/null || true)"
EXPIRES_EPOCH="$(jq -er '.expires_at | fromdateiso8601' "$LEASE_FILE" 2>/dev/null || true)"
NOW_EPOCH="$(date -u +%s)"
NOW_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [[ ! "$ISSUED_EPOCH" =~ ^[0-9]+$ || ! "$EXPIRES_EPOCH" =~ ^[0-9]+$ ]] ||
   (( EXPIRES_EPOCH <= NOW_EPOCH || EXPIRES_EPOCH <= ISSUED_EPOCH ||
      EXPIRES_EPOCH - ISSUED_EPOCH > 7500 || ISSUED_EPOCH > NOW_EPOCH + 300 )); then
  printf 'FAIL lease expired\n' >&2
  exit 1
fi
EGRESS_HASH="$(printf '%s' "$EXPECTED_IP" | shasum -a 256 | awk '{print substr($1,1,12)}')"

PATH_GROUPS=()
PATH_TAGS=()
while IFS=$'\t' read -r selector_group path_tag extra || [[ -n "$selector_group$path_tag$extra" ]]; do
  [[ -z "$selector_group" || "$selector_group" == \#* ]] && continue
  [[ -z "$extra" && "$selector_group" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ &&
     "$path_tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || {
    printf 'FAIL path list\n' >&2
    exit 1
  }
  for existing in "${PATH_TAGS[@]:-}"; do
    [[ "$existing" != "$path_tag" ]] || {
      printf 'FAIL path list\n' >&2
      exit 1
    }
  done
  PATH_GROUPS[${#PATH_GROUPS[@]}]="$selector_group"
  PATH_TAGS[${#PATH_TAGS[@]}]="$path_tag"
done <"$PATH_LIST_FILE"
(( ${#PATH_TAGS[@]} > 0 )) || {
  printf 'FAIL path list\n' >&2
  exit 1
}

for index in "${!PATH_TAGS[@]}"; do
  selector_group="${PATH_GROUPS[$index]}"
  path_tag="${PATH_TAGS[$index]}"
  if ! curl --config "$CURL_SELECTOR_CONFIG" --silent --show-error --fail \
    --max-time "$REQUEST_TIMEOUT" "$SELECTOR_URL/$selector_group" \
    >"$TMP/group.json" 2>/dev/null ||
    ! jq -e --arg group "$selector_group" --arg tag "$path_tag" '
      .name == $group and (.now | type == "string" and length > 0) and
      (.all | type == "array" and index($tag) != null)
    ' "$TMP/group.json" >/dev/null 2>&1; then
    printf 'FAIL selector ownership\n' >&2
    exit 1
  fi
  if ! awk -F '\t' -v group="$selector_group" '$1 == group { found=1 } END { exit !found }' "$ORIGINAL_SELECTIONS"; then
    original_selection="$(jq -er '.now' "$TMP/group.json")"
    [[ "$original_selection" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || {
      printf 'FAIL selector response\n' >&2
      exit 1
    }
    printf '%s\t%s\n' "$selector_group" "$original_selection" >>"$ORIGINAL_SELECTIONS"
    CLEANUP_READY=1
  fi
done

mkdir -p "$(dirname "$REPORT")"
REPORT_TMP="$TMP/report.md"
{
  printf '# Aurora Isolated Path Egress Verification\n\n'
  printf -- '- Generated (UTC): %s\n' "$NOW_UTC"
  # Markdown backticks are literal.
  # shellcheck disable=SC2016
  printf -- '- Household egress hash: `%s`\n' "$EGRESS_HASH"
  printf -- '- Lease state: Ed25519 verified, identity-bound, unexpired\n\n'
  printf '| Path | DNS | HTTPS 204 | GitHub asset | Dual reflector | Warm request | Bounded download | Result |\n'
  printf '|---|---:|---:|---:|---:|---:|---:|---:|\n'
} >"$REPORT_TMP"

select_path() {
  local selector_group="$1" path_tag="$2"
  printf '%s' "$path_tag" | jq -R '{name:.}' >"$TMP/selection.json"
  curl --config "$CURL_SELECTOR_CONFIG" --silent --show-error --fail \
    --max-time "$REQUEST_TIMEOUT" --request PUT \
    --header 'content-type: application/json' \
    --data-binary "@$TMP/selection.json" "$SELECTOR_URL/$selector_group" >/dev/null 2>&1 &&
  curl --config "$CURL_SELECTOR_CONFIG" --silent --show-error --fail \
    --max-time "$REQUEST_TIMEOUT" "$SELECTOR_URL/$selector_group" \
    >"$TMP/selected.json" 2>/dev/null &&
  jq -e --arg group "$selector_group" --arg tag "$path_tag" '
    .name == $group and .now == $tag and
    (.all | type == "array" and index($tag) != null)
  ' "$TMP/selected.json" >/dev/null 2>&1
}

resolve_url_host() {
  local target_url="$1" authority host
  authority="${target_url#*://}"
  authority="${authority%%/*}"
  host="${authority%%:*}"
  if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    return 0
  fi
  if command -v dscacheutil >/dev/null 2>&1; then
    dscacheutil -q host -a name "$host" 2>/dev/null | grep -q '^ip_address:'
  elif command -v getent >/dev/null 2>&1; then
    getent ahosts "$host" >/dev/null 2>&1
  else
    nslookup "$host" >/dev/null 2>&1
  fi
}

probe_http_code() {
  local target_url="$1" accepted="$2" code
  code="$(curl --silent --show-error --location --output /dev/null \
    --connect-timeout "$REQUEST_TIMEOUT" --max-time "$REQUEST_TIMEOUT" \
    --write-out '%{http_code}' "$target_url" 2>/dev/null || true)"
  [[ "$code" =~ $accepted ]]
}

probe_reflectors() {
  local first second
  first="$(curl --silent --show-error --fail --location --max-time "$REQUEST_TIMEOUT" \
    "$REFLECTOR_A" 2>/dev/null | tr -d '[:space:]' || true)"
  second="$(curl --silent --show-error --fail --location --max-time "$REQUEST_TIMEOUT" \
    "$REFLECTOR_B" 2>/dev/null | tr -d '[:space:]' || true)"
  [[ -n "$first" && "$first" == "$EXPECTED_IP" && "$second" == "$EXPECTED_IP" ]]
}

probe_warm_request() {
  curl --silent --show-error --location --output /dev/null \
    --connect-timeout "$REQUEST_TIMEOUT" --max-time "$REQUEST_TIMEOUT" \
    "$HTTPS_204" >/dev/null 2>&1 &&
  curl --silent --show-error --location --output /dev/null \
    --connect-timeout "$REQUEST_TIMEOUT" --max-time "$REQUEST_TIMEOUT" \
    --write-out '%{time_total}' "$HTTPS_204" >"$TMP/warm" 2>/dev/null &&
  grep -Eq '^[0-9]+\.[0-9]+$' "$TMP/warm"
}

probe_bounded_download() {
  local code bytes
  code="$(curl --silent --show-error --location --range 0-1048575 \
    --max-filesize 1048576 --connect-timeout "$REQUEST_TIMEOUT" \
    --max-time "$REQUEST_TIMEOUT" --output "$TMP/download" \
    --write-out '%{http_code}' "$DOWNLOAD_URL" 2>/dev/null || true)"
  bytes="$(wc -c <"$TMP/download" 2>/dev/null | tr -d '[:space:]' || true)"
  [[ "$code" =~ ^(200|206)$ && "$bytes" =~ ^[0-9]+$ ]] || return 1
  (( bytes > 0 && bytes <= 1048576 ))
}

PASS_COUNT=0
FAIL_COUNT=0
FIRST_SELECTION=1
for index in "${!PATH_TAGS[@]}"; do
  selector_group="${PATH_GROUPS[$index]}"
  path_tag="${PATH_TAGS[$index]}"
  dns_result=FAIL
  https_result=FAIL
  github_result=FAIL
  reflector_result=FAIL
  warm_result=FAIL
  download_result=FAIL
  row_result=FAIL
  if select_path "$selector_group" "$path_tag"; then
    if [[ "$FIRST_SELECTION" == 1 && "${AURORA_TEST_INTERRUPT_AFTER_SELECT:-0}" == 1 ]]; then
      kill -TERM "$$"
    fi
    FIRST_SELECTION=0
    resolve_url_host "$HTTPS_204" && dns_result=PASS
    probe_http_code "$HTTPS_204" '^204$' && https_result=PASS
    probe_http_code "$GITHUB_ASSET" '^(2[0-9][0-9]|3[0-9][0-9])$' && github_result=PASS
    probe_reflectors && reflector_result=PASS
    probe_warm_request && warm_result=PASS
    probe_bounded_download && download_result=PASS
  fi
  if [[ "$dns_result$https_result$github_result$reflector_result$warm_result$download_result" == 'PASSPASSPASSPASSPASSPASS' ]]; then
    row_result=PASS
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
  printf '| %s | %s | %s | %s | %s | %s | %s | %s |\n' \
    "$path_tag" "$dns_result" "$https_result" "$github_result" \
    "$reflector_result" "$warm_result" "$download_result" "$row_result" >>"$REPORT_TMP"
  printf '%s %s\n' "$row_result" "$path_tag"
done

if restore_selector; then
  CLEANUP_READY=0
else
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '\n- Selector restore: **FAIL**\n' >>"$REPORT_TMP"
fi
OVERALL=PASS
(( FAIL_COUNT == 0 )) || OVERALL=FAIL
{
  printf '\n- Overall: **%s**\n' "$OVERALL"
  printf -- '- Totals: PASS=%d, FAIL=%d\n' "$PASS_COUNT" "$FAIL_COUNT"
  printf '\nRaw addresses, selector credentials, and response bodies are intentionally omitted.\n'
} >>"$REPORT_TMP"
mv "$REPORT_TMP" "$REPORT"
printf 'SUMMARY pass=%d fail=%d egress_hash=%s\n' "$PASS_COUNT" "$FAIL_COUNT" "$EGRESS_HASH"
(( FAIL_COUNT == 0 ))
