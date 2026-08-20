#!/usr/bin/env bash
# Behavior tests for the idle auto-handoff hook (docs/captain-idle-handoff.md).
#
# The hook is bin/fm-captain-idle-handoff.sh, a UserPromptSubmit entrypoint that
# measures CAPTAIN idleness - the gap between two things the captain actually
# typed - and, past a configurable threshold, tells the agent to run the existing
# /handoff capture and show the captain a "CLEAR BEFORE SESSION" banner.
#
# Everything here is hermetic over temp dirs with an injected clock
# (FM_IDLE_HANDOFF_NOW); no real agent session and no real handoff are involved.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-captain-idle-handoff)
fm_git_identity fmtest fmtest@example.invalid

HOOK=fm-captain-idle-handoff.sh
INJECT_MARK=$'\xE2\x81\xA3'
FROMFIRST_MARK="[fm-from-firstmate]$INJECT_MARK"
HOUR=3600

install_hook_scripts() {
  local dir=$1 f
  mkdir -p "$dir/bin"
  for f in fm-captain-idle-handoff.sh fm-banner-lib.sh fm-primary-scope-lib.sh fm-marker-lib.sh; do
    cp "$ROOT/bin/$f" "$dir/bin/$f"
  done
  chmod +x "$dir/bin/fm-captain-idle-handoff.sh"
}

# A primary-shaped MAIN home: plain (non-worktree) git repo, AGENTS.md, bin/,
# state/ - what the hook's scoping check requires before it will act at all.
make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state" "$dir/config"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_hook_scripts "$dir"
  printf '%s\n' "$dir"
}

make_secondmate_dir() {
  local dir=$1
  make_primary_dir "$dir" >/dev/null
  printf 'sm-idle-1\n' > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

make_crewmate_worktree_dir() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/idle-handoff-test-branch
  mkdir -p "$dir/state" "$dir/config"
  : > "$dir/AGENTS.md"
  install_hook_scripts "$dir"
  printf '%s\n' "$dir"
}

payload() {  # <prompt>
  printf '{"hook_event_name":"UserPromptSubmit","prompt":%s}' "$(printf '%s' "$1" | jq -Rs .)"
}

# run_hook <dir> <now-epoch> [prompt]: invoke the hook with an injected clock,
# setting HOOK_OUT, HOOK_ERR, and HOOK_RC. It deliberately prints nothing, so no
# caller is tempted to wrap it in a command substitution - that would run it in a
# subshell and silently discard the two channels this hook is judged on.
HOOK_OUT=
HOOK_ERR=
HOOK_RC=0
run_hook() {
  local dir=$1 now=$2 prompt=${3:-what is the fleet up to?} outfile errfile
  outfile=$(mktemp "$TMP_ROOT/out.XXXXXX")
  errfile=$(mktemp "$TMP_ROOT/err.XXXXXX")
  payload "$prompt" | FM_IDLE_HANDOFF_NOW="$now" bash "$dir/bin/$HOOK" >"$outfile" 2>"$errfile"
  HOOK_RC=$?
  HOOK_OUT=$(cat "$outfile")
  HOOK_ERR=$(cat "$errfile")
  rm -f "$outfile" "$errfile"
}

seed_stretch() {  # <dir> <last-input-epoch>
  printf '%s\n' "$2" > "$1/state/.last-captain-input"
}

# --- fires -------------------------------------------------------------------

test_fires_past_threshold() {
  local dir out now last
  dir=$(make_primary_dir "$TMP_ROOT/fire")
  now=1800000000
  last=$((now - 8 * HOUR))
  seed_stretch "$dir" "$last"
  run_hook "$dir" "$now"
  out=$HOOK_OUT
  expect_code 0 "$HOOK_RC" "the hook must never fail a turn"
  assert_contains "$out" 'CLEAR BEFORE SESSION' "fired run must carry the reminder headline"
  assert_contains "$out" 'load the `handoff` skill' "fired run must direct the agent at the existing handoff capture"
  assert_contains "$out" 'data/handoffs/' "fired run must name the existing handoff destination"
  assert_contains "$HOOK_ERR" 'CLEAR BEFORE SESSION' "the banner must also reach stderr"
  assert_grep "$last" "$dir/state/.captain-idle-handoff" "fired run must claim the stretch it captured"
  assert_grep "fired" "$dir/state/.captain-idle-handoff.log" "fired run must be logged"
  assert_grep "$now" "$dir/state/.last-captain-input" "a firing prompt still closes the stretch it measured"
  pass "idle auto-handoff: fires past the threshold with directive, banner, and claim"
}

