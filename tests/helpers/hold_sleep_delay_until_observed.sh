#!/usr/bin/env bash

set -euo pipefail

(( $# == 2 )) || {
  echo "usage: hold_sleep_delay_until_observed.sh EVENT_LOG READY_FILE" >&2
  exit 2
}

event_log=$1
ready_file=$2

: >"$ready_file"
for ((attempt = 0; attempt < 3000; attempt++)); do
  if jq -e -s 'length >= 1 and .[0].sleeping == true' \
      "$event_log" >/dev/null 2>&1; then
    exit 0
  fi
  sleep 0.01
done

echo "timed out waiting for the pre-suspend sample" >&2
exit 1
