#!/usr/bin/env bash
#
# Fails if the repository drifts away from what makes it safe to publish: English only, and no public
# addresses outside the ranges reserved for documentation. It cannot catch everything, but it catches
# the mistakes that are easy to make when pasting from a real setup.
#
#   bash scripts/check-repo-policy.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

python3 - <<'PY'
import ipaddress
import re
import subprocess
import sys

SKIP_SUFFIXES = (".png", ".ico", ".icns", ".srs", ".jar", ".lock", ".sum")
SKIP_FILES = {"LICENSE", "scripts/check-repo-policy.sh"}

# Addresses that are fine to appear: well-known public DNS and connectivity-check services the code
# really uses. Everything else public must come from the documentation ranges.
ALLOWED_PUBLIC = {
    "1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4", "9.9.9.9", "223.5.5.5", "223.6.6.6",
    "119.29.29.29", "114.114.114.114", "208.67.222.222", "208.67.220.220", "94.140.14.14",
    "101.101.101.101", "149.112.112.112", "180.76.76.76",
    "192.88.99.0",  # deprecated 6to4 relay range, a bogon constant in edge-agent's lease validation
}
DOCUMENTATION = [ipaddress.ip_network(n) for n in ("192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24")]

CJK = re.compile("[\u4e00-\u9fff\u3000-\u303f\uff00-\uffef]")
IPV4 = re.compile(r"(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9.])")
# Credentials shapes that have no business in a commit.
SECRETS = [
    (re.compile(r"(?:gh[pousr]_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,})"), "API token"),
    (re.compile(r"aurora://v1/[A-Za-z0-9_-]{60,}"), "real aurora:// link"),
    (re.compile(r"hysteria2://[^@\s/]{8,}@(?!(?:203\.0\.113|198\.51\.100|192\.0\.2)\.)[0-9]"), "real share link"),
]
TEST_KEY_ALLOW = ("app/test/fixtures/untrusted_tls_fixture.dart",)

files = subprocess.run(
    ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
    capture_output=True, text=True, check=True,
).stdout.splitlines()

problems = []
for path in files:
    if path.endswith(SKIP_SUFFIXES) or path in SKIP_FILES:
        continue
    try:
        text = open(path, encoding="utf-8").read()
    except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError):
        continue
    for number, line in enumerate(text.splitlines(), 1):
        if CJK.search(line):
            problems.append(f"{path}:{number}: non-English text")
        for match in IPV4.findall(line):
            try:
                address = ipaddress.ip_address(match)
            except ValueError:
                continue  # version-like strings such as 999.1.1.1 used as negative tests
            if (
                address.is_global
                and not address.is_multicast
                and match not in ALLOWED_PUBLIC
                and not any(address in net for net in DOCUMENTATION)
            ):
                problems.append(f"{path}:{number}: public address {match}")
        for pattern, label in SECRETS:
            if pattern.search(line):
                problems.append(f"{path}:{number}: looks like a {label}")
        if "PRIVATE KEY-----" in line and path not in TEST_KEY_ALLOW:
            problems.append(f"{path}:{number}: private key material")

for problem in problems[:200]:
    print(problem)
if problems:
    print(f"\n{len(problems)} problem(s). Use documentation addresses (203.0.113.x, 198.51.100.x) and English.")
    sys.exit(1)
print(f"repository policy OK ({len(files)} files)")
PY
