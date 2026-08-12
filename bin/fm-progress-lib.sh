# shellcheck shell=bash
# Shared "is this task progressing" predicate.
# Usage: . bin/fm-progress-lib.sh
#
# A task is PROGRESSING when its reconciled run-step state (bin/fm-crew-state.sh)
# says work advances on its own. A task is IDLE when it is parked at a gate,
# awaiting a decision firstmate owns, deliberately paused on an external wait,
# failed, finished, or provably gone - all states that change only when firstmate
# acts, so polling them is guaranteed waste. Pane presence and pane idleness are
# deliberately NOT inputs; treating them as signals is the root cause this
# predicate replaces (docs/supervision-arming.md).
#
# The mapping is asymmetric on purpose: a state must be POSITIVELY recognized as
# idle to count idle. An indeterminate state, and a task with no verdict record at
# all, both count progressing, so a new or unreadable task always keeps the
# turn-end alarm armed.
#
# Reconciliation is expensive (fm-crew-state.sh may make a bounded no-mistakes
# call per task), while the consumers - a Stop hook, a PreToolUse gate, the
# fleet guard - must stay cheap. So the two are split:
#   fm_progress_reconcile     authoritative, writes state/.progress-<id>
#   fm_progress_count         pure file reads over those records
# The arm decision and the watcher's wedge state-change check pay the reconcile
# where a delay is already acceptable; the hooks only ever read.
#
# A record stays valid only while its evidence is unchanged: it carries the
# size:mtime signature of the task's .meta, .status, and .turn-ended files plus a
# long absolute expiry. Any change invalidates it, which can only ever move a task
# from idle back to progressing, never the reverse.

# Record format version. Bump when the field layout changes; an unrecognized
# version reads as no record at all, which is the safe (progressing) direction.
FM_PROGRESS_RECORD_VERSION=v1

# Absolute expiry for a verdict record, in seconds. Long by design: a
# deliberately parked fleet should stay quiet for as long as it stays parked, and
# every real resumption path (a status append, a turn-end marker, a metadata
# rewrite, a steer) invalidates the record on its own. This is only the backstop
# against a record whose evidence somehow never changes.
FM_PROGRESS_RECORD_TTL=${FM_PROGRESS_RECORD_TTL:-86400}
case "$FM_PROGRESS_RECORD_TTL" in ''|*[!0-9]*) FM_PROGRESS_RECORD_TTL=86400 ;; esac

# The crew current-state reader. Overridable so tests can stub the reconciled
# verdict without a real worktree or no-mistakes install; the same override
# bin/fm-classify-lib.sh uses, so a test stubs one binary for both.
_FM_PROGRESS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_PROGRESS_LIB_DIR="."
FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$_FM_PROGRESS_LIB_DIR/fm-crew-state.sh}"

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_progress_stat_sig() {  # <path> -> "<size>:<mtime>" or "absent"
  local out
  if [ ! -e "$1" ]; then
    printf 'absent'
    return 0
  fi
  if [ "$(uname)" = Darwin ]; then
    out=$(stat -f '%z:%m' "$1" 2>/dev/null)
  else
    out=$(stat -c '%s:%Y' "$1" 2>/dev/null)
  fi
  printf '%s' "${out:-unreadable}"
}

fm_progress_record_path() {  # <state-dir> <id>
  printf '%s/.progress-%s' "$1" "$2"
}

# The evidence signature a record is bound to. Every file here changes when a
# task resumes work: the status log on any append, the turn-end marker on any
# worker turn, the metadata on any respawn or re-point.
fm_progress_signature() {  # <state-dir> <id>
  local state=$1 id=$2
  printf 'meta:%s|status:%s|turnend:%s' \
    "$(fm_progress_stat_sig "$state/$id.meta")" \
    "$(fm_progress_stat_sig "$state/$id.status")" \
    "$(fm_progress_stat_sig "$state/$id.turn-ended")"
}

# Strip tabs/newlines so a detail string cannot break the single-line record.
_fm_progress_clean() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-200
}

