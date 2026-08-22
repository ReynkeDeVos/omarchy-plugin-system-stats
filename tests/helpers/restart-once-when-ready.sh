#!/usr/bin/env bash

set -euo pipefail

exec 3<&0

if mkdir -- "$SYSTEM_STATS_RESTART_MARKER_DIR" 2>/dev/null; then
  "$SYSTEM_STATS_REAL_HELPER" <&3 \
    > >(tee "$SYSTEM_STATS_RESTART_OBSERVATION_FILE") &
  helper_pid=$!
  while kill -0 "$helper_pid" 2>/dev/null; do
    if [[ $SYSTEM_STATS_RESTART_CONDITION == inventory-added ]]; then
      if [[ $(wc -l <"$SYSTEM_STATS_GPU_INVENTORY_FILE") -ge 2 ]]; then break; fi
    elif [[ $SYSTEM_STATS_RESTART_CONDITION == inventory-removed ]]; then
      if [[ $(wc -l <"$SYSTEM_STATS_GPU_INVENTORY_FILE") -eq 1 ]]; then break; fi
    elif grep -Fq '"fixedRetryStage":3' \
      "$SYSTEM_STATS_RESTART_OBSERVATION_FILE" 2>/dev/null; then
      break
    fi
    sleep 0.01
  done
  if kill -0 "$helper_pid" 2>/dev/null; then kill "$helper_pid"; fi
  wait "$helper_pid" || true
  exit 17
fi

exec "$SYSTEM_STATS_REAL_HELPER"
