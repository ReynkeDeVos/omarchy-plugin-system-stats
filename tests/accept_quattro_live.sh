#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: tests/accept_quattro_live.sh [--real-suspend]

Run the System Stats acceptance gate in the active two-or-more-screen Omarchy
session. The gate installs only a temporary Git copy, refuses to replace an
existing installation, and restores the original shell configuration on exit.

Without an option, the script is a non-power-state-changing preflight. It uses
reversible process pauses but does not satisfy the real-suspend release gate.

  --real-suspend  Prompt for one short and one 30-second system suspend and run
                  the complete Quattro lifecycle acceptance.
USAGE
}

real_suspend=false
case "${1:-}" in
  "") ;;
  --real-suspend) real_suspend=true ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
(( $# <= 1 )) || { usage >&2; exit 2; }

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
plugin_id="reynkedevos.system-stats"
shell_config="$HOME/.config/omarchy/shell.json"
plugin_dir="$HOME/.config/omarchy/plugins/$plugin_id"
helper_path="$plugin_dir/bin/system-stats-helper"
target_omarchy_version="4.0.0-1"
target_quickshell_revision="28771c7c74b42e20afca0b1b63980cb46515537c"

fail() {
  echo "accept_quattro_live: $*" >&2
  exit 1
}

for command in cp git hyprctl jq make omarchy omarchy-shell pgrep quickshell; do
  command -v "$command" >/dev/null || fail "missing command: $command"
done

# A plugin rescan rebuilds live QML and can legitimately exceed the shell
# wrapper's two-second default on the reference session.
export OMARCHY_SHELL_IPC_TIMEOUT="${OMARCHY_SHELL_IPC_TIMEOUT:-10s}"

# Long-lived tmux servers can predate Hyprland and omit its instance signature
# from new panes. Discover the matching live instance without changing tmux.
if [[ -z ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
  hyprland_instances=$(hyprctl instances -j 2>/dev/null) ||
    fail "could not discover the active Hyprland instance"
  if [[ -n ${WAYLAND_DISPLAY:-} ]]; then
    HYPRLAND_INSTANCE_SIGNATURE=$(jq -er --arg socket "$WAYLAND_DISPLAY" '
      [.[] | select(.wl_socket == $socket)]
      | if length == 1 then .[0].instance else empty end
    ' <<<"$hyprland_instances") ||
      fail "could not match WAYLAND_DISPLAY to one Hyprland instance"
  else
    HYPRLAND_INSTANCE_SIGNATURE=$(jq -er '
      if length == 1 then .[0].instance else empty end
    ' <<<"$hyprland_instances") ||
      fail "could not select one active Hyprland instance"
  fi
  export HYPRLAND_INSTANCE_SIGNATURE
fi

[[ $(omarchy version) == "$target_omarchy_version" ]] ||
  fail "this gate targets Omarchy $target_omarchy_version"
quickshell_version=$(quickshell --version 2>&1)
[[ $quickshell_version == *"revision $target_quickshell_revision"* ]] ||
  fail "this gate targets Quickshell revision $target_quickshell_revision"
[[ $(omarchy-shell shell ping 2>/dev/null) == "ok" ]] ||
  fail "the Omarchy shell is not responding"

monitor_count=$(hyprctl monitors -j | jq '[.[] | select(.disabled != true)] | length')
(( monitor_count >= 2 )) || fail "the live gate requires at least two active screens"
[[ ! -e $plugin_dir ]] ||
  fail "$plugin_id is already installed; refusing to replace it"

test_dir=$(mktemp -d)
stage_repo="$test_dir/system-stats"
config_backup="$test_dir/shell.json"
had_shell_config=false
config_snapshotted=false
owns_plugin=false

cleanup() {
  local status=$?
  trap - EXIT
  set +e

  if [[ $owns_plugin == true && -e $plugin_dir ]]; then
    omarchy plugin remove "$plugin_id" --yes >/dev/null 2>&1
  fi
  if [[ $config_snapshotted == true ]]; then
    if [[ $had_shell_config == true ]]; then
      cp -- "$config_backup" "$shell_config"
    else
      rm -f -- "$shell_config"
    fi
    omarchy-shell shell reloadConfig >/dev/null 2>&1
    omarchy-shell shell rescanPlugins >/dev/null 2>&1
  fi
  if [[ -n $test_dir && $test_dir != "/" && -d $test_dir ]]; then
    rm -rf -- "$test_dir"
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

if [[ -f $shell_config ]]; then
  cp -- "$shell_config" "$config_backup"
  had_shell_config=true
fi
config_snapshotted=true

make -s -C "$repo_root" build
omarchy plugin validate "$repo_root"

mkdir -p "$stage_repo/bin"
cp -- "$repo_root/manifest.json" "$repo_root/Service.qml" \
  "$repo_root/BarWidget.qml" "$repo_root/LICENSE" "$repo_root/README.md" \
  "$stage_repo/"
cp -- "$repo_root/bin/system-stats-helper" "$stage_repo/bin/"
git -C "$stage_repo" init -q
git -C "$stage_repo" config user.name "System Stats Acceptance"
git -C "$stage_repo" config user.email "acceptance@invalid"
git -C "$stage_repo" add .
git -C "$stage_repo" commit -qm "temporary Quattro acceptance package"

helper_pids=()
collect_helper_pids() {
  mapfile -t helper_pids < <(pgrep -f "^$helper_path$" || true)
}

widget_count() {
  local geometry
  geometry=$(omarchy-shell shell debugBarGeometry 2>/dev/null || printf '[]')
  jq --arg id "$plugin_id" '[.[] | select(.id == $id)] | length' <<<"$geometry"
}

entry_state() {
  local config
  config=$(omarchy-shell shell listShellConfig 2>/dev/null || printf '{}')
  jq -c --arg id "$plugin_id" '
    [.bar.layout // {} | to_entries[]
      | .key as $section
      | .value[]
      | select(.id == $id)
      | . + {section: $section}]
  ' <<<"$config"
}

acceptance_state() {
  omarchy-shell "$plugin_id" acceptanceState 2>/dev/null || printf '{}'
}

shared_live_state_matches() {
  local state=$1
  jq -e --argjson widgetCount "$monitor_count" '
    .widgetCount == $widgetCount
    and .serviceCount == 1
    and .snapshotCount == 1
    and .sharedSequence == true
    and .sharedSettings == true
  ' <<<"$state" >/dev/null
}

wait_for_shell() {
  local attempt
  for ((attempt = 0; attempt < 200; attempt++)); do
    [[ $(omarchy-shell shell ping 2>/dev/null || true) == "ok" ]] && return 0
    sleep 0.05
  done
  fail "the Omarchy shell did not resume"
}

wait_for_live() {
  local expected_section=$1
  local attempt widgets entries state
  for ((attempt = 0; attempt < 200; attempt++)); do
    collect_helper_pids
    widgets=$(widget_count)
    entries=$(entry_state)
    state=$(acceptance_state)
    if [[ ${#helper_pids[@]} -eq 1 && $widgets -eq $monitor_count ]] \
        && [[ $(jq 'length' <<<"$entries") -eq 1 ]] \
        && [[ $(jq -r '.[0].section' <<<"$entries") == "$expected_section" ]] \
        && shared_live_state_matches "$state"; then
      return 0
    fi
    sleep 0.05
  done
  fail "expected one service, one snapshot, one helper, and $monitor_count widgets in $expected_section"
}

wait_for_unloaded() {
  local attempt widgets entries
  for ((attempt = 0; attempt < 200; attempt++)); do
    collect_helper_pids
    widgets=$(widget_count)
    entries=$(entry_state)
    if [[ ${#helper_pids[@]} -eq 0 && $widgets -eq 0 ]] \
        && [[ $(jq 'length' <<<"$entries") -eq 0 ]]; then
      return 0
    fi
    sleep 0.05
  done
  fail "the disabled plugin left a widget or helper behind"
}

assert_helper_shape() {
  collect_helper_pids
  [[ ${#helper_pids[@]} -eq 1 ]] || fail "expected exactly one helper"
  local helper_pid=${helper_pids[0]}
  local children=""
  read -r children <"/proc/$helper_pid/task/$helper_pid/children" || true
  [[ -z $children ]] || fail "the helper launched a child process"
}

persisted_settings_match() {
  local entries=$1
  jq -e '
    length == 1
    and .[0].intervalSeconds == 3
    and .[0].ramDisplayFormat == "gib"
  ' <<<"$entries" >/dev/null
}

live_widget_settings_match() {
  local state=$1
  jq -e '
    .sharedSettings == true
    and ([.widgets[]
      | .settings.intervalSeconds == 3
        and .settings.ramDisplayFormat == "gib"] | all)
  ' <<<"$state" >/dev/null
}

assert_persisted_settings() {
  local entries state
  entries=$(entry_state)
  state=$(acceptance_state)
  persisted_settings_match "$entries" && live_widget_settings_match "$state" ||
    fail "the inline or per-screen settings changed or split"
}

wait_for_persisted_settings() {
  local attempt entries state
  for ((attempt = 0; attempt < 100; attempt++)); do
    entries=$(entry_state)
    state=$(acceptance_state)
    if persisted_settings_match "$entries" && live_widget_settings_match "$state"; then
      return 0
    fi
    sleep 0.05
  done
  fail "the inline settings were not persisted: entries=$(entry_state) widgets=$(acceptance_state)"
}

wait_for_shared_sequence_progress() {
  local initial_state initial_generation initial_sequence attempt state
  initial_state=$(acceptance_state)
  shared_live_state_matches "$initial_state" || fail "the live widget state is not shared"
  initial_generation=$(jq '.generation' <<<"$initial_state")
  initial_sequence=$(jq '.sequence' <<<"$initial_state")

  for ((attempt = 0; attempt < 240; attempt++)); do
    state=$(acceptance_state)
    if shared_live_state_matches "$state" \
        && live_widget_settings_match "$state" \
        && [[ $(jq '.generation' <<<"$state") -eq $initial_generation ]] \
        && [[ $(jq '.sequence' <<<"$state") -gt $initial_sequence ]]; then
      return 0
    fi
    sleep 0.05
  done
  fail "the real screen widgets did not advance through one shared sequence"
}

verify_resumed_runtime() {
  wait_for_shell
  wait_for_live right
  wait_for_persisted_settings
  assert_helper_shape
  assert_persisted_settings
}

pause_runtime() {
  local label=$1
  local seconds=$2
  local shell_pid
  assert_helper_shape
  local helper_pid=${helper_pids[0]}
  shell_pid=$(pgrep -f '^quickshell -n -p /usr/share/omarchy/shell$' | head -n 1)
  [[ -n $shell_pid ]] || fail "could not identify the Omarchy Quickshell process"

  kill -STOP "$helper_pid" "$shell_pid"
  sleep "$seconds"
  kill -CONT "$helper_pid" "$shell_pid"
  verify_resumed_runtime
  printf 'PASS: %s process pause leaves one helper\n' "$label"
}

real_suspend_cycle() {
  local label=$1
  local minimum_seconds=$2
  [[ -t 0 ]] || fail "--real-suspend requires an interactive terminal"
  printf '\n%s: press Enter to suspend, then resume after at least %s seconds.\n' \
    "$label" "$minimum_seconds"
  read -r
  local started_at resumed_at elapsed
  started_at=$(date +%s)
  systemctl suspend
  printf '%s: once the system has resumed and this terminal is usable, press Enter to continue.\n' \
    "$label"
  read -r
  resumed_at=$(date +%s)
  elapsed=$((resumed_at - started_at))
  (( elapsed >= minimum_seconds )) ||
    fail "$label lasted ${elapsed}s; expected at least ${minimum_seconds}s"
  verify_resumed_runtime
  printf 'PASS: %s system suspend leaves one helper\n' "$label"
}

# Exercise both shipped entry points before installing the temporary live copy.
bash "$repo_root/tests/test_widget.sh" >/dev/null
printf 'PASS: two-screen entry-point integration contract\n'

owns_plugin=true
omarchy plugin add "file://$stage_repo" --enable --yes
wait_for_live right
assert_helper_shape
printf 'PASS: default activation creates %s widgets and one helper on the right\n' \
  "$monitor_count"

omarchy bar set "$plugin_id" intervalSeconds 3 --json >/dev/null
omarchy bar set "$plugin_id" ramDisplayFormat gib >/dev/null
wait_for_persisted_settings
assert_persisted_settings
wait_for_shared_sequence_progress
printf 'PASS: real screen widgets advance one shared sequence and settings record\n'

old_helper=${helper_pids[0]}
touch "$plugin_dir/Service.qml"
max_helpers=0
new_helper=""
for ((attempt = 0; attempt < 400; attempt++)); do
  collect_helper_pids
  (( ${#helper_pids[@]} > max_helpers )) && max_helpers=${#helper_pids[@]}
  if [[ ${#helper_pids[@]} -eq 1 && ${helper_pids[0]} != "$old_helper" ]]; then
    new_helper=${helper_pids[0]}
    break
  fi
  sleep 0.02
done
[[ -n $new_helper ]] || fail "plugin reload did not replace the helper"
(( max_helpers <= 1 )) || fail "plugin reload overlapped $max_helpers helpers"
wait_for_live right
wait_for_persisted_settings
assert_persisted_settings
printf 'PASS: plugin reload peaks at one helper\n'

pause_runtime "short" 1
pause_runtime "long" 6
if [[ $real_suspend == true ]]; then
  real_suspend_cycle "short" 1
  real_suspend_cycle "long" 30
fi

for section in center left right; do
  omarchy bar move "$plugin_id" --section "$section" >/dev/null
  wait_for_live "$section"
  assert_helper_shape
  assert_persisted_settings
done
printf 'PASS: normal bar moves cover left, center, and right\n'

omarchy plugin disable "$plugin_id" >/dev/null
wait_for_unloaded
printf 'PASS: deactivation leaves no widget or helper\n'

for section in left center right; do
  omarchy plugin enable "$plugin_id" --section "$section" >/dev/null
  wait_for_live "$section"
  assert_helper_shape
  omarchy plugin disable "$plugin_id" >/dev/null
  wait_for_unloaded
done
printf 'PASS: explicit activation covers left, center, and right\n'

omarchy plugin enable "$plugin_id" >/dev/null
wait_for_live right
omarchy plugin remove "$plugin_id" --yes >/dev/null
owns_plugin=false
wait_for_unloaded
[[ ! -e $plugin_dir ]] || fail "plugin removal left its checkout behind"
printf 'PASS: removal leaves no checkout, widget, or helper\n'

if [[ $real_suspend == true ]]; then
  printf 'PASS: Quattro %s full live acceptance on %s screens\n' \
    "$target_omarchy_version" "$monitor_count"
else
  printf 'PASS: Quattro %s live preflight on %s screens\n' \
    "$target_omarchy_version" "$monitor_count"
  printf 'INCOMPLETE: run again with --real-suspend for release acceptance\n'
fi