test_banner_reports_the_measured_gap_and_path_slot() {
  local dir out now
  dir=$(make_primary_dir "$TMP_ROOT/fire-detail")
  now=1800000000
  seed_stretch "$dir" $((now - 7 * HOUR - 36 * 60))
  run_hook "$dir" "$now"
  out=$HOOK_OUT
  assert_contains "$out" 'You were away 7h 36m' "banner must state how long the captain was away"
  assert_contains "$out" '{{HANDOFF_PATH}}' "banner must leave a slot for the handoff path the agent writes"
  assert_contains "$out" 'replaced by the real path of the handoff document' \
    "the directive must tell the agent to fill the path slot in"
  pass "idle auto-handoff: banner carries the measured gap and a slot for the handoff path"
}

test_banner_reuses_the_shared_alarm_shape() {
  local dir out rule
  dir=$(make_primary_dir "$TMP_ROOT/fire-shape")
  seed_stretch "$dir" $((1800000000 - 8 * HOUR))
  run_hook "$dir" 1800000000
  out=$HOOK_OUT
  # shellcheck source=bin/fm-banner-lib.sh
  . "$ROOT/bin/fm-banner-lib.sh"
  rule="●$FM_BANNER_RULE"
  assert_contains "$out" "$rule" "the reminder must use the shared attention-banner rule, not its own"
  assert_contains "$out" "●  CLEAR BEFORE SESSION" "the headline must use the shared bullet-prefixed line shape"
  pass "idle auto-handoff: reuses the shared attention-banner shape"
}

test_fires_again_on_a_later_stretch() {
  local dir out now
  dir=$(make_primary_dir "$TMP_ROOT/fire-twice")
  now=1800000000
  seed_stretch "$dir" $((now - 8 * HOUR))
  run_hook "$dir" "$now"
  # A second quiet stretch, opened by the clock the first fire just wrote.
  run_hook "$dir" $((now + 9 * HOUR))
  out=$HOOK_OUT
  assert_contains "$out" 'CLEAR BEFORE SESSION' "the reminder must fire on EVERY auto-handoff, not only the first"
  pass "idle auto-handoff: fires again on the next quiet stretch"
}

# --- does not fire -----------------------------------------------------------

test_silent_before_threshold() {
  local dir out now
  dir=$(make_primary_dir "$TMP_ROOT/not-idle")
  now=1800000000
  seed_stretch "$dir" $((now - 40 * 60))
  run_hook "$dir" "$now"
  out=$HOOK_OUT
  expect_code 0 "$HOOK_RC" "an ordinary prompt must exit 0"
  [ -z "$out" ] || fail "a 40-minute gap must produce no reminder, got: $out"
  [ -z "$HOOK_ERR" ] || fail "a 40-minute gap must print no banner, got: $HOOK_ERR"
  assert_absent "$dir/state/.captain-idle-handoff" "no claim may be recorded below the threshold"
  assert_grep "$now" "$dir/state/.last-captain-input" "an ordinary prompt still advances the captain clock"
  pass "idle auto-handoff: silent below the threshold"
}

test_already_captured_for_this_stretch() {
  local dir out now last
  dir=$(make_primary_dir "$TMP_ROOT/already")
  now=1800000000
  last=$((now - 8 * HOUR))
  seed_stretch "$dir" "$last"
  printf '%s\n' "$last" > "$dir/state/.captain-idle-handoff"
  run_hook "$dir" "$now"
  out=$HOOK_OUT
  expect_code 0 "$HOOK_RC" "a repeat of the same stretch must exit 0"
  [ -z "$out" ] || fail "the same quiet stretch must not be captured twice, got: $out"
  [ -z "$HOOK_ERR" ] || fail "the same quiet stretch must not re-banner, got: $HOOK_ERR"
  assert_grep "already-captured" "$dir/state/.captain-idle-handoff.log" "the skipped repeat must be logged"
  pass "idle auto-handoff: one capture per quiet stretch, never a duplicate"
}

