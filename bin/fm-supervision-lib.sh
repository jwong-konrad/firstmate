# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/fm-supervision-lib.sh
#
# True exactly when a firstmate home has PROGRESSING work but no watcher has a
# fresh liveness beacon (state/.last-watcher-beat, touched every poll cycle,
# within the grace window). bin/fm-guard.sh uses this grace-based warning
# predicate directly; bin/fm-turnend-guard.sh uses the status fields here for its
# banner but performs its end-of-turn block decision with the live watcher lock
# check in bin/fm-wake-lib.sh.
#
# "Progressing" is deliberately narrower than "a state/<id>.meta exists": a
# deliberately parked fleet has runtime records but nothing a watcher could
# observe, and warning about it every turn is noise the guards used to produce.
# bin/fm-progress-lib.sh is the single owner of that predicate, including the
# fail-toward-alarming default that counts an unreadable or unrecorded task as
# progressing. The raw record count stays available as FM_SUP_IN_FLIGHT so a
# banner can still report how much metadata exists.

_fm_sup_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _fm_sup_lib_dir="."
# shellcheck source=bin/fm-progress-lib.sh
. "$_fm_sup_lib_dir/fm-progress-lib.sh"
unset _fm_sup_lib_dir

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of state/*.meta (tasks with a runtime record)
#   FM_SUP_PROGRESSING    how many of those are progressing (the alarm predicate)
#   FM_SUP_PROGRESS_DESC  short breakdown of the split, for banners
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} beat m age
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false

  fm_progress_count "$state"
  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh, tests) after sourcing.
  FM_SUP_IN_FLIGHT=$FM_PROGRESS_TASKS
  FM_SUP_PROGRESSING=$FM_PROGRESS_PROGRESSING
  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh, fm-turnend-guard.sh) after sourcing.
  FM_SUP_PROGRESS_DESC=$FM_PROGRESS_SUMMARY

  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      FM_SUP_BEACON_DESC="${age}s ago"
      [ "$age" -lt "$grace" ] && FM_SUP_WATCHER_FRESH=true
    else
      # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
      FM_SUP_BEACON_DESC=unknown
    fi
  fi

  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
  [ -s "$state/.wake-queue" ] && FM_SUP_QUEUE_PENDING=true
  return 0
}

# The reason tokens bin/fm-watch-arm.sh writes, split by what each one says about
# supervision's disposition. Every token the writer can emit must be classified by at
# least one list here; tests/fm-continuity-pretool-check.test.sh fails if the writer
# grows a token no list claims, so a new record type forces a decision instead of
# silently landing in whichever bucket the fallback happens to be.
#
# A token may appear in MORE than one list, because the reason alone does not always
# determine the disposition. unexpected-clean-exit is both FAILED and STANDDOWN, split
# by the successor field (successor=attached:<pid> is a hand-off, successor=none is a
# failure), and arm-interrupted is both FAILED and ATTACHED, split by origin. Do not
# "deduplicate" those entries: dropping either one silently changes the classification.
#
# DELIVERED - an owner arm read its child's output and confirmed a real wake.
# FAILED    - an owner arm closed without delivering anything: the arm tried and
#             failed, or its watcher died or was signalled. These deny.
# STANDDOWN - owner-origin bookkeeping about the arm's OWN observation ending while
#             a verified successor holds the lock (unexpected-clean-exit carrying
#             successor=attached:<pid>). It reports nothing about whether a wake was
#             delivered, so it neither opens nor closes the window.
# ATTACHED  - written by an arm that only attached to somebody else's watcher. Such
#             an arm never reads the watcher's output, so its rows are observer
#             bookkeeping too and are skipped by origin, not by reason.
# shellcheck disable=SC2034 # Read by tests to assert the writer emits nothing unclassified.
FM_SUPERVISION_REASONS_DELIVERED='actionable-signal actionable-stale actionable-check actionable-heartbeat'
# shellcheck disable=SC2034 # Read by tests to assert the writer emits nothing unclassified.
FM_SUPERVISION_REASONS_FAILED='confirmation-timeout nonzero-exit signal-exit arm-interrupted unexpected-clean-exit'
# shellcheck disable=SC2034 # Read by tests to assert the writer emits nothing unclassified.
FM_SUPERVISION_REASONS_STANDDOWN='unexpected-clean-exit'
# shellcheck disable=SC2034 # Read by tests to assert the writer emits nothing unclassified.
FM_SUPERVISION_REASONS_ATTACHED='attached-cycle-ended lock-replaced arm-interrupted'

# The other ledger literals the reader keys on, next to the reason vocabulary so the
# whole vocabulary stays in one registry: the origin an owner arm records (cycle_begin's
# started) versus an observer's (attached), and the two successor encodings the arm
# layer writes - attached:<pid>, which marks an owner's hand-off to a verified
# successor, and started:<pid>, which records a watcher this arm forked and is not a
# hand-off. The reader below is driven by these values, and the same drift test asserts
# they still match what bin/fm-watch-arm.sh writes - if origin or the successor encoding
# changed unnoticed, every genuine owner row would be skipped, the reader would report
# no servicing evidence, and the gate would deny always, which is exactly the
# 2026-08-05 deadlock this reader removed.
FM_SUPERVISION_ORIGIN_OWNER=started
# shellcheck disable=SC2034 # Read by tests to assert the writer's origins still match.
FM_SUPERVISION_ORIGIN_OBSERVER=attached
FM_SUPERVISION_SUCCESSOR_HANDOFF_PREFIX='attached:'
# shellcheck disable=SC2034 # Read by tests to assert the writer's successor encodings still match.
FM_SUPERVISION_SUCCESSOR_OWNED_PREFIX='started:'

# Age in seconds since the arm layer last recorded a watcher cycle, printed on
# stdout, but only when that MOST RECENT DISPOSITIVE cycle actually DELIVERED an
# actionable wake. Returns 1 and prints nothing otherwise.
#
# Only the newest dispositive record counts, because servicing evidence is a
# statement about the state supervision is in right now. A later close that failed,
# crashed, was signalled, or produced no wake supersedes the actionable close before
# it and must re-close the window immediately, rather than being masked by it until
# the older record ages out.
#
# Dispositive means the record reports supervision's disposition rather than one
# arm's own attachment. Every arm in a home appends to the same ledger, and only the
# arm that FORKED the watcher (origin=started) reads its output, so only an owner row
# can say whether a wake was delivered. A second arm merely attached to that watcher
# writes attached-cycle-ended or lock-replaced when its own observation ends; letting
# those supersede the owner's actionable close would shut the window seconds after a
# real wake, recreating the deadlock this gate exists to avoid.
#
# The watcher is intentionally one-shot, so every wake guarantees an interval with
# no lock holder. That interval is supervision working - it just handed control to
# firstmate - not supervision missing, and reading it as missing is what deadlocked
# recovery on 2026-08-05 (docs/supervision-deadlock-guard.md).
#
# bin/fm-watch-arm.sh remains the single owner of the ledger format and of which
# closes count actionable: it writes reason=actionable-* only after
# watch_output_has_wake confirmed a real wake reason, and writes the record before
# printing output and exiting. No other close reason can open the window, and a
# declined arm writes no record at all, so none of them can forge servicing
# evidence. This function only reads.
#
# The ledger is gitignored runtime state, so it is treated as untrusted input: an
# unparseable or future-dated timestamp reports "no servicing evidence" rather than
# an age a caller could read as fresh. Every rejection here lands on the safe side,
# which is the pre-existing deny.
#
# For the same reason the record is read FIELD-wise, not substring-wise: the reason
# and ended_at values are taken from their own tab-delimited fields, so a value
# carried in origin, successor, lock_before, or lock_after can never be read as
# servicing evidence or shift which timestamp is parsed. The arm layer strips tabs
# from every field it writes, which is what makes the field boundary structural.
fm_supervision_serviced_wake_age() {  # <state-dir>
  local log=$1/.watch-cycle-exits.log ended age
  [ -f "$log" ] || return 1
  # The ledger is size-capped by the arm layer, so a full scan is bounded.
  ended=$(awk -F '\t' \
    -v owner="$FM_SUPERVISION_ORIGIN_OWNER" \
    -v handoff="$FM_SUPERVISION_SUCCESSOR_HANDOFF_PREFIX" '
    NF {
      origin = ""; reason = ""; ended = ""; successor = ""
      for (i = 1; i <= NF; i++) {
        if (substr($i, 1, 7) == "origin=") origin = substr($i, 8)
        else if (substr($i, 1, 7) == "reason=") reason = substr($i, 8)
        else if (substr($i, 1, 9) == "ended_at=") ended = substr($i, 10)
        else if (substr($i, 1, 10) == "successor=") successor = substr($i, 11)
      }
      if (origin != owner) next
      if (reason == "unexpected-clean-exit" && substr(successor, 1, length(handoff)) == handoff) next
      last_reason = reason
      last_ended = ended
    }
    END {
      if (substr(last_reason, 1, 11) != "actionable-") exit 1
      print last_ended
    }
  ' "$log" 2>/dev/null) || return 1
  case "$ended" in ''|*[!0-9]*) return 1 ;; esac
  age=$(( $(date +%s) - ended ))
  [ "$age" -ge 0 ] || return 1
  printf '%s' "$age"
  return 0
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly in the dangerous state: progressing work exists and no
# watcher has a fresh beacon. Exit 1 (false) otherwise, including a fleet whose
# every task is deliberately parked, awaiting firstmate, failed, or gone.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_PROGRESSING" -gt 0 ] && [ "$FM_SUP_WATCHER_FRESH" = false ]
}
