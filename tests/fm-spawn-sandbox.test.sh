#!/usr/bin/env bash
# Behavior tests for the worker write boundary fm-spawn.sh writes for claude
# scouts, the unsandboxed tester kind, the captain-present override,
# bin/fm-sandbox-settings.sh (which restores the boundary before a relaunch or
# resume), and bin/fm-promote.sh lifting it when a scout becomes a ship task.
#
# fm-spawn runs against a fake tmux pane and a real isolated git worktree, as in
# tests/fm-spawn-dispatch-profile.test.sh; no real harness starts. Assertions
# read the generated .claude/settings.local.json with jq and the task meta.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
SETTINGS="$ROOT/bin/fm-sandbox-settings.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-sandbox)
# fm-spawn creates /tmp/fm-<id> outside the temp root; cases run in subshells,
# so the ids they use are listed here for the suite-level cleanup.
SPAWNED_IDS=(sbx-scout-a1 sbx-ship-b2 sbx-override-c3 sbx-afk-d4 sbx-batch-e5 sbx-codex-f6 sbx-relaunch-g7 sbx-refuse-h8 sbx-tester-i9 sbx-batch-tester-j1 sbx-conflict-k2 sbx-promote-l3 sbx-promote-tester-m4)

cleanup_task_tmp() {
  local id
  for id in "${SPAWNED_IDS[@]}"; do
    rm -rf "/tmp/fm-$id"
  done
  fm_test_cleanup
}
trap cleanup_task_tmp EXIT

command -v jq >/dev/null 2>&1 || { echo "skip: jq unavailable"; exit 0; }

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        [ "$prev" != "-l" ] || printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        prev=$a
      done
    fi
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_case <name> <harness> <id>: sets CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN LAUNCH_LOG ID
make_case() {
  CASE_DIR="$TMP_ROOT/$1"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  ID=$3
  FAKEBIN=$(make_spawn_fakebin "$CASE_DIR/fake")
  mkdir -p "$HOME_DIR/data/$ID" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
  printf '%s\n' "$2" > "$HOME_DIR/config/crew-harness"
  printf 'brief for %s\n' "$ID" > "$HOME_DIR/data/$ID/brief.md"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$1"
  touch "$HOME_DIR/state/.last-watcher-beat"
  : > "$LAUNCH_LOG"
}

run_spawn() {
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" GROK_HOME="$HOME_DIR/grok-home" PATH="$FAKEBIN:$PATH" \
    "$SPAWN" "$@" 2>&1
}

run_promote() {
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_SPAWN_NO_GUARD=1 PATH="$FAKEBIN:$PATH" "$PROMOTE" "$@" 2>&1
}

run_settings() {
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    "$SETTINGS" "$@" 2>&1
}

phys() {  # <existing path>
  if [ -d "$1" ]; then
    (cd -P "$1" && pwd -P)
  else
    printf '%s/%s\n' "$(cd -P "$(dirname "$1")" && pwd -P)" "$(basename "$1")"
  fi
}

settings_file() { printf '%s/.claude/settings.local.json\n' "$WT_DIR"; }

meta_last() {  # <key>
  grep "^$1=" "$HOME_DIR/state/$ID.meta" | tail -1 | cut -d= -f2-
}

# The exact block every claude worker carried before the boundary existed.
turnend_only_block() {
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch '"'"'%s'"'"'"}]}]}}\n' \
    "$(phys "$HOME_DIR/state")/$ID.turn-ended"
}

