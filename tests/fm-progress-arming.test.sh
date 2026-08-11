#!/usr/bin/env bash
# tests/fm-progress-arming.test.sh - the progressing-task predicate
# (bin/fm-progress-lib.sh) and the conditional-arming gate it drives in
# bin/fm-watch-arm.sh. See docs/supervision-arming.md.
#
# Three layers:
#   MAPPING   the state-token -> verdict table, and its deliberate asymmetry
#             (only a positively recognized idle state counts idle).
#   RECORDS   durable per-task verdicts: written, invalidated by any change in
#             the evidence they are bound to, expired by the absolute TTL, and
#             absent-means-progressing.
#   ARM GATE  a real bin/fm-watch-arm.sh subprocess over a hermetic bin/ whose
#             fm-watch.sh and fm-crew-state.sh are stubs, asserting that a fully
#             parked fleet declines to arm and one progressing task does not.
#
# Guard-side consumption (turn-end silence vs alarm) lives in
# fm-turnend-guard.test.sh; watcher-side stale suppression and the
# escalation-requires-a-state-change rule live in fm-watch-triage.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-progress-lib.sh
. "$ROOT/bin/fm-progress-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-progress-arming)

new_state() {  # <name>
  local state="$TMP_ROOT/$1/state"
  mkdir -p "$state"
  printf '%s\n' "$state"
}

# A task with metadata and a status log, the minimum fm_progress_count counts.
seed_task() {  # <state> <id> [status-line]
  local state=$1 id=$2 line=${3:-}
  printf 'window=test:fm-%s\nkind=ship\n' "$id" > "$state/$id.meta"
  [ -z "$line" ] || printf '%s\n' "$line" > "$state/$id.status"
}

# --- MAPPING ----------------------------------------------------------------

test_token_verdict_mapping() {
  local token
  [ "$(fm_progress_token_verdict working)" = progressing ] \
    || fail "working must map to progressing"
  for token in parked blocked paused failed 'done'; do
    [ "$(fm_progress_token_verdict "$token")" = idle ] \
      || fail "$token must map to idle (it changes only when firstmate acts)"
  done
  # Anything not positively recognized is indeterminate, never idle: the caller
  # resolves it toward progressing so an unreadable task keeps the alarm armed.
  [ "$(fm_progress_token_verdict unknown)" = indeterminate ] \
    || fail "unknown must be indeterminate, never idle"
  [ "$(fm_progress_token_verdict '')" = indeterminate ] \
    || fail "an empty state token must be indeterminate, never idle"
  [ "$(fm_progress_token_verdict some-future-state)" = indeterminate ] \
    || fail "an unrecognized future state token must be indeterminate, never idle"
  pass "fm_progress_token_verdict: only positively-idle states count idle"
}

# --- RECORDS ----------------------------------------------------------------

test_record_absent_reads_progressing() {
  local state
  state=$(new_state record-absent)
  seed_task "$state" solo 'working: building'
  if fm_progress_verdict_cached "$state" solo; then
    fail "a task with no record must report a cache miss"
  fi
  [ "$FM_PROGRESS_VERDICT" = progressing ] \
    || fail "a cache miss must default to progressing, got $FM_PROGRESS_VERDICT"
  pass "fm_progress_verdict_cached: no record reads progressing (fail toward the alarm)"
}

test_record_roundtrip_and_invalidation() {
  local state
  state=$(new_state record-roundtrip)
  seed_task "$state" parked1 'needs-decision: pick A or B'
  fm_progress_record_write "$state" parked1 idle parked 'parked at review'
  fm_progress_verdict_cached "$state" parked1 \
    || fail "a freshly written record must read back as valid"
  [ "$FM_PROGRESS_VERDICT" = idle ] || fail "expected idle, got $FM_PROGRESS_VERDICT"
  [ "$FM_PROGRESS_TOKEN" = parked ] || fail "expected token parked, got $FM_PROGRESS_TOKEN"

  fm_progress_record_invalidate "$state" parked1
  if fm_progress_verdict_cached "$state" parked1; then
    fail "an invalidated record must read as a cache miss"
  fi
  [ "$FM_PROGRESS_VERDICT" = progressing ] \
    || fail "an invalidated record must fall back to progressing"
  pass "fm_progress_record_write/invalidate: roundtrip, then absence reverts to progressing"
}

