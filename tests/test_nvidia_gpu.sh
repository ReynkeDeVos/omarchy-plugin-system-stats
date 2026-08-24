#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
helper_pid=""

cleanup() {
  if [[ -n $helper_pid ]] && kill -0 "$helper_pid" 2>/dev/null; then
    kill "$helper_pid"
    wait "$helper_pid" 2>/dev/null || true
  fi
  if [[ -d $test_dir ]]; then rm -rf -- "$test_dir"; fi
}
trap cleanup EXIT

mkdir -p "$test_dir/bin" "$test_dir/fixtures" "$test_dir/Ui" "$test_dir/Commons"
cp "$repo_root/Service.qml" "$test_dir/Service.qml"
cp "$repo_root/BarWidget.qml" "$test_dir/BarWidget.qml"
cp "$repo_root/tests/qml/FakeBar.qml" "$test_dir/FakeBar.qml"
cp "$repo_root/tests/qml/nvidia_gpu_harness.qml" "$test_dir/shell.qml"
cp "$repo_root/tests/qml/GpuSessionHarness.qml" "$test_dir/"
cp "$repo_root/tests/qml/gpu_harness_assertions.js" "$test_dir/"
cp "$repo_root/bin/system-stats-helper" "$test_dir/bin/system-stats-helper"
cp "$repo_root/tests/fixtures/cpu/normal.stat" "$test_dir/fixtures/cpu.stat"
cp "$repo_root/tests/fixtures/cpu/reconfigure.stat" \
  "$test_dir/fixtures/cpu-reconfigure.stat"
cp "$repo_root/tests/fixtures/ram/normal.meminfo" "$test_dir/fixtures/ram.meminfo"
cp "$repo_root/tests/fixtures/ram/widget.meminfo" \
  "$test_dir/fixtures/ram-reconfigure.meminfo"
cp -R /usr/share/omarchy/shell/Ui/. "$test_dir/Ui/"
cp -R /usr/share/omarchy/shell/Commons/. "$test_dir/Commons/"

fake_nvml="$test_dir/libnvidia-ml.so.1"
cc -std=c17 -O2 -Wall -Wextra -Werror -shared -fPIC \
  "$repo_root/tests/native/fake_nvml.c" -o "$fake_nvml"

selected_id=nvidia:GPU-22222222-2222-2222-2222-222222222222
selected_pci=0000:01:00.0
index_log="$test_dir/index-lookups.log"
helper_output="$test_dir/helper.output"

