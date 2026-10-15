#!/usr/bin/env bash
# Promote a scout or tester task to a ship task in place: the crewmate keeps its window,
# worktree, and loaded context; only the contract changes. Flips kind= to ship in
# state/<task-id>.meta so fm-teardown.sh applies the full ship-task teardown protection
# again. After promoting, send the crewmate its ship instructions via fm-send.sh
# (inventory scratch state, reset to a clean default-branch base, carry over only
# intended fix changes, create branch fm/<task-id>, implement, then report done
# according to the project's delivery mode).
# A claude scout launched inside the worker write sandbox stays inside it until it
# restarts, and ship work needs to push, so promotion also regenerates its settings
# to the ship posture (bin/fm-sandbox-settings.sh) and prints that the worker must
# be exited and resumed in the same worktree before it is sent ship instructions.
# Usage: fm-promote.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
KIND=$(grep '^kind=' "$META" | tail -1 | cut -d= -f2- || true)
case "$KIND" in
  scout|tester) ;;
  *) echo "error: task $ID is not a scout or tester task (kind=${KIND:-<none>} in meta)" >&2; exit 1 ;;
esac
SANDBOX=$(grep '^sandbox=' "$META" | tail -1 | cut -d= -f2- || true)

TMP="$META.tmp"
grep -v '^kind=' "$META" > "$TMP"
echo "kind=ship" >> "$TMP"
mv "$TMP" "$META"

HOME_Q=$(printf '%q' "$FM_HOME")
echo "promoted $ID to ship (teardown protection restored)"
if [ "$SANDBOX" = on ]; then
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-sandbox-settings.sh" "$ID" >/dev/null
  echo "sandbox: the worker still runs inside the scout write sandbox; its settings now carry the ship posture, so exit it and resume it in the same worktree (see the harness-adapters skill) before sending ship instructions"
fi
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions: review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; report done>'"
