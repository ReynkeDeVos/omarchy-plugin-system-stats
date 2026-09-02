#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  run_quattro_suspend_if_ready.sh --arm STATE PREVIOUS_SHELL_ID CURRENT_SHELL_ID PATH...
  run_quattro_suspend_if_ready.sh --run STATE PATH... -- COMMAND [ARG...]
USAGE
  exit 2
}

fail() {
  echo "run_quattro_suspend_if_ready: $*" >&2
  exit 1
}

refuse_suspend() {
  echo "run_quattro_suspend_if_ready: suspend readiness changed: $*" >&2
  exit 75
}

valid_shell_id() {
  [[ $1 =~ ^[1-9][0-9]*:[0-9]+$ ]]
}

shell_identity_is_live() {
  local identity=$1
  local pid=${identity%%:*}
  local expected_start_ticks=${identity#*:}
  local stat_line stat_tail process_state start_ticks

  [[ -r /proc/$pid/stat ]] || return 1
  IFS= read -r stat_line <"/proc/$pid/stat" || return 1
  stat_tail=${stat_line##*) }
  read -r process_state start_ticks < <(
    awk '{print $1, $20}' <<<"$stat_tail"
  )
  [[ $process_state != "Z" && $start_ticks == "$expected_start_ticks" ]]
}

fingerprint_paths() {
  local root entry
  {
    for root in "$@"; do
      printf 'root\0%s\0' "$root"
      if [[ ! -e $root && ! -L $root ]]; then
        printf 'missing\0'
        continue
      fi

      while IFS= read -r -d '' entry; do
        stat --printf='entry\0%n\0%F\0%i\0%a\0%s\0%y\0%z\0' -- "$entry"
        if [[ -f $entry ]]; then
          sha256sum --zero -- "$entry"
        elif [[ -L $entry ]]; then
          printf 'link\0'
          readlink --zero -- "$entry"
        fi
      done < <(find -P "$root" -print0 | sort -z)
    done
  } | sha256sum | awk '{print $1}'
}

(( $# >= 1 )) || usage
mode=$1
shift

case $mode in
  --arm)
    (( $# >= 4 )) || usage
    state_file=$1
    previous_shell_id=$2
    current_shell_id=$3
    shift 3
    [[ $state_file == /* && $state_file != "/" ]] ||
      fail "STATE must be a safe absolute path"
    valid_shell_id "$previous_shell_id" || fail "invalid previous shell identity"
    valid_shell_id "$current_shell_id" || fail "invalid current shell identity"
    [[ $previous_shell_id != "$current_shell_id" ]] ||
      fail "the Omarchy shell was not replaced"
    shell_identity_is_live "$current_shell_id" ||
      fail "the replacement Omarchy shell is not live"

    fingerprint=$(fingerprint_paths "$@")
    state_tmp="${state_file}.tmp"
    umask 077
    jq -n --arg shellIdentity "$current_shell_id" \
      --arg fingerprint "$fingerprint" '{
        version: 1,
        shellIdentity: $shellIdentity,
        fingerprint: $fingerprint
      }' >"$state_tmp"
    mv -f -- "$state_tmp" "$state_file"
    ;;

  --run)
    (( $# >= 4 )) || usage
    state_file=$1
    shift
    paths=()
    while (( $# > 0 )) && [[ $1 != "--" ]]; do
      paths+=("$1")
      shift
    done
    (( ${#paths[@]} > 0 && $# >= 2 )) || usage
    shift

    [[ -f $state_file ]] || refuse_suspend "barrier state is missing"
    expected_shell_id=$(jq -er '
      select(.version == 1)
      | .shellIdentity
      | select(type == "string")
    ' "$state_file") || refuse_suspend "barrier state is invalid"
    expected_fingerprint=$(jq -er '
      select(.version == 1)
      | .fingerprint
      | select(type == "string")
    ' "$state_file") || refuse_suspend "barrier state is invalid"

    valid_shell_id "$expected_shell_id" ||
      refuse_suspend "stored shell identity is invalid"
    shell_identity_is_live "$expected_shell_id" ||
      refuse_suspend "the replacement Omarchy shell is no longer live"
    current_fingerprint=$(fingerprint_paths "${paths[@]}")
    [[ $current_fingerprint == "$expected_fingerprint" ]] ||
      refuse_suspend "plugin or shell configuration changed"
    shell_identity_is_live "$expected_shell_id" ||
      refuse_suspend "the replacement Omarchy shell exited during the barrier check"

    exec "$@"
    ;;

  *) usage ;;
esac
