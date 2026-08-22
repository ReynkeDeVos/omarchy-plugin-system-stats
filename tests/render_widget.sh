#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
review_dir="$repo_root/.impeccable/review"

cleanup() {
  if [[ -d $test_dir ]]; then rm -rf -- "$test_dir"; fi
}
trap cleanup EXIT

mkdir -p "$test_dir/plugin/bin" "$test_dir/fixtures" "$test_dir/Ui" "$test_dir/Commons" "$review_dir"
cp "$repo_root/Service.qml" "$test_dir/plugin/Service.qml"
cp "$repo_root/BarWidget.qml" "$test_dir/plugin/BarWidget.qml"
cp "$repo_root/tests/qml/widget_preview.qml" "$test_dir/shell.qml"
cp "$repo_root/tests/qml/FakeBar.qml" "$test_dir/FakeBar.qml"
cp "$repo_root/bin/system-stats-helper" "$test_dir/plugin/bin/system-stats-helper"
cp -R "$repo_root/tests/fixtures/cpu" "$test_dir/fixtures/cpu"
cp -R "$repo_root/tests/fixtures/ram" "$test_dir/fixtures/ram"
cp -R "$repo_root/tests/fixtures/gpu" "$test_dir/fixtures/gpu"
cut -f1 "$test_dir/fixtures/gpu/hybrid-unique-display.inventory" \
  >"$test_dir/fixtures/gpu/hybrid.presence"
cp -R /usr/share/omarchy/shell/Ui/. "$test_dir/Ui/"
cp -R /usr/share/omarchy/shell/Commons/. "$test_dir/Commons/"

SYSTEM_STATS_REVIEW_DIR="$review_dir" \
  SYSTEM_STATS_FRAMES="$test_dir/fixtures/cpu/normal.stat" \
  SYSTEM_STATS_MEMINFO_FRAMES="$test_dir/fixtures/ram/normal.meminfo" \
  SYSTEM_STATS_GPU_INVENTORY_FILE="$test_dir/fixtures/gpu/hybrid-unique-display.inventory" \
  SYSTEM_STATS_GPU_PRESENCE_FILE="$test_dir/fixtures/gpu/hybrid.presence" \
  SYSTEM_STATS_INTEL_PROC_FRAMES="$test_dir/fixtures/gpu/intel/i915" \
  SYSTEM_STATS_INTERVAL_MS=250 \
  QT_QPA_PLATFORM=offscreen \
  timeout 5s quickshell --no-color --path "$test_dir/shell.qml"

magick "$review_dir/system-stats-initializing.png" -resize 720x144\! "$review_dir/system-stats-initializing.png"
magick "$review_dir/system-stats-percent.png" -resize 720x144\! "$review_dir/system-stats-percent.png"
magick "$review_dir/system-stats-gib.png" -resize 720x144\! "$review_dir/system-stats-gib.png"

test -s "$review_dir/system-stats-initializing.png"
test -s "$review_dir/system-stats-percent.png"
test -s "$review_dir/system-stats-gib.png"
