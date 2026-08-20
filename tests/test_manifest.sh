#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

omarchy plugin validate "$repo_root"

jq -e '
  .id == "reynkedevos.system-stats"
  and .name == "System Stats"
  and .kinds == ["service", "bar-widget"]
  and .entryPoints.service == "Service.qml"
  and .entryPoints.barWidget == "BarWidget.qml"
' "$repo_root/manifest.json" >/dev/null

test -x "$repo_root/bin/system-stats-helper"
test ! -e "$repo_root/install.sh"