run_case() {
  local case_name=$1
  local expected_status=$2
  local expected_error=$3
  local expected_retryability=$4
  local library_path=${5:-$fake_nvml}
  local inventory=${6:-nvidia-only.inventory}
  local second_ms=1000
  local cpu_frames="$test_dir/fixtures/cpu.stat"
  local ram_frames="$test_dir/fixtures/ram.meminfo"
  local output

  if [[ $case_name == hung-reopen || $case_name == shutdown-hangs ]]; then
    second_ms=300
    cpu_frames="$test_dir/fixtures/cpu-reconfigure.stat"
    ram_frames="$test_dir/fixtures/ram-reconfigure.meminfo"
  fi

  cp "$repo_root/tests/fixtures/gpu/$inventory" \
    "$test_dir/fixtures/gpu.inventory"
  cut -f1 "$test_dir/fixtures/gpu.inventory" >"$test_dir/fixtures/gpu.presence"

  output=$(SYSTEM_STATS_NVIDIA_CASE="$case_name" \
    SYSTEM_STATS_NVIDIA_STATUS="$expected_status" \
    SYSTEM_STATS_NVIDIA_ERROR="$expected_error" \
    SYSTEM_STATS_NVIDIA_RETRYABILITY="$expected_retryability" \
    SYSTEM_STATS_NVIDIA_STABLE_ID="$selected_id" \
    SYSTEM_STATS_NVIDIA_PCI_BDF="$selected_pci" \
    SYSTEM_STATS_NVIDIA_PERCENT=47 \
    SYSTEM_STATS_NVML_CASE="$case_name" \
    SYSTEM_STATS_NVML_LIBRARY="$library_path" \
    SYSTEM_STATS_NVML_INDEX_LOG="$index_log" \
    SYSTEM_STATS_NVML_CALL_LOG="$test_dir/$case_name.calls" \
    SYSTEM_STATS_FRAMES="$cpu_frames" \
    SYSTEM_STATS_MEMINFO_FRAMES="$ram_frames" \
    SYSTEM_STATS_GPU_INVENTORY_FILE="$test_dir/fixtures/gpu.inventory" \
    SYSTEM_STATS_GPU_PRESENCE_FILE="$test_dir/fixtures/gpu.presence" \
    SYSTEM_STATS_INTERVAL_MS=100 \
    SYSTEM_STATS_SECOND_MS="$second_ms" \
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

run_case swapped-indices available "" "" "$fake_nvml" \
  multiple-nvidia-swapped.inventory
[[ ! -e $index_log ]]
run_case shutdown-hangs available "" ""
run_case missing-library unavailable dependencyMissing retryable \
  "$test_dir/does-not-exist/libnvidia-ml.so.1"
run_case driver-missing unavailable dependencyMissing retryable
run_case device-missing unavailable deviceMissing retryable
run_case identity-mismatch unavailable sourceUnreadable retryable
run_case nvml-timeout unavailable sampleTimeout retryable
run_case hung-call unavailable sampleTimeout retryable
run_case hung-reopen unavailable sampleTimeout retryable
[[ $(wc -l <"$test_dir/hung-reopen.calls") -eq 1 ]]
run_case invalid-value unavailable malformedCounter retryable
run_case mig-unavailable unavailable unsupportedDevice nonRetryable
run_case suspended unavailable deviceSuspended retryable

cp "$repo_root/tests/qml/nvidia_relocation_harness.qml" \
  "$test_dir/relocation-shell.qml"
cp "$repo_root/tests/fixtures/gpu/multiple-nvidia-swapped.inventory" \
  "$test_dir/fixtures/gpu.inventory"
cut -f1 "$test_dir/fixtures/gpu.inventory" >"$test_dir/fixtures/gpu.presence"
relocation_output=$(SYSTEM_STATS_NVML_CASE=relocated \
  SYSTEM_STATS_NVML_LIBRARY="$fake_nvml" \
  SYSTEM_STATS_FRAMES="$test_dir/fixtures/cpu-reconfigure.stat" \
  SYSTEM_STATS_MEMINFO_FRAMES="$test_dir/fixtures/ram-reconfigure.meminfo" \
  SYSTEM_STATS_GPU_INVENTORY_FILE="$test_dir/fixtures/gpu.inventory" \
  SYSTEM_STATS_GPU_PRESENCE_FILE="$test_dir/fixtures/gpu.presence" \
  SYSTEM_STATS_INTERVAL_MS=100 \
  QT_QPA_PLATFORM=offscreen \
  timeout 5s quickshell --no-color --path "$test_dir/relocation-shell.qml" 2>&1) || {
    printf '%s\n' "$relocation_output"
    exit 1
  }
printf '%s\n' "$relocation_output"
grep -Fq "TEST-PASS: Nvidia UUID rebinds after its PCI address changes" \
  <<<"$relocation_output"

cp "$repo_root/tests/qml/nvidia_widget_harness.qml" "$test_dir/widget-shell.qml"
cp "$repo_root/tests/fixtures/gpu/multiple-nvidia-swapped.inventory" \
  "$test_dir/fixtures/gpu.inventory"
cut -f1 "$test_dir/fixtures/gpu.inventory" >"$test_dir/fixtures/gpu.presence"
widget_output=$(SYSTEM_STATS_NVML_CASE=valid \
  SYSTEM_STATS_NVML_LIBRARY="$fake_nvml" \
  SYSTEM_STATS_FRAMES="$test_dir/fixtures/cpu.stat" \
  SYSTEM_STATS_MEMINFO_FRAMES="$test_dir/fixtures/ram.meminfo" \
  SYSTEM_STATS_GPU_INVENTORY_FILE="$test_dir/fixtures/gpu.inventory" \
  SYSTEM_STATS_GPU_PRESENCE_FILE="$test_dir/fixtures/gpu.presence" \
  SYSTEM_STATS_INTERVAL_MS=100 \
  QT_QPA_PLATFORM=offscreen \
  timeout 5s quickshell --no-color --path "$test_dir/widget-shell.qml" 2>&1) || {
    printf '%s\n' "$widget_output"
    exit 1
  }
printf '%s\n' "$widget_output"
grep -Fq "TEST-PASS: Nvidia GPU usage reaches bar and detail panel" \
  <<<"$widget_output"

SYSTEM_STATS_NVML_CASE=valid \
  SYSTEM_STATS_NVML_LIBRARY="$fake_nvml" \
  SYSTEM_STATS_GPU_INVENTORY_FILE="$test_dir/fixtures/gpu.inventory" \
  SYSTEM_STATS_GPU_PRESENCE_FILE="$test_dir/fixtures/gpu.presence" \
  SYSTEM_STATS_INTERVAL_MS=100 \
  "$repo_root/bin/system-stats-helper" </dev/null >"$helper_output" 2>&1 &
helper_pid=$!
for ((attempt = 0; attempt < 100; attempt++)); do
  grep -Fq '"type":"hello"' "$helper_output" && break
  sleep 0.01
done
grep -Fq '"type":"hello"' "$helper_output"
[[ -r /proc/$helper_pid/task/$helper_pid/children ]]
read -r helper_children <"/proc/$helper_pid/task/$helper_pid/children" || true
[[ -z ${helper_children:-} ]]
kill -KILL "$helper_pid"
wait "$helper_pid" 2>/dev/null || true
helper_pid=""

! rg -n '\bnvidia-smi\b' "$repo_root/src"
