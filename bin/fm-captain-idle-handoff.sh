#!/usr/bin/env bash
# Auto-capture a handoff when the captain returns after a long quiet stretch,
# or when the session is about to auto-compact, and tell them prominently to
# clear.
#
# WHY. When the captain resumes the main session after a gap longer than the
# model's prompt-cache lifetime, the whole accumulated conversation is rebuilt at
# full price instead of being re-read cheaply. Measured on 2026-08-20 from the
# main session's own transcripts: 18 such resumptions, 4.3M tokens of rebuild,
# averaging ~239k each; the worst was a 7.6h overnight gap costing 336,652
# rebuild tokens against 22,548 of cheap re-read. The lever is NOT keeping a
# large session warm - a keep-alive re-reads everything each time - it is making
# the thing that gets rebuilt SMALL. Capture a handoff, let the captain clear,
# and the next rebuild is the session-start block rather than a whole day of
# conversation. docs/captain-idle-handoff.md owns the full rationale, the signal
# choice, the threshold reasoning, and the harness matrix.
#
# WHAT THIS IS. A UserPromptSubmit hook. It observes only genuine captain input,
# so the idleness it measures is CAPTAIN idleness - the wall-clock gap between
# two consecutive things the captain actually typed - and never fleet idleness,
# which is a different quantity that a busy overnight fleet would keep resetting.
# The observation and the decision are the same event, so no extra timer, daemon,
# or watcher work exists to go stale.
#
# TWO CONDITIONS, ONE CAPTURE. The quiet stretch above is one reason to fire.
# The other is context fill: Claude Code auto-compacts the conversation into a
# lossy summary once it passes a threshold, so this hook also fires on the first
# genuine captain prompt past a point a configurable margin (default 5 points)
# before that threshold, once per climb, re-armed only when the fill drops after
# a compaction or a clear. bin/fm-context-fill-lib.sh owns how the fill, the
# window, and the compaction point are read, and why that signal was chosen.
# Both conditions share every output, filter, and limit below; only the reason
# line differs.
#
# WHAT IT DOES ON FIRE. Two outputs, both on this one invocation:
#   stdout - a directive the harness injects into the turn's context, telling the
#            agent to run the existing /handoff capture (the handoff skill, which
#            stays the single owner of what a handoff contains) before answering
#            the captain, then print the banner below with the real path.
#   stderr - the same banner, best-effort, so it is visible even if the directive
#            is dropped.
# The banner uses bin/fm-banner-lib.sh, the same shape as the turn-end
# supervision alarm, because "firstmate needs your attention" is one visual
# vocabulary and not one per feature.
#
# WHAT IT NEVER DOES. It never clears or compacts the session - the captain
# clears, this only captures and reminds. It never enters away mode: away mode is
# a declared mode, it never widens approval authority, and its escalations are
# injected into this same transcript, so it GROWS the very thing being rebuilt.
# (Away mode may still be entered on the captain's behalf by bin/fm-auto-afk.sh -
# a separate decision, on the same shared clock, that this hook neither makes nor
# depends on; while its flag is present this hook defers and, crucially, leaves
# the clock alone so the stretch is not lost.)
# It never blocks, fails, or delays a turn: every path exits 0, and if the banner
# cannot be printed the handoff still counts as delivered and the failure is
# logged rather than escalated. It touches no watcher, lock, wake-queue, or task
# state, so a live fleet under active supervision is unaffected.
#
# Usage: fm-captain-idle-handoff.sh   (hook entrypoint; reads the payload on stdin)
#        fm-captain-idle-handoff.sh --help
set -u

case "${1-}" in
  --help|-h)
    cat <<'USAGE'
fm-captain-idle-handoff.sh - UserPromptSubmit hook: auto-capture a handoff when
the captain returns after a long quiet stretch, or when the session is close to
auto-compacting, and remind them to clear.

Reads the harness UserPromptSubmit payload on stdin. Always exits 0.

Threshold (first match wins):
  FM_IDLE_HANDOFF_SECONDS   env override, seconds, or "off" to disable
  config/idle-handoff       first non-empty line: seconds, or "off" to disable
  14400                     built-in default (4 hours)

