# shellcheck shell=bash
# Shared worker write-boundary mechanics for claude scout launches.
# Usage: . bin/fm-sandbox-lib.sh
#
# docs/configuration.md "Worker permission posture and captain-present override"
# owns the posture and override contract; this library owns the exact settings
# block that implements it, so bin/fm-spawn.sh (fresh spawn) and
# bin/fm-sandbox-settings.sh (relaunch or resume in an existing worktree) write
# byte-identical settings from one place.
#
# The boundary has two halves, both written into the worktree's
# .claude/settings.local.json, which fm-spawn already owns for the turn-end hook:
#   1. Claude Code's built-in OS sandbox (macOS Seatbelt) confines every shell
#      command and its child processes to the working directory plus
#      sandbox.filesystem.allowWrite. allowUnsandboxedCommands=false removes the
#      per-command dangerouslyDisableSandbox retry, which otherwise runs
#      unsandboxed with no prompt under --dangerously-skip-permissions.
#      enableWeakerNetworkIsolation=true opens only the macOS trust service so
#      gh can verify TLS; without it every gh call fails certificate checks.
#   2. The sandbox does not cover Claude's own file tools, so a PreToolUse hook
#      (bin/fm-sandbox-guard.sh) refuses an Edit, Write, MultiEdit, or
#      NotebookEdit whose target resolves outside the same write set.
# Hooks run outside the sandbox, so the turn-end hook and the guard keep working.
#
# Postures (recorded as sandbox= in state/<id>.meta):
#   on                   kind=scout on a claude harness: both halves written
#   override             kind=scout on claude, captain-present override: neither half
#   off                  kind=ship: unsandboxed until the ship-task spike decides
#   off-tester           kind=tester: deliberately unsandboxed, QA against the
#                        project's own stage and local apps needs a full browser
#   unsupported-harness  kind=scout on a non-claude harness: no verified mechanism
# A secondmate launch has no posture and no sandbox= field.

# fm_sandbox_posture <harness> <kind> <override:0|1>
fm_sandbox_posture() {
  local harness=$1 kind=$2 override=$3
  case "$kind" in
    scout) ;;
    tester) printf 'off-tester\n'; return 0 ;;
    *) printf 'off\n'; return 0 ;;
  esac
  case "$harness" in
    claude*) ;;
    *) printf 'unsupported-harness\n'; return 0 ;;
  esac
  if [ "$override" = 1 ]; then
    printf 'override\n'
  else
    printf 'on\n'
  fi
}

# fm_sandbox_override_refusal <state-dir>: prints the refusal and returns 1 when
# away mode forbids the captain-present override; returns 0 silently otherwise.
fm_sandbox_override_refusal() {
  local state=$1
  [ -e "$state/.afk" ] || return 0
  echo "error: --captain-present-override refused: away mode is active ($state/.afk exists); the override needs the captain on deck, so nothing was launched" >&2
  return 1
}

