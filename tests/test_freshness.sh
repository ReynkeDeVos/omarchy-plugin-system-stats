#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)

cleanup() {
  if [[ -d $test_dir ]]; then rm -rf -- "$test_dir"; fi
}
trap cleanup EXIT

mkdir -p "$test_dir/bin" "$test_dir/fixtures/cpu" "$test_dir/fixtures/gpu"
cp "$repo_root/Service.qml" "$test_dir/Service.qml"
cp "$repo_root/tests/qml/freshness_harness.qml" "$test_dir/shell.qml"
cp "$repo_root/bin/system-stats-helper" "$test_dir/bin/system-stats-helper"
cp "$repo_root/tests/fixtures/cpu/freshness.stat" "$test_dir/fixtures/cpu/freshness.stat"
cp "$repo_root/tests/fixtures/gpu/empty.inventory" "$test_dir/fixtures/gpu/inventory"
cp "$repo_root/tests/fixtures/gpu/empty.inventory" "$test_dir/fixtures/gpu/presence"

output=$(SYSTEM_STATS_FRAMES="$test_dir/fixtures/cpu/freshness.stat" \
  SYSTEM_STATS_GPU_INVENTORY_FILE="$test_dir/fixtures/gpu/inventory" \
  SYSTEM_STATS_GPU_PRESENCE_FILE="$test_dir/fixtures/gpu/presence" \
  SYSTEM_STATS_SECOND_MS=15 \
  QT_QPA_PLATFORM=offscreen \
  timeout 5s quickshell --no-color --path "$test_dir/shell.qml" 2>&1) || {
  printf '%s\n' "$output"
  exit 1
}

printf '%s\n' "$output"
grep -Fq "TEST-PASS: initialization, stale gaps, zero, and sample failures stay distinct" <<<"$output"
