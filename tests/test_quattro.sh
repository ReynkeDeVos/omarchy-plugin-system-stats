#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
plugin_id="reynkedevos.system-stats"
compatibility_doc="$repo_root/docs/quattro-compatibility.md"
live_gate="$repo_root/tests/accept_quattro_live.sh"

jq -e '.barWidget.defaultSection == "right"' "$repo_root/manifest.json" >/dev/null

for section in left center right; do
  grep -Fq "omarchy plugin enable $plugin_id --section $section" \
    "$repo_root/README.md"
done

grep -Fq "omarchy bar move $plugin_id --section left" "$repo_root/README.md"

if grep -Fq -- "--section tray" "$repo_root/README.md"; then
  echo "the tray drawer must not be documented as a widget placement target" >&2
  exit 1
fi

grep -Fq 'Validated target: **Omarchy 4.0.0-1**' "$compatibility_doc"
grep -Fq 'Quickshell 0.3.0 (revision 28771c7c74b42e20afca0b1b63980cb46515537c)' \
  "$compatibility_doc"
grep -Fq '## Limits on other versions' "$compatibility_doc"
grep -Fq 'bash tests/accept_quattro_live.sh --real-suspend' "$compatibility_doc"
grep -Fq "does not replace ADR-0001's separate" "$compatibility_doc"

live_help=$(bash "$live_gate" --help)
grep -Fq 'Usage: tests/accept_quattro_live.sh [--real-suspend]' <<<"$live_help"
grep -Fq 'restores the original shell configuration' <<<"$live_help"
grep -Fq 'export OMARCHY_SHELL_IPC_TIMEOUT="${OMARCHY_SHELL_IPC_TIMEOUT:-10s}"' \
  "$live_gate"
grep -Fq 'hyprctl instances -j' "$live_gate"

test ! -e "$repo_root/install.sh"
jq -e 'has("install") | not' "$repo_root/manifest.json" >/dev/null
if rg -n '\b(sudo|pkexec|pacman|yay|paru|setcap|sysctl|usermod|groupmod|chmod|chown|capset|setgroups)\b|/proc/sys' \
    "$repo_root/Service.qml" "$repo_root/BarWidget.qml" "$repo_root/src"; then
  echo "runtime sources must not perform privileged system changes" >&2
  exit 1
fi
