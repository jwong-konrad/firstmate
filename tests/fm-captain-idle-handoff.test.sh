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
  for f in fm-captain-idle-handoff.sh fm-banner-lib.sh fm-primary-scope-lib.sh fm-marker-lib.sh \
      fm-context-fill-lib.sh; do
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
  # shellcheck disable=SC2016  # single quotes are deliberate: a literal needle string, not an expansion
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
  local dir out now last
  dir=$(make_primary_dir "$TMP_ROOT/afk")
  now=1800000000
  last=$((now - 8 * HOUR))
  seed_stretch "$dir" "$last"
  : > "$dir/state/.afk"
  run_hook "$dir" "$now"
  out=$HOOK_OUT
  [ -z "$out" ] || fail "away mode owns the session; the hook must stay out of it, got: $out"
  assert_absent "$dir/state/.captain-idle-handoff" "away mode must leave no claim behind"
  # Deferring must PRESERVE the stretch, not consume it. Away mode can now be
  # armed on the captain's behalf after 30 quiet minutes (bin/fm-auto-afk.sh),
  # so advancing the clock here would let a short auto-arm silently swallow
  # every long gap this hook exists to capture.
  assert_grep "$last" "$dir/state/.last-captain-input" \
    "deferring to away mode must preserve the quiet stretch, not advance the clock"
  pass "idle auto-handoff: defers to away mode without consuming the quiet stretch"
}

