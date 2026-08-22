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
cp "$repo_root/tests/qml/supervision_harness.qml" "$test_dir/shell.qml"
cc -std=c17 -O2 -Wall -Wextra -Werror -pedantic \
  "$repo_root/tests/native/scripted_helper.c" -o "$test_dir/bin/system-stats-helper"

run_case() {
  local scenario=$1
  local expected=$2
  local case_dir="$test_dir/$scenario"
  local output
  mkdir -p "$case_dir"

  output=$(SYSTEM_STATS_SCENARIO="$scenario" \
    SYSTEM_STATS_SECOND_MS=8 \
    SYSTEM_STATS_COUNT_FILE="$case_dir/count" \
    SYSTEM_STATS_LOCK_FILE="$case_dir/lock" \
    SYSTEM_STATS_TRACE_FILE="$case_dir/trace" \
    QT_QPA_PLATFORM=offscreen \
    timeout 7s quickshell --no-color --path "$test_dir/shell.qml" 2>&1) || {
    printf '%s\n' "$output"
    exit 1
  }

  printf '%s\n' "$output"
  grep -Fq "$expected" <<<"$output"
  ! grep -Fq OVERLAP "$case_dir/trace"
}

run_case backoff-reset "TEST-PASS: crash backoff resets after stable operation"
run_case unresponsive "TEST-PASS: unresponsive helper exits before its replacement"
