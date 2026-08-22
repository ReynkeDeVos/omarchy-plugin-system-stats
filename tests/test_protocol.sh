#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)

cleanup() {
  if [[ -d $test_dir ]]; then rm -rf -- "$test_dir"; fi
}
trap cleanup EXIT

mkdir -p "$test_dir/bin"
cp "$repo_root/Service.qml" "$test_dir/Service.qml"
cp "$repo_root/tests/qml/protocol_harness.qml" "$test_dir/shell.qml"
cc -std=c17 -O2 -Wall -Wextra -Werror -pedantic \
  "$repo_root/tests/native/scripted_helper.c" -o "$test_dir/bin/system-stats-helper"

output=$(SYSTEM_STATS_SCENARIO=protocol \
  SYSTEM_STATS_SECOND_MS=20 \
  SYSTEM_STATS_COUNT_FILE="$test_dir/count" \
  SYSTEM_STATS_LOCK_FILE="$test_dir/lock" \
  SYSTEM_STATS_TRACE_FILE="$test_dir/trace" \
  QT_QPA_PLATFORM=offscreen \
  timeout 3s quickshell --no-color --path "$test_dir/shell.qml" 2>&1) || {
  printf '%s\n' "$output"
  exit 1
}

printf '%s\n' "$output"
grep -Fq "TEST-PASS: invalid protocol traffic is discarded" <<<"$output"
! grep -Fq OVERLAP "$test_dir/trace"