test_the_deferred_stretch_is_captured_once_away_mode_clears() {
  local dir now last
  dir=$(make_primary_dir "$TMP_ROOT/afk-deferred")
  now=1800000000
  last=$((now - 8 * HOUR))
  seed_stretch "$dir" "$last"
  : > "$dir/state/.afk"
  run_hook "$dir" "$now"
  [ -z "$HOOK_OUT" ] || fail "the hook must stay silent while away mode is active"
  # Away mode exits; the very next captain message is still measured against the
  # real eight-hour gap.
  rm -f "$dir/state/.afk"
  run_hook "$dir" $((now + 120))
  assert_contains "$HOOK_OUT" 'CLEAR BEFORE SESSION' \
    "the preserved stretch must still be captured on the first message after away mode clears"
  assert_grep "$last" "$dir/state/.captain-idle-handoff" \
    "the capture must claim the stretch it actually measured"
  pass "idle auto-handoff: a stretch deferred by away mode is captured once it clears"
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
  # shellcheck disable=SC2016  # single quotes are deliberate: a literal needle string, not an expansion
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
  before=$(find "$dir/state" -maxdepth 1 -mindepth 1 -exec basename {} \; | LC_ALL=C sort | tr '\n' ' ')
  seed_stretch "$dir" $((1800000000 - 8 * HOUR))
  run_hook "$dir" 1800000000
  out=$HOOK_OUT
  assert_contains "$out" 'CLEAR BEFORE SESSION' "a live fleet must not suppress the captain's reminder"
  after=$(find "$dir/state" -maxdepth 1 -mindepth 1 -exec basename {} \; | LC_ALL=C sort | tr '\n' ' ')
  assert_grep 'record' "$dir/state/.wake-queue" "the hook must not drain the wake queue"
  assert_grep 'working: implementing' "$dir/state/task1.status" "the hook must not touch task status"
  assert_grep 'progressing' "$dir/state/.progress-task1" "the hook must not rewrite progress verdicts"
  assert_grep "$$" "$dir/state/.watch.lock" "the hook must not disturb the watcher lock"
  # The only new files are the three this hook owns.
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
  # It may NAME the sibling that does enter away mode - explaining why this one
  # does not advance the clock requires saying so - but must never reach for the
  # lifecycle itself.
  assert_not_contains "$body" 'fm-afk-launch' "the hook must never reach for away-mode machinery"
  assert_not_contains "$body" 'fm-afk-start' "the hook must never reach for away-mode machinery"
  # shellcheck disable=SC2016  # single quotes are deliberate: a literal needle string, not an expansion
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

# --- context-fill trigger -------------------------------------------------------
# The same hook's second condition: capture shortly before Claude Code
# auto-compacts. Transcripts are synthetic JSONL carrying only the two line
# shapes the reader uses (bin/fm-context-fill-lib.sh), with a 1M window unless a
# case says otherwise. With a 1M window the effective window is 980000 tokens,
# so a 45% compaction setting compacts at 441000 and the default 5-point margin
# fires at 392000; with no setting Claude Code compacts at 967000 and the hook
# fires at 918000.

CTX_NOW=1800000000

ctx_model() {  # <transcript> <model-id>
  printf '{"type":"attachment","isSidechain":false,"attachment":{"type":"model","identity":{"modelId":"%s","marketingName":"Test"}}}\n' "$2" >> "$1"
}

ctx_usage() {  # <transcript> <total-tokens>
  printf '{"type":"assistant","isSidechain":false,"message":{"model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":%s,"output_tokens":50}}}\n' "$(($2 - 152))" >> "$1"
}

ctx_compact() {  # <transcript> <post-compaction-tokens>
  printf '{"type":"system","subtype":"compact_boundary","isSidechain":false,"compactMetadata":{"trigger":"auto","preTokens":450000,"postTokens":%s}}\n' "$2" >> "$1"
}

# ctx_transcript <path> <fill> [model]: a fresh transcript at that fill.
ctx_transcript() {
  : > "$1"
  ctx_model "$1" "${3:-claude-opus-5-5[1m]}"
  printf '{"type":"user","isSidechain":false,"message":{"content":"hello"}}\n' >> "$1"
  ctx_usage "$1" "$2"
}

# A primary home whose captain spoke a minute ago, so the quiet-stretch
# condition stays out of every context case unless one seeds it on purpose.
ctx_primary() {  # <name>
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/$1")
  seed_stretch "$dir" $((CTX_NOW - 60))
  printf '%s\n' "$dir"
}

# run_ctx_hook <dir> <now> <transcript> <prompt> [VAR=value...]: run the hook
# with a transcript in the payload and a hermetic compaction environment - the
# measuring host's own CLAUDE_AUTOCOMPACT_PCT_OVERRIDE must never leak in.
run_ctx_hook() {
  local dir=$1 now=$2 transcript=$3 prompt=$4 outfile errfile
  shift 4
  outfile=$(mktemp "$TMP_ROOT/out.XXXXXX")
  errfile=$(mktemp "$TMP_ROOT/err.XXXXXX")
  jq -cn --arg p "$prompt" --arg t "$transcript" \
      '{hook_event_name:"UserPromptSubmit", prompt:$p, transcript_path:$t}' \
    | env -u CLAUDE_AUTOCOMPACT_PCT_OVERRIDE -u FM_CONTEXT_HANDOFF_MARGIN -u FM_CONTEXT_WINDOW_TOKENS \
        -u CLAUDE_CODE_AUTO_COMPACT_WINDOW -u DISABLE_AUTO_COMPACT -u DISABLE_COMPACT \
        -u CLAUDE_CODE_DISABLE_1M_CONTEXT -u CLAUDE_CODE_MAX_OUTPUT_TOKENS -u FM_IDLE_HANDOFF_SECONDS \
        FM_IDLE_HANDOFF_NOW="$now" "$@" bash "$dir/bin/$HOOK" >"$outfile" 2>"$errfile"
  HOOK_RC=$?
  HOOK_OUT=$(cat "$outfile")
  HOOK_ERR=$(cat "$errfile")
  rm -f "$outfile" "$errfile"
}

test_context_fires_at_the_derived_point() {
  local dir t
  dir=$(ctx_primary ctx-fire)
  t="$dir/session.jsonl"
  ctx_transcript "$t" 392000
  run_ctx_hook "$dir" "$CTX_NOW" "$t" 'where are we?' CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45
  expect_code 0 "$HOOK_RC" "the hook must never fail a turn"
  assert_contains "$HOOK_OUT" 'CLEAR BEFORE SESSION' "a fill at the fire point must carry the reminder"
  # shellcheck disable=SC2016  # single quotes are deliberate: a literal needle string, not an expansion
  assert_contains "$HOOK_OUT" 'load the `handoff` skill' "the context condition must reuse the same capture directive"
  assert_contains "$HOOK_OUT" 'This session is 40% full and compacts itself at 45%' \
    "the banner must state the fill and the compaction point in the captain's own setting's units"
  assert_contains "$HOOK_OUT" '392000-token' "the directive must name the derived fire point"
  assert_contains "$HOOK_ERR" 'CLEAR BEFORE SESSION' "the banner must also reach stderr"
  assert_grep "$t" "$dir/state/.context-handoff" "a fire must claim this climb"
  assert_grep 'context-fired' "$dir/state/.captain-idle-handoff.log" "a fire must be logged"
  pass "context handoff: fires at the compaction point less the default margin"
}

test_context_silent_just_below_the_point() {
  local dir t
  dir=$(ctx_primary ctx-below)
  t="$dir/session.jsonl"
  ctx_transcript "$t" 391999
  run_ctx_hook "$dir" "$CTX_NOW" "$t" 'where are we?' CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45
  expect_code 0 "$HOOK_RC" "an ordinary prompt must exit 0"
  [ -z "$HOOK_OUT$HOOK_ERR" ] || fail "one token under the fire point must be silent, got: $HOOK_OUT$HOOK_ERR"
  assert_absent "$dir/state/.context-handoff" "a silent prompt must not claim a climb"
  pass "context handoff: silent one token under the fire point"
}

test_context_uses_the_default_compaction_point_without_an_override() {
  local dir t
  dir=$(ctx_primary ctx-default)
  t="$dir/session.jsonl"
  ctx_transcript "$t" 917999
  run_ctx_hook "$dir" "$CTX_NOW" "$t" 'where are we?'
  [ -z "$HOOK_OUT" ] || fail "without an override the fire point is 918000, got: $HOOK_OUT"
  ctx_usage "$t" 918000
  run_ctx_hook "$dir" "$CTX_NOW" "$t" 'where are we?'
  assert_contains "$HOOK_OUT" 'CLEAR BEFORE SESSION' "past Claude Code's default point less the margin must fire"
  assert_contains "$HOOK_OUT" 'compacts itself at 99%' "the banner must report Claude Code's default compaction point"
  pass "context handoff: derives the fire point from Claude Code's default when no override is set"
}

test_context_margin_is_configurable() {
  local dir t
  dir=$(ctx_primary ctx-margin)
  t="$dir/session.jsonl"
  printf '# points before compaction\n10\n' > "$dir/config/context-handoff"
  ctx_transcript "$t" 342999
  run_ctx_hook "$dir" "$CTX_NOW" "$t" 'where are we?' CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45
  [ -z "$HOOK_OUT" ] || fail "a 10-point margin fires at 343000, got: $HOOK_OUT"
  ctx_usage "$t" 343000
  run_ctx_hook "$dir" "$CTX_NOW" "$t" 'where are we?' CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45
  assert_contains "$HOOK_OUT" 'CLEAR BEFORE SESSION' "config/context-handoff must move the fire point"
  # The environment overrides the file.
  rm -f "$dir/state/.context-handoff"
  run_ctx_hook "$dir" "$CTX_NOW" "$t" 'where are we?' CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45 FM_CONTEXT_HANDOFF_MARGIN=2
  [ -z "$HOOK_OUT" ] || fail "FM_CONTEXT_HANDOFF_MARGIN must override the file, got: $HOOK_OUT"
  pass "context handoff: the margin is configurable by file and overridable by environment"
}

test_context_margin_off_disables_only_this_condition() {
  local dir t
  dir=$(make_primary_dir "$TMP_ROOT/ctx-off")
  t="$dir/session.jsonl"
  printf 'off\n' > "$dir/config/context-handoff"
  ctx_transcript "$t" 440000
  seed_stretch "$dir" $((CTX_NOW - 60))
  run_ctx_hook "$dir" "$CTX_NOW" "$t" 'where are we?' CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45
  [ -z "$HOOK_OUT" ] || fail "off must disable the context condition, got: $HOOK_OUT"
  assert_absent "$dir/state/.context-handoff" "off must never claim a climb"
  seed_stretch "$dir" $((CTX_NOW - 8 * HOUR))
  run_ctx_hook "$dir" "$CTX_NOW" "$t" 'where are we?' CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45
  assert_contains "$HOOK_OUT" 'You were away 8h 0m' "turning the context condition off must leave the quiet-stretch one working"
  pass "context handoff: off disables the context condition and nothing else"
}

test_context_malformed_margin_falls_back_to_the_default() {
  local dir t bad
  for bad in abc 0 -3 150; do
    dir=$(ctx_primary "ctx-bad-$bad")
    t="$dir/session.jsonl"
    printf '%s\n' "$bad" > "$dir/config/context-handoff"
    ctx_transcript "$t" 391999
    run_ctx_hook "$dir" "$CTX_NOW" "$t" 'where are we?' CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45
    [ -z "$HOOK_OUT" ] || fail "a malformed margin ($bad) must fall back to 5 points, not fire earlier: $HOOK_OUT"
    assert_grep "bad-context-margin config=$bad" "$dir/state/.captain-idle-handoff.log" "a malformed margin must be logged"
    ctx_usage "$t" 392000
    run_ctx_hook "$dir" "$CTX_NOW" "$t" 'where are we?' CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45
    assert_contains "$HOOK_OUT" 'CLEAR BEFORE SESSION' "a malformed margin ($bad) must still fire at the default point"
  done
  pass "context handoff: a malformed margin falls back to the default and is logged"
}

test_context_fire_point_at_or_below_zero_does_nothing() {
  local dir t
  dir=$(ctx_primary ctx-nonpositive)
  t="$dir/session.jsonl"
  ctx_transcript "$t" 500000
  # 3% compacts at 29400 tokens; five points earlier is below zero.
  run_ctx_hook "$dir" "$CTX_NOW" "$t" 'where are we?' CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=3
  [ -z "$HOOK_OUT" ] || fail "a fire point below zero must never fire, got: $HOOK_OUT"
  # A margin equal to the setting lands exactly on zero.
  run_ctx_hook "$dir" "$CTX_NOW" "$t" 'where are we?' CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45 FM_CONTEXT_HANDOFF_MARGIN=45
  [ -z "$HOOK_OUT" ] || fail "a fire point of zero must never fire, got: $HOOK_OUT"
  assert_grep 'context-fire-point-nonpositive' "$dir/state/.captain-idle-handoff.log" "a nonpositive fire point must be logged"
  assert_absent "$dir/state/.context-handoff" "a nonpositive fire point must not claim a climb"
  pass "context handoff: a fire point at or below zero does nothing"
}

test_context_undeterminable_window_does_nothing() {
  local dir t
  dir=$(ctx_primary ctx-window)
  t="$dir/session.jsonl"
  # A model id without a window marker is never assumed to be any size.
  ctx_transcript "$t" 999000 claude-opus-5-5
  run_ctx_hook "$dir" "$CTX_NOW" "$t" 'where are we?' CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45
  [ -z "$HOOK_OUT" ] || fail "an unknown window must never be guessed, got: $HOOK_OUT"
  # No model identity at all.
  printf '{"type":"assistant","isSidechain":false,"message":{"model":"x","usage":{"input_tokens":999000}}}\n' > "$t"
  run_ctx_hook "$dir" "$CTX_NOW" "$t" 'where are we?' CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45
  [ -z "$HOOK_OUT" ] || fail "a transcript with no model identity must do nothing, got: $HOOK_OUT"
  # Claude Code's 1M switch-off, and a malformed explicit declaration.
  ctx_transcript "$t" 999000
  run_ctx_hook "$dir" "$CTX_NOW" "$t" 'where are we?' CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45 CLAUDE_CODE_DISABLE_1M_CONTEXT=1
  [ -z "$HOOK_OUT" ] || fail "a disabled 1M window must not be assumed, got: $HOOK_OUT"
  run_ctx_hook "$dir" "$CTX_NOW" "$t" 'where are we?' CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45 FM_CONTEXT_WINDOW_TOKENS=lots
  [ -z "$HOOK_OUT" ] || fail "a malformed window declaration must do nothing, got: $HOOK_OUT"
  # A missing transcript.
  run_ctx_hook "$dir" "$CTX_NOW" "$dir/missing.jsonl" 'where are we?' CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45
  [ -z "$HOOK_OUT$HOOK_ERR" ] || fail "a missing transcript must be silent, got: $HOOK_OUT$HOOK_ERR"
  assert_absent "$dir/state/.context-handoff" "an undeterminable reading must not claim a climb"
  pass "context handoff: an undeterminable window or transcript does nothing"
}

test_context_explicit_window_declaration() {
  local dir t
  dir=$(ctx_primary ctx-declared)
  t="$dir/session.jsonl"
  # 200000 window: effective 180000, 45% compacts at 81000, fires at 72000.
  ctx_transcript "$t" 72000 claude-opus-5-5
  run_ctx_hook "$dir" "$CTX_NOW" "$t" 'where are we?' CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45 FM_CONTEXT_WINDOW_TOKENS=200k
  assert_contains "$HOOK_OUT" 'CLEAR BEFORE SESSION' "a declared window must be used for a model the hook cannot size"
  pass "context handoff: FM_CONTEXT_WINDOW_TOKENS sizes a window the transcript cannot"
}

test_context_latest_model_identity_wins() {
  local dir t
  dir=$(ctx_primary ctx-switch)
  t="$dir/session.jsonl"
  ctx_transcript "$t" 100000
  run_ctx_hook "$dir" "$CTX_NOW" "$t" 'where are we?' CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45
  assert_grep 'claude-opus-5-5[1m]' "$dir/state/.context-handoff-model" "the model identity must be cached"
  # A mid-session switch to a model the hook cannot size.
  ctx_model "$t" claude-opus-5-5
  ctx_usage "$t" 500000
  run_ctx_hook "$dir" "$CTX_NOW" "$t" 'where are we?' CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45
  [ -z "$HOOK_OUT" ] || fail "the latest model identity must win over the cached one, got: $HOOK_OUT"
  pass "context handoff: the latest model identity in the transcript wins"
}

test_context_fires_once_per_climb_and_rearms_after_a_drop() {
  local dir t t2
  dir=$(ctx_primary ctx-climb)
  t="$dir/session.jsonl"
  ctx_transcript "$t" 400000
  run_ctx_hook "$dir" "$CTX_NOW" "$t" 'one' CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45
  assert_contains "$HOOK_OUT" 'CLEAR BEFORE SESSION' "the first prompt past the line must fire"
  ctx_usage "$t" 420000
  run_ctx_hook "$dir" "$CTX_NOW" "$t" 'two' CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45
  [ -z "$HOOK_OUT" ] || fail "a second prompt in the same climb must stay silent, got: $HOOK_OUT"
  # Claude Code compacts: the fill drops, which re-arms the trigger.
  ctx_compact "$t" 30000
  run_ctx_hook "$dir" "$CTX_NOW" "$t" 'three' CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45
  [ -z "$HOOK_OUT" ] || fail "the prompt right after a compaction must be silent, got: $HOOK_OUT"
  assert_absent "$dir/state/.context-handoff" "a drop below the line must re-arm the trigger"
  assert_grep 'context-rearmed fill=30000(compacted)' "$dir/state/.captain-idle-handoff.log" "the re-arm must be logged"
  ctx_usage "$t" 395000
  run_ctx_hook "$dir" "$CTX_NOW" "$t" 'four' CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45
  assert_contains "$HOOK_OUT" 'CLEAR BEFORE SESSION' "the next climb must fire again"
  # A clear starts a new, small transcript: that re-arms too.
  t2="$dir/cleared.jsonl"
  ctx_transcript "$t2" 25000
  run_ctx_hook "$dir" "$CTX_NOW" "$t2" 'five' CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45
  [ -z "$HOOK_OUT" ] || fail "a freshly cleared session must be silent, got: $HOOK_OUT"
  assert_absent "$dir/state/.context-handoff" "a clear must re-arm the trigger"
  pass "context handoff: one capture per climb, re-armed by a compaction or a clear"
}

test_context_leaves_the_other_records_alone() {
  local dir t
  dir=$(ctx_primary ctx-records)
  t="$dir/session.jsonl"
  printf '1799990000\n' > "$dir/state/.captain-idle-handoff"
  printf '1799000000\t1799001800\t1800\n' > "$dir/state/.auto-afk-armed"
  ctx_transcript "$t" 400000
  run_ctx_hook "$dir" "$CTX_NOW" "$t" 'where are we?' CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45
  assert_contains "$HOOK_OUT" 'CLEAR BEFORE SESSION' "the context condition must fire here"
  [ "$(cat "$dir/state/.captain-idle-handoff")" = 1799990000 ] \
    || fail "a context capture must not touch the quiet-stretch claim"
  [ "$(cat "$dir/state/.auto-afk-armed")" = "$(printf '1799000000\t1799001800\t1800')" ] \
    || fail "a context capture must not touch the away-mode arm record"
  [ "$(cat "$dir/state/.last-captain-input")" = "$CTX_NOW" ] || fail "the shared clock still advances on its own terms"
  # The quiet-stretch condition still fires on its own clock afterwards.
  ctx_usage "$t" 410000
  run_ctx_hook "$dir" $((CTX_NOW + 8 * HOUR)) "$t" 'back again' CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45
  assert_contains "$HOOK_OUT" 'You were away 8h 0m' "the quiet-stretch condition must still fire on its own clock"
  pass "context handoff: leaves the quiet-stretch and away-mode records to their owners"
}

test_context_and_idle_together_capture_once() {
  local dir t
  dir=$(make_primary_dir "$TMP_ROOT/ctx-both")
  t="$dir/session.jsonl"
  seed_stretch "$dir" $((CTX_NOW - 8 * HOUR))
  ctx_transcript "$t" 400000
  run_ctx_hook "$dir" "$CTX_NOW" "$t" 'morning' CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45
  assert_contains "$HOOK_OUT" 'You were away 8h 0m' "when both hold, the quiet stretch leads the wording"
  # shellcheck disable=SC2016  # single quotes are deliberate: a literal needle string, not an expansion
  [ "$(printf '%s\n' "$HOOK_OUT" | grep -c 'load the `handoff` skill')" = 1 ] \
    || fail "both conditions on one prompt must produce exactly one capture directive"
  assert_grep "$t" "$dir/state/.context-handoff" "the shared capture must also claim the climb"
  run_ctx_hook "$dir" $((CTX_NOW + 60)) "$t" 'next' CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45
  [ -z "$HOOK_OUT" ] || fail "the prompt after a shared capture must be silent, got: $HOOK_OUT"
  pass "context handoff: one capture when both conditions hold on the same prompt"
}

test_context_ignores_injected_input() {
  local dir t
  dir=$(ctx_primary ctx-inject)
  t="$dir/session.jsonl"
  ctx_transcript "$t" 400000
  run_ctx_hook "$dir" "$CTX_NOW" "$t" "${INJECT_MARK}[fm-escalation] digest" CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45
  [ -z "$HOOK_OUT" ] || fail "an away-mode injection is not captain input, got: $HOOK_OUT"
  run_ctx_hook "$dir" "$CTX_NOW" "$t" "${FROMFIRST_MARK} relay" CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45
  [ -z "$HOOK_OUT" ] || fail "a supervisor relay is not captain input, got: $HOOK_OUT"
  assert_absent "$dir/state/.context-handoff" "injected input must not claim a climb"
  : > "$dir/state/.afk"
  run_ctx_hook "$dir" "$CTX_NOW" "$t" 'back' CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45
  [ -z "$HOOK_OUT" ] || fail "away mode owns the captain's return message, got: $HOOK_OUT"
  rm -f "$dir/state/.afk"
  run_ctx_hook "$dir" "$CTX_NOW" "$t" 'back' CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45
  assert_contains "$HOOK_OUT" 'CLEAR BEFORE SESSION' "the first genuine prompt after away mode must capture"
  pass "context handoff: injected input and away mode never trigger a capture"
}

test_context_silent_in_crewmate_worktree() {
  local dir t
  dir=$(make_crewmate_worktree_dir "$TMP_ROOT/ctx-crew-base" "$TMP_ROOT/ctx-crew-worktree")
  t="$dir/session.jsonl"
  ctx_transcript "$t" 440000
  run_ctx_hook "$dir" "$CTX_NOW" "$t" 'where are we?' CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45
  [ -z "$HOOK_OUT" ] || fail "a task worktree is not the primary session, got: $HOOK_OUT"
  assert_absent "$dir/state/.context-handoff" "a task worktree must not claim a climb"
  pass "context handoff: silent inside a crewmate task worktree"
}

test_context_reads_only_the_transcript_tail() {
  local dir t i
  dir=$(ctx_primary ctx-tail)
  t="$dir/session.jsonl"
  ctx_transcript "$t" 400000
  # Push the only usage line out of a 4 KiB tail window.
  for i in $(seq 1 60); do
    printf '{"type":"user","isSidechain":false,"message":{"content":"padding line %s ........................................"}}\n' "$i" >> "$t"
  done
  run_ctx_hook "$dir" "$CTX_NOW" "$t" 'where are we?' CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45 FM_CONTEXT_TAIL_BYTES=4096
  [ -z "$HOOK_OUT" ] || fail "a usage line outside the tail window must not be read, got: $HOOK_OUT"
  run_ctx_hook "$dir" "$CTX_NOW" "$t" 'where are we?' CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45
  assert_contains "$HOOK_OUT" 'CLEAR BEFORE SESSION' "inside the default tail window the same line must be read"
  pass "context handoff: reads the fill from the transcript tail only"
}

test_context_skips_sidechain_and_synthetic_usage() {
  local dir t
  dir=$(ctx_primary ctx-sidechain)
  t="$dir/session.jsonl"
  ctx_transcript "$t" 100000
  printf '{"type":"assistant","isSidechain":true,"message":{"model":"claude-opus-5-5","usage":{"input_tokens":900000}}}\n' >> "$t"
  printf '{"type":"assistant","isSidechain":false,"message":{"model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}\n' >> "$t"
  run_ctx_hook "$dir" "$CTX_NOW" "$t" 'where are we?' CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=45
  [ -z "$HOOK_OUT" ] || fail "subagent and synthetic usage must not count as the main session's fill, got: $HOOK_OUT"
  pass "context handoff: ignores subagent and synthetic usage"
}

test_context_config_file_is_gitignored() {
  assert_grep 'config/context-handoff' "$ROOT/.gitignore" "config/context-handoff must stay local and gitignored"
  pass "config/context-handoff is a local, gitignored operating choice"
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
run_case test_the_deferred_stretch_is_captured_once_away_mode_clears
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
run_case test_context_fires_at_the_derived_point
run_case test_context_silent_just_below_the_point
run_case test_context_uses_the_default_compaction_point_without_an_override
run_case test_context_margin_is_configurable
run_case test_context_margin_off_disables_only_this_condition
run_case test_context_malformed_margin_falls_back_to_the_default
run_case test_context_fire_point_at_or_below_zero_does_nothing
run_case test_context_undeterminable_window_does_nothing
run_case test_context_explicit_window_declaration
run_case test_context_latest_model_identity_wins
run_case test_context_fires_once_per_climb_and_rearms_after_a_drop
run_case test_context_leaves_the_other_records_alone
run_case test_context_and_idle_together_capture_once
run_case test_context_ignores_injected_input
run_case test_context_silent_in_crewmate_worktree
run_case test_context_reads_only_the_transcript_tail
run_case test_context_skips_sidechain_and_synthetic_usage
run_case test_context_config_file_is_gitignored
fm_case_summary "idle auto-handoff"
