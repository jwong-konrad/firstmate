#!/usr/bin/env bash
# Auto-arm away mode when the captain has been quiet past a configured stretch.
#
# WHY. Away mode is already the right tool for a captain-quiet stretch: its
# daemon self-handles routine wakes in bash and batches captain-relevant events
# into one digest instead of spending a firstmate turn per wake. But it only ever
# armed when the captain typed /afk before walking away, which is exactly the
# moment they do not. On 2026-09-16 one session spent 26 monitoring cycles
# re-arming supervision overnight for a fleet parked entirely on the captain,
# every one of them guaranteed to report "unchanged" before it ran. This closes
# that gap by noticing the quiet stretch itself.
#
# ONE CLOCK, TWO THRESHOLDS. This does NOT introduce a second notion of captain
# idleness. It reads the same state/.last-captain-input record that
# bin/fm-captain-idle-handoff.sh writes - the epoch of the last GENUINE captain
# prompt, already excluding away-mode daemon injections and supervisor relays,
# which is the subtle half of the problem and is solved there. Two detectors that
# could disagree about whether the captain is present would be worse than
# neither, so this one owns no clock of its own and never writes that record.
# docs/captain-idle-handoff.md owns the shared signal and both thresholds.
#
# WHY THE DEFAULT IS ON AT 30 MINUTES. The captain asked for this feature, so an
# absent config/auto-afk means ENABLED, not opt-in: a default-off feature would
# leave the measured waste in place for exactly the captain who requested the
# fix. 30 minutes is far shorter than the idle-handoff's four hours because the
# two thresholds buy different things and have opposite cost asymmetries. The
# handoff interrupts the captain with a banner, so firing it after a lunch break
# is a real cost and four hours buys quiet. Arming away mode interrupts nobody -
# it changes only how firstmate spends its own turns while the captain is gone,
# it exits automatically on their first real message, and a premature arm costs
# at most a slightly batched update. So the threshold is set where the waste
# starts rather than where the annoyance would.
#
# WHAT THIS IS. A predicate and a directive emitter, not an actor. Entering away
# mode means launching the daemon as a harness-tracked background process, which
# is harness-specific and belongs to the /afk skill; a shell script cannot do it.
# So this prints ONE directive telling firstmate to enter away mode through the
# ordinary /afk path, and firstmate does it. Nothing else changes: the away mode
# that results is byte-identical to a hand-typed one, state/.afk carries no
# provenance, and bin/fm-afk-return.sh exits it exactly as before.
#
# WHAT IT NEVER DOES.
#   - It never widens approval authority. AGENTS.md section 8 is explicit that
#     away mode never expands authority for merges, ask-user findings,
#     destructive or irreversible actions, or security-sensitive choices, and
#     never confers the captain-present sandbox override. Auto-arming inherits
#     every one of those limits STRUCTURALLY rather than by restating them: the
#     daemon is presence-gated on state/.afk alone and has no approval path at
#     all, and nothing anywhere reads how that flag came to exist.
#   - It never arms when there is nothing to supervise. A daemon buys nothing
#     over a parked fleet, which AGENTS.md section 8 already treats as the
#     healthy resting state.
#   - It never disturbs the idle-handoff. It writes only its own claim record and
#     log, never state/.last-captain-input and never
#     state/.captain-idle-handoff, so the handoff still fires at its own
#     threshold (see that script's away-mode branch for the other half).
#   - It never fires twice for one quiet stretch, and never fails a caller: every
#     path exits 0 and every ambiguous reading declines.
#
# Usage: fm-auto-afk.sh          evaluate, and print the directive when it fires
#        fm-auto-afk.sh --help
set -u

case "${1-}" in
  --help|-h)
    cat <<'USAGE'
fm-auto-afk.sh - print a directive telling firstmate to enter away mode when the
captain has been quiet past the configured stretch.

Prints nothing and exits 0 when it does not fire. Always exits 0.

