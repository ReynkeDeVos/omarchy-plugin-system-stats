#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)

cleanup() {
  if [[ -d $test_dir ]]; then rm -rf -- "$test_dir"; fi
}
trap cleanup EXIT

mkdir -p "$test_dir/bin" "$test_dir/fixtures" "$test_dir/Ui" "$test_dir/Commons"
cp "$repo_root/Service.qml" "$test_dir/Service.qml"
cp "$repo_root/BarWidget.qml" "$test_dir/BarWidget.qml"
cp "$repo_root/tests/qml/FakeBar.qml" "$test_dir/FakeBar.qml"
cp "$repo_root/tests/qml/amd_gpu_harness.qml" "$test_dir/shell.qml"
cp "$repo_root/tests/qml/GpuSessionHarness.qml" "$test_dir/"
cp "$repo_root/tests/qml/gpu_harness_assertions.js" "$test_dir/"
cp "$repo_root/bin/system-stats-helper" "$test_dir/bin/system-stats-helper"
cp "$repo_root/tests/fixtures/cpu/normal.stat" "$test_dir/fixtures/cpu.stat"
cp "$repo_root/tests/fixtures/ram/normal.meminfo" "$test_dir/fixtures/ram.meminfo"
cp -R /usr/share/omarchy/shell/Ui/. "$test_dir/Ui/"
cp -R /usr/share/omarchy/shell/Commons/. "$test_dir/Commons/"
run_available_case() {
  local case_name=$1
  local inventory=$2
  local stable_id=$3
  local pci_bdf=$4
  local expected_percent=$5
  local expected_path=${6:-amd-gpu-busy-percent}
  local proc_frames=${7:-}
  local transient_error=${8:-}
  local cpu_frames="$test_dir/fixtures/cpu.stat"
  local ram_frames="$test_dir/fixtures/ram.meminfo"
  local output

  if [[ -n $transient_error ]]; then
    cpu_frames="$repo_root/tests/fixtures/cpu/intel-recovery.stat"
    ram_frames="$repo_root/tests/fixtures/ram/intel-recovery.meminfo"
  fi

  cp "$repo_root/tests/fixtures/gpu/$inventory.inventory" \
    "$test_dir/fixtures/gpu.inventory"
  cut -f1 "$test_dir/fixtures/gpu.inventory" >"$test_dir/fixtures/gpu.presence"

  output=$(SYSTEM_STATS_AMD_CASE="$case_name" \
    SYSTEM_STATS_AMD_STATUS=available \
    SYSTEM_STATS_AMD_ERROR="" \
    SYSTEM_STATS_AMD_RETRYABILITY="" \
    SYSTEM_STATS_AMD_TRANSIENT_ERROR="$transient_error" \
    SYSTEM_STATS_AMD_STABLE_ID="$stable_id" \
    SYSTEM_STATS_AMD_PCI_BDF="$pci_bdf" \
    SYSTEM_STATS_AMD_PERCENT="$expected_percent" \
    SYSTEM_STATS_AMD_PATH="$expected_path" \
    SYSTEM_STATS_FRAMES="$cpu_frames" \
    SYSTEM_STATS_MEMINFO_FRAMES="$ram_frames" \
    SYSTEM_STATS_GPU_INVENTORY_FILE="$test_dir/fixtures/gpu.inventory" \
    SYSTEM_STATS_GPU_PRESENCE_FILE="$test_dir/fixtures/gpu.presence" \
    SYSTEM_STATS_PCI_DEVICES_ROOT="$repo_root/tests/fixtures/gpu/amd/$case_name" \
    SYSTEM_STATS_AMD_PROC_FRAMES="$proc_frames" \
    SYSTEM_STATS_INTERVAL_MS=100 \
    QT_QPA_PLATFORM=offscreen \
    timeout 5s quickshell --no-color --path "$test_dir/shell.qml" 2>&1) || {
    printf '%s\n' "$output"
    exit 1
  }

  printf '%s\n' "$output"
  grep -Fq "TEST-PASS: $case_name GPU usage through SystemStatsSession" \
    <<<"$output"
}

