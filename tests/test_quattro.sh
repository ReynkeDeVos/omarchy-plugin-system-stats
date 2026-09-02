#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
plugin_id="reynkedevos.system-stats"
compatibility_doc="$repo_root/docs/quattro-compatibility.md"
live_gate="$repo_root/tests/accept_quattro_live.sh"
acceptance_probe="$repo_root/tests/qml/QuattroAcceptanceProbe.qml"
sleep_verifier="$repo_root/tests/helpers/verify_logind_sleep_cycle.sh"
sleep_observer="$repo_root/tests/helpers/observe_logind_sleep_cycle.sh"
sleep_delay_holder="$repo_root/tests/helpers/hold_sleep_delay_until_observed.sh"
helper_guard="$repo_root/tests/helpers/quattro_helper_guard.sh"
config_restorer="$repo_root/tests/helpers/restore_quattro_shell_config.sh"
helper_cleanup_verifier="$repo_root/tests/helpers/verify_quattro_helper_cleanup.sh"
suspend_barrier="$repo_root/tests/helpers/run_quattro_suspend_if_ready.sh"
acceptance_cleanup="$repo_root/tests/helpers/cleanup_quattro_acceptance.sh"
session_unlock_verifier="$repo_root/tests/helpers/verify_quattro_session_unlocked.sh"
hyprland_instance_resolver="$repo_root/tests/helpers/resolve_quattro_hyprland_instance.sh"
test_dir=$(mktemp -d)
guard_pids=()
background_pids=()

