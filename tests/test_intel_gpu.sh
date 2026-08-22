#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)

cleanup() {
  if [[ -d $test_dir ]]; then rm -rf -- "$test_dir"; fi
}
trap cleanup EXIT

mkdir -p "$test_dir/bin" "$test_dir/fixtures"
cp "$repo_root/Service.qml" "$test_dir/Service.qml"
cp "$repo_root/tests/qml/intel_gpu_harness.qml" "$test_dir/shell.qml"
cp "$repo_root/bin/system-stats-helper" "$test_dir/bin/system-stats-helper"
cp "$repo_root/tests/fixtures/cpu/normal.stat" "$test_dir/fixtures/cpu.stat"
cp "$repo_root/tests/fixtures/ram/normal.meminfo" "$test_dir/fixtures/ram.meminfo"
cp "$repo_root/tests/fixtures/gpu/single-intel.inventory" "$test_dir/fixtures/gpu.inventory"
cut -f1 "$test_dir/fixtures/gpu.inventory" >"$test_dir/fixtures/gpu.presence"

run_available_case() {
  local case_name=$1
  local expected_path=$2
  local output

  output=$(SYSTEM_STATS_INTEL_CASE="$case_name" \
    SYSTEM_STATS_INTEL_STATUS=available \
    SYSTEM_STATS_INTEL_PATH="$expected_path" \
    SYSTEM_STATS_FRAMES="$test_dir/fixtures/cpu.stat" \
    SYSTEM_STATS_MEMINFO_FRAMES="$test_dir/fixtures/ram.meminfo" \
    SYSTEM_STATS_GPU_INVENTORY_FILE="$test_dir/fixtures/gpu.inventory" \
    SYSTEM_STATS_GPU_PRESENCE_FILE="$test_dir/fixtures/gpu.presence" \
    SYSTEM_STATS_INTEL_PROC_FRAMES="$repo_root/tests/fixtures/gpu/intel/$case_name" \
    SYSTEM_STATS_INTERVAL_MS=100 \
    QT_QPA_PLATFORM=offscreen \
    timeout 5s quickshell --no-color --path "$test_dir/shell.qml" 2>&1) || {
      printf '%s\n' "$output"
      exit 1
    }

  printf '%s\n' "$output"
  grep -Fq "TEST-PASS: $case_name GPU usage through SystemStatsSession" <<<"$output"
}

run_error_case() {
  local case_name=$1
  local expected_error=$2
  local expected_path=$3
  local output

  output=$(SYSTEM_STATS_INTEL_CASE="$case_name" \
    SYSTEM_STATS_INTEL_STATUS=unavailable \
    SYSTEM_STATS_INTEL_ERROR="$expected_error" \
    SYSTEM_STATS_INTEL_PATH="$expected_path" \
    SYSTEM_STATS_FRAMES="$test_dir/fixtures/cpu.stat" \
    SYSTEM_STATS_MEMINFO_FRAMES="$test_dir/fixtures/ram.meminfo" \
    SYSTEM_STATS_GPU_INVENTORY_FILE="$test_dir/fixtures/gpu.inventory" \
    SYSTEM_STATS_GPU_PRESENCE_FILE="$test_dir/fixtures/gpu.presence" \
    SYSTEM_STATS_INTEL_PROC_FRAMES="$repo_root/tests/fixtures/gpu/intel/$case_name" \
    SYSTEM_STATS_INTERVAL_MS=100 \
    QT_QPA_PLATFORM=offscreen \
    timeout 5s quickshell --no-color --path "$test_dir/shell.qml" 2>&1) || {
      printf '%s\n' "$output"
      exit 1
    }

  printf '%s\n' "$output"
  grep -Fq "TEST-PASS: $case_name GPU error through SystemStatsSession" <<<"$output"
}

run_available_case i915 intel-i915-fdinfo
run_available_case xe intel-xe-fdinfo
run_error_case insufficient-visibility insufficientVisibility intel-fdinfo
run_error_case permission-denied permissionDenied intel-fdinfo
run_error_case unknown-abi unsupportedDevice intel-fdinfo
run_error_case counter-reset counterReset intel-i915-fdinfo
run_error_case no-true-path noTrueEnginePath intel-measurement