test_no_prior_captain_input_starts_the_clock_silently() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/first-ever")
  run_hook "$dir" 1800000000
  out=$HOOK_OUT
  [ -z "$out" ] || fail "with no measured stretch there is nothing to act on, got: $out"
  assert_grep '1800000000' "$dir/state/.last-captain-input" "the first prompt must start the captain clock"
  pass "idle auto-handoff: a first prompt starts the clock and says nothing"
}

test_daemon_injection_is_not_captain_input() {
  local dir out now last
  dir=$(make_primary_dir "$TMP_ROOT/inject")
  now=1800000000
  last=$((now - 8 * HOUR))
  seed_stretch "$dir" "$last"
  run_hook "$dir" "$now" "${INJECT_MARK}escalation: PR is red"
  out=$HOOK_OUT
  [ -z "$out" ] || fail "an away-mode escalation is not the captain returning, got: $out"
  assert_grep "$last" "$dir/state/.last-captain-input" "a daemon injection must not advance the captain clock"
  pass "idle auto-handoff: an away-mode injection neither fires nor resets the captain clock"
}

test_from_firstmate_relay_is_not_captain_input() {
  local dir out now last
  dir=$(make_primary_dir "$TMP_ROOT/relay")
  now=1800000000
  last=$((now - 8 * HOUR))
  seed_stretch "$dir" "$last"
  run_hook "$dir" "$now" "${FROMFIRST_MARK}please rebase the branch"
  out=$HOOK_OUT
  [ -z "$out" ] || fail "a supervisor relay is not the captain returning, got: $out"
  assert_grep "$last" "$dir/state/.last-captain-input" "a supervisor relay must not advance the captain clock"
  pass "idle auto-handoff: a from-firstmate relay neither fires nor resets the captain clock"
}

test_away_mode_owns_the_session() {
  local dir out now
  dir=$(make_primary_dir "$TMP_ROOT/afk")
  now=1800000000
  seed_stretch "$dir" $((now - 8 * HOUR))
  : > "$dir/state/.afk"
  run_hook "$dir" "$now"
  out=$HOOK_OUT
  [ -z "$out" ] || fail "away mode owns the session; the hook must stay out of it, got: $out"
  assert_absent "$dir/state/.captain-idle-handoff" "away mode must leave no claim behind"
  assert_grep "$now" "$dir/state/.last-captain-input" "away mode still keeps the captain clock honest"
  pass "idle auto-handoff: stays out of the way while away mode is active"
}

test_silent_in_secondmate_home() {
  local dir out
  dir=$(make_secondmate_dir "$TMP_ROOT/secondmate")
  seed_stretch "$dir" $((1800000000 - 8 * HOUR))
  run_hook "$dir" 1800000000
  out=$HOOK_OUT
  [ -z "$out" ] || fail "a secondmate has no captain to remind, got: $out"
  pass "idle auto-handoff: silent in a secondmate's own home"
}

test_silent_in_crewmate_worktree() {
  local base dir out
  base="$TMP_ROOT/crew-base"
  dir=$(make_crewmate_worktree_dir "$base" "$TMP_ROOT/crew-worktree")
  seed_stretch "$dir" $((1800000000 - 8 * HOUR))
  run_hook "$dir" 1800000000
  out=$HOOK_OUT
  [ -z "$out" ] || fail "a task worktree is not a captain session, got: $out"
  pass "idle auto-handoff: silent inside a crewmate task worktree"
}

test_silent_without_stdin() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/nostdin")
  seed_stretch "$dir" $((1800000000 - 8 * HOUR))
  out=$(FM_IDLE_HANDOFF_NOW=1800000000 bash "$dir/bin/$HOOK" < /dev/null 2>&1)
  status=$?
  expect_code 0 "$status" "an empty payload must exit 0"
  [ -z "$out" ] || fail "an empty payload must produce no output, got: $out"
  pass "idle auto-handoff: silent no-op on an empty payload"
}