assert_sandboxed_settings() {
  local f expected actual state
  f=$(settings_file)
  state=$(phys "$HOME_DIR/state")
  [ "$(jq -r '.sandbox.enabled' "$f")" = true ] || fail "sandbox.enabled is not true"
  [ "$(jq -r '.sandbox.allowUnsandboxedCommands' "$f")" = false ] \
    || fail "allowUnsandboxedCommands must be false so dangerouslyDisableSandbox cannot escape"
  [ "$(jq -r '.sandbox.enableWeakerNetworkIsolation' "$f")" = true ] \
    || fail "enableWeakerNetworkIsolation must be true so gh can verify TLS"
  expected=$(printf '%s\n' "$state/$ID.status" "$state/$ID.turn-ended" \
    "$(phys "$HOME_DIR/data/$ID")" "$(phys "/tmp/fm-$ID")")
  actual=$(jq -r '.sandbox.filesystem.allowWrite[]' "$f")
  [ "$actual" = "$expected" ] || fail "allowWrite is not exactly the task's write set"$'\n'"expected:"$'\n'"$expected"$'\n'"actual:"$'\n'"$actual"
  [ "$(jq '.sandbox | keys | length' "$f")" = 4 ] || fail "unexpected extra sandbox keys: $(jq -c .sandbox "$f")"
  [ "$(jq -r '.hooks.Stop[0].hooks[0].command' "$f")" = "touch '$state/$ID.turn-ended'" ] \
    || fail "turn-end Stop hook was not preserved alongside the sandbox block"
  [ "$(jq -r '.hooks.PreToolUse[0].matcher' "$f")" = "Edit|Write|MultiEdit|NotebookEdit" ] \
    || fail "file-tool guard matcher missing"
  assert_contains "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$f")" \
    "bash '$ROOT/bin/fm-sandbox-guard.sh' '$WT_DIR' '$state/$ID.status'" \
    "file-tool guard command must name the guard, the worktree, and the write set"
}

test_claude_scout_gets_exact_sandbox_block() {
  local out status
  make_case scout-claude claude sbx-scout-a1
  out=$(run_spawn "$ID" "$PROJ_DIR" --scout)
  status=$?
  expect_code 0 "$status" "claude scout spawn should succeed: $out"
  assert_sandboxed_settings
  assert_present "$HOME_DIR/state/$ID.status" "status file must be pre-created for the single-file allowWrite entry"
  assert_present "$HOME_DIR/state/$ID.turn-ended" "turn-ended file must be pre-created"
  [ "$(meta_last sandbox)" = on ] || fail "meta must record sandbox=on"
  assert_no_grep "override=" "$HOME_DIR/state/$ID.meta" "no override recorded without the flag"
  assert_contains "$(cat "$LAUNCH_LOG")" "claude --dangerously-skip-permissions" "autonomy must stay on under the sandbox"
  pass "claude scout launches with the sandbox, the exact write set, the guard, and the turn-end hook"
}

