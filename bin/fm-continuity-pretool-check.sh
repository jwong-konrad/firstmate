#!/usr/bin/env bash
# Claude primary watcher-continuity PreToolUse gate.
#
# This hook is deliberately narrow. It denies only an executed bin/fm-*.sh fleet
# command other than bin/fm-wake-drain.sh, bin/fm-watch-arm.sh, or the
# independently fail-closed bin/fm-teardown.sh, and only when the active primary
# home has PROGRESSING work and supervision is genuinely ABSENT. Ordinary shell
# commands, recovery commands, healthy supervision, fleet-idle homes, and child
# worktrees are always allowed.
#
# "Absent" is a three-state test, not a live-lock test: neither an identity-matched
# lock holder nor a very recent watcher cycle that DELIVERED an actionable wake.
# The watcher is one-shot, so every wake guarantees an interval with no lock holder;
# reading that interval as absent supervision denied the only commands that could
# clear a stale-pane storm and deadlocked recovery for hours on 2026-08-05. See
# docs/supervision-deadlock-guard.md for the invariant and the rejected
# alternatives.
#
# The existing turn-end guard remains the unchanged final backstop, and
# deliberately grants no servicing grace: acting on a wake is not blind, ending a
# turn without re-arming is. This gate closes the long-turn gap before another
# fleet mutation, but does not replace or weaken the Stop hook.
#
# Input is Claude PreToolUse JSON on stdin. Tests may pass --command directly.
# Malformed transport, missing jq/Node, a missing classifier, or classifier
# failure all fail open. A deny writes Claude's hook decision to stderr only and
# exits 2.
set -u

COMMAND=
COMMAND_SET=0

usage() {
  cat <<'EOF'
Usage: fm-continuity-pretool-check.sh [--command <shell-command>]

Reads Claude PreToolUse JSON from stdin unless --command is supplied.
Exits 0 to allow. Exits 2 with a Claude deny object on stderr only when an
unhealthy primary tries to execute a non-recovery firstmate fleet script.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      COMMAND=$2
      COMMAND_SET=1
      shift 2
      ;;
    --command=*)
      COMMAND=${1#--command=}
      COMMAND_SET=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$COMMAND_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  COMMAND=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
fi
[ -n "$COMMAND" ] || exit 0

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)}
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
WATCH="$SCRIPT_DIR/fm-watch.sh"
POLICY="$SCRIPT_DIR/fm-continuity-command-policy.mjs"

# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
# Gate on PROGRESSING work, not on runtime records existing. A fleet whose every
# task is parked, awaiting firstmate's own decision, failed, or gone has nothing
# for a watcher to observe, and denying fleet commands there is what deadlocked
# recovery: the denied commands were the ones that would have revived the panes
# (bin/fm-progress-lib.sh, docs/supervision-arming.md).
fm_supervision_status "$STATE" "${FM_GUARD_GRACE:-300}"
[ "$FM_SUP_PROGRESSING" -gt 0 ] || exit 0

# Liveness has three states here, not two (docs/supervision-deadlock-guard.md).
#
# LIVE: an identity-matched watcher holds this home's lock.
LOCK_PID=$(cat "$STATE/.watch.lock/pid" 2>/dev/null || true)
if fm_pid_alive "$LOCK_PID" && fm_watcher_lock_matches_pid "$STATE" "$WATCH" "$LOCK_PID" "$FM_HOME"; then
  exit 0
fi

# SERVICED: no lock holder, but a watcher cycle DELIVERED an actionable wake very
# recently, so firstmate is inside the interval it was woken to act in. The watcher
# is one-shot by design, so every wake guarantees this unlocked interval; denying
# in it is what deadlocked the 2026-08-05 staged restart, because a stale reason
# was instantly available on every cycle and the denied commands were the only
# ones that could have cleared the staleness.
#
# This can only ever open on positive evidence that supervision did its job: a
# declined arm writes no ledger record, and a failed, crashed, or signalled close
# writes a non-actionable reason. Only the ledger's newest dispositive record is
# read, so a re-arm that fails after a delivered wake shuts the window at once
# instead of being masked by that wake, while a second arm's bookkeeping about its
# own attachment neither opens nor closes it. An actionable record older than the
# grace closes the gate again, so an abandoned wake does not hold it open.
#
# bin/fm-turnend-guard.sh deliberately grants no such grace: acting on a wake is
# not blind, but ENDING a turn without re-arming is, so the turn cannot end until
# supervision is restored and this window cannot become a way to run unsupervised.
SERVICE_GRACE=${FM_CONTINUITY_SERVICE_GRACE:-${FM_GUARD_GRACE:-300}}
case "$SERVICE_GRACE" in ''|*[!0-9]*) SERVICE_GRACE=300 ;; esac
if SERVICED_AGE=$(fm_supervision_serviced_wake_age "$STATE"); then
  [ "$SERVICED_AGE" -lt "$SERVICE_GRACE" ] && exit 0
fi

command -v node >/dev/null 2>&1 || exit 0
[ -f "$POLICY" ] || exit 0
CLASSIFICATION=$(node "$POLICY" --command "$COMMAND" --root "$FM_ROOT" 2>/dev/null) || exit 0
case "$CLASSIFICATION" in
  deny*) ;;
  *) exit 0 ;;
esac

TAB=$(printf '\t')
REST=${CLASSIFICATION#*"$TAB"}
[ -n "$REST" ] && [ "$REST" != "$CLASSIFICATION" ] || exit 0
BLOCKED_SCRIPT=${REST%%"$TAB"*}
REASON_CODE=${REST#*"$TAB"}
[ "$REASON_CODE" != "$REST" ] || REASON_CODE=""
case "$REASON_CODE" in
  unsafe-teardown)
    REASON="[watcher-continuity] tasks are in flight and no live watcher holds this home lock; during recovery only the ordinary literal bin/fm-teardown.sh is allowed, so drop --force and any shell-expanded arguments and retry the literal invocation (blocked: $BLOCKED_SCRIPT)"
    ;;
  *)
    REASON="[watcher-continuity] tasks are in flight and no live watcher holds this home lock; drain wakes with bin/fm-wake-drain.sh, use fail-closed bin/fm-teardown.sh for completed tasks when needed, then re-arm with bin/fm-watch-arm.sh as a tracked Claude background task before running other fleet commands (blocked: $BLOCKED_SCRIPT)"
    ;;
esac
ESCAPED=$(printf '%s' "$REASON" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
exit 2