test_silent_without_jq() {
  local dir out status fakebin tool tool_path
  dir=$(make_primary_dir "$TMP_ROOT/nojq")
  seed_stretch "$dir" $((1800000000 - 8 * HOUR))
  fakebin=$(fm_fakebin "$TMP_ROOT/nojq-fake")
  for tool in bash sh git cat printf date tr uname stat mkdir dirname; do
    tool_path=$(command -v "$tool") || fail "test host must provide $tool"
    ln -sf "$tool_path" "$fakebin/$tool"
  done
  out=$(payload hello | PATH="$fakebin" FM_IDLE_HANDOFF_NOW=1800000000 bash "$dir/bin/$HOOK" 2>&1)
  status=$?
  expect_code 0 "$status" "a missing jq must never fail a turn"
  [ -z "$out" ] || fail "without jq the hook must be a silent no-op, got: $out"
  assert_absent "$dir/state/.captain-idle-handoff" "without jq the hook must leave no side effects"
  pass "idle auto-handoff: silent no-op with no side effects when jq is missing"
}

# --- delivery is never blocked by the banner ---------------------------------

test_banner_failure_still_delivers_the_handoff() {
  local dir out last now
  dir=$(make_primary_dir "$TMP_ROOT/banner-fail")
  now=1800000000
  last=$((now - 8 * HOUR))
  seed_stretch "$dir" "$last"
  # Close stderr outright: the banner's own write fails, and the run must still
  # deliver the capture directive, claim the stretch, and exit 0.
  out=$(payload hello | FM_IDLE_HANDOFF_NOW="$now" bash "$dir/bin/$HOOK" 2>&-)
  expect_code 0 "$?" "a failed banner print must not fail the turn"
  assert_contains "$out" 'load the `handoff` skill' "the capture directive must survive a failed banner print"
  assert_grep "$last" "$dir/state/.captain-idle-handoff" "the handoff still counts as delivered when the banner cannot print"
  assert_grep "banner-stderr-failed" "$dir/state/.captain-idle-handoff.log" \
    "a failed banner print must be logged, not escalated"
  pass "idle auto-handoff: a failed banner print still counts the handoff as delivered"
}

# --- threshold configuration --------------------------------------------------

test_threshold_defaults_conservatively() {
  local default
  default=$(grep -E '^DEFAULT_THRESHOLD=' "$ROOT/bin/$HOOK" | cut -d= -f2)
  [ "$default" = "14400" ] || fail "default threshold must stay 4 hours (14400s), got $default"
  pass "idle auto-handoff: defaults to a conservative 4-hour quiet stretch"
}

test_default_threshold_ignores_an_ordinary_break() {
  local dir out now
  dir=$(make_primary_dir "$TMP_ROOT/lunch")
  now=1800000000
  # Just under the 4h default: a long lunch or a meeting, not a gap worth nagging about.
  seed_stretch "$dir" $((now - 14399))
  run_hook "$dir" "$now"
  out=$HOOK_OUT
  [ -z "$out" ] || fail "an ordinary break must not trigger the reminder, got: $out"
  pass "idle auto-handoff: an ordinary in-day break stays under the default threshold"
}

test_threshold_configurable_by_file() {
  local dir out now
  dir=$(make_primary_dir "$TMP_ROOT/config-threshold")
  now=1800000000
  printf '# quiet stretch before an auto-handoff\n3600\n' > "$dir/config/idle-handoff"
  seed_stretch "$dir" $((now - 2 * HOUR))
  run_hook "$dir" "$now"
  out=$HOOK_OUT
  assert_contains "$out" 'CLEAR BEFORE SESSION' "config/idle-handoff must lower the threshold"
  pass "idle auto-handoff: config/idle-handoff sets the threshold"
}

test_threshold_off_disables_the_hook() {
  local dir out now
  dir=$(make_primary_dir "$TMP_ROOT/off")
  now=1800000000
  printf 'off\n' > "$dir/config/idle-handoff"
  seed_stretch "$dir" $((now - 12 * HOUR))
  run_hook "$dir" "$now"
  out=$HOOK_OUT
  [ -z "$out" ] || fail "an 'off' setting must disable the reminder entirely, got: $out"
  pass "idle auto-handoff: 'off' disables the reminder"
}

