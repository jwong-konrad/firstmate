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
# A VERDICT IS A DATED OBSERVATION, not a fact that stays true until something
# tells us otherwise. This is the load-bearing correction to the model this
# library shipped with, and docs/supervision-arming.md states it in full.
#
# The original model was "a record stays valid while its evidence is unchanged",
# keyed on the size:mtime signature of the task's .meta, .status, and .turn-ended
# files. That model needs the invalidation set to be COMPLETE, and it cannot be:
# a task moving from idle into an active validation run changes none of those
# three - the sparse-status contract means a validating worker writes no status
# line, its metadata does not change, and its turn-end marker need not fire for
# as long as the pipeline runs. Nor can any firstmate-side trigger close the gap,
# because firstmate is not the only cause of resumption: a worker can resume
# itself off a gate, and a captain may steer one directly in its own window
# (AGENTS.md section 1 rule 4). So a stale idle verdict survived exactly when the
# task had started progressing.
#
# What replaces it rests on what an idle verdict can honestly claim. It never
# means "nothing is happening"; it means "no evidence of activity was found at
# time T". Every source is a proxy with a blind spot, so that claim decays. Three
# rules follow, and only `idle` is bound by them - `progressing` is the fail-safe
# direction and costs nothing but an armed watcher:
#
#   FRESHNESS  an idle verdict is believed only while its own observation age is
#              under FM_PROGRESS_IDLE_TTL. Past that it reads as no record at
#              all, which is progressing. No trigger has to fire for this to
#              work, which is why completeness is no longer required.
#   EVIDENCE   an observation may CONCLUDE idle only from evidence that was live
#              when it was read. bin/fm-crew-state.sh reports its source; a
#              status-log reading is a stored artifact, so when the log's own
#              last write is older than the same horizon it is not evidence of
#              current state and is demoted at observation time
#              (fm_progress_source_evidence_live). Without this, re-observing a
#              task just re-reads the same stale log and records the same
#              confident wrong answer.
#   ONE JUDGE  every consumer judges a record through fm_progress_verdict_cached.
#              Consumers differ only in whether they may CREATE an observation
#              (the arm gate and the watcher may; the hooks may not), never in
#              how they judge one, so two consumers cannot return opposite
#              answers for the same record.
#
# The signature binding and the explicit invalidation on a steer both survive,
# demoted from correctness mechanism to LATENCY optimization: they shorten the
# window in the cases they do cover, and nothing now depends on them covering
# every case.

# Record format version. Bump when the field layout changes; an unrecognized
# version reads as no record at all, which is the safe (progressing) direction.
FM_PROGRESS_RECORD_VERSION=v1

# How long an `idle` observation is believed, in seconds. This is the freshness
# rule above, and it is the whole reason a resumed task cannot stay invisible:
# past this horizon the verdict simply stops being evidence and the task counts
# progressing again, with no trigger required.
#
# The cost is deliberate and bounded. A genuinely parked fleet re-observes once
# per horizon: the turn-end guard counts the expired task progressing, firstmate
# arms, the gate pays one reconcile per task, confirms the fleet is still parked,
# rewrites the records, and declines again - so the loop self-quenches and no
# watcher cycle runs. That buys back the failure this replaced, where monitoring
# stayed down for as long as the fleet stayed quiet on paper.
FM_PROGRESS_IDLE_TTL=${FM_PROGRESS_IDLE_TTL:-900}
case "$FM_PROGRESS_IDLE_TTL" in ''|*[!0-9]*) FM_PROGRESS_IDLE_TTL=900 ;; esac

# Absolute expiry for ANY verdict record, in seconds. With idle bounded by the
# horizon above, this now only bounds `progressing` records - the safe direction,
# which no consumer can be harmed by holding - and backstops a record whose
# timestamp is unusable. Keep it well above FM_PROGRESS_IDLE_TTL.
FM_PROGRESS_RECORD_TTL=${FM_PROGRESS_RECORD_TTL:-86400}
case "$FM_PROGRESS_RECORD_TTL" in ''|*[!0-9]*) FM_PROGRESS_RECORD_TTL=86400 ;; esac

# Age returned for a path with no usable mtime (absent, unreadable, or dated in
# the future). Large on purpose: an age check on evidence we cannot date must
# read as too old, never as fresh.
FM_PROGRESS_AGE_UNKNOWN=999999999

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

# Age in seconds of a path, from the same portable stat the signature uses.
# FM_PROGRESS_AGE_UNKNOWN whenever the path cannot be dated, including a future
# mtime: runtime state is untrusted input, and an undatable path must never be
# able to pass a freshness check.
fm_progress_path_age() {  # <path>
  local sig mtime age
  sig=$(fm_progress_stat_sig "$1")
  case "$sig" in
    *:*) mtime=${sig#*:} ;;
    *)   mtime='' ;;
  esac
  case "$mtime" in ''|*[!0-9]*) printf '%s' "$FM_PROGRESS_AGE_UNKNOWN"; return 0 ;; esac
  age=$(( $(date +%s) - mtime ))
  [ "$age" -ge 0 ] || age=$FM_PROGRESS_AGE_UNKNOWN
  printf '%s' "$age"
}