cleanup() {
  local pid
  for pid in "${guard_pids[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  for pid in "${background_pids[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  [[ -n ${test_dir:-} && $test_dir != "/" && -d $test_dir ]] && rm -rf -- "$test_dir"
}
trap cleanup EXIT

jq -e '.barWidget.defaultSection == "right"' "$repo_root/manifest.json" >/dev/null

if rg -n 'acceptanceState|reynkedevos\.system-stats-acceptance' \
    "$repo_root/Service.qml" "$repo_root/BarWidget.qml"; then
  echo "acceptance instrumentation must stay outside production QML" >&2
  exit 1
fi
grep -Fq 'target: "reynkedevos.system-stats-acceptance"' "$acceptance_probe"
grep -Fq 'import Quickshell.Io' "$acceptance_probe"
grep -Fq 'function probeState()' "$acceptance_probe"
if grep -Fq 'function state() {' "$acceptance_probe"; then
  echo "the probe must not shadow QQuickItem.state" >&2
  exit 1
fi
grep -Fq 'serviceSlotCount: serviceSlots' "$acceptance_probe"
grep -Fq 'allWidgetsUseHostService: allWidgetsUseHostService' "$acceptance_probe"
grep -Fq 'targetServiceInstanceCount: targetServiceInstanceCount' "$acceptance_probe"
grep -Fq 'unregisteredServiceCount: unregisteredServiceCount' "$acceptance_probe"
grep -Fq 'serviceRegistryConsistent: serviceRegistryConsistent' "$acceptance_probe"
grep -Fq 'configuredIntervalSeconds: configuredIntervalSeconds' "$acceptance_probe"
grep -Fq 'ramDisplayFormat: ramDisplayFormat' "$acceptance_probe"
grep -Fq '.configuredIntervalSeconds == 3' "$live_gate"
grep -Fq '.ramDisplayFormat == "gib"' "$live_gate"
grep -Fq 'QuattroAcceptanceProbe.qml' "$live_gate"
grep -Fq 'serviceSlotCount == 1' "$live_gate"
grep -Fq 'allWidgetsUseHostService == true' "$live_gate"
grep -Fq 'targetServiceInstanceCount == 1' "$live_gate"
grep -Fq 'unregisteredServiceCount == 0' "$live_gate"
grep -Fq 'serviceRegistryConsistent == true' "$live_gate"
grep -Fq 'state_home="${XDG_STATE_HOME:-$HOME/.local/state}"' "$live_gate"
grep -Fq 'state_root="$state_home/omarchy-system-stats/acceptance"' "$live_gate"
grep -Fq 'exec {acceptance_lock_fd}>"$state_root/acceptance.lock"' "$live_gate"
grep -Fq 'flock --exclusive --nonblock "$acceptance_lock_fd"' "$live_gate"
[[ $(grep -Fc '{acceptance_lock_fd}>&- &' "$live_gate") -eq 2 ]] || {
  echo "every asynchronous acceptance child must close the gate lock descriptor" >&2
  exit 1
}
if rg -n 'SYSTEM_STATS_ACCEPTANCE_LOCK_HELD|--close' "$live_gate"; then
  echo "the acceptance lock must remain held by the cleanup process" >&2
  exit 1
fi
grep -Fq 'recovery_dir=$(mktemp -d "$state_root/run.XXXXXXXX")' "$live_gate"
grep -Fq 'helper_state_dir="$recovery_dir/helper-guard"' "$live_gate"
grep -Fq 'helper_overlap_marker="$helper_state_dir/overlap"' "$live_gate"
grep -Fq 'config_backup="$recovery_dir/shell.json"' "$live_gate"
grep -Fq 'last_gate_config="$recovery_dir/last-gate-shell.json"' "$live_gate"
grep -Fq 'recovery_file="$recovery_dir/RECOVERY.txt"' "$live_gate"
grep -Fq 'write_recovery_instructions "Acceptance run active"' "$live_gate"
grep -Fq '.acceptance-run-id' "$live_gate"
grep -Fq 'checkout_owned_by_run' "$live_gate"
grep -Fq 'config_owned_state_matches' "$live_gate"
grep -Fq 'run_config_mutation omarchy plugin add' "$live_gate"
grep -Fq 'run_config_mutation omarchy bar move' "$live_gate"
grep -Fq 'bash "$config_restorer" --restore' "$acceptance_cleanup"
grep -Fq 'bash "$helper_cleanup_verifier"' "$acceptance_cleanup"
grep -Fq 'shared acceptance cleanup failed' "$live_gate"
if grep -Fq 'cp -- "$config_backup" "$shell_config"' "$live_gate"; then
  echo "cleanup must not overwrite concurrent shell configuration changes" >&2
  exit 1
fi
grep -Fq '.acceptance-state-dir' "$helper_guard"

record_fixture="$test_dir/record-gate-config"
mkdir -p "$record_fixture/bin"
jq -n --arg target "$plugin_id" '{
  version: 1,
  plugins: [{id: $target}],
  bar: {layout: {left: [], center: [], right: [{id: $target}]}}
}' >"$record_fixture/old.json"
jq --arg target "$plugin_id" '
  .bar.layout.right[0].intervalSeconds = 3
' "$record_fixture/old.json" >"$record_fixture/new.json"
cp -- "$record_fixture/old.json" "$record_fixture/shell.json"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '[[ $* == "shell listShellConfig" ]] || exit 2' \
  'exec cp -- "$RECORD_GATE_NEW_CONFIG" /dev/stdout' \
  >"$record_fixture/bin/omarchy-shell"
chmod +x "$record_fixture/bin/omarchy-shell"
snapshot_function=$(sed -n '/^snapshot_shell_config()/,/^}$/p' "$live_gate")
record_function=$(sed -n '/^record_gate_config()/,/^}$/p' "$live_gate")
matches_function=$(sed -n '/^config_owned_state_matches()/,/^}$/p' "$live_gate")
SNAPSHOT_FUNCTION="$snapshot_function" RECORD_FUNCTION="$record_function" \
  MATCHES_FUNCTION="$matches_function" \
  RECORD_GATE_NEW_CONFIG="$record_fixture/new.json" \
  PATH="$record_fixture/bin:$PATH" bash -c '
    set -euo pipefail
    eval "$SNAPSHOT_FUNCTION"
    eval "$RECORD_FUNCTION"
    eval "$MATCHES_FUNCTION"
    shell_config="$1/shell.json"
    last_gate_config="$1/last-gate.json"
    current_config="$1/current.json"
    config_restorer="$2"
    plugin_id="$3"
    probe_id="reynkedevos.system-stats-acceptance"
    (sleep 0.05; cp -- "$1/new.json" "$shell_config") &
    delayed_writer=$!
    record_gate_config
    wait "$delayed_writer"
    jq -e ".bar.layout.right[0].intervalSeconds == 3" \
      "$last_gate_config" >/dev/null
    config_owned_state_matches
  ' _ "$record_fixture" "$config_restorer" "$plugin_id"

lock_state_home="$test_dir/lock-state"
lock_file="$lock_state_home/omarchy-system-stats/acceptance/acceptance.lock"
mkdir -p "$(dirname -- "$lock_file")"
flock "$lock_file" sleep 5 &
background_pids+=("$!")
lock_ready=false
for ((attempt = 0; attempt < 100; attempt++)); do
  if ! flock --nonblock "$lock_file" true; then
    lock_ready=true
    break
  fi
  sleep 0.01
done
[[ $lock_ready == true ]] || {
  echo "the acceptance test could not acquire its fixture lock" >&2
  exit 1
}
lock_output=""
lock_status=0
lock_output=$(XDG_STATE_HOME="$lock_state_home" bash "$live_gate" 2>&1) ||
  lock_status=$?
[[ $lock_status -eq 75 ]] || {
  echo "a concurrent acceptance run must fail with the lock conflict status" >&2
  exit 1
}
grep -Fq 'another acceptance run is active' <<<"$lock_output"
kill "${background_pids[-1]}" 2>/dev/null || true
wait "${background_pids[-1]}" 2>/dev/null || true
background_pids=()

signal_lock="$test_dir/signal-cleanup.lock"
signal_ready="$test_dir/signal-cleanup.ready"
cleanup_ready="$test_dir/signal-cleanup.active"
bash -c '
  set -eu
  exec {lock_fd}>"$1"
  flock --exclusive --nonblock "$lock_fd"
  trap '\''touch "$3"; sleep 0.3; exit 143'\'' TERM
  touch "$2"
  while :; do sleep 0.05; done
' _ "$signal_lock" "$signal_ready" "$cleanup_ready" &
signal_lock_pid=$!
background_pids+=("$signal_lock_pid")
for ((attempt = 0; attempt < 100; attempt++)); do
  [[ -e $signal_ready ]] && break
  sleep 0.01
done
[[ -e $signal_ready ]] || {
  echo "the signal-cleanup lock fixture did not become ready" >&2
  exit 1
}
kill -TERM "$signal_lock_pid"
for ((attempt = 0; attempt < 100; attempt++)); do
  [[ -e $cleanup_ready ]] && break
  sleep 0.01
done
[[ -e $cleanup_ready ]] || {
  echo "the signal-cleanup lock fixture did not enter cleanup" >&2
  exit 1
}
if flock --nonblock "$signal_lock" true; then
  echo "the acceptance lock must stay held throughout signal cleanup" >&2
  exit 1
fi
signal_status=0
wait "$signal_lock_pid" || signal_status=$?
[[ $signal_status -eq 143 ]] || {
  echo "the signal-cleanup lock fixture returned $signal_status" >&2
  exit 1
}
background_pids=()
flock --nonblock "$signal_lock" true || {
  echo "the acceptance lock must be released after cleanup exits" >&2
  exit 1
}

orphan_lock="$test_dir/orphan-child.lock"
orphan_ready="$test_dir/orphan-child.ready"
orphan_pid_file="$test_dir/orphan-child.pid"
bash -c '
  set -eu
  exec {lock_fd}>"$1"
  flock --exclusive --nonblock "$lock_fd"
  sleep 5 {lock_fd}>&- &
  printf "%s\n" "$!" >"$3"
  touch "$2"
  wait
' _ "$orphan_lock" "$orphan_ready" "$orphan_pid_file" &
orphan_owner_pid=$!
background_pids+=("$orphan_owner_pid")
for ((attempt = 0; attempt < 100; attempt++)); do
  [[ -e $orphan_ready ]] && break
  sleep 0.01
done
[[ -e $orphan_ready ]] || {
  echo "the orphan-child lock fixture did not become ready" >&2
  exit 1
}
IFS= read -r orphan_child_pid <"$orphan_pid_file"
background_pids+=("$orphan_child_pid")
kill -KILL "$orphan_owner_pid"
wait "$orphan_owner_pid" 2>/dev/null || true
kill -0 "$orphan_child_pid"
flock --nonblock "$orphan_lock" true || {
  echo "an asynchronous child must not inherit the acceptance lock" >&2
  exit 1
}
kill "$orphan_child_pid" 2>/dev/null || true
wait "$orphan_child_pid" 2>/dev/null || true
background_pids=()

target_id="reynkedevos.system-stats"
probe_id="reynkedevos.system-stats-acceptance"
original_config="$test_dir/config-original.json"
last_gate_config="$test_dir/config-last-gate.json"
concurrent_config="$test_dir/config-concurrent.json"
restored_config="$test_dir/config-restored.json"
conflicting_config="$test_dir/config-conflicting.json"
jq -n '{
  theme: "before",
  plugins: [{id: "example.keep", enabled: true}],
  bar: {layout: {
    left: [{id: "example.left"}],
    center: [],
    right: [{id: "example.clock", format: "short"}]
  }}
}' >"$original_config"
jq --arg target "$target_id" --arg probe "$probe_id" '
  .plugins += [{id: $target, enabled: true}, {id: $probe, enabled: true}]
  | .bar.layout.right += [{id: $target, intervalSeconds: 3}]
