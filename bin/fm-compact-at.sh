#!/usr/bin/env bash
# Firstmate-driven /compact for matching Claude workers, between their turns.
# Usage: fm-compact-at.sh <task-id>...
#
# WHY. Claude Code's own compaction knobs are process-wide, not per-model, so a
# cap injected for a Haiku worker would also cap a Sonnet reached by /model or a
# subagent (docs/haiku-autocompact-verification.md). The captain chose option B:
# firstmate watches a matching worker's context fill and sends it /compact itself.
#
# CONFIG. config/compact-at (LOCAL, gitignored), docs/configuration.md owns the
# schema: lines "<model-glob> <tokens>", matched against the task's recorded
# model= in state/<id>.meta. Absent file, absent/unset model, non-claude harness,
# or kind=secondmate means this script does nothing at all.
#
# CALLER. bin/fm-watch.sh calls it for each task whose turn-ended marker changed,
# so it acts only at a turn end and never mid-turn; one long turn can therefore
# overshoot the threshold. It is best-effort: every path exits 0.
#
# A /compact is sent only when ALL hold, each read deterministically:
#   - the fill, read from the worker's own transcript by bin/fm-context-fill-lib.sh,
#     is at or above the threshold (an unreadable fill does nothing);
#   - bin/fm-crew-state.sh reports neither working nor parked, so no validation
#     step or gate is active;
#   - the backend reports an empty composer and not a busy pane.
# Once per climb: state/.compact-at-<id> records the send and is removed only when
# a later read shows the fill below the threshold. Sends are logged to
# state/.compact-at.log.
#
# Test seams: FM_COMPACT_AT_SEND, FM_COMPACT_AT_CREW_STATE, FM_CLAUDE_PROJECTS_DIR.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CFG="$CONFIG/compact-at"
LOG="$STATE/.compact-at.log"
SEND="${FM_COMPACT_AT_SEND:-$SCRIPT_DIR/fm-send.sh}"
CREW_STATE="${FM_COMPACT_AT_CREW_STATE:-$SCRIPT_DIR/fm-crew-state.sh}"
PROJECTS_DIR="${FM_CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"

case "${1-}" in
  --help|-h) sed -n '2,/^set -u/p' "$0" | sed '$d'; exit 0 ;;
esac

[ -f "$CFG" ] || exit 0
[ "$#" -gt 0 ] || exit 0

# shellcheck source=bin/fm-context-fill-lib.sh
. "$SCRIPT_DIR/fm-context-fill-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" 2>/dev/null || true; }

meta_get() {  # <file> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}

# threshold_for <model>: print the token threshold of the first matching line.
threshold_for() {
  local model=$1 line glob tokens
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    case "$line" in ''|'#'*) continue ;; esac
    glob=${line%%[[:space:]]*}
    tokens=${line#"$glob"}
    tokens=${tokens#"${tokens%%[![:space:]]*}"}
    tokens=${tokens%"${tokens##*[![:space:]]}"}
    # shellcheck disable=SC2254  # the glob is the config's pattern, deliberately unquoted
    case "$model" in $glob) ;; *) continue ;; esac
    tokens=$(fm_context_tokens_value "$tokens") || continue
    printf '%s' "$tokens"
    return 0
  done < "$CFG"
  return 1
}

latest_transcript() {  # <worktree>
  local dir
  dir="$PROJECTS_DIR/$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')"
  # shellcheck disable=SC2012  # newest-by-mtime of this worktree's own transcripts
  ls -t "$dir"/*.jsonl 2>/dev/null | head -n 1
}

handle() {
  local id=$1 meta="$STATE/$1.meta" model thr wt tr marker="$STATE/.compact-at-$1" backend target cs comp busy
  [ -f "$meta" ] || return 0
  [ "$(meta_get "$meta" harness)" = claude ] || return 0
  [ "$(meta_get "$meta" kind)" != secondmate ] || return 0
  model=$(meta_get "$meta" model)
  case "$model" in ''|default) return 0 ;; esac
  thr=$(threshold_for "$model") || return 0
  wt=$(meta_get "$meta" worktree)
  [ -n "$wt" ] || return 0
  tr=$(latest_transcript "$wt")
  [ -n "$tr" ] || return 0
  fm_context_fill "$tr" || return 0
  if [ "$CTX_FILL" -lt "$thr" ]; then
    rm -f "$marker"
    return 0
  fi
  [ ! -e "$marker" ] || return 0
  cs=$("$CREW_STATE" "$id" 2>/dev/null | head -n 1)
  case "$cs" in
    'state: working'*|'state: parked'*) return 0 ;;
  esac
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$backend" ] && [ -n "$target" ] || return 0
  comp=$(fm_backend_composer_state "$backend" "$target")
  [ "$comp" = empty ] || return 0
  busy=$(fm_backend_busy_state "$backend" "$target")
  [ "$busy" != busy ] || return 0
  if "$SEND" "$id" /compact >/dev/null 2>&1; then
    : > "$marker"
    log "sent /compact to $id (model=$model fill=$CTX_FILL threshold=$thr)"
  else
    log "send failed for $id (model=$model fill=$CTX_FILL threshold=$thr); will retry next turn end"
  fi
}

for id in "$@"; do
  id=${id%.turn-ended}
  handle "$id" || true
done
exit 0
