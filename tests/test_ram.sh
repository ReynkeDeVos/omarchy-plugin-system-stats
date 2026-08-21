#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)

cleanup() {
  if [[ -d $test_dir ]]; then rm -rf -- "$test_dir"; fi
}
trap cleanup EXIT

mkdir -p "$test_dir/bin" "$test_dir/fixtures/cpu" "$test_dir/fixtures/ram"
cp "$repo_root/Service.qml" "$test_dir/Service.qml"
cp "$repo_root/tests/qml/ram_harness.qml" "$test_dir/shell.qml"
cp "$repo_root/bin/system-stats-helper" "$test_dir/bin/system-stats-helper"
cp -R "$repo_root/tests/fixtures/cpu/." "$test_dir/fixtures/cpu/"
cp -R "$repo_root/tests/fixtures/ram/." "$test_dir/fixtures/ram/"

run_case() {
  local case_name=$1
  local cpu_case=$2
  local expected_cpu_status=$3
  local expected_cpu_percent=$4
  local expected_ram_status=$5
  local expected_ram_percent=$6
  local expected_used_bytes=$7
  local expected_total_bytes=$8
  local expected_ram_error=$9
  local output

  output=$(SYSTEM_STATS_CASE="$case_name" \
    SYSTEM_STATS_EXPECTED_CPU_STATUS="$expected_cpu_status" \
    SYSTEM_STATS_EXPECTED_CPU_PERCENT="$expected_cpu_percent" \
    SYSTEM_STATS_EXPECTED_RAM_STATUS="$expected_ram_status" \
    SYSTEM_STATS_EXPECTED_RAM_PERCENT="$expected_ram_percent" \
    SYSTEM_STATS_EXPECTED_USED_BYTES="$expected_used_bytes" \
    SYSTEM_STATS_EXPECTED_TOTAL_BYTES="$expected_total_bytes" \
    SYSTEM_STATS_EXPECTED_RAM_ERROR="$expected_ram_error" \
    SYSTEM_STATS_FRAMES="$test_dir/fixtures/cpu/$cpu_case.stat" \
    SYSTEM_STATS_MEMINFO_FRAMES="$test_dir/fixtures/ram/$case_name.meminfo" \
    SYSTEM_STATS_INTERVAL_MS=1 \
    QT_QPA_PLATFORM=offscreen \
    timeout 5s quickshell --no-color --path "$test_dir/shell.qml" 2>&1) || {
    printf '%s\n' "$output"
    exit 1
  }

  printf '%s\n' "$output"
  grep -Fq "TEST-PASS: $case_name RAM through public session snapshot" <<<"$output"
}

run_case normal normal available 37 available 63 10737418240 17179869184 ""
run_case zero normal available 37 available 0 0 8589934592 ""
run_case hundred normal available 37 available 100 8589934592 8589934592 ""
run_case rounding normal available 37 available 13 1073741824 8589934592 ""
run_case missing-available normal available 37 unavailable 0 0 0 missingRequiredField
run_case missing-total normal available 37 unavailable 0 0 0 missingRequiredField
run_case zero-total normal available 37 unavailable 0 0 0 malformedCounter
run_case available-too-large normal available 37 unavailable 0 0 0 malformedCounter
run_case malformed-size normal available 37 unavailable 0 0 0 malformedCounter
run_case cpu-error missing-field unavailable 0 available 63 10737418240 17179869184 ""