test_record_invalidated_by_changed_evidence() {
  local state f
  for f in status turn-ended meta; do
    state=$(new_state "record-evidence-$f")
    seed_task "$state" t1 'needs-decision: waiting on the captain'
    fm_progress_record_write "$state" t1 idle parked 'parked at review'
    fm_progress_verdict_cached "$state" t1 || fail "[$f] record must start valid"
    # Any change to the evidence a verdict was bound to must invalidate it, so
    # a parked worker that resumes immediately counts progressing again.
    case "$f" in
      status)    printf 'working: resumed after the decision\n' >> "$state/t1.status" ;;
      turn-ended) : > "$state/t1.turn-ended" ;;
      meta)      printf 'harness=claude\n' >> "$state/t1.meta" ;;
    esac
    if fm_progress_verdict_cached "$state" t1; then
      fail "[$f] a changed $f must invalidate the verdict record"
    fi
    [ "$FM_PROGRESS_VERDICT" = progressing ] \
      || fail "[$f] an invalidated record must fall back to progressing"
  done
  pass "verdict records are invalidated by any change to the status, turn-end, or metadata evidence"
}

test_record_expires_on_absolute_ttl() {
  local state
  state=$(new_state record-ttl)
  seed_task "$state" t1 'paused: waiting on an upstream release'
  fm_progress_record_write "$state" t1 idle paused 'declared external wait'
  FM_PROGRESS_RECORD_TTL=0 fm_progress_verdict_cached "$state" t1 \
    && fail "a record at or past the absolute TTL must read as a cache miss"
  fm_progress_verdict_cached "$state" t1 \
    || fail "the same record inside the default TTL must still be valid"
  pass "fm_progress_verdict_cached: the absolute TTL backstop expires a record"
}

test_record_rejects_corrupt_content() {
  local state path
  state=$(new_state record-corrupt)
  seed_task "$state" t1 'needs-decision: something'
  path=$(fm_progress_record_path "$state" t1)
  printf 'v0\t1\tidle\tmeta:absent|status:absent|turnend:absent\tparked\told format\n' > "$path"
  if fm_progress_verdict_cached "$state" t1; then
    fail "an unrecognized record version must read as a cache miss"
  fi
  printf 'garbage\n' > "$path"
  if fm_progress_verdict_cached "$state" t1; then
    fail "a corrupt record must read as a cache miss"
  fi
  [ "$FM_PROGRESS_VERDICT" = progressing ] \
    || fail "a corrupt record must fall back to progressing, never to idle"
  pass "a stale-format or corrupt record fails toward progressing, never toward silence"
}

test_count_parked_fleet_versus_live_fleet() {
  local state id
  state=$(new_state count-parked)
  for id in a b c; do
    seed_task "$state" "$id" 'needs-decision: awaiting the captain'
    fm_progress_record_write "$state" "$id" idle parked 'parked at review'
  done
  fm_progress_count "$state"
  [ "$FM_PROGRESS_TASKS" -eq 3 ] || fail "expected 3 tasks, got $FM_PROGRESS_TASKS"
  [ "$FM_PROGRESS_PROGRESSING" -eq 0 ] \
    || fail "a fully parked fleet must report zero progressing, got $FM_PROGRESS_PROGRESSING"

  # One task resumes: its record is invalidated by the new status line, so the
  # fleet is progressing again without any reconcile.
  printf 'working: resumed\n' >> "$state/b.status"
  fm_progress_count "$state"
  [ "$FM_PROGRESS_PROGRESSING" -eq 1 ] \
    || fail "one resumed task must make the fleet progressing, got $FM_PROGRESS_PROGRESSING"
  [ "$FM_PROGRESS_UNRECORDED" -eq 1 ] \
    || fail "the resumed task must count as unrecorded, got $FM_PROGRESS_UNRECORDED"
  pass "fm_progress_count: a parked fleet reports zero progressing, one live task reports one"
}