# fm_sandbox_resolve_path <absolute-path>: the physical path a write to <path>
# would land on, following symlinks and resolving .. against the real
# filesystem. A missing tail is appended verbatim. Fails (returns 1) when the
# path cannot be resolved safely: a relative path, a symlink loop, a dangling
# symlink component, or a . or .. inside the missing tail.
fm_sandbox_resolve_path() {
  local p=$1 hops=0 link dir rest base
  case "$p" in /*) ;; *) return 1 ;; esac
  while [ "$p" != / ] && [ "${p%/}" != "$p" ]; do p=${p%/}; done
  while [ -L "$p" ]; do
    hops=$((hops + 1))
    [ "$hops" -le 40 ] || return 1
    link=$(readlink "$p") || return 1
    case "$link" in
      /*) p=$link ;;
      *) p="${p%/*}/$link" ;;
    esac
    while [ "$p" != / ] && [ "${p%/}" != "$p" ]; do p=${p%/}; done
  done
  dir=$p
  rest=
  while [ ! -d "$dir" ]; do
    [ ! -L "$dir" ] || return 1
    base=${dir##*/}
    case "$base" in
      .|..) return 1 ;;
      '') ;;
      *) rest="/$base$rest" ;;
    esac
    dir=${dir%/*}
    [ -n "$dir" ] || dir=/
  done
  dir=$(cd -P -- "$dir" 2>/dev/null && pwd -P) || return 1
  if [ "$dir" = / ]; then
    printf '%s\n' "${rest:-/}"
  else
    printf '%s%s\n' "$dir" "$rest"
  fi
}

# fm_sandbox_write_paths <state-dir> <data-dir> <task-id> <task-tmp>: create the
# task's declared out-of-worktree write targets and print their physical paths,
# one per line: status file, turn-ended file, data/<id>/, task temp root.
# The two state files are pre-created because the sandbox honours a single-file
# allowWrite entry only when the file already exists (verified, Claude Code
# 2.1.296: a not-yet-existing entry stays "operation not permitted").
fm_sandbox_write_paths() {
  local state=$1 data=$2 id=$3 tasktmp=$4 p
  mkdir -p "$state" "$data/$id" "$tasktmp" || return 1
  touch "$state/$id.status" "$state/$id.turn-ended" || return 1
  for p in "$state/$id.status" "$state/$id.turn-ended" "$data/$id" "$tasktmp"; do
    fm_sandbox_resolve_path "$p" || return 1
  done
}

# fm_sandbox_claude_tmp: the per-user temp root Claude Code's sandbox itself
# sets as TMPDIR and keeps writable (verified, Claude Code 2.1.296). The guard
# mirrors it so the file tools may write where shell commands already can.
fm_sandbox_claude_tmp() {
  fm_sandbox_resolve_path "/tmp/claude-$(id -u)"
}

fm_sandbox_json_string() {
  printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

fm_sandbox_shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# fm_sandbox_claude_settings <posture> <turn-ended> <guard-script> <worktree> [<write-path>...]
# Prints the complete .claude/settings.local.json body. Every posture except
# "on" prints exactly the turn-end-only block every claude worker has always
# had; "on" adds the PreToolUse guard and the sandbox block, with allowWrite set
# to exactly the given write paths.
fm_sandbox_claude_settings() {
  local posture=$1 turnend=$2 guard=$3 wt=$4 stop guard_cmd p allow sep claude_tmp
  shift 4
  stop="{\"hooks\":[{\"type\":\"command\",\"command\":$(fm_sandbox_json_string "touch $(fm_sandbox_shell_quote "$turnend")")}]}"
  if [ "$posture" != on ]; then
    printf '{"hooks":{"Stop":[%s]}}\n' "$stop"
    return 0
  fi
  guard_cmd="bash $(fm_sandbox_shell_quote "$guard") $(fm_sandbox_shell_quote "$wt")"
  allow=
  sep=
  for p in "$@"; do
    guard_cmd="$guard_cmd $(fm_sandbox_shell_quote "$p")"
    allow="$allow$sep$(fm_sandbox_json_string "$p")"
    sep=,
  done
  claude_tmp=$(fm_sandbox_claude_tmp) || claude_tmp=
  [ -z "$claude_tmp" ] || guard_cmd="$guard_cmd $(fm_sandbox_shell_quote "$claude_tmp")"
  printf '{"hooks":{"Stop":[%s],"PreToolUse":[{"matcher":"Edit|Write|MultiEdit|NotebookEdit","hooks":[{"type":"command","command":%s}]}]},"sandbox":{"enabled":true,"allowUnsandboxedCommands":false,"enableWeakerNetworkIsolation":true,"filesystem":{"allowWrite":[%s]}}}\n' \
    "$stop" "$(fm_sandbox_json_string "$guard_cmd")" "$allow"
}

# fm_sandbox_install_claude_settings <posture> <worktree> <state-dir> <data-dir> <task-id> <task-tmp> <guard-script>
# Writes <worktree>/.claude/settings.local.json for <posture>, replacing it
# atomically. For posture "on" it first creates the declared write targets so
# the sandbox honours them. The file is regenerated whole rather than merged:
# it is firstmate-owned and inside the worker's own writable copy, so carrying
# forward its old contents would carry forward anything a worker added to it.
fm_sandbox_install_claude_settings() {
  local posture=$1 wt=$2 state=$3 data=$4 id=$5 tasktmp=$6 guard=$7 turnend tmp p
  local -a paths=()
  mkdir -p "$wt/.claude" "$state" || return 1
  turnend="$(cd -P -- "$state" && pwd -P)/$id.turn-ended" || return 1
  if [ "$posture" = on ]; then
    while IFS= read -r p; do paths+=("$p"); done < <(fm_sandbox_write_paths "$state" "$data" "$id" "$tasktmp")
    [ "${#paths[@]}" -eq 4 ] || { echo "error: could not prepare the sandbox write paths for $id" >&2; return 1; }
  fi
  tmp=$(mktemp "$wt/.claude/.settings.local.json.XXXXXX") || return 1
  if fm_sandbox_claude_settings "$posture" "$turnend" "$guard" "$wt" "${paths[@]+"${paths[@]}"}" > "$tmp" \
     && mv -f "$tmp" "$wt/.claude/settings.local.json"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}
