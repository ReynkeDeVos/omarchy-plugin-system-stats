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
cp "$repo_root/bin/system-stats-helper" "$test_dir/plugin/bin/system-stats-helper"
cp -R "$repo_root/tests/fixtures/cpu" "$test_dir/fixtures/cpu"
cp -R /usr/share/omarchy/shell/Ui/. "$test_dir/Ui/"
cp -R /usr/share/omarchy/shell/Commons/. "$test_dir/Commons/"

SYSTEM_STATS_REVIEW_DIR="$review_dir" \
  timeout 5s quickshell --no-color --path "$test_dir/shell.qml"

magick "$review_dir/system-stats-initializing.png" -resize 720x144\! "$review_dir/system-stats-initializing.png"
magick "$review_dir/system-stats-cpu.png" -resize 720x144\! "$review_dir/system-stats-cpu.png"

test -s "$review_dir/system-stats-initializing.png"
test -s "$review_dir/system-stats-cpu.png"
