#!/usr/bin/env bash

set -euo pipefail

(( $# == 1 )) || {
  echo "Usage: verify_quattro_session_unlocked.sh USER_ID" >&2
  exit 2
}

user_id=$1
[[ $user_id =~ ^[0-9]+$ ]] || {
  echo "verify_quattro_session_unlocked: invalid user ID" >&2
  exit 2
}
helper_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

display_session=$(loginctl show-user "$user_id" -p Display --value \
  2>/dev/null) || exit 1
[[ -n $display_session ]] || exit 1
[[ $(loginctl show-session "$display_session" -p Type --value \
  2>/dev/null) == "wayland" ]] || exit 1
[[ $(loginctl show-session "$display_session" -p Active --value \
  2>/dev/null) == "yes" ]] || exit 1
[[ $(loginctl show-session "$display_session" -p LockedHint --value \
  2>/dev/null) == "no" ]] || exit 1

HYPRLAND_INSTANCE_SIGNATURE=$(bash \
  "$helper_dir/resolve_quattro_hyprland_instance.sh") || exit 1
export HYPRLAND_INSTANCE_SIGNATURE

if omarchy-hyprland-session-locked >/dev/null 2>&1; then
  exit 1
else
  compositor_lock_status=$?
fi
(( compositor_lock_status == 1 )) || exit 1

lock_state=$(OMARCHY_SHELL_IPC_TIMEOUT=1s omarchy-shell lock status \
  2>/dev/null) || exit 1
jq -e '
  .locked == false
  and .requested == false
  and .pending == false
  and .sessionLocked == false
  and .secure == false
' <<<"$lock_state" >/dev/null
