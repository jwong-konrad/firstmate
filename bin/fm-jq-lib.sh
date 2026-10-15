#!/usr/bin/env bash
# Sourced helper: defines a `jq` shell function that keeps unbounded payloads off the command line.
# A command line's total arguments are capped by ARG_MAX, so passing a large backlog or task list
# through `--arg`/`--argjson` fails with "Argument list too long" once it grows.
# Any `--arg` or `--argjson` value at or above FM_JQ_ARG_MAX_CHARS characters is written to a private
# temp file and handed to jq as `--rawfile`; an `--argjson` value is parsed back with `fromjson`
# under its original variable name, so filters and output are unchanged.
# Small values and every other jq option pass through untouched; stdin is never touched.
# Callers source this file and keep calling plain `jq`.

FM_JQ_ARG_MAX_CHARS=${FM_JQ_ARG_MAX_CHARS:-16384}

jq() {
  local -a pass=()
  local -a rewrites=()
  local tmp="" filter="" have_filter=0 rc a name value i f
  local -a args=("$@")
  local n=${#args[@]}
  i=0
  while [ "$i" -lt "$n" ]; do
    a=${args[$i]}
    case "$a" in
      --arg | --argjson)
        name=${args[$((i + 1))]-}
        value=${args[$((i + 2))]-}
        if [ "${#value}" -ge "$FM_JQ_ARG_MAX_CHARS" ]; then
          if [ -z "$tmp" ]; then tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-jq.XXXXXX") || return 1; fi
          f="$tmp/$name"
          printf '%s' "$value" > "$f" || { rm -rf "$tmp"; return 1; }
          pass+=(--rawfile "$name" "$f")
          [ "$a" = --argjson ] && rewrites+=("$name")
        else
          pass+=("$a" "$name" "$value")
        fi
        i=$((i + 3))
        ;;
      --slurpfile | --rawfile | --indent | --tab | -f | --from-file | -L | --seq)
        case "$a" in
          --tab | --seq) pass+=("$a"); i=$((i + 1)) ;;
          *) pass+=("$a" "${args[$((i + 1))]-}"); i=$((i + 2)) ;;
        esac
        ;;
      -*)
        pass+=("$a")
        i=$((i + 1))
        ;;
      *)
        if [ "$have_filter" = 0 ]; then
          filter=$a
          have_filter=1
        else
          pass+=("$a")
        fi
        i=$((i + 1))
        ;;
    esac
  done
  if [ "${#rewrites[@]}" -gt 0 ] && [ "$have_filter" = 1 ]; then
    local prefix=""
    for name in "${rewrites[@]}"; do
      prefix+="(\$$name | fromjson) as \$$name | "
    done
    filter="$prefix$filter"
  fi
  if [ "$have_filter" = 1 ]; then
    command jq ${pass[@]+"${pass[@]}"} "$filter"
  else
    command jq ${pass[@]+"${pass[@]}"}
  fi
  rc=$?
  [ -n "$tmp" ] && rm -rf "$tmp"
  return "$rc"
}
