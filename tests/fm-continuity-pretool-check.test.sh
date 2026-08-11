#!/usr/bin/env bash
# Behavior tests for Claude's narrowly scoped watcher-continuity PreToolUse gate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-continuity-pretool-check.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-continuity-pretool-tests)
PRIMARY="$TMP_ROOT/primary"
STATE="$PRIMARY/state"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"

mkdir -p "$PRIMARY/bin" "$STATE"
printf '# fixture\n' > "$PRIMARY/AGENTS.md"
git -C "$PRIMARY" init -q

run_command() {
  local command=$1 rc=0
  : > "$OUT"
  : > "$ERR"
  FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
    "$CHECK" --command "$command" > "$OUT" 2> "$ERR" || rc=$?
  return "$rc"
}

expect_allow() {
  local label=$1 command=$2 rc=0
  run_command "$command" || rc=$?
  [ "$rc" -eq 0 ] || fail "$label must allow, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "$label allow wrote stdout: $(cat "$OUT")"
  [ ! -s "$ERR" ] || fail "$label allow wrote stderr: $(cat "$ERR")"
}

expect_deny() {
  local label=$1 command=$2 blocked=$3 expected=${4:-} rc=0 actual
  run_command "$command" || rc=$?
  [ "$rc" -eq 2 ] || fail "$label must deny with exit 2, got $rc"
  [ ! -s "$OUT" ] || fail "$label deny wrote stdout: $(cat "$OUT")"
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny"' "$ERR" >/dev/null 2>&1 \
    || fail "$label deny omitted Claude's permission decision: $(cat "$ERR")"
  [ -n "$expected" ] || expected="[watcher-continuity] tasks are in flight and no live watcher holds this home lock; drain wakes with bin/fm-wake-drain.sh, use fail-closed bin/fm-teardown.sh for completed tasks when needed, then re-arm with bin/fm-watch-arm.sh as a tracked Claude background task before running other fleet commands (blocked: $blocked)"
  actual=$(jq -r '.systemMessage' "$ERR")
  [ "$actual" = "$expected" ] || fail "$label recovery guidance changed: $actual"
}

test_gate_scope_and_recovery_exceptions() {
  expect_allow "idle fleet command" 'bin/fm-crew-state.sh task'
  printf 'project=fixture\n' > "$STATE/task.meta"

  expect_allow "ordinary shell command" 'git status --short'
  expect_allow "fleet-script text as data" "rg -n 'bin/fm-send.sh' docs"
  expect_allow "wake drain recovery" 'bin/fm-wake-drain.sh'
  expect_allow "watch arm recovery" 'bin/fm-watch-arm.sh'
  expect_allow "drain then arm recovery" 'bin/fm-wake-drain.sh; bin/fm-watch-arm.sh'
  expect_allow "fail-closed teardown recovery" 'bin/fm-teardown.sh task'
  unsafe_teardown_reason='[watcher-continuity] tasks are in flight and no live watcher holds this home lock; during recovery only the ordinary literal bin/fm-teardown.sh is allowed, so drop --force and any shell-expanded arguments and retry the literal invocation (blocked: fm-teardown.sh)'
  expect_deny "forced teardown is not recovery" 'bin/fm-teardown.sh task --force' 'fm-teardown.sh' "$unsafe_teardown_reason"
  expect_deny "nested forced teardown is not recovery" "bash -lc 'bin/fm-teardown.sh task --force'" 'fm-teardown.sh' "$unsafe_teardown_reason"
  # shellcheck disable=SC2016  # single quotes are deliberate: "$TEARDOWN_MODE" is literal test data (an unsafe shell-expanded arg the gate must deny), not an expansion here
  expect_deny "dynamic teardown mode is not recovery" 'bin/fm-teardown.sh task "$TEARDOWN_MODE"' 'fm-teardown.sh' "$unsafe_teardown_reason"
  expect_deny "unrelated fleet command" 'bin/fm-crew-state.sh task' 'fm-crew-state.sh'
  expect_deny "recovery bundled with unrelated fleet command" 'bin/fm-wake-drain.sh; bin/fm-send.sh task hi' 'fm-send.sh'
  expect_deny "literal nested fleet command" "bash -lc 'bin/fm-bootstrap.sh'" 'fm-bootstrap.sh'
  pass "continuity gate allows recovery and ordinary commands but denies only other fleet execution"
}

