#!/usr/bin/env bash
# Auto-capture a handoff when the captain returns after a long quiet stretch,
# and tell them prominently to clear.
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
the captain returns after a long quiet stretch, and remind them to clear.

Reads the harness UserPromptSubmit payload on stdin. Always exits 0.

Threshold (first match wins):
  FM_IDLE_HANDOFF_SECONDS   env override, seconds, or "off" to disable
  config/idle-handoff       first non-empty line: seconds, or "off" to disable
  14400                     built-in default (4 hours)

State it owns, under the effective state dir:
  .last-captain-input       epoch of the last genuine captain prompt
  .captain-idle-handoff     epoch of the stretch a capture was already claimed for
  .captain-idle-handoff.log dated log of fires, skips, and banner-print failures
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

MARK="$STATE/.last-captain-input"
CLAIM="$STATE/.captain-idle-handoff"
LOG="$STATE/.captain-idle-handoff.log"

# shellcheck source=bin/fm-banner-lib.sh
. "$SCRIPT_DIR/fm-banner-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"

# The away-mode daemon's own sentinel. bin/fm-supervise-daemon.sh owns the
# injection contract; only the leading byte sequence is needed here, and it is
# the same U+2063 INVISIBLE SEPARATOR a captain cannot type.
FM_INJECT_MARK=$'\xE2\x81\xA3'

NOW=${FM_IDLE_HANDOFF_NOW:-$(date +%s)}

# note <event> <detail>: append one dated line to the local log. Never fatal -
# an unwritable log must not cost the captain their reminder.
note() {
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$LOG" 2>/dev/null || true
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

# --- threshold ---------------------------------------------------------------
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
case "$raw" in
  '') : ;;
  off|OFF|Off) exit 0 ;;
  *[!0-9]*|0)
    note bad-threshold "$THRESHOLD_SRC=$raw"
    THRESHOLD_SRC=default
    ;;
  *) THRESHOLD=$raw ;;
esac

# --- measure -----------------------------------------------------------------
# Away mode owns the session while it is active, and its own return procedure
# owns the captain's first unmarked message. Adding a handoff directive on top of
# that would collide with a contract this hook does not own, so stay out of the
# way and only keep the clock honest.
if [ -e "$STATE/.afk" ]; then
  mark_now
  exit 0
fi

LAST=$(read_epoch "$MARK") || {
  # No previous captain input on record, so there is no measured quiet stretch to
  # act on. Start the clock and say nothing.
  mark_now
  exit 0
}

IDLE=$((NOW - LAST))
if [ "$IDLE" -lt "$THRESHOLD" ]; then
  mark_now
  exit 0
fi

# Idempotence per quiet stretch: the claim records the epoch that OPENED the
# stretch a capture was already taken for. The clock advancing on every prompt
# would normally be enough, but a state dir that briefly refuses writes would
# otherwise re-fire on the next prompt and nag.
CLAIMED=$(read_epoch "$CLAIM") || CLAIMED=
if [ "$CLAIMED" = "$LAST" ]; then
  note already-captured "stretch=$LAST idle=${IDLE}s"
  mark_now
  exit 0
fi

# --- fire --------------------------------------------------------------------
printf '%s\n' "$LAST" > "$CLAIM" 2>/dev/null || note claim-write-failed "$CLAIM"
note fired "stretch=$LAST idle=${IDLE}s threshold=${THRESHOLD}s($THRESHOLD_SRC)"

HOURS=$((IDLE / 3600))
MINUTES=$(((IDLE % 3600) / 60))
if [ "$HOURS" -gt 0 ]; then
  AWAY_FOR="${HOURS}h ${MINUTES}m"
else
  AWAY_FOR="${MINUTES}m"
fi

# The banner is captain-facing text, so it follows AGENTS.md section 9: plain
# outcome language, none of firstmate's internal vocabulary. PATH_TOKEN is the
# one field this script cannot know - the handoff skill picks the document's
# dated slug - so the agent substitutes it after the capture lands.
PATH_TOKEN='{{HANDOFF_PATH}}'

banner() {
  fm_banner_rule
  fm_banner_line 'CLEAR BEFORE SESSION'
  fm_banner_line 'You were away %s, so I saved a handoff of this session first.' "$AWAY_FOR"
  fm_banner_line 'Read it before you clear if you want to check it: %s' "$PATH_TOKEN"
  fm_banner_line 'Clearing now is cheap: the next session picks up from that short'
  fm_banner_line 'handoff instead of re-reading this whole conversation, which is'
  fm_banner_line 'where nearly all of the cost of a long gap goes.'
  fm_banner_rule
}

# Best-effort second copy of the reminder. If stderr is closed or unwritable the
# handoff still counts as delivered - log it, do not escalate it, and never let
# it change this script's exit status. The redirections are order-sensitive:
# `>&2` first points the banner's own output at the REAL stderr, and only then
# does `2>/dev/null` swallow whatever the failing write complains about.
banner >&2 2>/dev/null || note banner-stderr-failed "idle=${IDLE}s"

cat <<DIRECTIVE
[firstmate] bin/fm-captain-idle-handoff.sh, a tracked hook in this repo, fired
because the captain's previous message was $AWAY_FOR ago, past the ${THRESHOLD}s
quiet-stretch threshold. Do this before answering their message:

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
# is closed and the next one is measured from here.
mark_now
exit 0
