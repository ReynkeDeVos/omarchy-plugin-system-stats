#!/usr/bin/env bash

set -euo pipefail

export LD_PRELOAD="$SYSTEM_STATS_PERF_FIXTURE_LIBRARY${LD_PRELOAD:+:$LD_PRELOAD}"
exec "$SYSTEM_STATS_REAL_HELPER" "$@"