Threshold (first match wins):
  FM_AUTO_AFK_SECONDS   env override, seconds, or "off" to disable
  config/auto-afk       first non-empty line: seconds, or "off" to disable
  1800                  built-in default (30 minutes), deliberately ON by default

It declines, silently, when:
  - this is not the main home (a secondmate has no captain to be away from)
  - away mode is already active, or a return catch-up is still open
  - no genuine captain input has ever been recorded, so no stretch is measurable
  - the measured stretch is under the threshold
  - this quiet stretch already fired
  - nothing is progressing and no poll is armed, so a daemon would buy nothing

State it owns, under the effective state dir:
  .auto-afk-armed       "<stretch-epoch>\t<armed-epoch>\t<idle-seconds>" for the
                        stretch already armed; read by bin/fm-afk-return.sh to
                        tell the captain it happened, and cleared there
  .auto-afk.log         dated log of fires and declines

It READS, and never writes, state/.last-captain-input (bin/fm-captain-idle-handoff.sh).
USAGE
    exit 0
    ;;
  '') : ;;
  *)
    echo "usage: $(basename "$0") [--help]" >&2
    exit 2
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# 30 minutes. See the header for why this is the default AND default-on.
DEFAULT_THRESHOLD=1800

# The shared captain clock, written only by bin/fm-captain-idle-handoff.sh.
MARK="$STATE/.last-captain-input"
CLAIM="$STATE/.auto-afk-armed"
LOG="$STATE/.auto-afk.log"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# The progressing-work predicate, through the same judge every guard and the arm
# gate read, so this can never hold a second opinion about a parked fleet.
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"

NOW=${FM_AUTO_AFK_NOW:-$(date +%s)}

# note <event> <detail>: append one dated line to the local log. Never fatal.
note() {
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$LOG" 2>/dev/null || true
}

# read_stretch <file>: echo the leading tab-separated field of the file's first
# line when it is a plain epoch, else nothing. Both records this reads lead with
# the epoch that opened a quiet stretch. A corrupt record reads as absent, which
# is the no-arm direction.
read_stretch() {
  local line value
  [ -f "$1" ] || return 1
  IFS= read -r line < "$1" 2>/dev/null || return 1
  value=${line%%$'\t'*}
  case "$value" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$value"
}

human_gap() {  # <seconds>
  local hours minutes
  hours=$(($1 / 3600))
  minutes=$((($1 % 3600) / 60))
  if [ "$hours" -gt 0 ]; then
    printf '%sh %sm' "$hours" "$minutes"
  else
    printf '%sm' "$minutes"
  fi
}

# --- scope ------------------------------------------------------------------
# The MAIN home only, for the same reason the idle-handoff hook excludes a
# secondmate: a secondmate runs its own primary session but has no captain to be
# away from. Its work arrives marked from the main firstmate and it idles in
# between, so "the captain went quiet" is not a state it can be in.
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
fm_root_is_secondmate_home "$FM_ROOT" && exit 0
# FM_HOME can select a home whose scripts come from a different tracked code root
# (AGENTS.md section 2), so the root check alone would miss a secondmate driven
# that way. Checking the home as well costs one file read and only ever declines.
fm_root_is_secondmate_home "$FM_HOME" && exit 0

# --- threshold ---------------------------------------------------------------
THRESHOLD_SRC=default
THRESHOLD=$DEFAULT_THRESHOLD
raw=${FM_AUTO_AFK_SECONDS-}
if [ -n "$raw" ]; then
  THRESHOLD_SRC='env'
