#!/usr/bin/env bash
# Compile the actual Android Kotlin classes against OS/JNI boundary doubles.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${KOTLINC:=kotlinc}"
java_bin="${JAVA_HOME:+$JAVA_HOME/bin/}java"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
# Host-only implementation of Android's built-in org.json API. It is never an
# app dependency. Pin the publisher's artifact bytes, including cache hits.
json_jar="${JSON_JAVA_JAR:-${HOME}/.cache/aurora-tools/android-native/json-20240303.jar}"
json_sha=3cf6cd6892e32e2b4c1c39e0f52f5248a2f5b37646fdfbb79a66b46b618414ed
if [[ ! -f "$json_jar" ]]; then
  mkdir -p "$(dirname "$json_jar")"
  curl --fail --silent --show-error --location --max-time 60 \
    https://repo.maven.apache.org/maven2/org/json/json/20240303/json-20240303.jar -o "$out/json.jar"
  actual_sha="$(shasum -a 256 "$out/json.jar" | cut -d' ' -f1)"
  [[ "$actual_sha" == "$json_sha" ]]
  install -m 600 "$out/json.jar" "$json_jar"
fi
[[ "$(shasum -a 256 "$json_jar" | cut -d' ' -f1)" == "$json_sha" ]]
"$KOTLINC" "$here"/stubs/*.kt "$here"/tests/*.kt \
  "$here"/../app/src/main/kotlin/com/aurora/vpn/*.kt \
  "$here"/../app/src/main/kotlin/com/aurora/aurora/MainActivity.kt \
  -classpath "$json_jar" -jvm-target 17 -include-runtime -d "$out/native-tests.jar"
"$java_bin" -cp "$out/native-tests.jar:$json_jar" com.aurora.vpn.test.MainKt "${1:-all}"
