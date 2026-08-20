#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
shell_pid=""

cleanup() {
  if [[ -n $shell_pid ]] && kill -0 "$shell_pid" 2>/dev/null; then
    kill "$shell_pid"
    wait "$shell_pid" 2>/dev/null || true
  fi
  if [[ -d $test_dir ]]; then rm -rf -- "$test_dir"; fi
}
trap cleanup EXIT

mkdir -p "$test_dir/plugin/bin" "$test_dir/fixtures" "$test_dir/Ui" "$test_dir/Commons"
cp "$repo_root/Service.qml" "$test_dir/plugin/Service.qml"
cp "$repo_root/BarWidget.qml" "$test_dir/plugin/BarWidget.qml"
cp "$repo_root/tests/qml/widget_harness.qml" "$test_dir/shell.qml"
cp "$repo_root/tests/qml/FakeBar.qml" "$test_dir/FakeBar.qml"
cp "$repo_root/bin/system-stats-helper" "$test_dir/plugin/bin/system-stats-helper"
cp -R "$repo_root/tests/fixtures/cpu" "$test_dir/fixtures/cpu"
cp -R /usr/share/omarchy/shell/Ui/. "$test_dir/Ui/"
cp -R /usr/share/omarchy/shell/Commons/. "$test_dir/Commons/"

output_file="$test_dir/quickshell.log"
SYSTEM_STATS_FRAMES="$test_dir/fixtures/cpu/normal.stat" \
  SYSTEM_STATS_INTERVAL_MS=20 \
  QT_QPA_PLATFORM=offscreen \
  quickshell --no-color --path "$test_dir/shell.qml" >"$output_file" 2>&1 &
shell_pid=$!

ready=false
for ((attempt = 0; attempt < 200; attempt++)); do
  if grep -Fq "TEST-READY: two widgets share one session" "$output_file"; then
    ready=true
    break
  fi
  if ! kill -0 "$shell_pid" 2>/dev/null; then break; fi
  sleep 0.02
done

if [[ $ready != true ]]; then
  cat "$output_file"
  echo "widget smoke did not reach its observable state" >&2
  exit 1
fi

helper_path=$(readlink -f "$test_dir/plugin/bin/system-stats-helper")
children=()
read -r -a children <"/proc/$shell_pid/task/$shell_pid/children" || true
helper_pids=()
for child_pid in "${children[@]}"; do
  child_executable=$(readlink -f "/proc/$child_pid/exe" 2>/dev/null || true)
  if [[ $child_executable == "$helper_path" ]]; then
    helper_pids+=("$child_pid")
  fi
done

if [[ ${#helper_pids[@]} -ne 1 ]]; then
  cat "$output_file"
  echo "expected exactly one live helper process, found ${#helper_pids[@]}" >&2
  exit 1
fi

helper_pid=${helper_pids[0]}
read -r helper_children <"/proc/$helper_pid/task/$helper_pid/children" || true
[[ -z ${helper_children:-} ]]
mapfile -t helper_tasks < <(find "/proc/$helper_pid/task" -mindepth 1 -maxdepth 1 -type d)
[[ ${#helper_tasks[@]} -eq 1 ]]

if rg -n '\bTimer\s*\{' "$repo_root/Service.qml" "$repo_root/BarWidget.qml"; then
  echo "service and widgets must not create another QML sampling timer" >&2
  exit 1
fi

status=0
for ((attempt = 0; attempt < 200; attempt++)); do
  if ! kill -0 "$shell_pid" 2>/dev/null; then
    wait "$shell_pid" || status=$?
    shell_pid=""
    break
  fi
  sleep 0.02
done

if [[ -n $shell_pid ]]; then
  cat "$output_file"
  echo "widget smoke timed out" >&2
  exit 1
fi

cat "$output_file"
if (( status != 0 )); then exit "$status"; fi
grep -Fq "TEST-PASS: two widgets share one session" "$output_file"
