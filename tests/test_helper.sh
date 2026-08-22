#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
helper="$repo_root/bin/system-stats-helper"
helper_pid=""

cleanup() {
  if [[ -n $helper_pid ]] && kill -0 "$helper_pid" 2>/dev/null; then
    kill "$helper_pid"
    wait "$helper_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

test -x "$helper"
test ! -e "$repo_root/install.sh"

"$helper" >/dev/null 2>&1 &
helper_pid=$!

for ((attempt = 0; attempt < 100; attempt++)); do
  [[ -r /proc/$helper_pid/task/$helper_pid/children ]] && break
done

[[ -r /proc/$helper_pid/task/$helper_pid/children ]]
read -r children <"/proc/$helper_pid/task/$helper_pid/children" || true
[[ -z ${children:-} ]]
mapfile -t helper_tasks < <(find "/proc/$helper_pid/task" -mindepth 1 -maxdepth 1 -type d)
[[ ${#helper_tasks[@]} -eq 1 ]]

if rg -n '\b(system|popen|fork|exec[lv]?[pe]?)\s*\(' \
  "$repo_root/src/system-stats-helper.c" "$repo_root/src/gpu-measurement.c"; then
  echo "helper must not create sample subprocesses" >&2
  exit 1
fi