' "$original_config" >"$last_gate_config"
jq --arg target "$target_id" --arg probe "$probe_id" '
  .theme = "changed while acceptance ran"
  | .plugins = [
      {id: "example.keep", enabled: true},
      {id: $target, enabled: true},
      {id: $probe, enabled: true},
      {id: "example.added", enabled: true}
    ]
  | .bar.layout.left += [{id: "example.added-widget"}]
  | .bar.layout.right = [
      {id: "example.clock", format: "long"},
      {id: $target, intervalSeconds: 3}
    ]
' "$original_config" >"$concurrent_config"

bash "$config_restorer" --assert-clean \
  "$original_config" "$target_id" "$probe_id"
if bash "$config_restorer" --assert-clean \
    "$last_gate_config" "$target_id" "$probe_id" >/dev/null 2>&1; then
  echo "a baseline containing acceptance-owned entries must be rejected" >&2
  exit 1
fi
bash "$config_restorer" --restore \
  "$last_gate_config" "$concurrent_config" "$restored_config" \
  "$target_id" "$probe_id"
jq -e --arg target "$target_id" --arg probe "$probe_id" '
  .theme == "changed while acceptance ran"
  and .plugins == [
    {id: "example.keep", enabled: true},
    {id: "example.added", enabled: true}
  ]
  and .bar.layout.left == [
    {id: "example.left"},
    {id: "example.added-widget"}
  ]
  and .bar.layout.right == [{id: "example.clock", format: "long"}]
  and ([.. | objects | .id? | select(. == $target or . == $probe)] | length) == 0
' "$restored_config" >/dev/null

jq --arg target "$target_id" '
  .bar.layout.right |= map(
    if .id == $target then .intervalSeconds = 9 else . end
  )
' "$concurrent_config" >"$conflicting_config"
if bash "$config_restorer" --restore \
    "$last_gate_config" "$conflicting_config" "$test_dir/must-not-exist.json" \
    "$target_id" "$probe_id" >/dev/null 2>&1; then
  echo "concurrent changes to acceptance-owned entries must block restoration" >&2
  exit 1
fi
[[ ! -e $test_dir/must-not-exist.json ]] || {
  echo "a conflicted restoration must not produce replacement config" >&2
  exit 1
}

tty_unlock_fixture="$test_dir/tty-unlock"
mkdir -p "$tty_unlock_fixture/bin"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [[ $1 == show-user && $4 == Display ]]; then printf "7\n"; exit; fi' \
  '[[ $1 == show-session && $2 == 7 && $3 == -p ]] || exit 2' \
  'case $4 in' \
  '  Type) printf "wayland\n" ;;' \
  '  Active) printf "yes\n" ;;' \
  '  LockedHint) printf "no\n" ;;' \
  '  *) exit 2 ;;' \
  'esac' \
  >"$tty_unlock_fixture/bin/loginctl"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [[ $1 == instances && $2 == -j ]]; then' \
  '  printf '\''[{"instance":"fixture-hyprland","wl_socket":"wayland-1"}]\n'\''' \
  'elif [[ $1 == monitors && $2 == -j' \
  '    && ${HYPRLAND_INSTANCE_SIGNATURE:-} == fixture-hyprland ]]; then' \
  '  printf "[]\n"' \
  'else' \
  '  exit 2' \
  'fi' \
  >"$tty_unlock_fixture/bin/hyprctl"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '[[ ${HYPRLAND_INSTANCE_SIGNATURE:-} == fixture-hyprland ]] || exit 2' \
  'exit 1' \
  >"$tty_unlock_fixture/bin/omarchy-hyprland-session-locked"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '[[ $* == "lock status" ]] || exit 2' \
  'printf '\''{"locked":false,"requested":false,"pending":false,'\
  '"sessionLocked":false,"secure":false}\n'\''' \
  >"$tty_unlock_fixture/bin/omarchy-shell"
chmod +x "$tty_unlock_fixture/bin/"*
env -u HYPRLAND_INSTANCE_SIGNATURE -u WAYLAND_DISPLAY \
  PATH="$tty_unlock_fixture/bin:$PATH" \
  bash "$session_unlock_verifier" 1000

cleanup_fixture="$test_dir/shared-cleanup"
mkdir -p "$cleanup_fixture/bin" "$cleanup_fixture/target" \
  "$cleanup_fixture/probe"
