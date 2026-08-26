#!/usr/bin/env bash

set -euo pipefail

(( $# == 2 )) || {
  echo "usage: verify_logind_sleep_cycle.sh EVENT_LOG MINIMUM_SECONDS" >&2
  exit 2
}

event_log=$1
minimum_seconds=$2
[[ $minimum_seconds =~ ^[0-9]+$ ]] || {
  echo "minimum seconds must be a non-negative integer" >&2
  exit 2
}

jq -e -s '
  length == 2
  and .[0].sleeping == true
  and .[1].sleeping == false
  and all(.[];
    (.boottimeNs | type) == "number"
    and (.monotonicNs | type) == "number"
    and (.boottimeNs | floor) == .boottimeNs
    and (.monotonicNs | floor) == .monotonicNs)
' "$event_log" >/dev/null || {
  echo "expected one logind sleep and resume event" >&2
  exit 1
}

mapfile -t boottime_ns < <(jq -r '.boottimeNs' "$event_log")
mapfile -t monotonic_ns < <(jq -r '.monotonicNs' "$event_log")

boottime_delta=$((boottime_ns[1] - boottime_ns[0]))
monotonic_delta=$((monotonic_ns[1] - monotonic_ns[0]))
suspended_ns=$((boottime_delta - monotonic_delta))
minimum_ns=$((minimum_seconds * 1000000000))

(( boottime_delta >= 0 && monotonic_delta >= 0 && suspended_ns >= minimum_ns )) || {
  printf 'actual suspend time was %.3f seconds; expected at least %s seconds\n' \
    "$(awk -v ns="$suspended_ns" 'BEGIN { print ns / 1000000000 }')" \
    "$minimum_seconds" >&2
  exit 1
}

printf '%s\n' "$suspended_ns"
