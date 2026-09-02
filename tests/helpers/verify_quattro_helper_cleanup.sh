#!/usr/bin/env bash

set -euo pipefail

if (( $# < 2 || $# > 4 )); then
  echo "Usage: verify_quattro_helper_cleanup.sh HELPER_PATH OVERLAP_MARKER [ATTEMPTS] [DELAY]" >&2
  exit 2
fi

helper_path=$1
overlap_marker=$2
attempts=${3:-200}
delay=${4:-0.05}
[[ $helper_path == /* && $helper_path != "/" ]] || {
  echo "verify_quattro_helper_cleanup: unsafe helper path: $helper_path" >&2
  exit 2
}
[[ $attempts =~ ^[1-9][0-9]*$ ]] || {
  echo "verify_quattro_helper_cleanup: ATTEMPTS must be positive" >&2
  exit 2
}

helper_is_running() {
  local cmdline argv0
  for cmdline in /proc/[0-9]*/cmdline; do
    argv0=""
    IFS= read -r -d '' argv0 2>/dev/null <"$cmdline" || true
    [[ $argv0 == "$helper_path" ]] && return 0
  done
  return 1
}

reject_recorded_overlap() {
  [[ ! -e $overlap_marker ]] || {
    echo "verify_quattro_helper_cleanup: helper overlap was recorded" >&2
    exit 1
  }
}

for ((attempt = 0; attempt < attempts; attempt++)); do
  reject_recorded_overlap
  if ! helper_is_running; then
    reject_recorded_overlap
    exit 0
  fi
  (( attempt + 1 == attempts )) || sleep "$delay"
done

reject_recorded_overlap
echo "verify_quattro_helper_cleanup: acceptance helper is still running" >&2
exit 1