Context-fill margin, in percentage points before auto-compaction (first match wins):
  FM_CONTEXT_HANDOFF_MARGIN env override, points, or "off" to disable
  config/context-handoff    first non-empty line: points, or "off" to disable
  5                         built-in default
The compaction point is Claude Code's own: CLAUDE_AUTOCOMPACT_PCT_OVERRIDE when
set, else its default. The window comes from the transcript's model identity
("[1m]" = 1000000) or FM_CONTEXT_WINDOW_TOKENS; when neither settles it, or the
fire point lands at or below zero, the context condition does nothing.

State it owns, under the effective state dir:
  .last-captain-input       epoch of the last genuine captain prompt
  .captain-idle-handoff     epoch of the stretch a capture was already claimed for
  .captain-idle-handoff.log dated log of fires, skips, and banner-print failures
  .context-handoff          transcript, fill, and epoch of the climb already captured
  .context-handoff-model    cached model identity and bytes scanned per transcript

While away mode is active this defers to the away-mode return procedure and
leaves the clock alone, so a quiet stretch survives an away session - including
one armed automatically by bin/fm-auto-afk.sh - and is captured on the first
message after away mode clears.
USAGE
    exit 0
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

DEFAULT_THRESHOLD=14400
DEFAULT_CONTEXT_MARGIN=5

MARK="$STATE/.last-captain-input"
CLAIM="$STATE/.captain-idle-handoff"
LOG="$STATE/.captain-idle-handoff.log"
CTX_CLAIM="$STATE/.context-handoff"
CTX_MODEL_CACHE="$STATE/.context-handoff-model"

# shellcheck source=bin/fm-banner-lib.sh
. "$SCRIPT_DIR/fm-banner-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"
# shellcheck source=bin/fm-context-fill-lib.sh
. "$SCRIPT_DIR/fm-context-fill-lib.sh"

# The away-mode daemon's own sentinel. bin/fm-supervise-daemon.sh owns the
# injection contract; only the leading byte sequence is needed here, and it is
# the same U+2063 INVISIBLE SEPARATOR a captain cannot type.
FM_INJECT_MARK=$'\xE2\x81\xA3'

NOW=${FM_IDLE_HANDOFF_NOW:-$(date +%s)}

# note <event> <detail...>: append one dated line to the local log. Never fatal -
# an unwritable log must not cost the captain their reminder.
note() {
  local event=$1
  shift
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$event" "$*" >> "$LOG" 2>/dev/null || true
}

# read_epoch <file>: echo the file's first line when it is a plain epoch, else
# nothing. A corrupt record reads as absent, which is the no-fire direction.
read_epoch() {
  local value
  [ -f "$1" ] || return 1
  IFS= read -r value < "$1" 2>/dev/null || return 1
  case "$value" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$value"
}

# mark_now: record this prompt as the captain's most recent input.
mark_now() {
  printf '%s\n' "$NOW" > "$MARK" 2>/dev/null || note mark-write-failed "$MARK"
}

# --- scope ------------------------------------------------------------------
# The MAIN home only. fm_primary_scope_matches deliberately force-includes a
# secondmate's own home because a secondmate runs its own primary session, but a
# secondmate has no captain to remind and no long captain-facing thread to clear:
# its work arrives marked from the main firstmate and it idles in between. So a
# marked secondmate home is excluded here even though it is a real primary.
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
fm_root_is_secondmate_home "$FM_ROOT" && exit 0

# --- payload ----------------------------------------------------------------
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# jq is the repo's established JSON dependency, and the turn-end guard sets the
# precedent: without it, degrade to a silent no-op with no side effects rather
# than guessing at the payload. Guessing here would mean mistaking a daemon
# injection for captain input, which is exactly the distinction this hook exists
# to make.
command -v jq >/dev/null 2>&1 || exit 0
PROMPT=$(printf '%s' "$PAYLOAD" | jq -r '.prompt // empty' 2>/dev/null) || exit 0

# --- is this actually the captain? -------------------------------------------
# Two kinds of text arrive on this event without the captain typing anything.
# Neither may refresh the idleness clock, or a busy quiet stretch would look like
# an attentive captain.
#   - a leading bare U+2063 is the away-mode daemon's escalation injection.
#   - the from-firstmate marker is a supervisor relay (bin/fm-marker-lib.sh).
case "$PROMPT" in
  "$FM_INJECT_MARK"*) exit 0 ;;
