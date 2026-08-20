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
cp "$repo_root/tests/qml/session_harness.qml" "$test_dir/shell.qml"
cp "$repo_root/bin/system-stats-helper" "$test_dir/bin/system-stats-helper"
cp -R "$repo_root/tests/fixtures/cpu" "$test_dir/fixtures/cpu"

observed_generations=()

run_case() {
  local case_name=$1
  local expected_status=$2
  local expected_percent=$3
  local expected_error=$4
  local output
  local status

  set +e
  output=$(SYSTEM_STATS_CASE="$case_name" \
    SYSTEM_STATS_EXPECTED_STATUS="$expected_status" \
    SYSTEM_STATS_EXPECTED_PERCENT="$expected_percent" \
    SYSTEM_STATS_EXPECTED_ERROR="$expected_error" \
    SYSTEM_STATS_FRAMES="$test_dir/fixtures/cpu/$case_name.stat" \
    SYSTEM_STATS_INTERVAL_MS=1 \
    QT_QPA_PLATFORM=offscreen \
    timeout 5s quickshell --no-color --path "$test_dir/shell.qml" 2>&1)
  status=$?
  set -e

  printf '%s\n' "$output"
  if (( status != 0 )); then return "$status"; fi
  grep -Fq "TEST-PASS: $case_name public session snapshot" <<<"$output"
  local generation
  generation=$(sed -n 's/.*TEST-GENERATION: //p' <<<"$output")
  [[ $generation =~ ^[0-9]+$ ]]
  (( generation > 4294967295 ))
  observed_generations+=("$generation")
}

run_case normal available 37 ""
run_case zero available 0 ""
run_case hundred available 100 ""
run_case rounding available 13 ""
run_case missing-field unavailable 0 missingRequiredField
run_case counter-reset unavailable 0 counterReset
run_case nonpositive-delta unavailable 0 malformedCounter

unique_generation_count=$(printf '%s\n' "${observed_generations[@]}" | sort -u | wc -l)
[[ $unique_generation_count -eq ${#observed_generations[@]} ]]
