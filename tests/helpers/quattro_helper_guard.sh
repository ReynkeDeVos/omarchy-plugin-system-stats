#!/usr/bin/env bash

set -euo pipefail

self=$(readlink -f -- "${BASH_SOURCE[0]}")
helper_dir=$(dirname -- "$self")
real_helper="$self.real"
state_dir_file="$helper_dir/.acceptance-state-dir"

[[ -x $real_helper ]] || {
  echo "acceptance helper is missing: $real_helper" >&2
  exit 1
}
IFS= read -r state_dir <"$state_dir_file" || {
  echo "acceptance helper state path is missing" >&2
  exit 1
}
[[ $state_dir == /* && $state_dir != "/" ]] || {
  echo "acceptance helper state path is unsafe: $state_dir" >&2
  exit 1
}
mkdir -p -- "$state_dir"
lock_file="$state_dir/helper.lock"
overlap_marker="$state_dir/overlap"

exec 9>"$lock_file"
if ! flock -n 9; then
  : >"$overlap_marker"
  flock 9
fi

exec -a "$self" "$real_helper"
