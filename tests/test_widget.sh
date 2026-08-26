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
cp -R "$repo_root/tests/fixtures/ram" "$test_dir/fixtures/ram"
cp -R "$repo_root/tests/fixtures/gpu" "$test_dir/fixtures/gpu"
cut -f1 "$test_dir/fixtures/gpu/hybrid-unique-display.inventory" \
  >"$test_dir/fixtures/gpu/hybrid.presence"
cp -R /usr/share/omarchy/shell/Ui/. "$test_dir/Ui/"
cp -R /usr/share/omarchy/shell/Commons/. "$test_dir/Commons/"

output_file="$test_dir/quickshell.log"
trace_file="$test_dir/helper.trace"
observer="$test_dir/helper-observer.so"
cc -std=c17 -O2 -Wall -Wextra -Werror -shared -fPIC \
  "$repo_root/tests/native/helper_observer.c" -o "$observer" -ldl

helper_path=$(readlink -f "$test_dir/plugin/bin/system-stats-helper")
SYSTEM_STATS_FRAMES="$test_dir/fixtures/cpu/widget.stat" \
  SYSTEM_STATS_MEMINFO_FRAMES="$test_dir/fixtures/ram/widget.meminfo" \
  SYSTEM_STATS_GPU_INVENTORY_FILE="$test_dir/fixtures/gpu/hybrid-unique-display.inventory" \
  SYSTEM_STATS_GPU_PRESENCE_FILE="$test_dir/fixtures/gpu/hybrid.presence" \
  SYSTEM_STATS_INTEL_PROC_FRAMES="$test_dir/fixtures/gpu/intel/i915" \
  SYSTEM_STATS_INTERVAL_MS=100 \
  SYSTEM_STATS_TRACE_EXECUTABLE="$helper_path" \
  SYSTEM_STATS_TRACE_FILE="$trace_file" \
  LD_PRELOAD="$observer" \
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

mapfile -t launch_events < <(awk '$1 == "launch" { print $2 }' "$trace_file")
mapfile -t sampler_events < <(awk '$1 == "sampler" { print $2 ":" $3 }' "$trace_file")
[[ ${#launch_events[@]} -eq 1 ]]
[[ ${#sampler_events[@]} -eq 1 ]]
[[ ${sampler_events[0]%%:*} == "${launch_events[0]}" ]]

cp "$repo_root/tests/qml/widget_error_harness.qml" "$test_dir/error-shell.qml"
error_output=$(SYSTEM_STATS_FRAMES="$test_dir/fixtures/cpu/widget.stat" \
  SYSTEM_STATS_MEMINFO_FRAMES="$test_dir/fixtures/ram/widget.meminfo" \
  SYSTEM_STATS_GPU_INVENTORY_FILE="$test_dir/fixtures/gpu/hybrid-unique-display.inventory" \
  SYSTEM_STATS_GPU_PRESENCE_FILE="$test_dir/fixtures/gpu/hybrid.presence" \
  SYSTEM_STATS_INTEL_PROC_FRAMES="$test_dir/fixtures/gpu/intel/permission-denied" \
  SYSTEM_STATS_INTERVAL_MS=100 \
  QT_QPA_PLATFORM=offscreen \
  timeout 5s quickshell --no-color --path "$test_dir/error-shell.qml" 2>&1) || {
    printf '%s\n' "$error_output"
    exit 1
  }
printf '%s\n' "$error_output"
grep -Fq "TEST-PASS: Intel GPU error is detailed without cluttering the bar" \
  <<<"$error_output"

cp "$repo_root/tests/qml/widget_contract_harness.qml" "$test_dir/contract-shell.qml"
contract_output=$(QT_QPA_PLATFORM=offscreen \
  timeout 5s quickshell --no-color --path "$test_dir/contract-shell.qml" 2>&1) || {
    printf '%s\n' "$contract_output"
    exit 1
  }
printf '%s\n' "$contract_output"
grep -Fq "TEST-PASS: approved widget contract remains stable and operable" \
  <<<"$contract_output"

cp "$repo_root/tests/qml/quattro_reload_settings_harness.qml" \
  "$test_dir/reload-settings-shell.qml"
reload_settings_output=$(QT_QPA_PLATFORM=offscreen \
  timeout 5s quickshell --no-color \
  --path "$test_dir/reload-settings-shell.qml" 2>&1) || {
    printf '%s\n' "$reload_settings_output"
    exit 1
  }
printf '%s\n' "$reload_settings_output"
grep -Fq "TEST-PASS: recreated widgets consume Quattro-injected settings" \
  <<<"$reload_settings_output"

if rg -n '\b(Process|Timer)\s*\{' "$repo_root/BarWidget.qml"; then
  echo "screen callers must remain pure readers without helpers or sampling timers" >&2
  exit 1
fi