test_live_lock_allows_fleet_command_even_with_stale_beacon() {
  local holder identity rc=0
  sleep 300 &
  holder=$!
  identity=$(FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$holder") \
    || fail "could not identify live continuity fixture"
  mkdir -p "$STATE/.watch.lock"
  printf '%s\n' "$holder" > "$STATE/.watch.lock/pid"
  printf '%s\n' "$PRIMARY" > "$STATE/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$STATE/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$STATE/.watch.lock/pid-identity"
  touch -t 200001010000 "$STATE/.last-watcher-beat"

  run_command 'bin/fm-crew-state.sh task' || rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$rc" -eq 0 ] || fail "identity-matched live lock must allow fleet command even when its beacon is stale"
  [ ! -s "$ERR" ] || fail "live-lock allow wrote stderr: $(cat "$ERR")"
  pass "continuity gate classifies the lock by live PID identity rather than beacon age"
}

test_child_worktree_and_malformed_input_fail_open() {
  local child="$TMP_ROOT/child" rc=0
  rm -rf "$STATE/.watch.lock"
  git -C "$PRIMARY" config user.name fixture
  git -C "$PRIMARY" config user.email fixture@example.test
  git -C "$PRIMARY" add AGENTS.md
  git -C "$PRIMARY" commit -qm fixture
  git -C "$PRIMARY" worktree add -q -b fixture-child "$child"
  mkdir -p "$child/bin" "$child/state"
  FM_ROOT_OVERRIDE="$child" FM_HOME="$child" FM_STATE_OVERRIDE="$child/state" \
    "$CHECK" --command 'bin/fm-send.sh task hi' > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "linked child worktree must be out of continuity-gate scope"

  expect_allow "malformed dynamic shell" "bin/fm-send.sh 'unterminated"
  printf '%s' '{not-json' | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
    "$CHECK" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "malformed Claude transport must fail open"
  pass "continuity gate excludes child worktrees and fails open on opaque input"
}

# The six commands the 2026-08-05 deadlock denied - exactly the ones that would
# have steered the idle panes back to life and cleared the staleness.
RECOVERY_COMMANDS=(
  'bin/fm-send.sh restart-1 continue'
  'bin/fm-peek.sh restart-1'
  'bin/fm-crew-state.sh restart-1'
  'bin/fm-brief.sh restart-1 fixture'
  'bin/fm-spawn.sh restart-1 fixture'
  'bin/fm-decision-hold.sh restart-1 --reason fixture'
)

CYCLE_LOG="$STATE/.watch-cycle-exits.log"

# One arm-layer lifecycle record in bin/fm-watch-arm.sh's exact tab-separated
# format. <reason> is the classified close and <ended-at> its epoch. <origin>
# defaults to started (the arm that forked the watcher) and <successor> to none.
ledger_record() {  # <reason> <ended-at> [origin] [successor]
  printf 'arm_pid=4242\twatcher_pid=4243\torigin=%s\tstarted_at=%s\tended_at=%s\texit_code=0\tsignal=none\treason=%s\tbeacon_age=2\tlock_before=pid:4243|identity:fixture\tlock_after=pid:none|identity:none\tsuccessor=%s\n' \
    "${3:-started}" "$(( $2 - 3 ))" "$2" "$1" "${4:-none}" >> "$CYCLE_LOG"
}

# Rebuild the exact 2026-08-05 shape: ten direct reports whose panes have been
# idle far past FM_STALE_ESCALATE_SECS, every task still counting progressing
# (no verdict record), and NO watcher holding the lock because the one-shot cycle
# closed the instant a stale reason was available.
stage_ten_idle_reports() {
  local i
  rm -rf "$STATE/.watch.lock"
  rm -f "$CYCLE_LOG" "$STATE"/*.meta "$STATE"/*.status "$STATE"/.progress-* 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9 10; do
    printf 'project=fixture\nwindow=fm-restart-%s\n' "$i" > "$STATE/restart-$i.meta"
    printf 'working: implementing\n' > "$STATE/restart-$i.status"
    touch -t 200001010000 "$STATE/restart-$i.status"
  done
  touch -t 200001010000 "$STATE/.last-watcher-beat"
}

test_serviced_wake_does_not_deadlock_recovery() {
  local command
  stage_ten_idle_reports
  # Counterfactual first: with no servicing evidence this is genuinely absent
  # supervision, and every recovery command must still be denied. This is the
  # pre-change behavior, and the reason the deadlock happened.
  for command in "${RECOVERY_COMMANDS[@]}"; do
    expect_deny "absent supervision blocks ${command%% *}" "$command" "$(basename "${command%% *}")"
  done

  # Now the watcher does what it is designed to do: it delivers one actionable
  # stale wake and closes, leaving no lock holder. Firstmate is inside the
  # interval it was woken to act in, so the remedy must be available.
  ledger_record actionable-stale "$(date +%s)"
  for command in "${RECOVERY_COMMANDS[@]}"; do
    expect_allow "serviced wake permits ${command%% *}" "$command"
  done
  pass "ten reports idle past the stale threshold no longer deadlock the six recovery commands"
}

test_only_a_delivered_wake_opens_the_service_window() {
  local reason command
  # Every non-actionable close reason bin/fm-watch-arm.sh can record. None of
  # them is evidence supervision ran, so none may open the window. A declined
  # arm writes no record at all, which the empty-ledger case above covers.
  for reason in confirmation-timeout unexpected-clean-exit nonzero-exit signal-exit \
                arm-interrupted; do
    stage_ten_idle_reports
    ledger_record "$reason" "$(date +%s)"
    expect_deny "close reason $reason is not servicing" 'bin/fm-send.sh restart-1 continue' 'fm-send.sh'
  done

  # The attach-path reasons, written with the origin the arm layer actually uses.
  # An arm that only attached to somebody else's watcher never read its output, so
  # its rows are not servicing evidence either.
  for reason in attached-cycle-ended lock-replaced arm-interrupted; do
    stage_ten_idle_reports
    ledger_record "$reason" "$(date +%s)" attached
    expect_deny "attached close reason $reason is not servicing" 'bin/fm-send.sh restart-1 continue' 'fm-send.sh'
  done

  # An actionable record that has aged past the grace re-closes the gate, so an
  # abandoned wake cannot hold it open indefinitely.
  stage_ten_idle_reports
  ledger_record actionable-stale "$(( $(date +%s) - 4000 ))"
  expect_deny "expired servicing evidence re-closes the gate" 'bin/fm-send.sh restart-1 continue' 'fm-send.sh'

  # A truncated or garbled ended_at field must not parse as fresh servicing.
  stage_ten_idle_reports
  printf 'arm_pid=1\treason=actionable-stale\tended_at=notanepoch\tsuccessor=none\n' >> "$CYCLE_LOG"
  expect_deny "unparseable servicing timestamp still denies" 'bin/fm-send.sh restart-1 continue' 'fm-send.sh'

  # The ledger is gitignored runtime state, so a future-dated record must not be
  # readable as permanently fresh servicing evidence.
  stage_ten_idle_reports
  ledger_record actionable-stale "$(( $(date +%s) + 999999 ))"
  expect_deny "future-dated servicing evidence still denies" 'bin/fm-send.sh restart-1 continue' 'fm-send.sh'

  # The grace is configurable, and shrinking it must re-engage the guard against
  # evidence that would otherwise be fresh enough.
  stage_ten_idle_reports
  ledger_record actionable-stale "$(( $(date +%s) - 120 ))"
  local rc=0
  : > "$OUT"; : > "$ERR"
  FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
    FM_CONTINUITY_SERVICE_GRACE=30 \
    "$CHECK" --command 'bin/fm-send.sh restart-1 continue' > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "a shortened service grace must re-engage the guard, got exit $rc"

  # Ordering: a delivered wake followed by an arm that failed, crashed, or was
  # signalled must re-close the window on the newer record, not stay open on the
  # older actionable one until it ages out.
  for reason in confirmation-timeout unexpected-clean-exit nonzero-exit signal-exit \
                arm-interrupted; do
    stage_ten_idle_reports
    ledger_record actionable-stale "$(( $(date +%s) - 6 ))"
    ledger_record "$reason" "$(date +%s)"
    expect_deny "a later $reason close re-closes the window" 'bin/fm-send.sh restart-1 continue' 'fm-send.sh'
  done

  # But a SECOND arm's bookkeeping must not supersede the owner's delivered wake.
  # Every arm in a home appends to the same ledger, so an arm that merely attached
  # to the owner's watcher notices the lock is gone shortly after the wake and
  # closes its own observation. Firstmate is still inside the interval it was woken
  # to act in, so those rows may not shut the window.
  for reason in attached-cycle-ended lock-replaced arm-interrupted; do
    stage_ten_idle_reports
    ledger_record actionable-stale "$(( $(date +%s) - 12 ))"
    ledger_record "$reason" "$(date +%s)" attached "attached:4444"
    expect_allow "attached $reason does not mask the owner's delivered wake" 'bin/fm-send.sh restart-1 continue'
  done

  # The owner writes one stand-down row of its own: a clean close while a verified
  # successor already holds the lock. It says nothing about wake delivery either.
  stage_ten_idle_reports
  ledger_record actionable-stale "$(( $(date +%s) - 12 ))"
  ledger_record unexpected-clean-exit "$(date +%s)" started "attached:4444"
  expect_allow "an owner hand-off to a successor does not mask a delivered wake" 'bin/fm-send.sh restart-1 continue'

  # The same reason with successor=none IS the arm failing, and must still deny.
  stage_ten_idle_reports
  ledger_record actionable-stale "$(( $(date +%s) - 12 ))"
  ledger_record unexpected-clean-exit "$(date +%s)" started none
  expect_deny "an owner clean close with no successor re-closes the window" 'bin/fm-send.sh restart-1 continue' 'fm-send.sh'

  # And the newest record still governs in the other direction: a fresh delivered
  # wake after a failed close re-opens the window.
  stage_ten_idle_reports
  ledger_record confirmation-timeout "$(( $(date +%s) - 6 ))"
  ledger_record actionable-stale "$(date +%s)"
  expect_allow "a later delivered wake re-opens the window" 'bin/fm-send.sh restart-1 continue'

  # Servicing evidence is read field-wise, so an actionable-looking value carried
  # in a free-text field of a non-actionable record cannot forge it.
  stage_ten_idle_reports
  printf 'arm_pid=4242\twatcher_pid=4243\torigin=reason=actionable-stale ended_at=%s\tstarted_at=%s\tended_at=%s\texit_code=1\tsignal=none\treason=confirmation-timeout\tbeacon_age=2\tlock_before=none\tlock_after=none\tsuccessor=none\n' \
    "$(date +%s)" "$(( $(date +%s) - 3 ))" "$(date +%s)" >> "$CYCLE_LOG"
  expect_deny "field-anchored parse rejects forged servicing text" 'bin/fm-send.sh restart-1 continue' 'fm-send.sh'

  # And the recovery/teardown exemptions still behave while servicing is absent.
  stage_ten_idle_reports
  expect_allow "wake drain still exempt while absent" 'bin/fm-wake-drain.sh'
  expect_allow "arm still exempt while absent" 'bin/fm-watch-arm.sh'
  pass "only a genuinely delivered wake inside the grace opens the service window"
}

# Every ledger literal the reader in bin/fm-supervision-lib.sh keys on - the reason
# vocabulary, the cycle origins, and the successor hand-off encoding - must still
# match what bin/fm-watch-arm.sh writes. An unclassified reason token would land in
# whichever bucket the fallback happens to be, which is how an observer's bookkeeping
# row came to mask a genuinely delivered wake.
test_reader_classifies_every_reason_the_writer_emits() {
  local token classified emitted unclassified=
  # shellcheck source=bin/fm-supervision-lib.sh
  . "$ROOT/bin/fm-supervision-lib.sh"
  classified=" $FM_SUPERVISION_REASONS_DELIVERED $FM_SUPERVISION_REASONS_FAILED $FM_SUPERVISION_REASONS_STANDDOWN $FM_SUPERVISION_REASONS_ATTACHED "
  emitted=$( {
    grep -h 'cycle_log_append ' "$ROOT/bin/fm-watch-arm.sh" | grep -v '^[[:space:]]*#' \
      | tr ' ' '\n' | grep -E '^[a-z]+(-[a-z]+)+$'
    grep -oE "printf 'actionable-[a-z]+'" "$ROOT/bin/fm-watch-arm.sh" | sed "s/.*'\(.*\)'/\1/"
    grep -oE 'reason_type="[a-z-]+"' "$ROOT/bin/fm-watch-arm.sh" | sed 's/.*"\(.*\)"/\1/'
  } | sort -u )
  [ -n "$emitted" ] || fail "could not enumerate the reason tokens bin/fm-watch-arm.sh emits"
  for token in $emitted; do
    case "$classified" in
      *" $token "*) ;;
      *) unclassified="$unclassified $token" ;;
    esac
  done
  [ -z "$unclassified" ] || fail "bin/fm-supervision-lib.sh classifies no bucket for reason token(s):$unclassified"

  # The reader keys on two more ledger literals, and drift in either fails SILENTLY
  # in the dangerous direction: if bin/fm-watch-arm.sh grew a third cycle_begin
  # origin, or encoded the successor hand-off differently, every genuine owner row
  # would be skipped, the reader would report no servicing evidence, and the gate
  # would deny always - the exact 2026-08-05 deadlock. So compare the registry in
  # bin/fm-supervision-lib.sh against what the writer actually contains.
  local origins expected_origins successor_prefixes expected_prefixes
  origins=$(grep -oE 'cycle_begin "\$[A-Za-z_]+" [a-z]+' "$ROOT/bin/fm-watch-arm.sh" \
    | awk '{print $3}' | sort -u | tr '\n' ' ')
  expected_origins=$(printf '%s\n%s\n' "$FM_SUPERVISION_ORIGIN_OWNER" "$FM_SUPERVISION_ORIGIN_OBSERVER" \
    | sort -u | tr '\n' ' ')
  [ "$origins" = "$expected_origins" ] \
    || fail "bin/fm-watch-arm.sh cycle origins ($origins) no longer match the reader's registry ($expected_origins)"

  # Both writers of the successor field, which are also the only two writes to the
  # ledger file: cycle_log_append appends the row, and cycle_mark_predecessor_successor
  # rewrites an earlier row's successor=none in place. Covering both completes the
  # coverage, so renaming the hand-off literal at either fails here instead of silently
  # detaching the reader's stand-down skip from the rows it is meant to match.
  successor_prefixes=$(grep -hE 'cycle_log_append |cycle_mark_predecessor_successor "' "$ROOT/bin/fm-watch-arm.sh" \
    | grep -v '^[[:space:]]*#' \
    | grep -oE '"[a-z]+:\$[A-Za-z_]+"' | sed -E 's/.*"([a-z]+:)\$.*/\1/' | sort -u | tr '\n' ' ')
  expected_prefixes=$(printf '%s\n%s\n' "$FM_SUPERVISION_SUCCESSOR_HANDOFF_PREFIX" "$FM_SUPERVISION_SUCCESSOR_OWNED_PREFIX" \
    | sort -u | tr '\n' ' ')
  [ "$successor_prefixes" = "$expected_prefixes" ] \
    || fail "bin/fm-watch-arm.sh successor encodings ($successor_prefixes) no longer match the reader's registry ($expected_prefixes)"

  # And the classification is behavioral, not just declarative: a delivered token
  # opens the window and a failed owner token closes it.
  for token in $FM_SUPERVISION_REASONS_DELIVERED; do
    stage_ten_idle_reports
    ledger_record "$token" "$(date +%s)"
    expect_allow "delivered token $token opens the window" 'bin/fm-send.sh restart-1 continue'
  done
  for token in $FM_SUPERVISION_REASONS_FAILED; do
    stage_ten_idle_reports
    ledger_record "$token" "$(date +%s)" started none
    expect_deny "failed token $token closes the window" 'bin/fm-send.sh restart-1 continue' 'fm-send.sh'
  done
  pass "the servicing reader classifies every close reason the arm layer can write"
}

test_turnend_guard_grants_no_service_grace() {
  # The asymmetry that keeps the window honest: acting on a wake is not blind,
  # but ending a turn without re-arming is, so the Stop hook must still block on
  # exactly the fixture the PreToolUse gate now allows.
  local rc=0
  stage_ten_idle_reports
  ledger_record actionable-stale "$(date +%s)"
  expect_allow "gate allows during servicing" 'bin/fm-send.sh restart-1 continue'
  printf '{"stop_hook_active":false}' | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" \
    FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-turnend-guard.sh" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] \
    || fail "turn-end guard must still block a blind turn end during servicing, got exit $rc"
  grep -q 'TURN WOULD END BLIND' "$ERR" \
    || fail "turn-end guard lost its blind-turn banner: $(cat "$ERR")"
  pass "the servicing window bounds unlocked action without letting a turn end unsupervised"
}

test_claude_hook_registration_preserves_stop_backstop() {
  jq -e '
    [.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command]
      | any(contains("fm-continuity-pretool-check.sh"))
  ' "$ROOT/.claude/settings.json" >/dev/null || fail "Claude settings omit the continuity PreToolUse hook"
  jq -e '
    .hooks.Stop == [{"hooks":[{"type":"command","command":"\"$CLAUDE_PROJECT_DIR\"/bin/fm-turnend-guard.sh"}]}]
  ' "$ROOT/.claude/settings.json" >/dev/null || fail "Claude Stop turn-end backstop changed"
  pass "Claude wires the continuity gate while preserving the existing Stop backstop byte-for-byte"
}

test_gate_scope_and_recovery_exceptions
test_live_lock_allows_fleet_command_even_with_stale_beacon
test_child_worktree_and_malformed_input_fail_open
test_serviced_wake_does_not_deadlock_recovery
test_only_a_delivered_wake_opens_the_service_window
test_reader_classifies_every_reason_the_writer_emits
test_turnend_guard_grants_no_service_grace
test_claude_hook_registration_preserves_stop_backstop