test_ship_gets_no_sandbox() {
  local out status
  make_case ship-claude claude sbx-ship-b2
  out=$(run_spawn "$ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude ship spawn should succeed: $out"
  [ "$(cat "$(settings_file)")" = "$(turnend_only_block)" ] \
    || fail "ship settings must stay byte-identical to the turn-end-only block: $(cat "$(settings_file)")"
  [ "$(meta_last sandbox)" = off ] || fail "meta must record sandbox=off for ship"
  pass "ship tasks keep today's unsandboxed settings and record sandbox=off"
}

test_override_omits_block_once() {
  local out status
  make_case scout-override claude sbx-override-c3
  out=$(run_spawn "$ID" "$PROJ_DIR" --scout --captain-present-override)
  status=$?
  expect_code 0 "$status" "override scout spawn should succeed: $out"
  [ "$(cat "$(settings_file)")" = "$(turnend_only_block)" ] \
    || fail "override must omit the sandbox and guard but keep the turn-end hook: $(cat "$(settings_file)")"
  [ "$(meta_last sandbox)" = override ] || fail "meta must record sandbox=override"
  [ "$(meta_last override)" = captain-present ] || fail "meta must record override=captain-present"
  assert_contains "$(cat "$LAUNCH_LOG")" "claude --dangerously-skip-permissions" "override must leave autonomy unchanged"

  # The next relaunch defaults back to the standing posture; the recorded
  # override is never read back as authorization.
  out=$(run_settings "$ID")
  status=$?
  expect_code 0 "$status" "relaunch restore should succeed: $out"
  assert_contains "$out" "sandbox=on task=$ID" "relaunch restore must report the standing posture"
  assert_sandboxed_settings
  [ "$(meta_last sandbox)" = on ] || fail "relaunch must record sandbox=on"
  [ "$(meta_last override)" = none ] || fail "relaunch without the flag must supersede the override record"
  pass "the override lifts the boundary for one launch, and the next relaunch is sandboxed again"
}

test_override_refused_in_away_mode() {
  local out status
  make_case scout-afk claude sbx-afk-d4
  touch "$HOME_DIR/state/.afk"
  out=$(run_spawn "$ID" "$PROJ_DIR" --scout --captain-present-override)
  status=$?
  [ "$status" -ne 0 ] || fail "override must be refused while state/.afk exists"
  assert_contains "$out" "away mode is active" "refusal must name away mode"
  assert_absent "$HOME_DIR/state/$ID.meta" "a refused override must create no task record"
  assert_absent "$(settings_file)" "a refused override must write no settings"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused override must launch nothing"

  # Same refusal on the relaunch path, leaving the existing settings untouched.
  rm -f "$HOME_DIR/state/.afk"
  out=$(run_spawn "$ID" "$PROJ_DIR" --scout)
  expect_code 0 "$?" "plain scout spawn should succeed: $out"
  cp "$(settings_file)" "$CASE_DIR/before.json"
  touch "$HOME_DIR/state/.afk"
  out=$(run_settings "$ID" --captain-present-override)
  status=$?
  [ "$status" -ne 0 ] || fail "relaunch override must be refused while state/.afk exists"
  assert_contains "$out" "away mode is active" "relaunch refusal must name away mode"
  cmp -s "$CASE_DIR/before.json" "$(settings_file)" || fail "a refused relaunch override must not touch the settings"
  assert_no_grep "override=" "$HOME_DIR/state/$ID.meta" "a refused relaunch override must record nothing"
  pass "the override is refused with no launch and no change while away mode is active"
}

test_override_refused_for_secondmate_and_batch() {
  local out status
  make_case override-batch claude sbx-batch-e5
  out=$(run_spawn "$ID=$PROJ_DIR" --scout --captain-present-override)
  status=$?
  [ "$status" -ne 0 ] || fail "override must be refused in batch dispatch"
  assert_contains "$out" "never valid in batch dispatch" "batch refusal must say why"
  assert_absent "$HOME_DIR/state/$ID.meta" "a refused batch must spawn nothing"

  out=$(run_spawn "$ID" "$CASE_DIR/sm-home" --secondmate --captain-present-override)
  status=$?
  [ "$status" -ne 0 ] || fail "override must be refused for --secondmate"
  assert_contains "$out" "never --secondmate" "secondmate refusal must say why"
  pass "the override is refused for secondmates and in batch dispatch"
}

test_non_claude_scout_records_unsupported() {
  local out status
  make_case scout-codex codex sbx-codex-f6
  out=$(run_spawn "$ID" "$PROJ_DIR" --scout)
  status=$?
  expect_code 0 "$status" "codex scout spawn should succeed: $out"
  [ "$(meta_last sandbox)" = unsupported-harness ] || fail "meta must record sandbox=unsupported-harness"
  assert_absent "$(settings_file)" "a non-claude scout must get no claude settings"
  assert_contains "$(cat "$LAUNCH_LOG")" "--dangerously-bypass-approvals-and-sandbox" "codex launch must be unchanged"
  pass "a non-claude scout launches as before and records sandbox=unsupported-harness"
}

test_relaunch_discards_worker_edits_and_keeps_hooks() {
  local out status f
  make_case relaunch-edit claude sbx-relaunch-g7
  out=$(run_spawn "$ID" "$PROJ_DIR" --scout)
  expect_code 0 "$?" "claude scout spawn should succeed: $out"
  f=$(settings_file)
  # A worker widening its own boundary from inside its writable copy.
  jq '.sandbox.enabled=false | .sandbox.filesystem.allowWrite += ["/"] | .hooks.PreToolUse=[]' "$f" > "$f.new" && mv "$f.new" "$f"
  out=$(run_settings "$ID")
  status=$?
  expect_code 0 "$status" "relaunch restore should succeed: $out"
  assert_sandboxed_settings
  assert_no_grep "override=" "$HOME_DIR/state/$ID.meta" "no override record appears when none was ever used"
  pass "a relaunch regenerates the boundary, discarding worker edits and keeping the turn-end hook"
}

test_settings_refuses_secondmate_and_missing_task() {
  local out status
  make_case settings-refuse claude sbx-refuse-h8
  out=$(run_settings "$ID")
  status=$?
  [ "$status" -ne 0 ] || fail "a task with no record must be refused"
  fm_write_secondmate_meta "$HOME_DIR/state/$ID.meta" "$CASE_DIR"
  out=$(run_settings "$ID")
  status=$?
  [ "$status" -ne 0 ] || fail "a secondmate must be refused"
  assert_contains "$out" "only ship, scout, and tester tasks" "secondmate refusal must say why"
  pass "the relaunch restore refuses a missing task record and a secondmate"
}

test_tester_is_unsandboxed() {
  local out status
  make_case tester-claude claude sbx-tester-i9
  out=$(run_spawn "$ID" "$PROJ_DIR" --tester)
  status=$?
  expect_code 0 "$status" "claude tester spawn should succeed: $out"
  assert_contains "$out" "kind=tester" "spawn must report kind=tester"
  [ "$(meta_last kind)" = tester ] || fail "meta must record kind=tester"
  [ "$(cat "$(settings_file)")" = "$(turnend_only_block)" ] \
    || fail "tester settings must be the turn-end-only block: $(cat "$(settings_file)")"
  [ "$(meta_last sandbox)" = off-tester ] || fail "meta must record sandbox=off-tester"

  # A relaunch keeps a tester unsandboxed.
  out=$(run_settings "$ID")
  expect_code 0 "$?" "tester relaunch restore should succeed: $out"
  assert_contains "$out" "sandbox=off-tester task=$ID" "tester relaunch must keep its posture"
  [ "$(cat "$(settings_file)")" = "$(turnend_only_block)" ] || fail "tester relaunch must stay unsandboxed"
  pass "a tester launches and relaunches unsandboxed and records sandbox=off-tester"
}

test_tester_batch_and_kind_conflict() {
  local out status
  make_case tester-batch claude sbx-batch-tester-j1
  out=$(run_spawn "$ID=$PROJ_DIR" --tester)
  status=$?
  expect_code 0 "$status" "tester batch should succeed: $out"
  [ "$(meta_last kind)" = tester ] || fail "batch must forward --tester to each pair"

  make_case kind-conflict claude sbx-conflict-k2
  out=$(run_spawn "$ID" "$PROJ_DIR" --scout --tester)
  status=$?
  [ "$status" -ne 0 ] || fail "--scout with --tester must be refused"
  assert_contains "$out" "at most one of --scout, --tester, --secondmate" "kind conflict must say why"
  assert_absent "$HOME_DIR/state/$ID.meta" "a refused kind conflict must spawn nothing"
  pass "batch dispatch forwards --tester, and conflicting kind flags are refused"
}

test_promote_lifts_scout_sandbox() {
  local out status
  make_case promote-scout claude sbx-promote-l3
  out=$(run_spawn "$ID" "$PROJ_DIR" --scout)
  expect_code 0 "$?" "claude scout spawn should succeed: $out"
  out=$(run_promote "$ID")
  status=$?
  expect_code 0 "$status" "promote should succeed: $out"
  [ "$(meta_last kind)" = ship ] || fail "promote must flip kind to ship"
  [ "$(meta_last sandbox)" = off ] || fail "promote must record the ship posture"
  [ "$(cat "$(settings_file)")" = "$(turnend_only_block)" ] \
    || fail "promote must rewrite the settings to the ship posture: $(cat "$(settings_file)")"
  assert_contains "$out" "exit it and resume it in the same worktree" "promote must say the running worker is still sandboxed"

  make_case promote-tester claude sbx-promote-tester-m4
  out=$(run_spawn "$ID" "$PROJ_DIR" --tester)
  expect_code 0 "$?" "claude tester spawn should succeed: $out"
  out=$(run_promote "$ID")
  status=$?
  expect_code 0 "$status" "tester promote should succeed: $out"
  [ "$(meta_last kind)" = ship ] || fail "tester promote must flip kind to ship"
  assert_not_contains "$out" "sandbox:" "an unsandboxed tester needs no restart note"
  pass "promotion accepts scouts and testers, and lifts a scout's sandbox with a restart note"
}

run_case test_claude_scout_gets_exact_sandbox_block
run_case test_ship_gets_no_sandbox
run_case test_override_omits_block_once
run_case test_override_refused_in_away_mode
run_case test_override_refused_for_secondmate_and_batch
run_case test_non_claude_scout_records_unsupported
run_case test_relaunch_discards_worker_edits_and_keeps_hooks
run_case test_settings_refuses_secondmate_and_missing_task
run_case test_tester_is_unsandboxed
run_case test_tester_batch_and_kind_conflict
run_case test_promote_lifts_scout_sandbox
fm_case_summary "fm-spawn-sandbox"