printf 'run.fixture\n' >"$cleanup_fixture/target/.acceptance-run-id"
printf 'run.fixture\n' >"$cleanup_fixture/probe/.acceptance-run-id"
cp -- "$concurrent_config" "$cleanup_fixture/shell.json"
cp -- "$last_gate_config" "$cleanup_fixture/last-gate.json"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  '[[ $1 == plugin && $2 == remove && $4 == --yes ]] || exit 2' \
  'id=$3' \
  'printf "%s\n" "$id" >>"$CLEANUP_REMOVE_LOG"' \
  'case $id in' \
  '  "$CLEANUP_TARGET_ID") checkout=$CLEANUP_TARGET_DIR ;;' \
  '  "$CLEANUP_PROBE_ID") checkout=$CLEANUP_PROBE_DIR ;;' \
  '  *) exit 2 ;;' \
  'esac' \
  'rm -rf -- "$checkout"' \
  '[[ -f $CLEANUP_SHELL_CONFIG ]] || exit 0' \
  'jq --arg id "$id" '\''
    .plugins |= map(select((if type == "string" then . else (.id? // "") end) != $id))
    | .bar.layout |= with_entries(
        .value |= map(select((type != "object") or ((.id? // "") != $id)))
      )
  '\'' "$CLEANUP_SHELL_CONFIG" >"$CLEANUP_SHELL_CONFIG.tmp"' \
  'mv -f -- "$CLEANUP_SHELL_CONFIG.tmp" "$CLEANUP_SHELL_CONFIG"' \
  >"$cleanup_fixture/bin/omarchy"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\n" "$*" >>"$CLEANUP_RELOAD_LOG"' \
  >"$cleanup_fixture/bin/omarchy-shell"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '[[ ${CLEANUP_UNLOCKED:-false} == true ]]' \
  >"$cleanup_fixture/bin/session-unlocked"
chmod +x "$cleanup_fixture/bin/omarchy" \
  "$cleanup_fixture/bin/omarchy-shell" \
  "$cleanup_fixture/bin/session-unlocked"
jq -n \
  --arg runId 'run.fixture' \
  --arg lockFile "$cleanup_fixture/acceptance.lock" \
  --arg shellConfig "$cleanup_fixture/shell.json" \
  --arg lastGateConfig "$cleanup_fixture/last-gate.json" \
  --arg originalEffectiveConfig "$original_config" \
  --arg targetId "$target_id" \
  --arg targetDir "$cleanup_fixture/target" \
  --arg probeId "$probe_id" \
  --arg probeDir "$cleanup_fixture/probe" \
  --arg configRestorer "$config_restorer" \
  --arg helperVerifier "$helper_cleanup_verifier" \
  --arg helperPath "$cleanup_fixture/target/bin/system-stats-helper" \
  --arg overlapMarker "$cleanup_fixture/helper-overlap" \
  --arg sessionUnlockVerifier "$cleanup_fixture/bin/session-unlocked" '{
    version: 1,
    runId: $runId,
    lockFile: $lockFile,
    shellConfig: $shellConfig,
    lastGateConfig: $lastGateConfig,
    originalEffectiveConfig: $originalEffectiveConfig,
    originalConfigExisted: true,
    target: {id: $targetId, path: $targetDir},
    probe: {id: $probeId, path: $probeDir},
    configRestorer: $configRestorer,
    helperCleanupVerifier: $helperVerifier,
    helperPath: $helperPath,
    helperOverlapMarker: $overlapMarker,
    sessionUnlockVerifier: $sessionUnlockVerifier,
    sessionUserId: "1000"
  }' >"$cleanup_fixture/manifest.json"

locked_cleanup_fixture="$cleanup_fixture/locked"
mkdir -p "$locked_cleanup_fixture/target" "$locked_cleanup_fixture/probe"
printf 'run.fixture\n' >"$locked_cleanup_fixture/target/.acceptance-run-id"
printf 'run.fixture\n' >"$locked_cleanup_fixture/probe/.acceptance-run-id"
cp -- "$concurrent_config" "$locked_cleanup_fixture/shell.json"
cp -- "$last_gate_config" "$locked_cleanup_fixture/last-gate.json"
jq --arg root "$locked_cleanup_fixture" \
  '.lockFile = ($root + "/acceptance.lock")
   | .shellConfig = ($root + "/shell.json")
   | .lastGateConfig = ($root + "/last-gate.json")
   | .target.path = ($root + "/target")
   | .probe.path = ($root + "/probe")
   | .helperPath = ($root + "/target/bin/system-stats-helper")
   | .helperOverlapMarker = ($root + "/helper-overlap")' \
  "$cleanup_fixture/manifest.json" >"$locked_cleanup_fixture/manifest.json"
: >"$locked_cleanup_fixture/remove.log"
: >"$locked_cleanup_fixture/reload.log"
if PATH="$cleanup_fixture/bin:$PATH" \
    CLEANUP_UNLOCKED=false \
    CLEANUP_REMOVE_LOG="$locked_cleanup_fixture/remove.log" \
    CLEANUP_RELOAD_LOG="$locked_cleanup_fixture/reload.log" \
    CLEANUP_TARGET_ID="$target_id" \
    CLEANUP_TARGET_DIR="$locked_cleanup_fixture/target" \
    CLEANUP_PROBE_ID="$probe_id" \
    CLEANUP_PROBE_DIR="$locked_cleanup_fixture/probe" \
    CLEANUP_SHELL_CONFIG="$locked_cleanup_fixture/shell.json" \
    bash "$acceptance_cleanup" --acquire-lock \
      "$locked_cleanup_fixture/manifest.json" >/dev/null 2>&1; then
  echo "TTY cleanup must refuse to mutate while the session is locked" >&2
  exit 1
fi
[[ -e $locked_cleanup_fixture/target && -e $locked_cleanup_fixture/probe ]]
[[ ! -s $locked_cleanup_fixture/remove.log ]]

: >"$cleanup_fixture/remove.log"
: >"$cleanup_fixture/reload.log"
PATH="$cleanup_fixture/bin:$PATH" \
  CLEANUP_UNLOCKED=true \
  CLEANUP_REMOVE_LOG="$cleanup_fixture/remove.log" \
  CLEANUP_RELOAD_LOG="$cleanup_fixture/reload.log" \
  CLEANUP_TARGET_ID="$target_id" \
  CLEANUP_TARGET_DIR="$cleanup_fixture/target" \
  CLEANUP_PROBE_ID="$probe_id" \
  CLEANUP_PROBE_DIR="$cleanup_fixture/probe" \
  CLEANUP_SHELL_CONFIG="$cleanup_fixture/shell.json" \
  bash "$acceptance_cleanup" --acquire-lock "$cleanup_fixture/manifest.json"
jq -e --slurpfile expected "$restored_config" \
  '. == $expected[0]' "$cleanup_fixture/shell.json" >/dev/null
[[ ! -e $cleanup_fixture/target && ! -e $cleanup_fixture/probe ]]
[[ $(wc -l <"$cleanup_fixture/remove.log") -eq 2 ]]
grep -Fxq 'shell reloadConfig' "$cleanup_fixture/reload.log"
grep -Fxq 'shell rescanPlugins' "$cleanup_fixture/reload.log"

no_original_fixture="$cleanup_fixture/no-original"
mkdir -p "$no_original_fixture/target" "$no_original_fixture/probe"
printf 'run.fixture\n' >"$no_original_fixture/target/.acceptance-run-id"
printf 'run.fixture\n' >"$no_original_fixture/probe/.acceptance-run-id"
jq -n '{
  version: 1,
  plugins: [],
  bar: {layout: {
    left: [],
    center: [],
    right: [{id: "example.clock", format: "short"}]
  }}
}' >"$no_original_fixture/original-effective.json"
jq --arg target "$target_id" --arg probe "$probe_id" '
  .plugins = [$target, $probe]
  | .bar.layout.left += [{id: $probe}]
  | .bar.layout.right += [{id: $target}]
' "$no_original_fixture/original-effective.json" \
  >"$no_original_fixture/last-gate.json"
cp -- "$no_original_fixture/last-gate.json" "$no_original_fixture/shell.json"
jq --arg root "$no_original_fixture" \
  '.lockFile = ($root + "/acceptance.lock")
   | .shellConfig = ($root + "/shell.json")
   | .lastGateConfig = ($root + "/last-gate.json")
   | .originalEffectiveConfig = ($root + "/original-effective.json")
   | .originalConfigExisted = false
   | .target.path = ($root + "/target")
   | .probe.path = ($root + "/probe")
   | .helperPath = ($root + "/target/bin/system-stats-helper")
   | .helperOverlapMarker = ($root + "/helper-overlap")' \
  "$cleanup_fixture/manifest.json" >"$no_original_fixture/manifest.json"
: >"$no_original_fixture/remove.log"
: >"$no_original_fixture/reload.log"
PATH="$cleanup_fixture/bin:$PATH" \
  CLEANUP_UNLOCKED=true \
  CLEANUP_REMOVE_LOG="$no_original_fixture/remove.log" \
  CLEANUP_RELOAD_LOG="$no_original_fixture/reload.log" \
  CLEANUP_TARGET_ID="$target_id" \
  CLEANUP_TARGET_DIR="$no_original_fixture/target" \
  CLEANUP_PROBE_ID="$probe_id" \
  CLEANUP_PROBE_DIR="$no_original_fixture/probe" \
  CLEANUP_SHELL_CONFIG="$no_original_fixture/shell.json" \
  bash "$acceptance_cleanup" --acquire-lock \
    "$no_original_fixture/manifest.json"
[[ ! -e $no_original_fixture/shell.json ]]
[[ ! -e $no_original_fixture/target && ! -e $no_original_fixture/probe ]]

no_mutation_fixture="$cleanup_fixture/no-mutation"
mkdir -p "$no_mutation_fixture"
printf '{}\n' >"$no_mutation_fixture/last-gate.json"
cp -- "$no_original_fixture/original-effective.json" \
  "$no_mutation_fixture/original-effective.json"
jq --arg root "$no_mutation_fixture" \
  '.lockFile = ($root + "/acceptance.lock")
   | .shellConfig = ($root + "/shell.json")
   | .lastGateConfig = ($root + "/last-gate.json")
   | .originalEffectiveConfig = ($root + "/original-effective.json")
   | .originalConfigExisted = false
   | .target.path = ($root + "/target")
   | .probe.path = ($root + "/probe")
   | .helperPath = ($root + "/target/bin/system-stats-helper")
   | .helperOverlapMarker = ($root + "/helper-overlap")' \
  "$cleanup_fixture/manifest.json" >"$no_mutation_fixture/manifest.json"
: >"$no_mutation_fixture/remove.log"
: >"$no_mutation_fixture/reload.log"
PATH="$cleanup_fixture/bin:$PATH" \
  CLEANUP_UNLOCKED=true \
  CLEANUP_REMOVE_LOG="$no_mutation_fixture/remove.log" \
  CLEANUP_RELOAD_LOG="$no_mutation_fixture/reload.log" \
  CLEANUP_TARGET_ID="$target_id" \
  CLEANUP_TARGET_DIR="$no_mutation_fixture/target" \
  CLEANUP_PROBE_ID="$probe_id" \
  CLEANUP_PROBE_DIR="$no_mutation_fixture/probe" \
  CLEANUP_SHELL_CONFIG="$no_mutation_fixture/shell.json" \
  bash "$acceptance_cleanup" --acquire-lock \
    "$no_mutation_fixture/manifest.json"
[[ ! -e $no_mutation_fixture/shell.json ]]
[[ ! -s $no_mutation_fixture/remove.log ]]

partial_checkout_fixture="$cleanup_fixture/partial-checkout"
mkdir -p "$partial_checkout_fixture/target"
printf 'run.fixture\n' >"$partial_checkout_fixture/target/.acceptance-run-id"
printf '{}\n' >"$partial_checkout_fixture/last-gate.json"
cp -- "$no_original_fixture/original-effective.json" \
  "$partial_checkout_fixture/original-effective.json"
jq --arg root "$partial_checkout_fixture" \
  '.lockFile = ($root + "/acceptance.lock")
   | .shellConfig = ($root + "/shell.json")
   | .lastGateConfig = ($root + "/last-gate.json")
   | .originalEffectiveConfig = ($root + "/original-effective.json")
   | .originalConfigExisted = false
   | .target.path = ($root + "/target")
   | .probe.path = ($root + "/probe")
   | .helperPath = ($root + "/target/bin/system-stats-helper")
   | .helperOverlapMarker = ($root + "/helper-overlap")' \
  "$cleanup_fixture/manifest.json" \
  >"$partial_checkout_fixture/manifest.json"
: >"$partial_checkout_fixture/remove.log"
: >"$partial_checkout_fixture/reload.log"
PATH="$cleanup_fixture/bin:$PATH" \
  CLEANUP_UNLOCKED=true \
  CLEANUP_REMOVE_LOG="$partial_checkout_fixture/remove.log" \
  CLEANUP_RELOAD_LOG="$partial_checkout_fixture/reload.log" \
  CLEANUP_TARGET_ID="$target_id" \
  CLEANUP_TARGET_DIR="$partial_checkout_fixture/target" \
  CLEANUP_PROBE_ID="$probe_id" \
  CLEANUP_PROBE_DIR="$partial_checkout_fixture/probe" \
  CLEANUP_SHELL_CONFIG="$partial_checkout_fixture/shell.json" \
  bash "$acceptance_cleanup" --acquire-lock \
    "$partial_checkout_fixture/manifest.json"
[[ ! -e $partial_checkout_fixture/shell.json ]]
[[ ! -e $partial_checkout_fixture/target ]]
[[ $(wc -l <"$partial_checkout_fixture/remove.log") -eq 1 ]]

named_helper="$test_dir/named-helper"
bash -c 'exec -a "$1" sleep 5' _ "$named_helper" &
named_helper_pid=$!
background_pids+=("$named_helper_pid")
if bash "$helper_cleanup_verifier" "$named_helper" \
    "$test_dir/helper-overlap" 2 0.01 >/dev/null 2>&1; then
  echo "cleanup must fail while an acceptance helper is still running" >&2
  exit 1
fi
kill "$named_helper_pid" 2>/dev/null || true
wait "$named_helper_pid" 2>/dev/null || true
background_pids=()
touch "$test_dir/helper-overlap"
if bash "$helper_cleanup_verifier" "$named_helper" \
    "$test_dir/helper-overlap" 2 0.01 >/dev/null 2>&1; then
  echo "cleanup must fail when the durable overlap witness exists" >&2
  exit 1
fi
rm -f "$test_dir/helper-overlap"
bash "$helper_cleanup_verifier" "$named_helper" \
  "$test_dir/helper-overlap" 2 0.01

bash -c 'exec -a "$1" sleep 0.2' _ "$named_helper" &
named_helper_pid=$!
background_pids+=("$named_helper_pid")
dynamic_overlap_marker="$test_dir/dynamic-helper-overlap"
bash "$helper_cleanup_verifier" "$named_helper" \
  "$dynamic_overlap_marker" 100 0.01 >/dev/null 2>&1 &
dynamic_verifier_pid=$!
background_pids+=("$dynamic_verifier_pid")
sleep 0.03
touch "$dynamic_overlap_marker"
dynamic_verifier_status=0
wait "$dynamic_verifier_pid" || dynamic_verifier_status=$?
[[ $dynamic_verifier_status -ne 0 ]] || {
  echo "an overlap recorded while polling must block helper cleanup" >&2
  exit 1
}
kill "$named_helper_pid" 2>/dev/null || true
wait "$named_helper_pid" 2>/dev/null || true
background_pids=()

if grep -Fq 'max_helpers' "$live_gate"; then
  echo "helper overlap must use a durable witness instead of polling" >&2
  exit 1
fi

suspend_fixture="$test_dir/suspend-barrier"
mkdir -p "$suspend_fixture/target" "$suspend_fixture/probe"
printf 'service-v1\n' >"$suspend_fixture/target/Service.qml"
printf 'probe-v1\n' >"$suspend_fixture/probe/Service.qml"
printf '{"plugins":[]}\n' >"$suspend_fixture/shell.json"
barrier_state="$suspend_fixture/barrier.json"
command_witness="$suspend_fixture/command-ran"
sleep 30 &
barrier_shell_pid=$!
background_pids+=("$barrier_shell_pid")
barrier_shell_start=$(awk '{print $22}' "/proc/$barrier_shell_pid/stat")
barrier_shell_id="$barrier_shell_pid:$barrier_shell_start"

bash "$suspend_barrier" --arm "$barrier_state" \
  '1:1' "$barrier_shell_id" \
  "$suspend_fixture/target" "$suspend_fixture/probe" \
  "$suspend_fixture/shell.json"
bash "$suspend_barrier" --run "$barrier_state" \
  "$suspend_fixture/target" "$suspend_fixture/probe" \
  "$suspend_fixture/shell.json" -- touch "$command_witness"
[[ -e $command_witness ]] || {
  echo "an unchanged post-restart runtime must pass the suspend barrier" >&2
  exit 1
}

rm -f -- "$command_witness"
touch "$suspend_fixture/target/Service.qml"
if bash "$suspend_barrier" --run "$barrier_state" \
    "$suspend_fixture/target" "$suspend_fixture/probe" \
    "$suspend_fixture/shell.json" -- touch "$command_witness" \
    >/dev/null 2>&1; then
  echo "a post-barrier plugin touch must block the suspend command" >&2
  exit 1
fi
[[ ! -e $command_witness ]] || {
  echo "the suspend command ran after a post-barrier plugin touch" >&2
  exit 1
}

printf 'service-v1\n' >"$suspend_fixture/target/Service.qml"
mtime_reference="$suspend_fixture/original-mtime"
touch -r "$suspend_fixture/target/Service.qml" "$mtime_reference"
bash "$suspend_barrier" --arm "$barrier_state" \
  '1:1' "$barrier_shell_id" \
  "$suspend_fixture/target" "$suspend_fixture/probe" \
  "$suspend_fixture/shell.json"
fingerprinted_shape=$(stat -c '%a:%s:%y' \
  "$suspend_fixture/target/Service.qml")
sleep 0.01
printf 'transient!\n' >"$suspend_fixture/target/Service.qml"
printf 'service-v1\n' >"$suspend_fixture/target/Service.qml"
touch -r "$mtime_reference" "$suspend_fixture/target/Service.qml"
[[ $(stat -c '%a:%s:%y' "$suspend_fixture/target/Service.qml") \
    == "$fingerprinted_shape" ]]
if bash "$suspend_barrier" --run "$barrier_state" \
    "$suspend_fixture/target" "$suspend_fixture/probe" \
    "$suspend_fixture/shell.json" -- touch "$command_witness" \
    >/dev/null 2>&1; then
  echo "a rewritten file with restored bytes and mtime must block suspend" >&2
  exit 1
fi
[[ ! -e $command_witness ]] || {
  echo "the suspend command ran after an inotify-visible rewrite" >&2
  exit 1
}

bash "$suspend_barrier" --arm "$barrier_state" \
  '1:1' "$barrier_shell_id" \
  "$suspend_fixture/target" "$suspend_fixture/probe" \
  "$suspend_fixture/shell.json"
if bash "$suspend_barrier" --arm "$barrier_state" \
    "$barrier_shell_id" "$barrier_shell_id" \
    "$suspend_fixture/target" "$suspend_fixture/probe" \
    "$suspend_fixture/shell.json" >/dev/null 2>&1; then
  echo "the suspend barrier must require a replacement shell" >&2
  exit 1
fi
kill "$barrier_shell_pid"
wait "$barrier_shell_pid" 2>/dev/null || true
if bash "$suspend_barrier" --run "$barrier_state" \
    "$suspend_fixture/target" "$suspend_fixture/probe" \
    "$suspend_fixture/shell.json" -- touch "$command_witness" \
    >/dev/null 2>&1; then
  echo "a stale stored shell identity must block the suspend command" >&2
  exit 1
fi
[[ ! -e $command_witness ]] || {
  echo "the suspend command ran after the replacement shell exited" >&2
  exit 1
}

if rg -n 'shellConfig|inlineSettingsFromShellConfig|restoreInlineSettings' \
    "$repo_root/BarWidget.qml"; then
  echo "the widget must consume host-injected settings without walking shell config" >&2
  exit 1
fi

for section in left center right; do
  grep -Fq "omarchy plugin enable $plugin_id --section $section" \
    "$repo_root/README.md"
done

grep -Fq "omarchy bar move $plugin_id --section left" "$repo_root/README.md"

if grep -Fq -- "--section tray" "$repo_root/README.md"; then
  echo "the tray drawer must not be documented as a widget placement target" >&2
  exit 1
fi

grep -Fq 'Acceptance target: **Omarchy 4.0.2-1**' "$compatibility_doc"
grep -Fq 'Quickshell 0.3.1 (Arch Linux package; revision field empty).' \
  "$compatibility_doc"
grep -Fq 'target_omarchy_version="4.0.2-1"' "$live_gate"
grep -Fq 'target_quickshell_fingerprint="Quickshell 0.3.1 (revision , distributed by Arch Linux)"' \
  "$live_gate"
grep -Fq '[[ $quickshell_version == "$target_quickshell_fingerprint" ]]' \
  "$live_gate"
if rg -n '4\.0\.1-1' "$live_gate" "$compatibility_doc"; then
  echo "the retargeted gate must not retain the old Omarchy package release" >&2
  exit 1
fi
if rg -n 'target_quickshell_revision|28771c7c74b42e20afca0b1b63980cb46515537c' \
    "$live_gate" "$compatibility_doc"; then
  echo "the retargeted gate must not retain the old Quickshell revision" >&2
  exit 1
fi
grep -Fq 'Full live acceptance: **pending**' "$compatibility_doc"
grep -Fq 'No successful full `--real-suspend` run has been recorded yet.' \
  "$compatibility_doc"
grep -Fq 'restarts the unlocked Omarchy' "$compatibility_doc"
grep -Fq 'shell before the first suspend' "$compatibility_doc"
grep -Fq 'plugin, probe, or shell configuration rewrite after' \
  "$compatibility_doc"
grep -Fq '`omarchy bar set` persists the inline settings before a normal bar move' \
  "$compatibility_doc"
grep -Fq 'wait_for_persisted_entry_settings' "$live_gate"
grep -Fq 'wait_for_live_widget_settings' "$live_gate"
grep -Fq 'recreate_widget_slots_from_persisted_settings' "$live_gate"
persisted_wait=$(sed -n '/^wait_for_persisted_entry_settings()/,/^}$/p' "$live_gate")
if grep -Eq 'acceptance_state|live_widget_settings_match' <<<"$persisted_wait"; then
  echo "the pinned host persistence check must not require stale live widgets" >&2
  exit 1
fi
settings_write_line=$(grep -nF \
  'run_config_mutation omarchy bar set "$plugin_id" ramDisplayFormat gib' \
  "$live_gate" | cut -d: -f1)
persisted_wait_line=$(grep -nF 'wait_for_persisted_entry_settings' "$live_gate" \
  | tail -n1 | cut -d: -f1)
recreate_widgets_line=$(grep -nF 'recreate_widget_slots_from_persisted_settings' \
  "$live_gate" | tail -n1 | cut -d: -f1)
reload_line=$(grep -nF 'touch "$plugin_dir/Service.qml"' "$live_gate" | cut -d: -f1)
live_settings_line=$(grep -nF 'wait_for_live_widget_settings' "$live_gate" \
  | tail -n1 | cut -d: -f1)
(( settings_write_line < persisted_wait_line
   && persisted_wait_line < recreate_widgets_line
   && recreate_widgets_line < reload_line
   && reload_line < live_settings_line )) || {
  echo "settings must be persisted, applied by a bar move, and retained after reload" >&2
  exit 1
}
barrier_setup_function=$(sed -n \
  '/^establish_suspend_reload_barrier()/,/^}$/p' "$live_gate")
grep -Fq 'omarchy-restart-shell' <<<"$barrier_setup_function" || {
  echo "the suspend barrier must replace the shell that handled hot reload" >&2
  exit 1
}
grep -Fq 'bash "$suspend_barrier" --arm' <<<"$barrier_setup_function" || {
  echo "the replacement shell must arm the suspend barrier" >&2
  exit 1
}
barrier_setup_line=$(grep -nF '  establish_suspend_reload_barrier' "$live_gate" \
  | cut -d: -f1)
short_suspend_line=$(grep -nF 'real_suspend_cycle "short" 1' "$live_gate" \
  | cut -d: -f1)
(( reload_line < barrier_setup_line
   && barrier_setup_line < short_suspend_line )) || {
  echo "real suspend must follow hot reload with a replacement-shell barrier" >&2
  exit 1
}
real_suspend_function=$(sed -n '/^real_suspend_cycle()/,/^}$/p' "$live_gate")
grep -Fq 'bash "$suspend_barrier" --run' <<<"$real_suspend_function"
if grep -Eq '^[[:space:]]*systemctl suspend$' <<<"$real_suspend_function"; then
  echo "real suspend must run only through the reload barrier" >&2
  exit 1
fi
if rg -ni 'validated target|validated Quattro compatibility|validated x86-64|Evidence status' \
    "$compatibility_doc"; then
  echo "pending compatibility must not be documented as validated" >&2
  exit 1
fi
grep -Fq '## Limits on other versions' "$compatibility_doc"
grep -Fq 'bash tests/accept_quattro_live.sh --real-suspend' "$compatibility_doc"
grep -Fq "does not replace ADR-0001's separate" "$compatibility_doc"

live_help=$(bash "$live_gate" --help)
grep -Fq 'Usage: tests/accept_quattro_live.sh [--real-suspend]' <<<"$live_help"
grep -Fq 'removes only its own shell-configuration entries' <<<"$live_help"
grep -Fq 'Restart the unlocked Omarchy shell once' <<<"$live_help"
grep -Fq 'export OMARCHY_SHELL_IPC_TIMEOUT="${OMARCHY_SHELL_IPC_TIMEOUT:-10s}"' \
  "$live_gate"
grep -Fq 'OMARCHY_SHELL_IPC_TIMEOUT=1s omarchy-shell "$probe_id" state' \
  "$live_gate"
grep -Fq 'probe_entry="runs/${BASHPID}/Service.qml"' "$live_gate"
grep -Fq 'hyprctl instances -j' "$hyprland_instance_resolver"
grep -Fq 'if [[ -z $resolved_instance ]] || ! hyprctl monitors -j' \
  "$hyprland_instance_resolver"
grep -Fq 'HYPRLAND_INSTANCE_SIGNATURE=$(bash "$hyprland_instance_resolver")' \
  "$live_gate"
grep -Fq 'cleanup_mutations_safe=false' "$live_gate"
grep -Fq 'session_is_unlocked' "$live_gate"
grep -Fq 'bash "$session_unlock_verifier" "$UID"' "$live_gate"
grep -Fq 'omarchy-hyprland-session-locked' "$session_unlock_verifier"
grep -Fq '.locked == false' "$session_unlock_verifier"
grep -Fq '.requested == false' "$session_unlock_verifier"
grep -Fq '.sessionLocked == false' "$session_unlock_verifier"
grep -Fq '.secure == false' "$session_unlock_verifier"
grep -Fq 'if [[ $cleanup_mutations_safe != true ]] || ! session_is_unlocked; then' \
  "$live_gate"
grep -Fq 'LockedHint --value' "$session_unlock_verifier"
grep -Fq 'bash "$session_unlock_verifier" "$session_user_id"' \
  "$acceptance_cleanup"
grep -Fq 'cleanup_failed=true' "$live_gate"
grep -Fq 'bash "$config_restorer" --matches' "$acceptance_cleanup"
grep -Fq 'Never copy the full original' "$live_gate"
grep -Fq 'cleanup_manifest="$recovery_dir/cleanup-manifest.json"' "$live_gate"
grep -Fq 'post-remove config differs from safe merge' "$acceptance_cleanup"
if rg -n 'CURRENT_CONFIG|POST_REMOVE_CONFIG|MERGED_CONFIG' "$live_gate"; then
  echo "recovery instructions must contain an executable, consistent file sequence" >&2
  exit 1
fi

recovery_fixture="$test_dir/recovery-render"
mkdir -p "$recovery_fixture"
recovery_function=$(sed -n '/^write_recovery_instructions()/,/^}$/p' "$live_gate")
RECOVERY_FUNCTION="$recovery_function" RECOVERY_FIXTURE="$recovery_fixture" \
  bash -c '
    eval "$RECOVERY_FUNCTION"
    run_id="run.fixture"
    helper_overlap_marker="$RECOVERY_FIXTURE/helper-overlap"
    config_backup="$RECOVERY_FIXTURE/original.json"
    original_effective_config="$RECOVERY_FIXTURE/original-effective.json"
    last_gate_config="$RECOVERY_FIXTURE/last.json"
    recovery_cleanup="$RECOVERY_FIXTURE/cleanup_quattro_acceptance.sh"
    cleanup_manifest="$RECOVERY_FIXTURE/cleanup-manifest.json"
    recovery_dir="$RECOVERY_FIXTURE"
    recovery_file="$RECOVERY_FIXTURE/RECOVERY.txt"
    write_recovery_instructions "fixture"
  '
sed -n '/^  set -euo pipefail$/,/^$/p' \
  "$recovery_fixture/RECOVERY.txt" \
  | sed 's/^  //' >"$recovery_fixture/recovery-block.sh"
bash -n "$recovery_fixture/recovery-block.sh"
grep -Fq 'cleanup_quattro_acceptance.sh' \
  "$recovery_fixture/recovery-block.sh"
grep -Fq 'cleanup-manifest.json' "$recovery_fixture/recovery-block.sh"
grep -Fq '"$expected_config.initializing"' "$acceptance_cleanup"
if grep -Eq '\]\] \|\| cp -- .*expected_config' "$acceptance_cleanup"; then
  echo "the initial recovery expectation must be installed atomically" >&2
  exit 1
fi
first_remove_line=$(grep -n -m1 'remove_checkout "$target_id"' \
  "$acceptance_cleanup" | cut -d: -f1)
target_marker_line=$(grep -n -m1 'target ownership marker is missing' \
  "$acceptance_cleanup" | cut -d: -f1)
probe_marker_line=$(grep -n -m1 'probe ownership marker is missing' \
  "$acceptance_cleanup" | cut -d: -f1)
(( target_marker_line < first_remove_line && probe_marker_line < first_remove_line )) || {
  echo "recovery must validate every checkout marker before its first mutation" >&2
  exit 1
}
[[ $(grep -Fc 'snapshot_config "$expected_config"' "$acceptance_cleanup") -eq 1 ]] || {
  echo "recovery must persist its expected config after every removal attempt" >&2
  exit 1
}
grep -Fq 'RECOVERY.txt' "$live_gate"
grep -Fq 'cleanup_quattro_acceptance.sh' "$live_gate"
grep -Fq -- '--acquire-lock' "$recovery_fixture/recovery-block.sh"
if grep -Fq 'omarchy plugin remove' <<<"$recovery_function"; then
  echo "recovery instructions must delegate the shared cleanup policy" >&2
  exit 1
fi
cleanup_function=$(sed -n '/^cleanup()/,/^}$/p' "$live_gate")
if grep -Eq 'omarchy plugin remove|--restore' <<<"$cleanup_function"; then
  echo "live cleanup must delegate the shared cleanup policy" >&2
  exit 1
fi
grep -Fq 'PrepareForSleep' "$live_gate"
grep -Fq 'CLOCK_BOOTTIME' "$sleep_observer"
grep -Fq 'verify_logind_sleep_cycle.sh' "$live_gate"
grep -Fq 'gdbus monitor --system --dest org.freedesktop.login1' "$sleep_observer"
grep -Fq 'systemd-inhibit --what=sleep --mode=delay' "$live_gate"
grep -Fq 'hold_sleep_delay_until_observed.sh' "$live_gate"
if grep -Fq 'busctl' "$sleep_observer"; then
  echo "the sleep observer must use an unprivileged signal subscription" >&2
  exit 1
fi

bash "$sleep_observer" "$test_dir/observer-events.jsonl" \
  "$test_dir/observer.ready" &
background_pids+=("$!")
for ((attempt = 0; attempt < 100; attempt++)); do
  [[ -e $test_dir/observer.ready ]] && break
  kill -0 "${background_pids[-1]}" 2>/dev/null || break
  sleep 0.01
done
[[ -e $test_dir/observer.ready ]] || {
  echo "the unprivileged logind observer did not become ready" >&2
  exit 1
}
kill "${background_pids[-1]}" 2>/dev/null || true
wait "${background_pids[-1]}" 2>/dev/null || true
background_pids=()

: >"$test_dir/delay-events.jsonl"
bash "$sleep_delay_holder" "$test_dir/delay-events.jsonl" \
  "$test_dir/delay.ready" &
background_pids+=("$!")
for ((attempt = 0; attempt < 100; attempt++)); do
  [[ -e $test_dir/delay.ready ]] && break
  kill -0 "${background_pids[-1]}" 2>/dev/null || break
  sleep 0.01
done
[[ -e $test_dir/delay.ready ]] || {
  echo "the sleep delay holder did not become ready" >&2
  exit 1
}
printf '%s\n' '{"sleeping":true}' >"$test_dir/delay-events.jsonl"
wait "${background_pids[-1]}"
background_pids=()

printf '%s\n' \
  '{"sleeping":true,"boottimeNs":100000000000,"monotonicNs":90000000000}' \
  '{"sleeping":false,"boottimeNs":131000000000,"monotonicNs":91000000000}' \
  >"$test_dir/real-sleep.jsonl"
bash "$sleep_verifier" "$test_dir/real-sleep.jsonl" 30 >/dev/null

printf '%s\n' \
  '{"sleeping":true,"boottimeNs":100000000000,"monotonicNs":90000000000}' \
  '{"sleeping":false,"boottimeNs":131000000000,"monotonicNs":121000000000}' \
  >"$test_dir/manual-wait.jsonl"
if bash "$sleep_verifier" "$test_dir/manual-wait.jsonl" 30 >/dev/null 2>&1; then
  echo "manual waiting must not satisfy the real-suspend gate" >&2
  exit 1
fi

printf '%s\n' \
  '{"sleeping":true,"boottimeNs":100000000000,"monotonicNs":90000000000}' \
  >"$test_dir/missing-resume.jsonl"
if bash "$sleep_verifier" "$test_dir/missing-resume.jsonl" 1 >/dev/null 2>&1; then
  echo "an incomplete logind sleep cycle must fail" >&2
  exit 1
fi

mkdir -p "$test_dir/guard/bin"
cp -- "$helper_guard" "$test_dir/guard/bin/system-stats-helper"
mkdir -p "$test_dir/guard-state"
printf '%s\n' "$test_dir/guard-state" \
  >"$test_dir/guard/bin/.acceptance-state-dir"
printf '%s\n' '#!/usr/bin/env bash' 'exec sleep 5' \
  >"$test_dir/guard/bin/system-stats-helper.real"
grep -Fxq 'exec sleep 5' "$test_dir/guard/bin/system-stats-helper.real"
chmod +x "$test_dir/guard/bin/system-stats-helper" \
  "$test_dir/guard/bin/system-stats-helper.real"
"$test_dir/guard/bin/system-stats-helper" &
guard_pids+=("$!")
sleep 0.05
"$test_dir/guard/bin/system-stats-helper" &
guard_pids+=("$!")
for ((attempt = 0; attempt < 100; attempt++)); do
  [[ -e $test_dir/guard-state/overlap ]] && break
  sleep 0.01
done
[[ -e $test_dir/guard-state/overlap ]] || {
  echo "the helper guard did not durably record an overlap" >&2
  exit 1
}

test ! -e "$repo_root/install.sh"
jq -e 'has("install") | not' "$repo_root/manifest.json" >/dev/null
if rg -n '\b(sudo|pkexec|pacman|yay|paru|setcap|sysctl|usermod|groupmod|chmod|chown|capset|setgroups)\b|/proc/sys' \
    "$repo_root/Service.qml" "$repo_root/BarWidget.qml" "$repo_root/src"; then
  echo "runtime sources must not perform privileged system changes" >&2
  exit 1
fi
