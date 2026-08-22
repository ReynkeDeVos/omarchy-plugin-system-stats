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
cp "$repo_root/tests/qml/gpu_selection_harness.qml" "$test_dir/shell.qml"
cp "$repo_root/bin/system-stats-helper" "$test_dir/bin/system-stats-helper"

run_case() {
  local case_name=$1
  local initial_inventory=$2
  local second_ms=${3:-5}
  local inventory_file="$test_dir/$case_name.inventory"
  local presence_file="$test_dir/$case_name.presence"
  local output

  cp "$repo_root/tests/fixtures/gpu/$initial_inventory" "$inventory_file"
  cut -f1 "$inventory_file" >"$presence_file"

  output=$(SYSTEM_STATS_GPU_CASE="$case_name" \
    SYSTEM_STATS_GPU_INVENTORY_FILE="$inventory_file" \
    SYSTEM_STATS_GPU_PRESENCE_FILE="$presence_file" \
    SYSTEM_STATS_NVML_LIBRARY="$test_dir/missing-nvml.so" \
    SYSTEM_STATS_PCI_DEVICES_ROOT="$test_dir/missing-pci" \
    SYSTEM_STATS_SECOND_MS="$second_ms" \
    QT_QPA_PLATFORM=offscreen \
    timeout 15s quickshell --no-color --path "$test_dir/shell.qml" 2>&1) || {
      printf '%s\n' "$output"
      exit 1
    }

  printf '%s\n' "$output"
  grep -Fq "TEST-PASS:" <<<"$output"
}

run_case single single-intel.inventory
run_case single-nvidia nvidia-only.inventory
run_case none empty.inventory
run_case unique-display hybrid-unique-display.inventory
run_case ambiguous multiple-ambiguous.inventory
run_case hotplug single-intel.inventory
run_case fixed single-intel.inventory 1
run_case fixed-amd single-intel.inventory 1
run_case fixed-immediate single-intel.inventory
run_case switch-auto hybrid-unique-display.inventory

run_linux_label_case() {
  local sys_root="$test_dir/linux-label-sys"
  local drm_root="$sys_root/drm"
  local pci_root="$sys_root/pci/0000:00:02.0"
  local udev_root="$sys_root/udev"
  local nvidia_root="$sys_root/nvidia"
  local output

  mkdir -p "$drm_root/card0" "$drm_root/card0-eDP-1" "$pci_root" \
    "$udev_root" "$nvidia_root"
  ln -s "$pci_root" "$drm_root/card0/device"
  printf '0x8086\n' >"$pci_root/vendor"
  printf '0x7d55\n' >"$pci_root/device"
  printf 'connected\n' >"$drm_root/card0-eDP-1/status"
  printf 'E:ID_MODEL_FROM_DATABASE=Meteor Lake-P Integrated Graphics Controller\n' \
    >"$udev_root/+pci:0000:00:02.0"
  cp "$repo_root/bin/system-stats-helper" "$test_dir/bin/system-stats-helper"

  output=$(SYSTEM_STATS_GPU_CASE=linux-label \
    SYSTEM_STATS_DRM_ROOT="$drm_root" \
    SYSTEM_STATS_NVIDIA_ROOT="$nvidia_root" \
    SYSTEM_STATS_UDEV_DATA_ROOT="$udev_root" \
    SYSTEM_STATS_SECOND_MS=1 \
    QT_QPA_PLATFORM=offscreen \
    timeout 15s quickshell --no-color --path "$test_dir/shell.qml" 2>&1) || {
      printf '%s\n' "$output"
      exit 1
    }

  printf '%s\n' "$output"
  grep -Fq "TEST-PASS:" <<<"$output"
}

run_linux_label_case

run_restart_case() {
  local case_name=$1
  local restart_condition=$2
  local second_ms=$3
  local initial_inventory=$4
  local inventory_file="$test_dir/$case_name.inventory"
  local presence_file="$test_dir/$case_name.presence"
  local marker_dir="$test_dir/$case_name.marker"
  local output

  cp "$repo_root/tests/fixtures/gpu/$initial_inventory" "$inventory_file"
  cut -f1 "$inventory_file" >"$presence_file"
  touch "$test_dir/$case_name.output"
  cp "$repo_root/bin/system-stats-helper" "$test_dir/bin/system-stats-helper.real"
  cp "$repo_root/tests/helpers/restart-once-when-ready.sh" "$test_dir/bin/system-stats-helper"
  chmod +x "$test_dir/bin/system-stats-helper"

  output=$(SYSTEM_STATS_GPU_CASE="$case_name" \
    SYSTEM_STATS_GPU_INVENTORY_FILE="$inventory_file" \
    SYSTEM_STATS_GPU_PRESENCE_FILE="$presence_file" \
    SYSTEM_STATS_NVML_LIBRARY="$test_dir/missing-nvml.so" \
    SYSTEM_STATS_RESTART_MARKER_DIR="$marker_dir" \
    SYSTEM_STATS_RESTART_CONDITION="$restart_condition" \
    SYSTEM_STATS_RESTART_OBSERVATION_FILE="$test_dir/$case_name.output" \
    SYSTEM_STATS_REAL_HELPER="$test_dir/bin/system-stats-helper.real" \
    SYSTEM_STATS_SECOND_MS="$second_ms" \
    QT_QPA_PLATFORM=offscreen \
    timeout 15s quickshell --no-color --path "$test_dir/shell.qml" 2>&1) || {
      printf '%s\n' "$output"
      exit 1
    }

  printf '%s\n' "$output"
  grep -Fq "TEST-PASS:" <<<"$output"
}

run_restart_case auto-restart inventory-added 10 single-intel.inventory
run_restart_case fixed-restart fixed-retry-paused 1 single-intel.inventory
run_restart_case required-restart inventory-removed 10 multiple-ambiguous.inventory
run_restart_case selected-disappears-restart inventory-removed 10 hybrid-unique-display.inventory