test_count_unrecorded_task_counts_progressing() {
  local state
  state=$(new_state count-unrecorded)
  seed_task "$state" fresh
  fm_progress_count "$state"
  [ "$FM_PROGRESS_PROGRESSING" -eq 1 ] \
    || fail "a freshly spawned task with no record must count progressing"
  pass "fm_progress_count: a task with no verdict record counts progressing"
}

test_pollable_work_detected() {
  local state
  state=$(new_state pollable)
  fm_progress_has_pollable_work "$state" && fail "an empty state dir has nothing to poll"
  printf 'echo\n' > "$state/t1.check.sh"
  fm_progress_has_pollable_work "$state" || fail "an armed check poll must count as pollable work"
  rm -f "$state/t1.check.sh"
  mkdir -p "$state/pending-replies"
  fm_progress_has_pollable_work "$state" && fail "an empty pending-replies dir has nothing to poll"
  : > "$state/pending-replies/corr-1"
  fm_progress_has_pollable_work "$state" || fail "a pending reply must count as pollable work"
  pass "fm_progress_has_pollable_work: armed polls and pending replies keep a cycle worth arming"
}

test_reconcile_maps_and_persists() {
  local state fakebin
  state=$(new_state reconcile)
  fakebin="$TMP_ROOT/reconcile/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_FAKE_CREW_STATE:-state: unknown · source: none · fake}"
SH
  chmod +x "$fakebin/fm-crew-state.sh"
  seed_task "$state" t1 'working: building'

  FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    fm_progress_reconcile "$state" t1 >/dev/null
  [ "$FM_PROGRESS_VERDICT" = progressing ] || fail "an active run must reconcile to progressing"
  fm_progress_verdict_cached "$state" t1 || fail "reconcile must persist a valid record"
  [ "$FM_PROGRESS_VERDICT" = progressing ] || fail "the persisted verdict must be progressing"

  FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review: 2 finding(s)' \
    fm_progress_reconcile "$state" t1 >/dev/null
  [ "$FM_PROGRESS_VERDICT" = idle ] || fail "a task parked at a gate must reconcile to idle"

  # An unreadable reader is indeterminate, and the endpoint probe is unavailable
  # here (no fm-backend.sh sourced), so it must resolve toward progressing.
  FM_CREW_STATE_BIN="$fakebin/does-not-exist.sh" fm_progress_reconcile "$state" t1 >/dev/null
  [ "$FM_PROGRESS_VERDICT" = progressing ] \
    || fail "an unreadable crew-state verdict must resolve toward progressing"
  pass "fm_progress_reconcile: maps the reconciled state, persists it, and fails toward progressing"
}