esac
fm_message_from_firstmate "$PROMPT" && exit 0

# --- away mode ---------------------------------------------------------------
# Away mode owns the session while it is active, and its own return procedure
# owns the captain's first unmarked message. Adding a handoff directive on top of
# that would collide with a contract this hook does not own, so stay out of the
# way - for both conditions below.
#
# But do NOT advance the clock here, which this branch used to do. Away mode can
# now be armed on the captain's behalf after a short quiet stretch
# (bin/fm-auto-afk.sh, 30 minutes by default) rather than only by a captain who
# typed /afk, so marking here would let that short auto-arm silently swallow
# every quiet stretch this hook exists to capture: the captain's return message
# would land with away mode still up, the clock would jump to now, and a
# nine-hour gap would look like no gap at all. Preserving the stretch instead
# defers the capture to the first message after away mode clears - one message
# later than it used to arrive, and still measured against the real gap.
if [ -e "$STATE/.afk" ]; then
  note away-mode-deferred "stretch=$(read_epoch "$MARK" || printf none)"
  exit 0
fi

# --- condition 1: the captain was quiet for a long stretch --------------------
IDLE_FIRE=0
THRESHOLD_SRC=default
THRESHOLD=$DEFAULT_THRESHOLD
raw=${FM_IDLE_HANDOFF_SECONDS-}
if [ -n "$raw" ]; then
  THRESHOLD_SRC='env'
else
  if [ -f "$CONFIG/idle-handoff" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line=${line%%#*}
      line=$(printf '%s' "$line" | tr -d '[:space:]')
      [ -n "$line" ] || continue
      raw=$line
      THRESHOLD_SRC=config
      break
    done < "$CONFIG/idle-handoff"
  fi
fi
IDLE_ENABLED=1
case "$raw" in
  '') : ;;
  off|OFF|Off) IDLE_ENABLED=0 ;;
  *[!0-9]*|0)
    note bad-threshold "$THRESHOLD_SRC=$raw"
    THRESHOLD_SRC=default
    ;;
  *) THRESHOLD=$raw ;;
esac

# `off` disables this condition only, and - as before the context condition
# existed - leaves the clock exactly where it was.
if [ "$IDLE_ENABLED" = 1 ]; then
  if LAST=$(read_epoch "$MARK"); then
    IDLE=$((NOW - LAST))
    if [ "$IDLE" -lt "$THRESHOLD" ]; then
      mark_now
    else
      # Idempotence per quiet stretch: the claim records the epoch that OPENED
      # the stretch a capture was already taken for. The clock advancing on every
      # prompt would normally be enough, but a state dir that briefly refuses
      # writes would otherwise re-fire on the next prompt and nag.
      CLAIMED=$(read_epoch "$CLAIM") || CLAIMED=
      if [ "$CLAIMED" = "$LAST" ]; then
        note already-captured "stretch=$LAST idle=${IDLE}s"
        mark_now
      else
        IDLE_FIRE=1
      fi
    fi
  else
    # No previous captain input on record, so there is no measured quiet stretch
    # to act on. Start the clock and say nothing.
    mark_now
  fi
fi

