#!/usr/bin/env bash

set -euo pipefail

(( $# == 0 )) || {
  echo "Usage: resolve_quattro_hyprland_instance.sh" >&2
  exit 2
}

resolved_instance=${HYPRLAND_INSTANCE_SIGNATURE:-}
if [[ -z $resolved_instance ]] || ! hyprctl monitors -j >/dev/null 2>&1; then
  hyprland_instances=$(env -u HYPRLAND_INSTANCE_SIGNATURE \
    hyprctl instances -j 2>/dev/null) || exit 1
  if [[ -n ${WAYLAND_DISPLAY:-} ]]; then
    resolved_instance=$(jq -er --arg socket "$WAYLAND_DISPLAY" '
      [.[] | select(.wl_socket == $socket)]
      | if length == 1 then .[0].instance else empty end
    ' <<<"$hyprland_instances") || exit 1
  else
    resolved_instance=$(jq -er '
      if length == 1 then .[0].instance else empty end
    ' <<<"$hyprland_instances") || exit 1
  fi
fi

HYPRLAND_INSTANCE_SIGNATURE=$resolved_instance hyprctl monitors -j \
  >/dev/null 2>&1 || exit 1
printf '%s\n' "$resolved_instance"