test_bad_threshold_falls_back_to_the_default() {
  local dir out now
  dir=$(make_primary_dir "$TMP_ROOT/bad-threshold")
  now=1800000000
  printf 'soon\n' > "$dir/config/idle-handoff"
  seed_stretch "$dir" $((now - 2 * HOUR))
  run_hook "$dir" "$now"
  out=$HOOK_OUT
  [ -z "$out" ] || fail "an unreadable threshold must fall back to the conservative default, got: $out"
  assert_grep "bad-threshold" "$dir/state/.captain-idle-handoff.log" "an unreadable threshold must be logged"
  pass "idle auto-handoff: an unreadable threshold falls back to the default and is logged"
}

test_env_threshold_overrides_the_file() {
  local dir out now
  dir=$(make_primary_dir "$TMP_ROOT/env-threshold")
  now=1800000000
  printf 'off\n' > "$dir/config/idle-handoff"
  seed_stretch "$dir" $((now - 2 * HOUR))
  out=$(payload hello | FM_IDLE_HANDOFF_NOW="$now" FM_IDLE_HANDOFF_SECONDS=3600 bash "$dir/bin/$HOOK" 2>/dev/null)
  assert_contains "$out" 'CLEAR BEFORE SESSION' "FM_IDLE_HANDOFF_SECONDS must win over the file"
  pass "idle auto-handoff: FM_IDLE_HANDOFF_SECONDS overrides config/idle-handoff"
}

# --- a live fleet is untouched ------------------------------------------------

test_live_supervised_fleet_is_unaffected() {
  local dir out before after
  dir=$(make_primary_dir "$TMP_ROOT/live-fleet")
  : > "$dir/state/task1.meta"
  printf 'working: implementing\n' > "$dir/state/task1.status"
  printf 'progressing 1800000000\n' > "$dir/state/.progress-task1"
  printf 'record\n' > "$dir/state/.wake-queue"
  touch "$dir/state/.last-watcher-beat"
  printf '%s\n' "$$" > "$dir/state/.watch.lock"
  before=$(cd "$dir/state" && ls -1 | sort | tr '\n' ' ')
  seed_stretch "$dir" $((1800000000 - 8 * HOUR))
  run_hook "$dir" 1800000000
  out=$HOOK_OUT
  assert_contains "$out" 'CLEAR BEFORE SESSION' "a live fleet must not suppress the captain's reminder"
  after=$(cd "$dir/state" && ls -1 | sort | tr '\n' ' ')
  assert_grep 'record' "$dir/state/.wake-queue" "the hook must not drain the wake queue"
  assert_grep 'working: implementing' "$dir/state/task1.status" "the hook must not touch task status"
  assert_grep 'progressing' "$dir/state/.progress-task1" "the hook must not rewrite progress verdicts"
  assert_grep "$$" "$dir/state/.watch.lock" "the hook must not disturb the watcher lock"
  # The only new files are the three this hook owns.
  case "$after" in
    "$before"*|*) : ;;
  esac
  for f in $after; do
    case "$f" in
      .captain-idle-handoff|.captain-idle-handoff.log|.last-captain-input) continue ;;
    esac
    case " $before " in
      *" $f "*) : ;;
      *) fail "the hook created an unexpected state file: $f" ;;
    esac
  done
  pass "idle auto-handoff: a live, actively-supervised fleet is unaffected"
}

test_runs_fast() {
  local dir start elapsed_s
  dir=$(make_primary_dir "$TMP_ROOT/timing")
  seed_stretch "$dir" $((1800000000 - 8 * HOUR))
  start=$SECONDS
  run_hook "$dir" 1800000000
  elapsed_s=$((SECONDS - start))
  [ "$elapsed_s" -lt 3 ] || fail "hook took ${elapsed_s}s, expected well under a second (generous 3s CI margin)"
  pass "idle auto-handoff: runs well under the generous timing margin (${elapsed_s}s)"
}

# --- tracked wiring and captain-facing wording --------------------------------