run_error_case() {
  local case_name=$1
  local expected_error=$2
  local expected_path=$3
  local expected_retryability=$4
  local proc_frames=${5:-}
  local output

  cp "$repo_root/tests/fixtures/gpu/single-amd-dgpu.inventory" \
    "$test_dir/fixtures/gpu.inventory"
  cut -f1 "$test_dir/fixtures/gpu.inventory" >"$test_dir/fixtures/gpu.presence"

  output=$(SYSTEM_STATS_AMD_CASE="$case_name" \
    SYSTEM_STATS_AMD_STATUS=unavailable \
    SYSTEM_STATS_AMD_ERROR="$expected_error" \
    SYSTEM_STATS_AMD_RETRYABILITY="$expected_retryability" \
    SYSTEM_STATS_AMD_TRANSIENT_ERROR="" \
    SYSTEM_STATS_AMD_STABLE_ID=pci:0000:03:00.0 \
    SYSTEM_STATS_AMD_PCI_BDF=0000:03:00.0 \
    SYSTEM_STATS_AMD_PERCENT=0 \
    SYSTEM_STATS_AMD_PATH="$expected_path" \
    SYSTEM_STATS_FRAMES="$test_dir/fixtures/cpu.stat" \
    SYSTEM_STATS_MEMINFO_FRAMES="$test_dir/fixtures/ram.meminfo" \
    SYSTEM_STATS_GPU_INVENTORY_FILE="$test_dir/fixtures/gpu.inventory" \
    SYSTEM_STATS_GPU_PRESENCE_FILE="$test_dir/fixtures/gpu.presence" \
    SYSTEM_STATS_PCI_DEVICES_ROOT="$repo_root/tests/fixtures/gpu/amd/$case_name" \
    SYSTEM_STATS_AMD_PROC_FRAMES="$proc_frames" \
    SYSTEM_STATS_INTERVAL_MS=100 \
    QT_QPA_PLATFORM=offscreen \
    timeout 5s quickshell --no-color --path "$test_dir/shell.qml" 2>&1) || {
      printf '%s\n' "$output"
      exit 1
    }

  printf '%s\n' "$output"
  grep -Fq "TEST-PASS: $case_name GPU error through SystemStatsSession" \
    <<<"$output"
}

run_available_case sysfs-apu single-amd-apu pci:0000:c4:00.0 0000:c4:00.0 27
run_available_case sysfs-dgpu single-amd-dgpu pci:0000:03:00.0 0000:03:00.0 61
run_available_case sysfs-multiple multiple-amd pci:0000:c4:00.0 0000:c4:00.0 73
run_available_case fdinfo-fallback multiple-amd pci:0000:c4:00.0 \
  0000:c4:00.0 40 amd-fdinfo \
  "$repo_root/tests/fixtures/gpu/amd/fdinfo-fallback-proc"
run_available_case unsupported-fallback multiple-amd pci:0000:c4:00.0 \
  0000:c4:00.0 40 amd-fdinfo \
  "$repo_root/tests/fixtures/gpu/amd/fdinfo-fallback-proc" unsupportedDevice
run_available_case fdinfo-counter-reset single-amd-dgpu pci:0000:03:00.0 \
  0000:03:00.0 15 amd-fdinfo \
  "$repo_root/tests/fixtures/gpu/amd/fdinfo-counter-reset-proc" counterReset
run_error_case runtime-suspended deviceSuspended amd-gpu-busy-percent retryable
run_error_case unsupported unsupportedDevice amd-gpu-busy-percent nonRetryable
run_error_case permission-denied permissionDenied amd-gpu-busy-percent retryable
run_error_case invalid-value malformedCounter amd-gpu-busy-percent retryable
run_error_case device-missing deviceMissing amd-gpu-busy-percent retryable
run_error_case device-disappeared-during-read deviceMissing \
  amd-gpu-busy-percent retryable
run_error_case no-true-path noTrueEnginePath amd-measurement nonRetryable \
  "$repo_root/tests/fixtures/gpu/amd/no-true-path-proc"
run_error_case ambiguous-eperm sourceUnreadable amd-gpu-busy-percent retryable

cp "$repo_root/tests/qml/amd_widget_harness.qml" "$test_dir/widget-shell.qml"
cp "$repo_root/tests/fixtures/gpu/multiple-amd.inventory" \
  "$test_dir/fixtures/gpu.inventory"
cut -f1 "$test_dir/fixtures/gpu.inventory" >"$test_dir/fixtures/gpu.presence"
widget_output=$(SYSTEM_STATS_FRAMES="$test_dir/fixtures/cpu.stat" \
  SYSTEM_STATS_MEMINFO_FRAMES="$test_dir/fixtures/ram.meminfo" \
  SYSTEM_STATS_GPU_INVENTORY_FILE="$test_dir/fixtures/gpu.inventory" \
  SYSTEM_STATS_GPU_PRESENCE_FILE="$test_dir/fixtures/gpu.presence" \
  SYSTEM_STATS_PCI_DEVICES_ROOT="$repo_root/tests/fixtures/gpu/amd/sysfs-multiple" \
  SYSTEM_STATS_INTERVAL_MS=100 \
  QT_QPA_PLATFORM=offscreen \
  timeout 5s quickshell --no-color --path "$test_dir/widget-shell.qml" 2>&1) || {
    printf '%s\n' "$widget_output"
    exit 1
  }
printf '%s\n' "$widget_output"
grep -Fq "TEST-PASS: AMD GPU usage reaches bar and detail panel" \
  <<<"$widget_output"
