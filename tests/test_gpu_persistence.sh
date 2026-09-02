#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)

cleanup() {
  if [[ -d $test_dir ]]; then rm -rf -- "$test_dir"; fi
}
trap cleanup EXIT

mkdir -p "$test_dir/plugin/bin" "$test_dir/Ui" "$test_dir/Commons"
cp "$repo_root/Service.qml" "$test_dir/plugin/Service.qml"
cp "$repo_root/BarWidget.qml" "$test_dir/plugin/BarWidget.qml"
cp "$repo_root/tests/qml/gpu_persistence_harness.qml" "$test_dir/shell.qml"
cp "$repo_root/tests/qml/FakeBar.qml" "$test_dir/FakeBar.qml"
cp "$repo_root/bin/system-stats-helper" "$test_dir/plugin/bin/system-stats-helper"
cp -R /usr/share/omarchy/shell/Ui/. "$test_dir/Ui/"
cp -R /usr/share/omarchy/shell/Commons/. "$test_dir/Commons/"

inventory_file="$test_dir/inventory"
presence_file="$test_dir/presence"
cp "$repo_root/tests/fixtures/gpu/hybrid-unique-display.inventory" "$inventory_file"
cut -f1 "$inventory_file" >"$presence_file"

output=$(SYSTEM_STATS_GPU_INVENTORY_FILE="$inventory_file" \
  SYSTEM_STATS_GPU_PRESENCE_FILE="$presence_file" \
  SYSTEM_STATS_SECOND_MS=100 \
  QT_QPA_PLATFORM=offscreen \
  timeout 5s quickshell --no-color --path "$test_dir/shell.qml" 2>&1) || {
    printf '%s\n' "$output"
    exit 1
  }

printf '%s\n' "$output"
grep -Fq "TEST-PASS: persisted fixed GPU is restored in a new session" <<<"$output"