test_claude_hook_is_registered() {
  local settings command
  settings="$ROOT/.claude/settings.json"
  command=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command // empty' "$settings")
  [ -n "$command" ] || fail "UserPromptSubmit hook is missing from .claude/settings.json"
  assert_contains "$command" 'CLAUDE_PROJECT_DIR' "the hook must resolve via CLAUDE_PROJECT_DIR, not a cwd-relative path"
  assert_contains "$command" 'fm-captain-idle-handoff.sh' "the UserPromptSubmit hook must invoke the idle auto-handoff entrypoint"
  pass ".claude/settings.json: the idle auto-handoff hook is registered on UserPromptSubmit"
}

test_config_file_is_gitignored() {
  assert_grep 'config/idle-handoff' "$ROOT/.gitignore" "config/idle-handoff must stay local and gitignored"
  pass "config/idle-handoff is a local, gitignored operating choice"
}

test_banner_stays_in_captain_language() {
  local dir out term
  dir=$(make_primary_dir "$TMP_ROOT/wording")
  seed_stretch "$dir" $((1800000000 - 8 * HOUR))
  run_hook "$dir" 1800000000
  out=$HOOK_ERR
  # AGENTS.md section 9: captain-facing text carries no internal vocabulary.
  for term in crewmate worktree teardown watcher heartbeat "wake queue" "fail-open" "fail-closed" \
      "task id" brief harness backend "prompt cache" token; do
    assert_not_contains "$out" "$term" "the captain-facing banner must not use internal vocabulary"
  done
  pass "idle auto-handoff: the banner stays in plain captain-facing language"
}

test_never_clears_or_enters_away_mode() {
  local body
  body=$(cat "$ROOT/bin/$HOOK")
  assert_contains "$body" 'Do NOT clear or compact anything yourself' \
    "the directive must forbid the agent from clearing the session itself"
  assert_contains "$body" 'do NOT enter away mode' "the directive must forbid entering away mode"
  assert_not_contains "$body" 'fm-afk' "the hook must never reach for away-mode machinery"
  assert_not_contains "$body" 'touch "$STATE/.afk"' "the hook must never set the away-mode flag"
  pass "idle auto-handoff: never clears the session and never enters away mode"
}

test_handoff_skill_declares_the_unprompted_trigger() {
  local skill
  skill="$ROOT/.agents/skills/handoff/SKILL.md"
  assert_grep 'bin/fm-captain-idle-handoff.sh' "$skill" \
    "the handoff skill must name the hook that invokes it unprompted"
  assert_grep 'CLEAR BEFORE SESSION' "$skill" \
    "the handoff skill must carry the banner obligation for an unprompted capture"
  pass "handoff skill: declares the unprompted idle trigger and its banner obligation"
}

run_case test_fires_past_threshold
run_case test_banner_reports_the_measured_gap_and_path_slot
run_case test_banner_reuses_the_shared_alarm_shape
run_case test_fires_again_on_a_later_stretch
run_case test_silent_before_threshold
run_case test_already_captured_for_this_stretch
run_case test_no_prior_captain_input_starts_the_clock_silently
run_case test_daemon_injection_is_not_captain_input
run_case test_from_firstmate_relay_is_not_captain_input
run_case test_away_mode_owns_the_session
run_case test_silent_in_secondmate_home
run_case test_silent_in_crewmate_worktree
run_case test_silent_without_stdin
run_case test_silent_without_jq
run_case test_banner_failure_still_delivers_the_handoff
run_case test_threshold_defaults_conservatively
run_case test_default_threshold_ignores_an_ordinary_break
run_case test_threshold_configurable_by_file
run_case test_threshold_off_disables_the_hook
run_case test_bad_threshold_falls_back_to_the_default
run_case test_env_threshold_overrides_the_file
run_case test_live_supervised_fleet_is_unaffected
run_case test_runs_fast
run_case test_claude_hook_is_registered
run_case test_config_file_is_gitignored
run_case test_banner_stays_in_captain_language
run_case test_never_clears_or_enters_away_mode
run_case test_handoff_skill_declares_the_unprompted_trigger
fm_case_summary "idle auto-handoff"