fm_progress_record_write() {  # <state-dir> <id> <verdict> <state-token> <detail>
  local state=$1 id=$2 verdict=$3 token=$4 detail=${5:-} path tmp
  [ -d "$state" ] || return 0
  path=$(fm_progress_record_path "$state" "$id")
  tmp="$path.tmp.$$"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$FM_PROGRESS_RECORD_VERSION" \
    "$(date +%s)" \
    "$verdict" \
    "$(fm_progress_signature "$state" "$id")" \
    "$(_fm_progress_clean "$token")" \
    "$(_fm_progress_clean "$detail")" > "$tmp" 2>/dev/null || return 0
  mv -f "$tmp" "$path" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

# Drop a task's verdict so it counts progressing again. Called wherever firstmate
# deliberately restarts work on a task (a steer, in bin/fm-send.sh). Teardown does
# not call this: it removes state/.progress-<id> alongside the task's other state
# files in bin/fm-teardown.sh, because by then the whole task is going away.
fm_progress_record_invalidate() {  # <state-dir> <id>
  rm -f "$(fm_progress_record_path "$1" "$2")" 2>/dev/null || true
  return 0
}

# Read a task's cached verdict. Sets FM_PROGRESS_VERDICT (always) and
# FM_PROGRESS_TOKEN / FM_PROGRESS_DETAIL (only on a valid record).
# Returns 0 when the record is present, current, and unexpired; 1 otherwise -
# and on 1 the verdict is `progressing`, the fail-toward-alarming default.
fm_progress_verdict_cached() {  # <state-dir> <id>
  local state=$1 id=$2 path line version stamp verdict signature token detail age
  FM_PROGRESS_VERDICT=progressing
  FM_PROGRESS_TOKEN=unrecorded
  FM_PROGRESS_DETAIL='no verdict recorded'
  path=$(fm_progress_record_path "$state" "$id")
  [ -f "$path" ] || return 1
  IFS= read -r line < "$path" 2>/dev/null || return 1
  IFS=$(printf '\t') read -r version stamp verdict signature token detail <<EOF
$line
EOF
  [ "$version" = "$FM_PROGRESS_RECORD_VERSION" ] || return 1
  case "$stamp" in ''|*[!0-9]*) return 1 ;; esac
  case "$verdict" in progressing|idle) ;; *) return 1 ;; esac
  [ "$signature" = "$(fm_progress_signature "$state" "$id")" ] || return 1
  age=$(( $(date +%s) - stamp ))
  [ "$age" -lt "$FM_PROGRESS_RECORD_TTL" ] || return 1
  FM_PROGRESS_VERDICT=$verdict
  FM_PROGRESS_TOKEN=${token:-unknown}
  FM_PROGRESS_DETAIL=$detail
  return 0
}

# Map a bin/fm-crew-state.sh state token onto a verdict. Prints one of:
#   progressing    work advances without firstmate acting
#   idle           positively recognized as changing only when firstmate acts
#   indeterminate  no confident reading; the caller resolves it, and every
#                  caller here resolves it toward progressing
# The single owner of this mapping. See docs/supervision-arming.md for why it is
# asymmetric.
fm_progress_token_verdict() {  # <state-token>
  case "$1" in
    working)                            printf 'progressing' ;;
    parked|blocked|paused|failed|done)  printf 'idle' ;;
    *)                                  printf 'indeterminate' ;;
  esac
}

# 0 when a task's endpoint is provably absent - the "dead" case that makes an
# `unknown` reading idle rather than indeterminate. Mirrors exactly the four
# absences bin/fm-crew-state.sh itself reports as unknown/none: missing metadata,
# a torn-down worktree, no recorded backend target, and an unreadable target.
# Only ever called on the reconcile path, so the bounded probe is never paid by
# a hook.
#
# This is the ONE path that can turn an indeterminate reading into `idle`, so the
# endpoint probe is fm_backend_target_exists - the purpose-built existence
# predicate, which for tmux is the same `display-message -p` read that
# fm-crew-state.sh's pane_readable performs. No expected-label argument is
# passed: a label mismatch is a naming disagreement, not an absence. When the
# predicate is not in scope at all, the reading stays indeterminate (return 1),
# because a missing probe is not evidence of a dead endpoint.
fm_progress_endpoint_gone() {  # <state-dir> <id>
  local state=$1 id=$2 meta worktree backend target
  meta="$state/$id.meta"
  [ -f "$meta" ] || return 0
  command -v fm_backend_target_of_meta >/dev/null 2>&1 || return 1
  command -v fm_backend_target_exists >/dev/null 2>&1 || return 1
  worktree=$(fm_meta_get "$meta" worktree)
  [ -z "$worktree" ] || [ -d "$worktree" ] || return 0
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || return 0
  backend=$(fm_backend_of_meta "$meta")
  fm_backend_target_exists "$backend" "$target" >/dev/null 2>&1 || return 0
  return 1
}

