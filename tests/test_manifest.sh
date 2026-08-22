#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

omarchy plugin validate "$repo_root"

jq -e '
  .id == "reynkedevos.system-stats"
  and .name == "System Stats"
  and .version == "0.4.0"
  and .kinds == ["service", "bar-widget"]
  and .entryPoints.service == "Service.qml"
  and .entryPoints.barWidget == "BarWidget.qml"
  and .barWidget.defaults.ramDisplayFormat == "percent"
  and .barWidget.defaults.gpuSelection == {"mode":"auto", "configRevision":0}
  and (.barWidget.schema | any(
    .key == "ramDisplayFormat"
    and .type == "enum"
    and .options == ["percent", "gib"]
    and .defaultValue == "percent"
  ))
' "$repo_root/manifest.json" >/dev/null

test -x "$repo_root/bin/system-stats-helper"
test ! -e "$repo_root/install.sh"