else
  if [ -f "$CONFIG/auto-afk" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line=${line%%#*}
      line=$(printf '%s' "$line" | tr -d '[:space:]')
      [ -n "$line" ] || continue
      raw=$line
      THRESHOLD_SRC=config
      break
    done < "$CONFIG/auto-afk"
  fi
fi
case "$raw" in
  '') : ;;
  off|OFF|Off) exit 0 ;;
  *[!0-9]*|0)
    # An unreadable value falls back to the default, never to anything shorter:
    # a typo must not make firstmate arm away mode more eagerly than asked.
    note bad-threshold "$THRESHOLD_SRC=$raw"
    THRESHOLD_SRC=default
    ;;
  *) THRESHOLD=$raw ;;
esac

# --- already away, or coming back --------------------------------------------
# Away mode active means there is nothing to arm. An open return catch-up means
# the captain is already back and mid-return, which is the strongest possible
# "do not fight a present captain" reading.
[ -e "$STATE/.afk" ] && exit 0
[ -e "$STATE/.afk-return-catchup" ] && exit 0

# --- measure -----------------------------------------------------------------
LAST=$(read_stretch "$MARK") || exit 0
IDLE=$((NOW - LAST))
# A clock that runs backwards (a record dated in the future) is not evidence of a
# quiet captain, so decline rather than guess.
[ "$IDLE" -ge "$THRESHOLD" ] || exit 0

# One arm per quiet stretch, keyed on the epoch that OPENED it. That epoch only
# advances when the captain actually types, so a stretch cannot re-fire; and if
# firstmate declines or fails to enter away mode, this stays quiet for the rest
# of the stretch rather than repeating itself every monitoring cycle.
CLAIMED=$(read_stretch "$CLAIM") || CLAIMED=
if [ "$CLAIMED" = "$LAST" ]; then
  note already-armed "stretch=$LAST idle=${IDLE}s"
  exit 0
fi

# --- is there anything to supervise? -----------------------------------------
# A parked fleet is the healthy resting state (AGENTS.md section 8), and a daemon
# over it would batch nothing. Judged through fm_supervision_status, the same
# cached-record reader bin/fm-turnend-guard.sh and bin/fm-watch-arm.sh use, so
# this and the arm gate cannot report opposite answers for the same fleet.
fm_supervision_status "$STATE"
if [ "$FM_SUP_PROGRESSING" -le 0 ] && ! fm_progress_has_pollable_work "$STATE"; then
  note nothing-to-supervise "stretch=$LAST idle=${IDLE}s"
  exit 0
fi

# --- fire --------------------------------------------------------------------
printf '%s\t%s\t%s\n' "$LAST" "$NOW" "$IDLE" > "$CLAIM" 2>/dev/null || note claim-write-failed "$CLAIM"
note armed "stretch=$LAST idle=${IDLE}s threshold=${THRESHOLD}s($THRESHOLD_SRC) progressing=$FM_SUP_PROGRESSING"

AWAY_FOR=$(human_gap "$IDLE")

cat <<DIRECTIVE
auto-afk: the captain has been quiet $AWAY_FOR, past the ${THRESHOLD}s stretch
that bin/fm-auto-afk.sh, a tracked script in this repo, watches for. Work is
still under way, so every further monitoring cycle spends a turn on a fleet
nobody is reading. Enter away mode now:

1. Load the \`afk\` skill and follow it exactly as a captain-typed /afk, through
   \`bin/fm-afk-launch.sh\`. Do not invent a shortcut, a variant flag, or a second
   away-mode flavour - the whole point is that this away session is
   indistinguishable from one the captain typed, so their return works unchanged.
2. Say nothing to the captain about it now. They are not reading; the return
   catch-up tells them it happened, in one line, when they are back.

Away mode does NOT widen your approval authority (AGENTS.md section 8). A pull
request ready to merge, an ask-user finding, and anything destructive,
irreversible, or security-sensitive still wait for the captain's explicit word,
exactly as they would if they had typed /afk themselves, and you still have no
captain-present sandbox override.

If the captain HAS sent a message since this was measured, do nothing: a present
captain takes precedence, and this will arm again on its own if they go quiet.
DIRECTIVE

exit 0