# Authoritative reconcile for one task: read bin/fm-crew-state.sh, map its state
# token, resolve an indeterminate reading against endpoint absence, persist the
# verdict, and print it. Sets FM_PROGRESS_VERDICT / FM_PROGRESS_TOKEN /
# FM_PROGRESS_DETAIL the same way the cached read does.
#
# Expensive by design (see the header). Callers that can tolerate a stale answer
# should call fm_progress_verdict_cached first and reconcile only on a miss.
# The reading half of the reconcile: everything except persisting the record.
# Split out so a caller that runs the reconcile under its own wall-clock bound
# (the arm gate) can persist the verdict itself, once, from a call it saw
# complete - a killed reconcile must never leave a record behind.
fm_progress_reconcile_read() {  # <state-dir> <id>
  local state=$1 id=$2 line token source detail verdict
  FM_PROGRESS_TOKEN=unknown
  FM_PROGRESS_DETAIL=''
  line=$("$FM_CREW_STATE_BIN" "$id" 2>/dev/null) || true
  case "$line" in
    state:*)
      token=${line#state: }
      token=${token%% *}
      detail=$line
      case "$line" in
        *'source: '*) source=${line#*source: }; source=${source%% *} ;;
        *)            source=none ;;
      esac
      ;;
    *)
      token=unknown
      source=none
      detail='crew state unreadable'
      ;;
  esac
  # shellcheck disable=SC2034 # Read by callers (fm-watch.sh) after sourcing.
  FM_PROGRESS_SOURCE=$source
  verdict=$(fm_progress_token_verdict "$token")
  if [ "$verdict" = indeterminate ]; then
    if fm_progress_endpoint_gone "$state" "$id"; then
      verdict=idle
      detail="$detail (endpoint gone)"
    else
      verdict=progressing
    fi
  fi
  FM_PROGRESS_VERDICT=$verdict
  # shellcheck disable=SC2034 # Read by callers (fm-watch-arm.sh, fm-watch.sh) after sourcing.
  FM_PROGRESS_TOKEN=$token
  # shellcheck disable=SC2034 # Read by callers after sourcing.
  FM_PROGRESS_DETAIL=$detail
  printf '%s' "$verdict"
}

fm_progress_reconcile() {  # <state-dir> <id>
  fm_progress_reconcile_read "$1" "$2" >/dev/null
  fm_progress_record_write "$1" "$2" "$FM_PROGRESS_VERDICT" "$FM_PROGRESS_TOKEN" "$FM_PROGRESS_DETAIL"
  printf '%s' "$FM_PROGRESS_VERDICT"
}

# Cheap fleet count over cached records. Populates:
#   FM_PROGRESS_TASKS        number of state/<id>.meta files
#   FM_PROGRESS_PROGRESSING  how many of them count progressing
#   FM_PROGRESS_UNRECORDED   how many had no valid record (all counted progressing)
#   FM_PROGRESS_SUMMARY      short human-readable breakdown for a banner
# Pure file reads: safe for a Stop hook or a PreToolUse gate. Always returns 0.
fm_progress_count() {  # <state-dir>
  local state=$1 meta id idle=0
  FM_PROGRESS_TASKS=0
  FM_PROGRESS_PROGRESSING=0
  FM_PROGRESS_UNRECORDED=0
  FM_PROGRESS_SUMMARY='no tasks'
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    FM_PROGRESS_TASKS=$((FM_PROGRESS_TASKS + 1))
    if fm_progress_verdict_cached "$state" "$id"; then
      if [ "$FM_PROGRESS_VERDICT" = idle ]; then
        idle=$((idle + 1))
        continue
      fi
    else
      FM_PROGRESS_UNRECORDED=$((FM_PROGRESS_UNRECORDED + 1))
    fi
    FM_PROGRESS_PROGRESSING=$((FM_PROGRESS_PROGRESSING + 1))
  done
  if [ "$FM_PROGRESS_TASKS" -gt 0 ]; then
    # shellcheck disable=SC2034 # Read by callers (fm-supervision-lib.sh) after sourcing.
    FM_PROGRESS_SUMMARY="$FM_PROGRESS_PROGRESSING progressing, $idle idle of $FM_PROGRESS_TASKS"
  fi
  return 0
}

# 0 when the home has something a monitoring cycle could actually observe, beyond
# progressing tasks: an armed per-task poll (a merge watch, the X-mode relay) or a
# durable pending-reply expectation the watcher must tick. Cheap: directory reads
# only. Kept separate from the task count so a home with zero tasks but a live
# merge poll still arms.
fm_progress_has_pollable_work() {  # <state-dir>
  local state=$1 f
  for f in "$state"/*.check.sh; do
    [ -e "$f" ] && return 0
  done
  for f in "$state"/pending-replies/*; do
    [ -e "$f" ] && return 0
  done
  return 1
}
