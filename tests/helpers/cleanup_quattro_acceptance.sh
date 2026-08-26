#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  cleanup_quattro_acceptance.sh --lock-held MANIFEST
  cleanup_quattro_acceptance.sh --acquire-lock MANIFEST
USAGE
  exit 2
}

fail() {
  echo "cleanup_quattro_acceptance: $*" >&2
  exit 1
}

json_string() {
  jq -er "$1 | select(type == \"string\" and length > 0)" "$manifest"
}

safe_absolute_path() {
  [[ $1 == /* && $1 != "/" ]]
}

snapshot_config() {
  local destination=$1
  local destination_tmp="${destination}.tmp"
  if [[ -f $shell_config ]]; then
    cp -- "$shell_config" "$destination_tmp"
  else
    jq -n '{}' >"$destination_tmp"
  fi
  mv -f -- "$destination_tmp" "$destination"
}

checkout_owned_by_run() {
  local checkout_dir=$1
  local marker="$checkout_dir/.acceptance-run-id"
  local owner=""
  [[ -f $marker ]] || return 1
  IFS= read -r owner <"$marker" || return 1
  [[ $owner == "$run_id" ]]
}

remove_checkout() {
  local plugin_id=$1
  local checkout_dir=$2
  local label=$3
  local remove_status=0
  [[ -e $checkout_dir ]] || return 0

  omarchy plugin remove "$plugin_id" --yes || remove_status=$?
  snapshot_config "$expected_config"
  (( remove_status == 0 )) || fail "$label removal failed"
}

(( $# == 2 )) || usage
mode=$1
manifest=$2
[[ -f $manifest ]] || fail "manifest is missing: $manifest"
manifest=$(readlink -f -- "$manifest") || fail "could not resolve manifest"
safe_absolute_path "$manifest" || fail "manifest path is unsafe"
jq -e '.version == 1' "$manifest" >/dev/null || fail "manifest is invalid"

run_id=$(json_string '.runId')
lock_file=$(json_string '.lockFile')
shell_config=$(json_string '.shellConfig')
last_gate_config=$(json_string '.lastGateConfig')
original_effective_config=$(json_string '.originalEffectiveConfig')
target_id=$(json_string '.target.id')
target_dir=$(json_string '.target.path')
probe_id=$(json_string '.probe.id')
probe_dir=$(json_string '.probe.path')
config_restorer=$(json_string '.configRestorer')
helper_cleanup_verifier=$(json_string '.helperCleanupVerifier')
helper_path=$(json_string '.helperPath')
helper_overlap_marker=$(json_string '.helperOverlapMarker')
session_unlock_verifier=$(json_string '.sessionUnlockVerifier')
session_user_id=$(json_string '.sessionUserId')
original_config_existed=$(jq -er '
  .originalConfigExisted
  | select(type == "boolean")
  | tostring
' "$manifest") ||
  fail "manifest lacks originalConfigExisted"
[[ $session_user_id =~ ^[0-9]+$ ]] || fail "manifest has an invalid session user ID"

for path in "$lock_file" "$shell_config" "$last_gate_config" \
  "$original_effective_config" "$target_dir" "$probe_dir" \
  "$config_restorer" "$helper_cleanup_verifier" "$helper_path" \
  "$helper_overlap_marker" "$session_unlock_verifier"; do
  safe_absolute_path "$path" || fail "manifest contains an unsafe path: $path"
done
[[ $target_dir != "$probe_dir" && $target_id != "$probe_id" ]] ||
  fail "target and probe must be distinct"
[[ -f $last_gate_config ]] || fail "last gate configuration is missing"
[[ -f $original_effective_config ]] ||
  fail "original effective configuration is missing"
[[ -f $config_restorer ]] || fail "configuration restorer is missing"
[[ -f $helper_cleanup_verifier ]] || fail "helper verifier is missing"
[[ -f $session_unlock_verifier ]] || fail "session unlock verifier is missing"

case $mode in
  --lock-held) ;;
  --acquire-lock)
    exec {cleanup_lock_fd}>"$lock_file"
    flock --exclusive --nonblock "$cleanup_lock_fd" || {
      echo "cleanup_quattro_acceptance: acceptance lock is busy" >&2
      exit 75
    }
    ;;
  *) usage ;;
esac

bash "$session_unlock_verifier" "$session_user_id" ||
  fail "the graphical session is not confirmed unlocked"

recovery_dir=${manifest%/*}
expected_config="$recovery_dir/recovery-expected.json"
current_config="$recovery_dir/recovery-current.json"
merged_config="$recovery_dir/recovery-merged.json"
post_config="$recovery_dir/recovery-post-remove.json"
cleanup_started_with_shell_config=false
cleanup_started_without_shell_config_state=false
[[ -f $shell_config ]] && cleanup_started_with_shell_config=true

if [[ ! -f $expected_config ]]; then
  cp -- "$last_gate_config" "$expected_config.initializing"
  mv -f -- "$expected_config.initializing" "$expected_config"
fi
snapshot_config "$current_config"
bash "$config_restorer" --matches \
  "$expected_config" "$current_config" "$target_id" "$probe_id"
if [[ $original_config_existed == false \
    && $cleanup_started_with_shell_config == false ]] \
    && jq -e 'type == "object" and length == 0' "$current_config" >/dev/null \
    && bash "$config_restorer" --assert-clean \
      "$current_config" "$target_id" "$probe_id"; then
  cleanup_started_without_shell_config_state=true
fi

# Validate every extant checkout before the first mutation. A partial earlier
# recovery may have removed either checkout, but a replacement is never ours.
if [[ -e $target_dir ]] && ! checkout_owned_by_run "$target_dir"; then
  fail "target ownership marker is missing or foreign"
fi
if [[ -e $probe_dir ]] && ! checkout_owned_by_run "$probe_dir"; then
  fail "probe ownership marker is missing or foreign"
fi

remove_checkout "$target_id" "$target_dir" "target"
remove_checkout "$probe_id" "$probe_dir" "probe"

# Re-read after the official removals. Unrelated concurrent edits are retained,
# while any concurrent change to an acceptance-owned entry stops the merge.
snapshot_config "$current_config"
bash "$config_restorer" --matches \
  "$expected_config" "$current_config" "$target_id" "$probe_id"
bash "$config_restorer" --restore \
  "$expected_config" "$current_config" "$merged_config" \
  "$target_id" "$probe_id"
cp -- "$merged_config" "$shell_config.installing"
chmod --reference="$current_config" "$shell_config.installing"
mv -f -- "$shell_config.installing" "$shell_config"

snapshot_config "$post_config"
bash "$config_restorer" --assert-clean \
  "$post_config" "$target_id" "$probe_id"
jq -e --slurpfile expected "$merged_config" \
  '. == $expected[0]' "$post_config" >/dev/null ||
  fail "post-remove config differs from safe merge"
bash "$helper_cleanup_verifier" "$helper_path" "$helper_overlap_marker"

if [[ $original_config_existed == false ]] && {
    jq -e --slurpfile original "$original_effective_config" \
      '. == $original[0]' "$post_config" >/dev/null \
      || { [[ $cleanup_started_without_shell_config_state == true ]] \
        && jq -e 'type == "object" and length == 0' "$post_config" >/dev/null; }
  }; then
  rm -f -- "$shell_config"
fi
omarchy-shell shell reloadConfig
omarchy-shell shell rescanPlugins