fm_progress_record_path() {  # <state-dir> <id>
  printf '%s/.progress-%s' "$1" "$2"
}

# The evidence signature a record is bound to: the status log on any append, the
# turn-end marker on any worker turn, the metadata on any respawn or re-point.
#
# This is an OPTIMIZATION, not the validity rule (see the header). A change here
# retires a verdict early, which is why a parked worker that writes a status line
# reverts to progressing immediately rather than waiting out the idle horizon.
# What it deliberately no longer claims is the converse - that an unchanged
# signature means an unchanged state. It does not: a worker moving into an active
# validation run touches none of these three files.
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

# Drop a task's verdict so it counts progressing again. Two callers: bin/fm-send.sh
# on a steer, because firstmate deliberately restarting work should not wait out
# the idle horizon; and bin/fm-teardown.sh in its main-task cleanup, where the
# whole task is going away and a leftover record must not outlive it (teardown
# clears a SECONDMATE's child records by path instead, since those live in
# another home's state dir).
#
# Neither call is load-bearing for correctness. A steer that never reached this
# function still self-corrects at the idle horizon, and a record left behind by a
# missed teardown expires on the absolute TTL.
fm_progress_record_invalidate() {  # <state-dir> <id>
  rm -f "$(fm_progress_record_path "$1" "$2")" 2>/dev/null || true
  return 0
}

# Read a task's cached verdict. Sets FM_PROGRESS_VERDICT (always) and
# FM_PROGRESS_TOKEN / FM_PROGRESS_DETAIL (only on a valid record).
# Returns 0 when the record is present, current, and believable; 1 otherwise -
# and on 1 the verdict is `progressing`, the fail-toward-alarming default.
#
# THE SINGLE JUDGE (header rule three). Every consumer - the Stop hook, the
# PreToolUse gate, the fleet guard, and the arm gate after its own reconcile -
# decides on this function's answer, so no two of them can read the same record
# and return opposite verdicts. A consumer that may create an observation
# reconciles on a miss and then comes back through here; it never acts on a raw
# reconcile result the cheap consumers would have judged differently.
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
  [ "$age" -ge 0 ] || return 1
  [ "$age" -lt "$FM_PROGRESS_RECORD_TTL" ] || return 1
  # The freshness rule (header rule one). An `idle` observation past its horizon
  # is no longer evidence that the task is still idle, so it reads as no record
  # at all rather than as silence. `progressing` is not bound here: it is the
  # fail-safe direction, already covered by the absolute TTL above.
  if [ "$verdict" = idle ] && [ "$age" -ge "$FM_PROGRESS_IDLE_TTL" ]; then
    return 1
  fi
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

# 0 when an `idle` reading from <source> rests on evidence that was itself live
# when bin/fm-crew-state.sh read it. The EVIDENCE rule (header rule two), and the
# half of the age bound that has to cover the fallback rather than the record.
#
# `run-step` and `pane` are live probes: crew-state queried the pipeline or the
# endpoint at reading time, so the reading is as current as the reading is.
# `status-log` is not - it is crew-state's last resort, a stored artifact whose
# newest line can be arbitrarily old, and the status contract makes old normal
# (a worker appends only supervisor-actionable events, so a task that resumed
# quietly leaves its last line in place indefinitely). An hours-old line was
# observed producing a confident `parked` for a task that was actually
# validating, and because that reading then fed the record, every automated view
# agreed on the wrong answer. Bounding only the record would not have helped:
# re-observing re-reads the same log and reproduces the same verdict.
#
# So a status-log reading older than the idle horizon is not evidence of current
# state at all. It is demoted to indeterminate, which resolves the way every
# indeterminate reading resolves - idle only if the endpoint is provably gone,
# otherwise progressing. `source: none` never reaches here: crew-state pairs it
# with `unknown`, which is already indeterminate.
#
# One known exception, accepted rather than fixed here: bin/fm-crew-state.sh
# emits `done` labelled `status-log` from a reading that is actually live and
# run-step-corroborated (the checks-green PR-monitoring case), so this rule
# demotes it once the status line ages past the horizon. The label fix belongs to
# crew-state and is filed as crewstate-source-provenance-taxonomy-s2; the bound
# that makes the gap acceptable is written up under "What it costs, deliberately"
# in docs/supervision-arming.md.
fm_progress_source_evidence_live() {  # <state-dir> <id> <source>
  local state=$1 id=$2 source=$3
  case "$source" in
    status-log) ;;
    *) return 0 ;;
  esac
  [ "$(fm_progress_path_age "$state/$id.status")" -lt "$FM_PROGRESS_IDLE_TTL" ]
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
  # The evidence rule, applied HERE rather than at read time, so a verdict this
  # library could not stand behind never reaches the record in the first place.
  if [ "$verdict" = idle ] && ! fm_progress_source_evidence_live "$state" "$id" "$source"; then
    verdict=indeterminate
    detail="$detail (stale $source evidence)"
  fi
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
