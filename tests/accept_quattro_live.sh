#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: tests/accept_quattro_live.sh [--real-suspend]

Run the System Stats acceptance gate in the active two-or-more-screen Omarchy
session. The gate installs only a temporary Git copy, refuses to replace an
existing installation, and removes only its own shell-configuration entries on
a normal or confirmed-unlocked exit. Concurrent unrelated edits are preserved.
If interrupted before resume and unlock are confirmed, it defers shell
mutations and leaves a recovery bundle.

Without an option, the script is a non-power-state-changing preflight. It uses
reversible process pauses but does not satisfy the real-suspend release gate.

  --real-suspend  Restart the unlocked Omarchy shell once, then prompt for one
                  short and one 30-second system suspend and run the complete
                  Quattro lifecycle acceptance.
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
state_home="${XDG_STATE_HOME:-$HOME/.local/state}"
state_root="$state_home/omarchy-system-stats/acceptance"
[[ $state_root == /* && $state_root != "/" ]] || {
  echo "accept_quattro_live: the acceptance recovery state path is unsafe: $state_root" >&2
  exit 1
}
command -v flock >/dev/null && command -v mkdir >/dev/null || {
  echo "accept_quattro_live: flock and mkdir are required" >&2
  exit 1
}
mkdir -p -- "$state_root"
exec {acceptance_lock_fd}>"$state_root/acceptance.lock"
if ! flock --exclusive --nonblock "$acceptance_lock_fd"; then
  echo "accept_quattro_live: another acceptance run is active" >&2
  exit 75
fi
plugin_id="reynkedevos.system-stats"
probe_id="reynkedevos.system-stats-acceptance"
shell_config="$HOME/.config/omarchy/shell.json"
plugin_dir="$HOME/.config/omarchy/plugins/$plugin_id"
probe_dir="$HOME/.config/omarchy/plugins/$probe_id"
helper_path="$plugin_dir/bin/system-stats-helper"
config_restorer="$repo_root/tests/helpers/restore_quattro_shell_config.sh"
helper_cleanup_verifier="$repo_root/tests/helpers/verify_quattro_helper_cleanup.sh"
suspend_barrier="$repo_root/tests/helpers/run_quattro_suspend_if_ready.sh"
acceptance_cleanup="$repo_root/tests/helpers/cleanup_quattro_acceptance.sh"
session_unlock_verifier="$repo_root/tests/helpers/verify_quattro_session_unlocked.sh"
hyprland_instance_resolver="$repo_root/tests/helpers/resolve_quattro_hyprland_instance.sh"
target_omarchy_version="4.0.1-1"
target_quickshell_fingerprint="Quickshell 0.3.1 (revision , distributed by Arch Linux)"

fail() {
  echo "accept_quattro_live: $*" >&2
  exit 1
}

for command in awk chmod cp env find flock gdbus git hyprctl jq loginctl make \
  mkdir mktemp mv omarchy omarchy-hyprland-session-locked omarchy-restart-shell \
  omarchy-shell pgrep python3 quickshell readlink sha256sum sort stat stdbuf \
  systemctl systemd-inhibit touch; do
  command -v "$command" >/dev/null || fail "missing command: $command"
done

# A plugin rescan rebuilds live QML and can legitimately exceed the shell
# wrapper's two-second default on the reference session.
export OMARCHY_SHELL_IPC_TIMEOUT="${OMARCHY_SHELL_IPC_TIMEOUT:-10s}"

# Long-lived tmux servers and fresh TTYs can predate Hyprland and omit its
# instance signature. Resolve the one matching live instance without mutating
# either environment outside this gate.
HYPRLAND_INSTANCE_SIGNATURE=$(bash "$hyprland_instance_resolver") ||
  fail "could not resolve one active Hyprland instance"
export HYPRLAND_INSTANCE_SIGNATURE

session_is_unlocked() {
  bash "$session_unlock_verifier" "$UID"
}

session_is_unlocked || fail "the active login session is locked or unavailable"

[[ $(omarchy version) == "$target_omarchy_version" ]] ||
  fail "this gate targets Omarchy $target_omarchy_version"
quickshell_version=$(quickshell --version 2>&1)
[[ $quickshell_version == "$target_quickshell_fingerprint" ]] ||
  fail "this gate targets $target_quickshell_fingerprint"
[[ $(omarchy-shell shell ping 2>/dev/null) == "ok" ]] ||
  fail "the Omarchy shell is not responding"

monitor_count=$(hyprctl monitors -j | jq '[.[] | select(.disabled != true)] | length')
(( monitor_count >= 2 )) || fail "the live gate requires at least two active screens"
[[ ! -e $plugin_dir ]] ||
  fail "$plugin_id is already installed; refusing to replace it"
[[ ! -e $probe_dir ]] ||
  fail "$probe_id is already installed; refusing to replace it"
if [[ -f $shell_config ]] && ! bash "$config_restorer" --assert-clean \
    "$shell_config" "$plugin_id" "$probe_id"; then
  fail "shell configuration already contains acceptance-owned entries"
fi

mkdir -p -- "$state_root"
recovery_dir=$(mktemp -d "$state_root/run.XXXXXXXX")
run_id=${recovery_dir##*/}
test_dir="$recovery_dir/staging"
mkdir -p -- "$test_dir"
helper_state_dir="$recovery_dir/helper-guard"
helper_overlap_marker="$helper_state_dir/overlap"
stage_repo="$test_dir/system-stats"
stage_probe="$test_dir/acceptance-probe"
config_backup="$recovery_dir/shell.json"
last_gate_config="$recovery_dir/last-gate-shell.json"
original_effective_config="$recovery_dir/original-effective-shell.json"
current_config="$recovery_dir/current-shell.json"
recovery_restorer="$recovery_dir/restore_quattro_shell_config.sh"
recovery_helper_verifier="$recovery_dir/verify_quattro_helper_cleanup.sh"
recovery_cleanup="$recovery_dir/cleanup_quattro_acceptance.sh"
recovery_session_unlock_verifier="$recovery_dir/verify_quattro_session_unlocked.sh"
recovery_hyprland_instance_resolver="$recovery_dir/resolve_quattro_hyprland_instance.sh"
cleanup_manifest="$recovery_dir/cleanup-manifest.json"
recovery_file="$recovery_dir/RECOVERY.txt"
suspend_barrier_state="$recovery_dir/suspend-barrier.json"
had_shell_config=false
config_snapshotted=false
sleep_observer_pid=""
sleep_inhibitor_pid=""
cleanup_mutations_safe=true

snapshot_shell_config() {
  local destination=$1
  local destination_tmp="${destination}.tmp"
  if [[ -f $shell_config ]]; then
    cp -- "$shell_config" "$destination_tmp"
  else
    printf '{}\n' >"$destination_tmp"
  fi
  mv -f -- "$destination_tmp" "$destination"
}

record_gate_config() {
  local attempt
  local live_config_tmp="${last_gate_config}.tmp"
  if ! OMARCHY_SHELL_IPC_TIMEOUT=1s omarchy-shell shell listShellConfig \
      >"$live_config_tmp" 2>/dev/null \
      || ! jq -e 'type == "object"' "$live_config_tmp" >/dev/null; then
    rm -f -- "$live_config_tmp"
    return 1
  fi
  mv -f -- "$live_config_tmp" "$last_gate_config"
  for ((attempt = 0; attempt < 200; attempt++)); do
    config_owned_state_matches >/dev/null 2>&1 && return 0
    sleep 0.01
  done
  echo "accept_quattro_live: shell configuration did not persist the gate mutation" >&2
  return 1
}

config_owned_state_matches() {
  snapshot_shell_config "$current_config" || return 1
  bash "$config_restorer" --matches \
    "$last_gate_config" "$current_config" "$plugin_id" "$probe_id"
}

run_config_mutation() {
  local mutation_status=0
  config_owned_state_matches ||
    fail "acceptance-owned shell configuration changed concurrently"
  "$@" || mutation_status=$?
  record_gate_config || fail "could not record the last gate-produced configuration"
  return "$mutation_status"
}

checkout_owned_by_run() {
  local checkout_dir=$1
  local checkout_run_id=""
  [[ -f $checkout_dir/.acceptance-run-id ]] || return 1
  IFS= read -r checkout_run_id <"$checkout_dir/.acceptance-run-id" || return 1
  [[ $checkout_run_id == "$run_id" ]]
}

write_recovery_instructions() {
  local phase=$1
  local recovery_tmp="$recovery_file.tmp"
  {
    printf 'System Stats acceptance recovery\n'
    printf 'Status: %s\n\n' "$phase"
    printf 'Run ID: %s\n' "$run_id"
    printf 'Expected ownership marker contents: %s\n\n' "$run_id"
    printf 'Do not mutate plugins or shell configuration while the graphical session is locked.\n'
    printf 'After unlock, paste this complete block into one fresh Bash shell. The same\n'
    printf 'cleanup policy used by the live gate stops on any ownership or configuration\n'
    printf 'conflict and never installs the old snapshot:\n\n'
    printf '  set -euo pipefail\n'
    printf '  bash %q --acquire-lock %q\n\n' \
      "$recovery_cleanup" "$cleanup_manifest"
    printf 'If the block stops, preserve this bundle and inspect the reported conflict.\n'
    printf 'Never copy the full original snapshot over the live config; that would discard\n'
    printf 'concurrent unrelated edits.\n'
    printf 'Persistent helper-overlap witness: %s\n' "$helper_overlap_marker"
    printf 'Original config evidence: %s\n' "$config_backup"
    printf 'Original effective config: %s\n' "$original_effective_config"
    printf 'Last gate-produced config: %s\n' "$last_gate_config"
    printf 'Recovery bundle: %s\n' "$recovery_dir"
  } >"$recovery_tmp" || return 1
  mv -f -- "$recovery_tmp" "$recovery_file"
}

cleanup() {
  local status=$?
  local cleanup_failed=false
  trap - EXIT
  set +e

  if [[ -n $sleep_observer_pid ]] && kill -0 "$sleep_observer_pid" 2>/dev/null; then
    kill "$sleep_observer_pid" 2>/dev/null
    wait "$sleep_observer_pid" 2>/dev/null
  fi
  if [[ -n $sleep_inhibitor_pid ]] && kill -0 "$sleep_inhibitor_pid" 2>/dev/null; then
    kill "$sleep_inhibitor_pid" 2>/dev/null
    wait "$sleep_inhibitor_pid" 2>/dev/null
  fi

  if [[ $cleanup_mutations_safe != true ]] || ! session_is_unlocked; then
    write_recovery_instructions \
      "Cleanup deferred: complete resume and unlock were not confirmed" || true
    printf 'accept_quattro_live: cleanup deferred until confirmed unlock; recovery instructions: %s\n' \
      "$recovery_file" >&2
    (( status == 0 )) && status=1
    exit "$status"
  fi

  if [[ $config_snapshotted == true ]] \
      && ! bash "$recovery_cleanup" --lock-held "$cleanup_manifest" \
        {acceptance_lock_fd}>&-; then
    echo "accept_quattro_live: shared acceptance cleanup failed" >&2
    cleanup_failed=true
  fi
  if [[ $cleanup_failed == false && -n $recovery_dir \
      && $recovery_dir == "$state_root"/run.* && -d $recovery_dir ]]; then
    if ! rm -rf -- "$recovery_dir"; then
      echo "accept_quattro_live: cleanup could not remove $recovery_dir" >&2
      cleanup_failed=true
    fi
  fi
  if [[ $cleanup_failed == true ]]; then
    write_recovery_instructions "Cleanup incomplete" || true
    printf 'accept_quattro_live: cleanup incomplete; recovery bundle preserved at %s\n' \
      "$recovery_dir" >&2
    (( status == 0 )) && status=1
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

if [[ -f $shell_config ]]; then
  had_shell_config=true
fi
snapshot_shell_config "$config_backup"
if ! OMARCHY_SHELL_IPC_TIMEOUT=1s omarchy-shell shell listShellConfig \
    >"$original_effective_config.tmp" 2>/dev/null \
    || ! jq -e 'type == "object"' "$original_effective_config.tmp" \
      >/dev/null; then
  rm -f -- "$original_effective_config.tmp"
  fail "could not snapshot the original effective shell configuration"
fi
mv -f -- "$original_effective_config.tmp" "$original_effective_config"
cp -- "$config_backup" "$last_gate_config"
cp -- "$config_restorer" "$recovery_restorer"
cp -- "$helper_cleanup_verifier" "$recovery_helper_verifier"
cp -- "$acceptance_cleanup" "$recovery_cleanup"
cp -- "$session_unlock_verifier" "$recovery_session_unlock_verifier"
cp -- "$hyprland_instance_resolver" "$recovery_hyprland_instance_resolver"
chmod +x "$recovery_restorer" "$recovery_helper_verifier" \
  "$recovery_cleanup" "$recovery_session_unlock_verifier" \
  "$recovery_hyprland_instance_resolver"
jq -n \
  --arg runId "$run_id" \
  --arg lockFile "$state_root/acceptance.lock" \
  --arg shellConfig "$shell_config" \
  --arg lastGateConfig "$last_gate_config" \
  --arg originalEffectiveConfig "$original_effective_config" \
  --arg targetId "$plugin_id" \
  --arg targetDir "$plugin_dir" \
  --arg probeId "$probe_id" \
  --arg probeDir "$probe_dir" \
  --arg configRestorer "$recovery_restorer" \
  --arg helperVerifier "$recovery_helper_verifier" \
  --arg helperPath "$helper_path" \
  --arg overlapMarker "$helper_overlap_marker" \
  --arg sessionUnlockVerifier "$recovery_session_unlock_verifier" \
  --arg sessionUserId "$UID" \
  --argjson originalConfigExisted "$had_shell_config" '{
    version: 1,
    runId: $runId,
    lockFile: $lockFile,
    shellConfig: $shellConfig,
    lastGateConfig: $lastGateConfig,
    originalEffectiveConfig: $originalEffectiveConfig,
    originalConfigExisted: $originalConfigExisted,
    target: {id: $targetId, path: $targetDir},
    probe: {id: $probeId, path: $probeDir},
    configRestorer: $configRestorer,
    helperCleanupVerifier: $helperVerifier,
    helperPath: $helperPath,
    helperOverlapMarker: $overlapMarker,
    sessionUnlockVerifier: $sessionUnlockVerifier,
    sessionUserId: $sessionUserId
  }' >"$cleanup_manifest.tmp"
mv -f -- "$cleanup_manifest.tmp" "$cleanup_manifest"
config_snapshotted=true
write_recovery_instructions "Acceptance run active"

make -s -C "$repo_root" build
omarchy plugin validate "$repo_root"

mkdir -p "$stage_repo/bin"
printf '%s\n' "$run_id" >"$stage_repo/.acceptance-run-id"
cp -- "$repo_root/manifest.json" "$repo_root/Service.qml" \
  "$repo_root/BarWidget.qml" "$repo_root/LICENSE" "$repo_root/README.md" \
  "$stage_repo/"
cp -- "$repo_root/bin/system-stats-helper" \
  "$stage_repo/bin/system-stats-helper.real"
cp -- "$repo_root/tests/helpers/quattro_helper_guard.sh" \
  "$stage_repo/bin/system-stats-helper"
mkdir -p "$helper_state_dir"
printf '%s\n' "$helper_state_dir" \
  >"$stage_repo/bin/.acceptance-state-dir"
chmod +x "$stage_repo/bin/system-stats-helper"
git -C "$stage_repo" init -q
git -C "$stage_repo" config user.name "System Stats Acceptance"
git -C "$stage_repo" config user.email "acceptance@invalid"
git -C "$stage_repo" add .
git -C "$stage_repo" commit -qm "temporary Quattro acceptance package"

mkdir -p "$stage_probe"
printf '%s\n' "$run_id" >"$stage_probe/.acceptance-run-id"
probe_entry="runs/${BASHPID}/Service.qml"
jq --arg entry "$probe_entry" '.entryPoints.service = $entry' \
  "$repo_root/tests/fixtures/quattro-acceptance-probe.manifest.json" \
  >"$stage_probe/manifest.json"
mkdir -p "$stage_probe/runs/${BASHPID}"
cp -- "$repo_root/tests/qml/QuattroAcceptanceProbe.qml" \
  "$stage_probe/$probe_entry"
git -C "$stage_probe" init -q
git -C "$stage_probe" config user.name "System Stats Acceptance"
git -C "$stage_probe" config user.email "acceptance@invalid"
git -C "$stage_probe" add .
git -C "$stage_probe" commit -qm "temporary Quattro acceptance probe"
omarchy plugin validate "$stage_probe"

helper_pids=()
collect_helper_pids() {
  [[ ! -e $helper_overlap_marker ]] ||
    fail "the helper guard recorded concurrent helper launches"
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
  OMARCHY_SHELL_IPC_TIMEOUT=1s omarchy-shell "$probe_id" state 2>/dev/null ||
    printf '{}'
}

shared_live_state_matches() {
  local state=$1
  jq -e --argjson widgetCount "$monitor_count" '
    .widgetCount == $widgetCount
    and .serviceSlotCount == 1
    and .targetServiceInstanceCount == 1
    and .unregisteredServiceCount == 0
    and .serviceRegistryConsistent == true
    and .allWidgetsUseHostService == true
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

omarchy_shell_identity() {
  local shell_pid stat_line start_ticks
  local shell_pids=()
  mapfile -t shell_pids < <(
    pgrep -f '^quickshell -n -p /usr/share/omarchy/shell$' || true
  )
  (( ${#shell_pids[@]} == 1 )) || return 1
  shell_pid=${shell_pids[0]}
  [[ -r /proc/$shell_pid/stat ]] || return 1
  IFS= read -r stat_line <"/proc/$shell_pid/stat" || return 1
  start_ticks=$(awk '{print $22}' <<<"$stat_line")
  [[ $start_ticks =~ ^[0-9]+$ ]] || return 1
  printf '%s:%s\n' "$shell_pid" "$start_ticks"
}

wait_for_unlocked() {
  local attempt
  for ((attempt = 0; attempt < 200; attempt++)); do
    session_is_unlocked && return 0
    sleep 0.05
  done
  fail "the login session did not report a completed unlock"
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
      | .configuredIntervalSeconds == 3
        and .ramDisplayFormat == "gib"] | all)
  ' <<<"$state" >/dev/null
}

assert_persisted_settings() {
  local entries state
  entries=$(entry_state)
  state=$(acceptance_state)
  persisted_settings_match "$entries" && live_widget_settings_match "$state" ||
    fail "the inline or per-screen settings changed or split"
}

wait_for_persisted_entry_settings() {
  local attempt entries
  for ((attempt = 0; attempt < 100; attempt++)); do
    entries=$(entry_state)
    persisted_settings_match "$entries" && return 0
    sleep 0.05
  done
  fail "the inline settings were not persisted: entries=$(entry_state)"
}

wait_for_live_widget_settings() {
  local attempt state
  for ((attempt = 0; attempt < 100; attempt++)); do
    state=$(acceptance_state)
    live_widget_settings_match "$state" && return 0
    sleep 0.05
  done
  fail "the persisted settings were not injected after reload: widgets=$(acceptance_state)"
}

recreate_widget_slots_from_persisted_settings() {
  run_config_mutation omarchy bar move "$plugin_id" --section center >/dev/null
  wait_for_live center
  wait_for_live_widget_settings
  assert_persisted_settings
  run_config_mutation omarchy bar move "$plugin_id" --section right >/dev/null
  wait_for_live right
  wait_for_live_widget_settings
  assert_persisted_settings
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
  wait_for_persisted_entry_settings
  wait_for_live_widget_settings
  assert_helper_shape
  assert_persisted_settings
}

establish_suspend_reload_barrier() {
  local previous_shell_id current_shell_id attempt
  session_is_unlocked ||
    fail "the login session must be unlocked before replacing the Omarchy shell"
  previous_shell_id=$(omarchy_shell_identity) ||
    fail "could not identify exactly one Omarchy shell before restart"

  omarchy-restart-shell || fail "could not restart the Omarchy shell before suspend"
  current_shell_id=""
  for ((attempt = 0; attempt < 200; attempt++)); do
    current_shell_id=$(omarchy_shell_identity 2>/dev/null || true)
    [[ -n $current_shell_id && $current_shell_id != "$previous_shell_id" ]] && break
    sleep 0.05
  done
  [[ -n $current_shell_id && $current_shell_id != "$previous_shell_id" ]] ||
    fail "the Omarchy shell was not replaced before suspend"

  verify_resumed_runtime
  wait_for_shared_sequence_progress
  config_owned_state_matches ||
    fail "acceptance-owned configuration changed during the shell restart"
  current_shell_id=$(omarchy_shell_identity) ||
    fail "could not identify exactly one replacement Omarchy shell"
  [[ $current_shell_id != "$previous_shell_id" ]] ||
    fail "the original Omarchy shell returned before the suspend barrier"

  bash "$suspend_barrier" --arm "$suspend_barrier_state" \
    "$previous_shell_id" "$current_shell_id" \
    "$plugin_dir" "$probe_dir" "$shell_config" ||
    fail "could not arm the post-reload suspend barrier"
  printf 'PASS: replacement shell cleared pending plugin reloads before suspend\n'
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
  local event_log ready_file inhibitor_ready_file attempt suspended_ns
  local suspend_status
  event_log="$test_dir/logind-$label.jsonl"
  ready_file="$test_dir/logind-$label.ready"
  inhibitor_ready_file="$test_dir/logind-$label.inhibitor-ready"
  bash "$repo_root/tests/helpers/observe_logind_sleep_cycle.sh" \
    "$event_log" "$ready_file" {acceptance_lock_fd}>&- &
  sleep_observer_pid=$!
  for ((attempt = 0; attempt < 100; attempt++)); do
    [[ -e $ready_file ]] && break
    kill -0 "$sleep_observer_pid" 2>/dev/null ||
      fail "$label could not start the logind sleep observer"
    sleep 0.01
  done
  [[ -e $ready_file ]] || fail "$label logind sleep observer was not ready"

  systemd-inhibit --what=sleep --mode=delay \
    --who="System Stats acceptance" \
    --why="Record the pre-suspend monotonic clocks" \
    bash "$repo_root/tests/helpers/hold_sleep_delay_until_observed.sh" \
      "$event_log" "$inhibitor_ready_file" {acceptance_lock_fd}>&- &
  sleep_inhibitor_pid=$!
  for ((attempt = 0; attempt < 100; attempt++)); do
    [[ -e $inhibitor_ready_file ]] && break
    kill -0 "$sleep_inhibitor_pid" 2>/dev/null ||
      fail "$label could not acquire the logind sleep delay inhibitor"
    sleep 0.01
  done
  [[ -e $inhibitor_ready_file ]] ||
    fail "$label logind sleep delay inhibitor was not ready"

  cleanup_mutations_safe=false
  suspend_status=0
  bash "$suspend_barrier" --run "$suspend_barrier_state" \
    "$plugin_dir" "$probe_dir" "$shell_config" \
    -- systemctl suspend || suspend_status=$?
  if (( suspend_status != 0 )); then
    if (( suspend_status == 75 )); then
      cleanup_mutations_safe=true
      fail "$label refused suspend because the post-reload runtime changed"
    fi
    fail "$label systemctl suspend failed with status $suspend_status"
  fi
  printf '%s: once the system has resumed and this terminal is usable, press Enter to continue.\n' \
    "$label"
  read -r

  wait "$sleep_inhibitor_pid" || {
    sleep_inhibitor_pid=""
    fail "$label did not record the pre-suspend clock sample"
  }
  sleep_inhibitor_pid=""

  for ((attempt = 0; attempt < 200; attempt++)); do
    kill -0 "$sleep_observer_pid" 2>/dev/null || break
    sleep 0.05
  done
  if kill -0 "$sleep_observer_pid" 2>/dev/null; then
    kill "$sleep_observer_pid" 2>/dev/null || true
    wait "$sleep_observer_pid" 2>/dev/null || true
    sleep_observer_pid=""
    fail "$label did not produce a complete logind PrepareForSleep cycle"
  fi
  wait "$sleep_observer_pid" || {
    sleep_observer_pid=""
    fail "$label logind sleep observer failed"
  }
  sleep_observer_pid=""
  suspended_ns=$(bash "$repo_root/tests/helpers/verify_logind_sleep_cycle.sh" \
    "$event_log" "$minimum_seconds") ||
    fail "$label did not spend at least ${minimum_seconds}s actually suspended"
  wait_for_unlocked
  cleanup_mutations_safe=true
  verify_resumed_runtime
  printf 'PASS: %s system suspend (%.3fs asleep) leaves one helper\n' \
    "$label" "$(awk -v ns="$suspended_ns" 'BEGIN { print ns / 1000000000 }')"
}

# Exercise both shipped entry points before installing the temporary live copy.
bash "$repo_root/tests/test_widget.sh" >/dev/null
printf 'PASS: two-screen entry-point integration contract\n'

if ! run_config_mutation omarchy plugin add "file://$stage_probe" --enable --yes; then
  fail "could not install the acceptance probe"
fi
checkout_owned_by_run "$probe_dir" ||
  fail "the installed acceptance probe is not owned by this run"
if ! run_config_mutation omarchy plugin add "file://$stage_repo" --enable --yes; then
  fail "could not install the temporary System Stats checkout"
fi
checkout_owned_by_run "$plugin_dir" ||
  fail "the installed System Stats checkout is not owned by this run"
wait_for_live right
assert_helper_shape
printf 'PASS: default activation creates %s widgets and one helper on the right\n' \
  "$monitor_count"

run_config_mutation omarchy bar set "$plugin_id" intervalSeconds 3 --json >/dev/null
run_config_mutation omarchy bar set "$plugin_id" ramDisplayFormat gib >/dev/null
wait_for_persisted_entry_settings
recreate_widget_slots_from_persisted_settings

old_helper=${helper_pids[0]}
touch "$plugin_dir/Service.qml"
new_helper=""
for ((attempt = 0; attempt < 400; attempt++)); do
  collect_helper_pids
  if [[ ${#helper_pids[@]} -eq 1 && ${helper_pids[0]} != "$old_helper" ]]; then
    new_helper=${helper_pids[0]}
    break
  fi
  sleep 0.02
done
[[ -n $new_helper ]] || fail "plugin reload did not replace the helper"
wait_for_live right
wait_for_live_widget_settings
assert_persisted_settings
printf 'PASS: plugin reload peaks at one helper\n'
wait_for_shared_sequence_progress
printf 'PASS: real screen widgets advance one shared sequence and persisted settings\n'

pause_runtime "short" 1
pause_runtime "long" 6
if [[ $real_suspend == true ]]; then
  establish_suspend_reload_barrier
  real_suspend_cycle "short" 1
  real_suspend_cycle "long" 30
fi

for section in center left right; do
  run_config_mutation omarchy bar move "$plugin_id" --section "$section" >/dev/null
  wait_for_live "$section"
  assert_helper_shape
  assert_persisted_settings
done
printf 'PASS: normal bar moves cover left, center, and right\n'

run_config_mutation omarchy plugin disable "$plugin_id" >/dev/null
wait_for_unloaded
printf 'PASS: deactivation leaves no widget or helper\n'

for section in left center right; do
  run_config_mutation omarchy plugin enable "$plugin_id" --section "$section" >/dev/null
  wait_for_live "$section"
  assert_helper_shape
  run_config_mutation omarchy plugin disable "$plugin_id" >/dev/null
  wait_for_unloaded
done
printf 'PASS: explicit activation covers left, center, and right\n'

run_config_mutation omarchy plugin enable "$plugin_id" >/dev/null
wait_for_live right
checkout_owned_by_run "$plugin_dir" ||
  fail "the temporary System Stats checkout changed ownership"
run_config_mutation omarchy plugin remove "$plugin_id" --yes >/dev/null
wait_for_unloaded
[[ ! -e $plugin_dir ]] || fail "plugin removal left its checkout behind"
printf 'PASS: removal leaves no checkout, widget, or helper\n'

checkout_owned_by_run "$probe_dir" ||
  fail "the acceptance probe checkout changed ownership"
run_config_mutation omarchy plugin remove "$probe_id" --yes >/dev/null
[[ ! -e $probe_dir ]] || fail "acceptance probe removal left its checkout behind"

if [[ $real_suspend == true ]]; then
  printf 'PASS: Quattro %s full live acceptance on %s screens\n' \
    "$target_omarchy_version" "$monitor_count"
else
  printf 'PASS: Quattro %s live preflight on %s screens\n' \
    "$target_omarchy_version" "$monitor_count"
  printf 'INCOMPLETE: run again with --real-suspend for release acceptance\n'
fi