# --- condition 2: the session is close to auto-compacting ---------------------
# bin/fm-context-fill-lib.sh owns how the fill, the window, and Claude Code's
# compaction point are read; this block owns the margin and the once-per-climb
# claim. The fire point is the compaction point less MARGIN percentage points of
# the same effective window CLAUDE_AUTOCOMPACT_PCT_OVERRIDE is measured against,
# so "45" with the default margin fires at 40.
#
# One capture per climb: CTX_CLAIM holds the transcript a capture was taken for.
# The fill only falls through a compaction (same transcript, much smaller
# reading) or a clear (a new transcript that starts small), so a reading below
# the fire point is exactly the drop that re-arms it. An unreadable fill or
# window changes nothing, including the claim.
CONTEXT_FIRE=0
context_condition() {
  local transcript margin_raw='' margin_src=default margin=$DEFAULT_CONTEXT_MARGIN line claimed=''
  command -v awk >/dev/null 2>&1 || return 0
  margin_raw=${FM_CONTEXT_HANDOFF_MARGIN-}
  if [ -n "$margin_raw" ]; then
    margin_src='env'
  elif [ -f "$CONFIG/context-handoff" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line=${line%%#*}
      line=$(printf '%s' "$line" | tr -d '[:space:]')
      [ -n "$line" ] || continue
      margin_raw=$line
      margin_src=config
      break
    done < "$CONFIG/context-handoff"
  fi
  case "$margin_raw" in
    '') : ;;
    off|OFF|Off) return 0 ;;
    *)
      if printf '%s' "$margin_raw" | grep -Eq '^[0-9]+(\.[0-9]+)?$' \
          && awk -v m="$margin_raw" 'BEGIN { exit !(m > 0 && m < 100) }'; then
        margin=$margin_raw
      else
        note bad-context-margin "$margin_src=$margin_raw"
        margin_src=default
      fi
      ;;
  esac

  transcript=$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // empty' 2>/dev/null) || return 0
  case "$transcript" in /*) : ;; *) return 0 ;; esac
  fm_context_model "$transcript" "$CTX_MODEL_CACHE" || true
  fm_context_window "$CTX_MODEL" || return 0
  fm_context_compact_point "$CTX_WINDOW" || return 0
  CTX_FIRE_AT=$(awk -v t="$CTX_COMPACT_AT" -v e="$CTX_EFFECTIVE" -v m="$margin" \
    'BEGIN { printf "%d", t - e * m / 100 }')
  if [ "$CTX_FIRE_AT" -le 0 ]; then
    note context-fire-point-nonpositive "compact_at=${CTX_COMPACT_AT} margin=${margin}($margin_src)"
    return 0
  fi
  fm_context_fill "$transcript" || return 0

  [ -f "$CTX_CLAIM" ] && IFS= read -r claimed < "$CTX_CLAIM" 2>/dev/null
  claimed=${claimed%%$'\t'*}
  if [ "$CTX_FILL" -lt "$CTX_FIRE_AT" ]; then
    if [ -n "$claimed" ]; then
      rm -f "$CTX_CLAIM" 2>/dev/null || note context-claim-clear-failed "$CTX_CLAIM"
      note context-rearmed "fill=${CTX_FILL}($CTX_FILL_SRC) fire_at=$CTX_FIRE_AT"
    fi
    return 0
  fi
  [ "$claimed" = "$transcript" ] && return 0
  CONTEXT_FIRE=1
  CTX_TRANSCRIPT=$transcript
  CTX_MARGIN=$margin
  CTX_MARGIN_SRC=$margin_src
}
context_condition

[ "$IDLE_FIRE" = 1 ] || [ "$CONTEXT_FIRE" = 1 ] || exit 0

# --- fire --------------------------------------------------------------------
# One capture covers both conditions: when both hold on the same prompt, the
# quiet stretch leads the wording and the climb is claimed too, so the next
# prompt does not capture again.
if [ "$IDLE_FIRE" = 1 ]; then
  printf '%s\n' "$LAST" > "$CLAIM" 2>/dev/null || note claim-write-failed "$CLAIM"
  note fired "stretch=$LAST idle=${IDLE}s threshold=${THRESHOLD}s($THRESHOLD_SRC)"
fi
if [ "$CONTEXT_FIRE" = 1 ]; then
  printf '%s\t%s\t%s\n' "$CTX_TRANSCRIPT" "$CTX_FILL" "$NOW" > "$CTX_CLAIM" 2>/dev/null \
    || note context-claim-write-failed "$CTX_CLAIM"
  note context-fired "fill=$CTX_FILL fire_at=$CTX_FIRE_AT compact_at=$CTX_COMPACT_AT" \
    "window=$CTX_WINDOW($CTX_WINDOW_SRC) pct=$CTX_PCT($CTX_PCT_SRC) margin=$CTX_MARGIN($CTX_MARGIN_SRC)" \
    "$([ "$IDLE_FIRE" = 1 ] && printf 'covered-by=idle')"
fi

# Percentages the captain sees are of the same effective window Claude Code's
# own compaction setting is written in, so "compacts at 45%" matches it.
FILL_PCT=
COMPACT_PCT=
if [ "$CONTEXT_FIRE" = 1 ]; then
  FILL_PCT=$(awk -v f="$CTX_FILL" -v e="$CTX_EFFECTIVE" 'BEGIN { printf "%d", f * 100 / e }')
  COMPACT_PCT=$(awk -v p="$CTX_PCT" 'BEGIN { printf "%d", p + 0.5 }')
fi

if [ "$IDLE_FIRE" = 1 ]; then
  HOURS=$((IDLE / 3600))
  MINUTES=$(((IDLE % 3600) / 60))
  if [ "$HOURS" -gt 0 ]; then
    AWAY_FOR="${HOURS}h ${MINUTES}m"
  else
    AWAY_FOR="${MINUTES}m"
  fi
  WHY="because the captain's previous message was $AWAY_FOR ago, past the ${THRESHOLD}s
quiet-stretch threshold."
else
  WHY="because this session's context is ${CTX_FILL} tokens, past the ${CTX_FIRE_AT}-token
fire point set ${CTX_MARGIN} points before auto-compaction at ${CTX_COMPACT_AT} tokens."
fi

# The banner is captain-facing text, so it follows AGENTS.md section 9: plain
# outcome language, none of firstmate's internal vocabulary. PATH_TOKEN is the
# one field this script cannot know - the handoff skill picks the document's
# dated slug - so the agent substitutes it after the capture lands.
PATH_TOKEN='{{HANDOFF_PATH}}'

banner() {
  fm_banner_rule
  fm_banner_line 'CLEAR BEFORE SESSION'
  if [ "$IDLE_FIRE" = 1 ]; then
    fm_banner_line 'You were away %s, so I saved a handoff of this session first.' "$AWAY_FOR"
  else
    fm_banner_line 'This session is %s%% full and compacts itself at %s%%, so I saved' "$FILL_PCT" "$COMPACT_PCT"
    fm_banner_line 'a handoff of it first.'
  fi
  fm_banner_line 'Read it before you clear if you want to check it: %s' "$PATH_TOKEN"
  if [ "$IDLE_FIRE" = 1 ]; then
    fm_banner_line 'Clearing now is cheap: the next session picks up from that short'
    fm_banner_line 'handoff instead of re-reading this whole conversation, which is'
    fm_banner_line 'where nearly all of the cost of a long gap goes.'
  else
    fm_banner_line 'Clearing now loses nothing: the next session picks up from that'
    fm_banner_line 'handoff instead of an automatic summary that drops detail.'
  fi
  fm_banner_rule
}

# Best-effort second copy of the reminder. If stderr is closed or unwritable the
# handoff still counts as delivered - log it, do not escalate it, and never let
# it change this script's exit status. The redirections are order-sensitive:
# `>&2` first points the banner's own output at the REAL stderr, and only then
# does `2>/dev/null` swallow whatever the failing write complains about.
banner >&2 2>/dev/null || note banner-stderr-failed "idle=${IDLE:-none}s fill=${CTX_FILL:-none}"

cat <<DIRECTIVE
[firstmate] bin/fm-captain-idle-handoff.sh, a tracked hook in this repo, fired
$WHY
Do this before answering their message:

1. Run the handoff capture now, unprompted: load the \`handoff\` skill and follow
   it exactly as a captain-invoked /handoff, writing to data/handoffs/ as usual.
2. Then print the block below to the captain VERBATIM, as your first output, with
   $PATH_TOKEN replaced by the real path of the handoff document you just wrote.
   Do not reword it, summarise it, or fold it into a sentence - the captain asked
   for this reminder to be impossible to miss.
3. Then answer their message normally.

Do NOT clear or compact anything yourself, and do NOT enter away mode. The
captain clears; you only captured and reminded. If the capture cannot be
completed, say so plainly in one line and carry on with their message - this is
not a blocker to escalate.

$(banner)
DIRECTIVE

# The clock advances even on a firing prompt, so the stretch this capture covers
# is closed and the next one is measured from here. With the quiet-stretch
# condition off, the clock stays exactly where it was, as it always has.
[ "$IDLE_ENABLED" = 1 ] && mark_now
exit 0
