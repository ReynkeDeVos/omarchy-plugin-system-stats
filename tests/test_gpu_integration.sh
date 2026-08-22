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
cp "$repo_root/tests/qml/gpu_matrix_harness.qml" "$test_dir/shell.qml"
cp "$repo_root/tests/qml/GpuSessionHarness.qml" "$test_dir/"
cp "$repo_root/tests/qml/gpu_harness_assertions.js" "$test_dir/"
cp "$repo_root/bin/system-stats-helper" "$test_dir/bin/system-stats-helper"
cp "$repo_root/tests/fixtures/cpu/normal.stat" "$test_dir/fixtures/cpu.stat"
cp "$repo_root/tests/fixtures/ram/normal.meminfo" "$test_dir/fixtures/ram.meminfo"

fake_nvml="$test_dir/libnvidia-ml.so.1"
cc -std=c17 -O2 -Wall -Wextra -Werror -shared -fPIC \
  "$repo_root/tests/native/fake_nvml.c" -o "$fake_nvml"

run_matrix_case() {
  local case_name=$1
  local inventory_name=$2
  local expected_status=$3
  local expected_id=$4
  local expected_vendor=$5
  local expected_display=$6
  local expected_count=$7
  local inventory_file="$test_dir/fixtures/$case_name.inventory"
  local presence_file="$test_dir/fixtures/$case_name.presence"
  local output

  cp "$repo_root/tests/fixtures/gpu/$inventory_name" "$inventory_file"
  cut -f1 "$inventory_file" >"$presence_file"

  output=$(SYSTEM_STATS_GPU_CASE="$case_name" \
    SYSTEM_STATS_GPU_EXPECTED_STATUS="$expected_status" \
    SYSTEM_STATS_GPU_EXPECTED_ID="$expected_id" \
    SYSTEM_STATS_GPU_EXPECTED_VENDOR="$expected_vendor" \
    SYSTEM_STATS_GPU_EXPECTED_DISPLAY="$expected_display" \
    SYSTEM_STATS_GPU_EXPECTED_COUNT="$expected_count" \
    SYSTEM_STATS_FRAMES="$test_dir/fixtures/cpu.stat" \
    SYSTEM_STATS_MEMINFO_FRAMES="$test_dir/fixtures/ram.meminfo" \
    SYSTEM_STATS_GPU_INVENTORY_FILE="$inventory_file" \
    SYSTEM_STATS_GPU_PRESENCE_FILE="$presence_file" \
    SYSTEM_STATS_PCI_DEVICES_ROOT="$test_dir/missing-pci" \
    SYSTEM_STATS_NVML_LIBRARY="$test_dir/missing-nvml.so" \
    SYSTEM_STATS_INTERVAL_MS=100 \
    QT_QPA_PLATFORM=offscreen \
    timeout 5s quickshell --no-color --path "$test_dir/shell.qml" 2>&1) || {
      printf '%s\n' "$output"
      exit 1
    }

  printf '%s\n' "$output"
  grep -Fq "TEST-PASS: $case_name follows the shared Auto rules" <<<"$output"
}

run_matrix_case intel-nvidia hybrid-unique-display.inventory selected \
  pci:0000:00:02.0 intel yes 2
run_matrix_case intel-amd hybrid-intel-amd.inventory selected \
  pci:0000:c4:00.0 amd yes 2
run_matrix_case multiple-amd multiple-amd.inventory selected \
  pci:0000:c4:00.0 amd yes 2
run_matrix_case multiple-nvidia multiple-nvidia-swapped.inventory selected \
  nvidia:GPU-22222222-2222-2222-2222-222222222222 nvidia yes 2
run_matrix_case mixed-display mixed-display.inventory required "" "" "" 3

cp "$repo_root/tests/qml/gpu_error_stability_harness.qml" \
  "$test_dir/error-stability-shell.qml"
cp "$repo_root/tests/fixtures/gpu/hybrid-amd-nvidia-display.inventory" \
  "$test_dir/fixtures/error-stability.inventory"
