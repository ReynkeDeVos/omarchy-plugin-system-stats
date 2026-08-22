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

perf_fixture="$test_dir/perf-event-fixture.so"
cc -std=c17 -O2 -Wall -Wextra -Werror -shared -fPIC \
  "$repo_root/tests/native/perf_event_fixture.c" -o "$perf_fixture"

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

recovery_output=$(SYSTEM_STATS_INTEL_CASE=permission-recovery \
  SYSTEM_STATS_INTEL_STATUS=available \
  SYSTEM_STATS_INTEL_PATH=intel-i915-fdinfo \
  SYSTEM_STATS_INTEL_TRANSIENT_ERROR=permissionDenied \
  SYSTEM_STATS_FRAMES="$repo_root/tests/fixtures/cpu/intel-recovery.stat" \
  SYSTEM_STATS_MEMINFO_FRAMES="$repo_root/tests/fixtures/ram/intel-recovery.meminfo" \
  SYSTEM_STATS_GPU_INVENTORY_FILE="$test_dir/fixtures/gpu.inventory" \
  SYSTEM_STATS_GPU_PRESENCE_FILE="$test_dir/fixtures/gpu.presence" \
  SYSTEM_STATS_INTEL_PROC_FRAMES="$repo_root/tests/fixtures/gpu/intel/permission-recovery" \
  SYSTEM_STATS_INTERVAL_MS=100 \
  QT_QPA_PLATFORM=offscreen \
  timeout 5s quickshell --no-color --path "$test_dir/shell.qml" 2>&1) || {
    printf '%s\n' "$recovery_output"
    exit 1
  }
printf '%s\n' "$recovery_output"
grep -Fq "TEST-PASS: permission-recovery GPU usage through SystemStatsSession" \
  <<<"$recovery_output"

reset_recovery_output=$(SYSTEM_STATS_INTEL_CASE=counter-reset \
  SYSTEM_STATS_INTEL_STATUS=available \
  SYSTEM_STATS_INTEL_PATH=intel-i915-fdinfo \
  SYSTEM_STATS_INTEL_TRANSIENT_ERROR=counterReset \
  SYSTEM_STATS_FRAMES="$repo_root/tests/fixtures/cpu/intel-recovery.stat" \
  SYSTEM_STATS_MEMINFO_FRAMES="$repo_root/tests/fixtures/ram/intel-recovery.meminfo" \
  SYSTEM_STATS_GPU_INVENTORY_FILE="$test_dir/fixtures/gpu.inventory" \
  SYSTEM_STATS_GPU_PRESENCE_FILE="$test_dir/fixtures/gpu.presence" \
  SYSTEM_STATS_INTEL_PROC_FRAMES="$repo_root/tests/fixtures/gpu/intel/counter-reset" \
  SYSTEM_STATS_INTERVAL_MS=100 \
  QT_QPA_PLATFORM=offscreen \
  timeout 5s quickshell --no-color --path "$test_dir/shell.qml" 2>&1) || {
    printf '%s\n' "$reset_recovery_output"
    exit 1
  }
printf '%s\n' "$reset_recovery_output"
grep -Fq "TEST-PASS: counter-reset GPU usage through SystemStatsSession" \
  <<<"$reset_recovery_output"

pmu_pci_root="$test_dir/fixtures/pmu-pci"
mkdir -p "$pmu_pci_root/0000:00:02.0" "$pmu_pci_root/drivers"
touch "$pmu_pci_root/drivers/i915"
ln -s "$pmu_pci_root/drivers/i915" "$pmu_pci_root/0000:00:02.0/driver"
cp "$repo_root/bin/system-stats-helper" "$test_dir/bin/system-stats-helper.real"
cp "$repo_root/tests/helpers/perf-fixture-helper.sh" \
  "$test_dir/bin/system-stats-helper"
chmod +x "$test_dir/bin/system-stats-helper"

run_pmu_case() {
  local case_name=$1
  local expected_status=$2
  local expected_error=$3
  local denied_config=${4:-}
  local reset_config=${5:-}
  local transient_error=${6:-}
  local cpu_frames="$test_dir/fixtures/cpu.stat"
  local ram_frames="$test_dir/fixtures/ram.meminfo"
  local output

  if [[ -n $transient_error ]]; then
    cpu_frames="$repo_root/tests/fixtures/cpu/intel-recovery.stat"
    ram_frames="$repo_root/tests/fixtures/ram/intel-recovery.meminfo"
  fi

  output=$(SYSTEM_STATS_INTEL_CASE="$case_name" \
    SYSTEM_STATS_INTEL_STATUS="$expected_status" \
    SYSTEM_STATS_INTEL_ERROR="$expected_error" \
    SYSTEM_STATS_INTEL_PATH=intel-i915-pmu \
    SYSTEM_STATS_INTEL_TRANSIENT_ERROR="$transient_error" \
    SYSTEM_STATS_FRAMES="$cpu_frames" \
    SYSTEM_STATS_MEMINFO_FRAMES="$ram_frames" \
    SYSTEM_STATS_GPU_INVENTORY_FILE="$test_dir/fixtures/gpu.inventory" \
    SYSTEM_STATS_GPU_PRESENCE_FILE="$test_dir/fixtures/gpu.presence" \
    SYSTEM_STATS_EVENT_SOURCE_ROOT="$repo_root/tests/fixtures/gpu/intel/i915-pmu/event-source" \
    SYSTEM_STATS_PCI_DEVICES_ROOT="$pmu_pci_root" \
    SYSTEM_STATS_PERF_FIXTURE_LIBRARY="$perf_fixture" \
    SYSTEM_STATS_PERF_DENY_CONFIG="$denied_config" \
    SYSTEM_STATS_PERF_RESET_CONFIG="$reset_config" \
    SYSTEM_STATS_REAL_HELPER="$test_dir/bin/system-stats-helper.real" \
    SYSTEM_STATS_INTERVAL_MS=100 \
    QT_QPA_PLATFORM=offscreen \
    timeout 5s quickshell --no-color --path "$test_dir/shell.qml" 2>&1) || {
      printf '%s\n' "$output"
      exit 1
    }

  printf '%s\n' "$output"
  if [[ $expected_status == available ]]; then
    grep -Fq "TEST-PASS: $case_name GPU usage through SystemStatsSession" \
      <<<"$output"
  else
    grep -Fq "TEST-PASS: $case_name GPU error through SystemStatsSession" \
      <<<"$output"
  fi
}

run_pmu_case i915-pmu available ""
run_pmu_case i915-pmu-partial-permission unavailable permissionDenied 3
run_pmu_case i915-pmu-reset available "" "" 1 counterReset
