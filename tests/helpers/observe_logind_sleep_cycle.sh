#!/usr/bin/env bash

set -euo pipefail

(( $# == 2 )) || {
  echo "usage: observe_logind_sleep_cycle.sh EVENT_LOG READY_FILE" >&2
  exit 2
}

event_log=$1
ready_file=$2
monitor_pid=""

cleanup() {
  if [[ -n $monitor_pid ]] && kill -0 "$monitor_pid" 2>/dev/null; then
    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

: >"$event_log"

coproc LOGIND_EVENTS {
  stdbuf -oL gdbus monitor --system --dest org.freedesktop.login1 \
    --object-path /org/freedesktop/login1
}
monitor_pid=$LOGIND_EVENTS_PID
event_count=0

while IFS= read -r event <&"${LOGIND_EVENTS[0]}"; do
  if [[ $event == "The name org.freedesktop.login1 is owned by "* ]]; then
    : >"$ready_file"
    continue
  fi

  case $event in
    "/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (true,)")
      sleeping=true
      ;;
    "/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (false,)")
      sleeping=false
      ;;
    *)
      continue
      ;;
  esac
  read -r boottime_ns monotonic_ns < <(python3 -c '
import time
print(time.clock_gettime_ns(time.CLOCK_BOOTTIME), time.monotonic_ns())
')
  printf '{"sleeping":%s,"boottimeNs":%s,"monotonicNs":%s}\n' \
    "$sleeping" "$boottime_ns" "$monotonic_ns" >>"$event_log"
  event_count=$((event_count + 1))
  (( event_count == 2 )) && break
done

(( event_count == 2 )) || {
  echo "logind signal subscription ended before a complete sleep cycle" >&2
  exit 1
}
kill "$monitor_pid" 2>/dev/null || true
wait "$monitor_pid" 2>/dev/null || true
monitor_pid=""