cut -f1 "$test_dir/fixtures/error-stability.inventory" \
  >"$test_dir/fixtures/error-stability.presence"
nvml_call_log="$test_dir/identity-mismatch.calls"
error_stability_output=$(SYSTEM_STATS_NVML_CASE=identity-mismatch \
  SYSTEM_STATS_NVML_LIBRARY="$fake_nvml" \
  SYSTEM_STATS_NVML_CALL_LOG="$nvml_call_log" \
  SYSTEM_STATS_FRAMES="$repo_root/tests/fixtures/cpu/reconfigure.stat" \
  SYSTEM_STATS_MEMINFO_FRAMES="$test_dir/fixtures/ram.meminfo" \
  SYSTEM_STATS_GPU_INVENTORY_FILE="$test_dir/fixtures/error-stability.inventory" \
  SYSTEM_STATS_GPU_PRESENCE_FILE="$test_dir/fixtures/error-stability.presence" \
  SYSTEM_STATS_PCI_DEVICES_ROOT="$test_dir/missing-pci" \
  SYSTEM_STATS_INTERVAL_MS=100 \
  QT_QPA_PLATFORM=offscreen \
  timeout 5s quickshell --no-color \
    --path "$test_dir/error-stability-shell.qml" 2>&1) || {
    printf '%s\n' "$error_stability_output"
    exit 1
  }
printf '%s\n' "$error_stability_output"
grep -Fq "TEST-PASS: measurement errors do not cause GPU reselection" \
  <<<"$error_stability_output"
[[ ! -e $nvml_call_log ]]

cp "$repo_root/tests/qml/amd_gpu_harness.qml" "$test_dir/selected-only-shell.qml"
cp "$repo_root/tests/fixtures/gpu/hybrid-nvidia-amd-display.inventory" \
  "$test_dir/fixtures/selected-only.inventory"
cut -f1 "$test_dir/fixtures/selected-only.inventory" \
  >"$test_dir/fixtures/selected-only.presence"
nvml_api_log="$test_dir/unselected-nvidia-api.log"
selected_only_output=$(SYSTEM_STATS_AMD_CASE=selected-only \
  SYSTEM_STATS_AMD_STATUS=available \
  SYSTEM_STATS_AMD_ERROR="" \
  SYSTEM_STATS_AMD_RETRYABILITY="" \
  SYSTEM_STATS_AMD_TRANSIENT_ERROR="" \
  SYSTEM_STATS_AMD_STABLE_ID=pci:0000:c4:00.0 \
  SYSTEM_STATS_AMD_PCI_BDF=0000:c4:00.0 \
  SYSTEM_STATS_AMD_PERCENT=73 \
  SYSTEM_STATS_AMD_PATH=amd-gpu-busy-percent \
  SYSTEM_STATS_NVML_CASE=valid \
  SYSTEM_STATS_NVML_LIBRARY="$fake_nvml" \
  SYSTEM_STATS_NVML_API_LOG="$nvml_api_log" \
  SYSTEM_STATS_FRAMES="$test_dir/fixtures/cpu.stat" \
  SYSTEM_STATS_MEMINFO_FRAMES="$test_dir/fixtures/ram.meminfo" \
  SYSTEM_STATS_GPU_INVENTORY_FILE="$test_dir/fixtures/selected-only.inventory" \
  SYSTEM_STATS_GPU_PRESENCE_FILE="$test_dir/fixtures/selected-only.presence" \
  SYSTEM_STATS_PCI_DEVICES_ROOT="$repo_root/tests/fixtures/gpu/amd/sysfs-multiple" \
  SYSTEM_STATS_INTERVAL_MS=100 \
  QT_QPA_PLATFORM=offscreen \
  timeout 5s quickshell --no-color \
    --path "$test_dir/selected-only-shell.qml" 2>&1) || {
    printf '%s\n' "$selected_only_output"
    exit 1
  }
printf '%s\n' "$selected_only_output"
grep -Fq "TEST-PASS: selected-only GPU usage through SystemStatsSession" \
  <<<"$selected_only_output"
[[ ! -e $nvml_api_log ]]