# --- ARM GATE ---------------------------------------------------------------
#
# A hermetic bin/ of symlinks to the real scripts, with fm-watch.sh and
# fm-crew-state.sh replaced by stubs. bash resolves BASH_SOURCE to the symlink
# path, so fm-watch-arm.sh's SCRIPT_DIR is this directory and it forks the stub
# watcher rather than a real one.
make_arm_home() {  # <name>
  local name=$1 home bin
  home="$TMP_ROOT/$name"
  bin="$home/bin"
  mkdir -p "$bin" "$home/state"
  ln -s "$ROOT"/bin/* "$bin/" 2>/dev/null || true
  rm -f "$bin/fm-watch.sh" "$bin/fm-crew-state.sh"
  cat > "$bin/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
# Stub watcher: report one wake immediately so the arm has an honest outcome to
# print without a real supervision cycle.
printf 'signal: stub-wake\n'
exit 0
SH
  cat > "$bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
id=${1:-}
key=$(printf '%s' "$id" | tr -c 'A-Za-z0-9' '_')
var="FM_FAKE_CREW_STATE_$key"
printf '%s\n' "${!var:-${FM_FAKE_CREW_STATE:-state: unknown · source: none · fake default}}"
SH
  chmod +x "$bin/fm-watch.sh" "$bin/fm-crew-state.sh"
  printf '%s\n' "$home"
}

run_arm() {  # <home> [args...]
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CREW_STATE_BIN="$home/bin/fm-crew-state.sh" \
    FM_ARM_CONFIRM_TIMEOUT=1 \
    bash "$home/bin/fm-watch-arm.sh" "$@" 2>&1
}

test_arm_declines_when_every_task_is_idle() {
  local home state out status
  home=$(make_arm_home arm-parked); state="$home/state"
  seed_task "$state" alpha 'needs-decision: pick A or B'
  seed_task "$state" beta 'paused: waiting on an upstream release'
  seed_task "$state" gamma 'failed: pipeline gave up'
  fm_progress_record_write "$state" alpha idle parked 'parked at review'
  fm_progress_record_write "$state" beta idle paused 'declared external wait'
  fm_progress_record_write "$state" gamma idle failed 'run failed'

  out=$(run_arm "$home"); status=$?
  expect_code 0 "$status" "declining to arm is a clean outcome, not a failure"
  assert_contains "$out" "watcher: not armed - nothing to watch" \
    "the decline must be one clear line naming why"
  assert_contains "$out" "3 task(s), none progressing" \
    "the decline must report how many tasks were judged"
  [ -e "$state/.watch.lock" ] && fail "a declined arm must not create a watcher lock"
  pass "fm-watch-arm: declines to arm when every task is parked, paused, or failed"
}

test_arm_declines_with_no_tasks_at_all() {
  local home out status
  home=$(make_arm_home arm-empty)
  out=$(run_arm "$home"); status=$?
  expect_code 0 "$status" "an empty fleet declines cleanly"
  assert_contains "$out" "no tasks, no armed polls" \
    "an empty fleet must say so rather than reporting a task count"
  pass "fm-watch-arm: declines to arm with no tasks and no armed polls"
}

test_arm_proceeds_with_one_progressing_task() {
  local home state out
  home=$(make_arm_home arm-progressing); state="$home/state"
  seed_task "$state" alpha 'needs-decision: pick A or B'
  seed_task "$state" beta 'working: validating'
  fm_progress_record_write "$state" alpha idle parked 'parked at review'
  fm_progress_record_write "$state" beta progressing working 'validating (running)'

  out=$(run_arm "$home")
  case "$out" in
    *"not armed"*) fail "the gate must not decline when a task is progressing: $out" ;;
  esac
  assert_contains "$out" "signal: stub-wake" \
    "with a progressing task the arm must run its watcher cycle exactly as before"
  pass "fm-watch-arm: arms as before when at least one task is progressing"
}

test_arm_proceeds_for_an_unrecorded_working_task() {
  local home state out
  home=$(make_arm_home arm-unrecorded); state="$home/state"
  # A just-spawned task has no verdict record, so the gate reconciles it rather
  # than assuming. bin/fm-spawn.sh therefore needs no change: on the guard side a
  # missing record already counts progressing, and here the reconcile confirms it.
  seed_task "$state" fresh
  out=$(FM_FAKE_CREW_STATE='state: working · source: pane · harness busy' run_arm "$home")
  case "$out" in
    *"not armed"*) fail "an unrecorded task reconciling to working must not be treated as idle: $out" ;;
  esac
  pass "fm-watch-arm: an unrecorded task reconciling to working arms"
}

test_arm_declines_for_a_dead_endpoint() {
  local home state out status
  home=$(make_arm_home arm-dead); state="$home/state"
  # The "dead" case from the acceptance criteria: no confident state reading AND
  # a backend target that cannot be read. That is provably gone, not merely
  # indeterminate, so it is the one unknown reading allowed to count idle.
  seed_task "$state" ghost
  out=$(FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available' run_arm "$home")
  status=$?
  expect_code 0 "$status" "declining on a dead fleet is a clean outcome"
  assert_contains "$out" "watcher: not armed - nothing to watch" \
    "a fleet of only dead endpoints has nothing to watch"
  pass "fm-watch-arm: a task whose endpoint is provably gone counts idle"
}

test_arm_proceeds_for_an_armed_check_poll() {
  local home state out
  home=$(make_arm_home arm-check); state="$home/state"
  seed_task "$state" alpha 'done: PR https://example.test/pr/1 checks green'
  fm_progress_record_write "$state" alpha idle 'done' 'checks green'
  printf 'echo\n' > "$state/alpha.check.sh"
  out=$(run_arm "$home")
  case "$out" in
    *"not armed"*) fail "an armed merge poll must keep a cycle worth arming: $out" ;;
  esac
  pass "fm-watch-arm: an armed poll arms even when no task is progressing"
}

test_arm_force_overrides_the_gate() {
  local home state out
  home=$(make_arm_home arm-force); state="$home/state"
  seed_task "$state" alpha 'needs-decision: pick A or B'
  fm_progress_record_write "$state" alpha idle parked 'parked at review'
  out=$(run_arm "$home" --force)
  case "$out" in
    *"not armed"*) fail "--force must arm a fully idle fleet: $out" ;;
  esac
  assert_contains "$out" "signal: stub-wake" "--force must run the watcher cycle"
  pass "fm-watch-arm: --force deliberately arms past the gate"
}

test_arm_gate_precedes_restart_teardown() {
  local home state out
  home=$(make_arm_home arm-restart); state="$home/state"
  seed_task "$state" alpha 'needs-decision: pick A or B'
  fm_progress_record_write "$state" alpha idle parked 'parked at review'
  # The gate runs BEFORE --restart stops anything, so a declined restart can
  # never leave the home with its old cycle killed and no replacement.
  mkdir -p "$state/.watch.lock"
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  out=$(run_arm "$home" --restart)
  assert_contains "$out" "watcher: not armed - nothing to watch" \
    "--restart must respect the gate"
  [ "$(cat "$state/.watch.lock/pid")" = "$$" ] \
    || fail "a declined --restart must not have touched the recorded watcher lock"
  pass "fm-watch-arm: the gate is evaluated before --restart stops the current cycle"
}

test_arm_reconciles_on_a_cache_miss() {
  local home state out
  home=$(make_arm_home arm-reconcile); state="$home/state"
  seed_task "$state" alpha 'needs-decision: pick A or B'
  # No record at all: the gate must reconcile rather than assume, and the
  # reconciled parked verdict must then decline the arm.
  out=$(FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review' run_arm "$home")
  assert_contains "$out" "watcher: not armed - nothing to watch" \
    "a reconciled parked task must decline the arm"
  assert_contains "$out" "alpha=parked" "the decline must name the reconciled state it judged"
  [ -f "$(fm_progress_record_path "$state" alpha)" ] \
    || fail "the arm's reconcile must persist a verdict record for the hooks to read"
  pass "fm-watch-arm: a cache miss reconciles authoritatively and persists the verdict"
}

test_token_verdict_mapping
test_record_absent_reads_progressing
test_record_roundtrip_and_invalidation
test_record_invalidated_by_changed_evidence
test_record_expires_on_absolute_ttl
test_record_rejects_corrupt_content
test_count_parked_fleet_versus_live_fleet
test_count_unrecorded_task_counts_progressing
test_pollable_work_detected
test_reconcile_maps_and_persists
test_arm_declines_when_every_task_is_idle
test_arm_declines_with_no_tasks_at_all
test_arm_proceeds_with_one_progressing_task
test_arm_proceeds_for_an_unrecorded_working_task
test_arm_declines_for_a_dead_endpoint
test_arm_proceeds_for_an_armed_check_poll
test_arm_force_overrides_the_gate
test_arm_gate_precedes_restart_teardown
test_arm_reconciles_on_a_cache_miss
