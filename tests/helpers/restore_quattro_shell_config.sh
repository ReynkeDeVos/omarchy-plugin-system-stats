#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  restore_quattro_shell_config.sh --assert-clean CONFIG TARGET_ID PROBE_ID
  restore_quattro_shell_config.sh --matches LAST_GATE CURRENT TARGET_ID PROBE_ID
  restore_quattro_shell_config.sh --restore LAST_GATE CURRENT OUTPUT TARGET_ID PROBE_ID
USAGE
  exit 2
}

owned_projection() {
  local config=$1
  local target_id=$2
  local probe_id=$3
  jq -ceS --arg target "$target_id" --arg probe "$probe_id" '
    def acceptance_id:
      . == $target or . == $probe;
    def plugin_id:
      if type == "string" then .
      elif type == "object" then (.id? // "")
      else ""
      end;
    {
      plugins: [
        (.plugins? // [])[]
        | select((plugin_id | acceptance_id))
      ],
      layout: [
        ((.bar?.layout? // {}) | to_entries[]) as $section
        | $section.value[]?
        | select(type == "object")
        | select((.id? // "") | acceptance_id)
        | {section: $section.key, entry: .}
      ]
    }
  ' "$config"
}

validate_config() {
  local config=$1
  [[ -f $config ]] || {
    echo "restore_quattro_shell_config: missing JSON file: $config" >&2
    return 1
  }
  jq -e 'type == "object"' "$config" >/dev/null || {
    echo "restore_quattro_shell_config: invalid shell configuration: $config" >&2
    return 1
  }
}

mode=${1:-}
case "$mode" in
  --assert-clean)
    (( $# == 4 )) || usage
    validate_config "$2"
    projection=$(owned_projection "$2" "$3" "$4")
    [[ $projection == '{"layout":[],"plugins":[]}' ]] || {
      echo "restore_quattro_shell_config: config already contains acceptance-owned entries" >&2
      exit 3
    }
    ;;
  --matches)
    (( $# == 5 )) || usage
    validate_config "$2"
    validate_config "$3"
    last_projection=$(owned_projection "$2" "$4" "$5")
    current_projection=$(owned_projection "$3" "$4" "$5")
    [[ $current_projection == "$last_projection" ]] || {
      echo "restore_quattro_shell_config: acceptance-owned entries changed concurrently" >&2
      exit 3
    }
    ;;
  --restore)
    (( $# == 6 )) || usage
    last_gate=$2
    current=$3
    output=$4
    target_id=$5
    probe_id=$6
    validate_config "$last_gate"
    validate_config "$current"
    last_projection=$(owned_projection "$last_gate" "$target_id" "$probe_id")
    current_projection=$(owned_projection "$current" "$target_id" "$probe_id")
    [[ $current_projection == "$last_projection" ]] || {
      echo "restore_quattro_shell_config: acceptance-owned entries changed concurrently" >&2
      exit 3
    }
    output_dir=$(dirname -- "$output")
    [[ -d $output_dir ]] || {
      echo "restore_quattro_shell_config: output directory does not exist: $output_dir" >&2
      exit 1
    }
    output_tmp=$(mktemp "$output_dir/.restore-shell.XXXXXXXX")
    trap 'rm -f -- "$output_tmp"' EXIT
    jq --arg target "$target_id" --arg probe "$probe_id" '
      def acceptance_id:
        . == $target or . == $probe;
      def plugin_id:
        if type == "string" then .
        elif type == "object" then (.id? // "")
        else ""
        end;
      if (.plugins? | type) == "array" then
        .plugins |= map(select(((plugin_id | acceptance_id) | not)))
      else
        .
      end
      | if (.bar?.layout? | type) == "object" then
          .bar.layout |= with_entries(
            if (.value | type) == "array" then
              .value |= map(
                select(
                  (type != "object")
                  or (((.id? // "") | acceptance_id) | not)
                )
              )
            else
              .
            end
          )
        else
          .
        end
    ' "$current" >"$output_tmp"
    chmod --reference="$current" "$output_tmp"
    mv -f -- "$output_tmp" "$output"
    trap - EXIT
    ;;
  *)
    usage
    ;;
esac
