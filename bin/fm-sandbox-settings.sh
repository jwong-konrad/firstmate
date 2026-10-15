#!/usr/bin/env bash
# Restore a ship, scout, or tester task's worker write boundary before a relaunch or
# resume in its existing worktree.
# Usage: fm-sandbox-settings.sh <task-id> [--captain-present-override]
#
# A relaunch or resume does not go through fm-spawn.sh: firstmate restarts the
# recorded harness in the recorded worktree. The claude settings file there is
# what decides whether the restarted worker is sandboxed, so run this
# immediately before every claude relaunch or resume. It regenerates
# <worktree>/.claude/settings.local.json from the task's recorded worktree,
# kind, and harness with the same code fm-spawn.sh uses
# (bin/fm-sandbox-lib.sh), which also discards anything a worker added to that
# file. Without the flag the task returns to its standing posture, so an
# earlier captain-present override is never carried forward.
#
# --captain-present-override lifts the boundary for this one relaunch or resume
# only, exactly as docs/configuration.md "The captain-present override"
# specifies: it needs an explicit captain instruction in the current session
# naming the task, and it is refused with no change while state/.afk exists.
#
# Appends sandbox=<on|off|off-tester|override|unsupported-harness> to state/<id>.meta, plus
# override=captain-present when the flag was used, or override=none when it was
# not and the meta's latest override= says otherwise. Those fields are a record
# of what was launched, never read back as authorization.
# Non-claude harnesses have no verified sandbox mechanism; their settings are
# left untouched and the posture is recorded as it stands.
# Refuses a missing meta, a secondmate, and a missing worktree.
# On success prints: sandbox=<posture> task=<id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-sandbox-lib.sh
. "$SCRIPT_DIR/fm-sandbox-lib.sh"

usage() {
  sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
}

ID=
OVERRIDE=0
for a in "$@"; do
  case "$a" in
    -h|--help) usage; exit 0 ;;
    --captain-present-override) OVERRIDE=1 ;;
    -*) echo "error: unknown flag $a" >&2; usage >&2; exit 2 ;;
    *)
      [ -z "$ID" ] || { echo "error: exactly one task id is allowed" >&2; exit 2; }
      ID=$a
      ;;
  esac
done
[ -n "$ID" ] || { usage >&2; exit 2; }
case "$ID" in
  .*|*[!A-Za-z0-9._-]*) echo "error: invalid task id" >&2; exit 2 ;;
esac

# The LAST value of key= wins, matching fm_meta_get in bin/fm-backend.sh.
meta_get() {  # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no task record for $ID ($META)" >&2; exit 1; }
KIND=$(meta_get kind)
HARNESS=$(meta_get harness)
WT=$(meta_get worktree)
TASK_TMP=$(meta_get tasktmp)
case "$KIND" in
  ship|scout|tester) ;;
  *) echo "error: $ID is kind=${KIND:-unknown}; only ship, scout, and tester tasks carry a worker write boundary" >&2; exit 1 ;;
esac
[ -n "$WT" ] && [ -d "$WT" ] || { echo "error: recorded worktree for $ID is missing: ${WT:-<none>}" >&2; exit 1; }
[ -n "$TASK_TMP" ] || TASK_TMP="/tmp/fm-$ID"

if [ "$OVERRIDE" = 1 ]; then
  fm_sandbox_override_refusal "$STATE" || exit 1
fi

POSTURE=$(fm_sandbox_posture "$HARNESS" "$KIND" "$OVERRIDE")
case "$HARNESS" in
  claude*)
    fm_sandbox_install_claude_settings "$POSTURE" "$WT" "$STATE" "$DATA" "$ID" "$TASK_TMP" "$SCRIPT_DIR/fm-sandbox-guard.sh" \
      || { echo "error: could not write the claude settings for $ID" >&2; exit 1; }
    ;;
esac

{
  echo "sandbox=$POSTURE"
  if [ "$OVERRIDE" = 1 ]; then
    echo "override=captain-present"
  else
    prev=$(meta_get override)
    [ -z "$prev" ] || [ "$prev" = none ] || echo "override=none"
  fi
} >> "$META"
echo "sandbox=$POSTURE task=$ID"
