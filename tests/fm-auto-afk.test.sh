#!/usr/bin/env bash
# Behavior tests for auto-armed away mode (docs/captain-idle-handoff.md).
#
# bin/fm-auto-afk.sh watches the SAME captain clock the idle auto-handoff hook
# writes - state/.last-captain-input - and, past a much shorter threshold, prints
# a directive telling firstmate to enter away mode through the ordinary /afk
# path. Two thresholds, one clock, on purpose: two detectors that could disagree
# about whether the captain is present would be worse than neither.
#
# The cases below are grouped by the property they defend:
#   - the threshold, its configuration, and its deliberate default-ON
#   - one arm per quiet stretch
#   - the fleet precondition (a parked fleet buys nothing from a daemon)
#   - the idle-handoff's own threshold surviving an auto-arm, which is the
#     regression this design is most likely to cause silently
#   - the away-mode exit path staying byte-for-byte the one the captain knows
#   - the approval-authority boundary being inherited rather than restated
#
# Everything is hermetic over temp dirs with an injected clock; no real agent
# session, no real daemon, and no real away mode are involved.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-auto-afk)
fm_git_identity fmtest fmtest@example.invalid

MINUTE=60
HOUR=3600
# The built-in default this suite asserts against, in one place.
DEFAULT_THRESHOLD=1800

install_scripts() {  # <dir>
  local dir=$1 f
  mkdir -p "$dir/bin"
  for f in fm-auto-afk.sh fm-captain-idle-handoff.sh fm-primary-scope-lib.sh \
           fm-supervision-lib.sh fm-progress-lib.sh fm-banner-lib.sh fm-marker-lib.sh \
           fm-context-fill-lib.sh; do
    cp "$ROOT/bin/$f" "$dir/bin/$f"
  done
  chmod +x "$dir/bin/fm-auto-afk.sh" "$dir/bin/fm-captain-idle-handoff.sh"
}

# A primary-shaped MAIN home: plain (non-worktree) git repo, AGENTS.md, bin/,
# state/, config/ - what the scoping check requires before it will act at all.
make_primary_dir() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state" "$dir/config"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_scripts "$dir"
  printf '%s\n' "$dir"
}

make_secondmate_dir() {  # <dir>
  local dir=$1
  make_primary_dir "$dir" >/dev/null
  printf 'sm-auto-afk-1\n' > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

make_crewmate_worktree_dir() {  # <base> <dir>
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/auto-afk-test-branch
  mkdir -p "$dir/state" "$dir/config"
  : > "$dir/AGENTS.md"
  install_scripts "$dir"
  printf '%s\n' "$dir"
}

# One task with a runtime record and no progress verdict reads as PROGRESSING
# through the shared judge (an unrecorded task always counts progressing), which
# is the ordinary "work is under way" shape.
seed_work() {  # <dir>
  printf 'window=synthetic:auto-afk\nkind=ship\n' > "$1/state/t1.meta"
}

seed_stretch() {  # <dir> <last-captain-input-epoch>
  printf '%s\n' "$2" > "$1/state/.last-captain-input"
}

# run_detector <dir> <now-epoch> [env assignments...]: invoke the detector with
# an injected clock, setting OUT and RC. Prints nothing itself so no caller is
# tempted to wrap it in a command substitution and lose a channel.
OUT=
RC=0
run_detector() {
  local dir=$1 now=$2 outfile
  shift 2
  outfile=$(mktemp "$TMP_ROOT/out.XXXXXX")
  env "$@" FM_AUTO_AFK_NOW="$now" FM_ROOT_OVERRIDE="$dir" \
    bash "$dir/bin/fm-auto-afk.sh" >"$outfile" 2>&1
  RC=$?
  OUT=$(cat "$outfile")
  rm -f "$outfile"
}

handoff_payload() {  # <prompt>
  printf '{"hook_event_name":"UserPromptSubmit","prompt":%s}' "$(printf '%s' "$1" | jq -Rs .)"
}

# run_handoff <dir> <now-epoch> [prompt]: invoke the idle-handoff hook on the
# same home, so the two detectors can be exercised against one shared clock.
HANDOFF_OUT=
run_handoff() {
  local dir=$1 now=$2 prompt=${3:-where did we leave the fleet?} outfile
  outfile=$(mktemp "$TMP_ROOT/handoff.XXXXXX")
  handoff_payload "$prompt" \
    | env FM_IDLE_HANDOFF_NOW="$now" FM_ROOT_OVERRIDE="$dir" \
      bash "$dir/bin/fm-captain-idle-handoff.sh" >"$outfile" 2>/dev/null
  HANDOFF_OUT=$(cat "$outfile")
  rm -f "$outfile"
}

# code_mentions <file> <needle>: true when <needle> appears in EXECUTABLE code -
# outside a `#` comment and outside the quoted --help heredoc. Both of those are
# documentation, and a script naming the records it must not touch is the point,
# so neither may read as touching them.
code_mentions() {
  awk -v needle="$2" '
    /^[[:space:]]*cat <<.USAGE./ { doc = 1; next }
    doc && /^USAGE$/ { doc = 0; next }
    doc { next }
    /^[[:space:]]*#/ { next }
    index($0, needle) { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$1"
}

# A minimal home for exercising bin/fm-afk-return.sh, the real script, with the
# daemon lifecycle and wake drain stubbed out. Mirrors tests/fm-afk-return.test.sh
# so the two agree about what a return looks like.
install_return_runner() {  # <case-dir>
  local dir=$1
  mkdir -p "$dir/bin" "$dir/home/state" "$dir/home/data" "$dir/home/config"
  cp "$ROOT/bin/fm-afk-return.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-classify-lib.sh" "$dir/bin/"
  cat > "$dir/bin/fm-afk-launch.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = stop ] || exit 2
rm -f "$FM_HOME/state/.afk" "$FM_HOME/state/.afk-daemon-terminal"
SH
  cat > "$dir/bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/bin/"*.sh
}

run_return() {  # <case-dir> [mode]
  local dir=$1 mode=${2:-begin}
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" "$dir/bin/fm-afk-return.sh" "$mode" 2>&1
}

# --- threshold ---------------------------------------------------------------

test_fires_past_the_default_threshold() {
  local dir now
  dir=$(make_primary_dir "$TMP_ROOT/fire")
  seed_work "$dir"
  now=1800000000
  seed_stretch "$dir" $((now - 33 * MINUTE))
  run_detector "$dir" "$now"
  expect_code 0 "$RC" "the detector must never fail its caller"
  assert_contains "$OUT" 'auto-afk: the captain has been quiet 33m' \
    "a fired run must state the measured quiet stretch"
  # shellcheck disable=SC2016  # a literal needle, not an expansion
  assert_contains "$OUT" 'Load the `afk` skill' \
    "a fired run must route firstmate through the existing /afk entry"
  assert_contains "$OUT" 'bin/fm-afk-launch.sh' \
    "a fired run must name the one away-mode lifecycle owner"
  assert_grep "armed" "$dir/state/.auto-afk.log" "a fired run must be logged"
  assert_present "$dir/state/.auto-afk-armed" "a fired run must claim the stretch it armed"
  pass "auto-afk: fires past the default threshold with a directive and a claim"
}

test_default_is_thirty_minutes_and_on() {
  local dir now
  dir=$(make_primary_dir "$TMP_ROOT/default-on")
  seed_work "$dir"
  now=1800000000
  # No config/auto-afk at all: absent must mean ENABLED at 30 minutes, because
  # the captain asked for this feature. A default-off reading would leave the
  # measured waste in place for exactly the captain who requested the fix.
  assert_absent "$dir/config/auto-afk" "this case must exercise the absent-config default"
  seed_stretch "$dir" $((now - DEFAULT_THRESHOLD))
  run_detector "$dir" "$now"
  assert_contains "$OUT" 'past the 1800s stretch' "the built-in default must be 1800 seconds"
  pass "auto-afk: absent configuration means enabled at 30 minutes"
}

test_silent_just_under_the_threshold() {
  local dir now
  dir=$(make_primary_dir "$TMP_ROOT/under")
  seed_work "$dir"
  now=1800000000
  seed_stretch "$dir" $((now - DEFAULT_THRESHOLD + 1))
  run_detector "$dir" "$now"
  expect_code 0 "$RC" "a quiet decline is still a clean exit"
  [ -z "$OUT" ] || fail "one second under the threshold must not arm, got: $OUT"
  assert_absent "$dir/state/.auto-afk-armed" "a declined run must claim nothing"
  pass "auto-afk: silent one second under the threshold"
}

test_fires_exactly_at_the_threshold() {
  local dir now
  dir=$(make_primary_dir "$TMP_ROOT/boundary")
  seed_work "$dir"
  now=1800000000
  seed_stretch "$dir" $((now - DEFAULT_THRESHOLD))
  run_detector "$dir" "$now"
  assert_contains "$OUT" 'auto-afk:' "the threshold itself must count as reached"
  pass "auto-afk: fires exactly at the threshold boundary"
}

test_off_disables_it_entirely() {
  local dir now
  dir=$(make_primary_dir "$TMP_ROOT/off")
  seed_work "$dir"
  now=1800000000
  seed_stretch "$dir" $((now - 9 * HOUR))
  printf 'off\n' > "$dir/config/auto-afk"
  run_detector "$dir" "$now"
  expect_code 0 "$RC" "the kill switch must exit cleanly"
  [ -z "$OUT" ] || fail "off must disable the detector outright, got: $OUT"
  assert_absent "$dir/state/.auto-afk-armed" "a disabled detector must claim nothing"

  # The env override carries the same kill switch, so a home can be silenced for
  # one session without editing its standing choice.
  rm -f "$dir/config/auto-afk"
  run_detector "$dir" "$now" FM_AUTO_AFK_SECONDS=off
  [ -z "$OUT" ] || fail "the env kill switch must also disable it, got: $OUT"
  pass "auto-afk: off disables it from the file and from the environment"
}

test_bad_threshold_falls_back_to_the_default_never_shorter() {
  local dir now
  dir=$(make_primary_dir "$TMP_ROOT/bad-threshold")
  seed_work "$dir"
  now=1800000000
  printf 'half an hour\n' > "$dir/config/auto-afk"
  # Under the default but over any plausible typo-shortened threshold: a
  # malformed value must never make firstmate arm away mode MORE eagerly.
  seed_stretch "$dir" $((now - 20 * MINUTE))
  run_detector "$dir" "$now"
  [ -z "$OUT" ] || fail "a malformed threshold must fall back to the default, not to something shorter, got: $OUT"
  assert_grep "bad-threshold" "$dir/state/.auto-afk.log" "a malformed threshold must be logged"

  # And the default still applies normally once the stretch is genuinely long.
  seed_stretch "$dir" $((now - 40 * MINUTE))
  run_detector "$dir" "$now"
  assert_contains "$OUT" 'past the 1800s stretch' "the fallback must be the built-in default"
  pass "auto-afk: a malformed threshold falls back to the default, never to anything shorter"
}

test_env_overrides_the_file() {
  local dir now
  dir=$(make_primary_dir "$TMP_ROOT/env-override")
  seed_work "$dir"
  now=1800000000
  printf '7200\n' > "$dir/config/auto-afk"
  seed_stretch "$dir" $((now - 1 * HOUR))
  run_detector "$dir" "$now"
  [ -z "$OUT" ] || fail "the file's two-hour threshold must hold, got: $OUT"
  run_detector "$dir" "$now" FM_AUTO_AFK_SECONDS=600
  assert_contains "$OUT" 'past the 600s stretch' "the env value must override the file"
  pass "auto-afk: the environment overrides the configured threshold"
}

# --- one arm per quiet stretch -----------------------------------------------

test_one_quiet_stretch_arms_exactly_once() {
  local dir now first
  dir=$(make_primary_dir "$TMP_ROOT/once")
  seed_work "$dir"
  now=1800000000
  first=$((now - 40 * MINUTE))
  seed_stretch "$dir" "$first"
  run_detector "$dir" "$now"
  assert_contains "$OUT" 'auto-afk:' "the first evaluation of a stretch must arm"

  # Every later monitoring cycle re-runs this. None of them may repeat the
  # directive: if firstmate declined or failed to enter away mode, nagging once
  # per cycle is exactly the noise this feature exists to remove.
  run_detector "$dir" $((now + 5 * MINUTE))
  [ -z "$OUT" ] || fail "a second evaluation of the same stretch must stay silent, got: $OUT"
  run_detector "$dir" $((now + 2 * HOUR))
  [ -z "$OUT" ] || fail "a much later evaluation of the same stretch must still stay silent, got: $OUT"
  assert_grep "already-armed" "$dir/state/.auto-afk.log" "a repeat evaluation must be logged as already armed"

  # A NEW stretch is a new decision. The clock only advances when the captain
  # actually types, so this is the honest "they came back and left again" case.
  seed_stretch "$dir" $((now + 3 * HOUR))
  run_detector "$dir" $((now + 4 * HOUR))
  assert_contains "$OUT" 'auto-afk:' "a later quiet stretch must arm on its own"
  pass "auto-afk: one quiet stretch arms exactly once, and a later stretch arms again"
}

# --- the fleet precondition ---------------------------------------------------

test_no_work_under_way_does_not_arm() {
  local dir now
  dir=$(make_primary_dir "$TMP_ROOT/no-work")
  now=1800000000
  seed_stretch "$dir" $((now - 9 * HOUR))
  # Deliberately no task records and no armed poll: a parked fleet is the
  # healthy resting state, and a daemon over it would batch nothing.
  run_detector "$dir" "$now"
  expect_code 0 "$RC" "an empty fleet is not an error"
  [ -z "$OUT" ] || fail "nothing to supervise must not arm away mode, got: $OUT"
  assert_absent "$dir/state/.auto-afk-armed" "a fleet with nothing to watch must leave no claim"
  assert_grep "nothing-to-supervise" "$dir/state/.auto-afk.log" "the decline must be logged with its reason"
  pass "auto-afk: does not arm when there is nothing to supervise"
}

test_an_idle_fleet_with_an_armed_poll_still_arms() {
  local dir now
  dir=$(make_primary_dir "$TMP_ROOT/poll-only")
  now=1800000000
  seed_stretch "$dir" $((now - 9 * HOUR))
  # No progressing task, but a merge watch is armed: something will still wake
  # this home, so batching those wakes is worth something.
  : > "$dir/state/t7.check.sh"
  run_detector "$dir" "$now"
  assert_contains "$OUT" 'auto-afk:' "an armed poll is still work worth batching"
  pass "auto-afk: an idle fleet with an armed poll still arms"
}

# --- do not fight a present captain ------------------------------------------

test_declines_while_away_mode_is_already_active() {
  local dir now
  dir=$(make_primary_dir "$TMP_ROOT/already-away")
  seed_work "$dir"
  now=1800000000
  seed_stretch "$dir" $((now - 9 * HOUR))
  date +%s > "$dir/state/.afk"
  run_detector "$dir" "$now"
  [ -z "$OUT" ] || fail "away mode is already active; there is nothing to arm, got: $OUT"
  pass "auto-afk: declines while away mode is already active"
}

test_declines_while_a_return_catch_up_is_open() {
  local dir now
  dir=$(make_primary_dir "$TMP_ROOT/returning")
  seed_work "$dir"
  now=1800000000
  seed_stretch "$dir" $((now - 9 * HOUR))
  # An open return gate is the strongest available reading of "the captain is
  # back and mid-return". A present captain takes precedence, always.
  printf 'schema\tfm-afk-return.v1\n' > "$dir/state/.afk-return-catchup"
  run_detector "$dir" "$now"
  [ -z "$OUT" ] || fail "a captain mid-return must never be pushed back into away mode, got: $OUT"
  pass "auto-afk: declines while a return catch-up is still open"
}

test_no_recorded_captain_input_is_not_a_quiet_captain() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/no-clock")
  seed_work "$dir"
  assert_absent "$dir/state/.last-captain-input" "this case must exercise an absent clock"
  run_detector "$dir" 1800000000
  [ -z "$OUT" ] || fail "with no recorded captain input there is no measurable stretch, got: $OUT"

  # A corrupt record reads as absent, which is the no-arm direction.
  printf 'not-an-epoch\n' > "$dir/state/.last-captain-input"
  run_detector "$dir" 1800000000
  [ -z "$OUT" ] || fail "a corrupt clock must read as absent, got: $OUT"
  pass "auto-afk: an absent or corrupt captain clock never reads as a quiet captain"
}

test_a_clock_dated_in_the_future_never_arms() {
  local dir now
  dir=$(make_primary_dir "$TMP_ROOT/future-clock")
  seed_work "$dir"
  now=1800000000
  seed_stretch "$dir" $((now + 9 * HOUR))
  run_detector "$dir" "$now"
  [ -z "$OUT" ] || fail "a backwards clock is not evidence of a quiet captain, got: $OUT"
  pass "auto-afk: a captain clock dated in the future never arms"
}

# --- scope -------------------------------------------------------------------

test_silent_in_a_secondmate_home() {
  local dir now
  dir=$(make_secondmate_dir "$TMP_ROOT/secondmate")
  seed_work "$dir"
  now=1800000000
  seed_stretch "$dir" $((now - 9 * HOUR))
  run_detector "$dir" "$now"
  [ -z "$OUT" ] || fail "a secondmate has no captain to be away from, got: $OUT"

  # A secondmate home can also be driven with scripts from a different tracked
  # code root (AGENTS.md section 2), which the root check alone would miss.
  local main
  main=$(make_primary_dir "$TMP_ROOT/secondmate-remote-root")
  seed_work "$dir"
  env FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_AUTO_AFK_NOW="$now" FM_ROOT_OVERRIDE="$main" bash "$main/bin/fm-auto-afk.sh" > "$TMP_ROOT/sm.out" 2>&1
  [ ! -s "$TMP_ROOT/sm.out" ] \
    || fail "a secondmate home driven from another code root must still be excluded: $(cat "$TMP_ROOT/sm.out")"
  pass "auto-afk: silent in a secondmate home however its scripts are resolved"
}

test_silent_in_a_task_worktree() {
  local base dir now
  base="$TMP_ROOT/worktree-base"
  dir=$(make_crewmate_worktree_dir "$base" "$TMP_ROOT/worktree-task")
  seed_work "$dir"
  now=1800000000
  seed_stretch "$dir" $((now - 9 * HOUR))
  run_detector "$dir" "$now"
  [ -z "$OUT" ] || fail "a task worktree is not a primary session, got: $OUT"
  pass "auto-afk: silent inside a crewmate task worktree"
}

# --- the shared clock ---------------------------------------------------------

test_never_writes_the_shared_captain_clock() {
  local dir now before after body
  dir=$(make_primary_dir "$TMP_ROOT/shared-clock")
  seed_work "$dir"
  now=1800000000
  seed_stretch "$dir" $((now - 9 * HOUR))
  before=$(cat "$dir/state/.last-captain-input")
  run_detector "$dir" "$now"
  after=$(cat "$dir/state/.last-captain-input")
  [ "$before" = "$after" ] || fail "the detector must read the captain clock, never write it ($before -> $after)"
  assert_absent "$dir/state/.captain-idle-handoff" \
    "the detector must never touch the idle-handoff's own claim"

  # The one-owner rule, asserted structurally: only the idle-handoff hook writes
  # the clock, so the two can never disagree about when the captain last spoke.
  # The records may be DOCUMENTED here - saying which ones this must not touch is
  # the point - but must never appear in executable code.
  body=$(cat "$ROOT/bin/fm-auto-afk.sh")
  # shellcheck disable=SC2016  # single quotes are deliberate: a literal needle string, not an expansion
  assert_not_contains "$body" '> "$MARK"' "the detector must never write the shared captain clock"
  if code_mentions "$ROOT/bin/fm-auto-afk.sh" 'captain-idle-handoff'; then
    fail "the detector must only ever name the idle-handoff's records in comments, never touch them"
  fi
  pass "auto-afk: reads the shared captain clock and never writes it"
}

# --- the idle-handoff's own threshold survives an auto-arm --------------------

test_an_auto_arm_does_not_consume_the_handoff_stretch() {
  local dir armed_at returned_at next_at stretch
  dir=$(make_primary_dir "$TMP_ROOT/handoff-survives")
  seed_work "$dir"

  # 09:00 - the captain's last real message opens the stretch.
  stretch=1800000000
  seed_stretch "$dir" "$stretch"

  # 09:31 - auto-afk fires at its 30-minute threshold, long before the
  # idle-handoff's four hours.
  armed_at=$((stretch + 31 * MINUTE))
  run_detector "$dir" "$armed_at"
  assert_contains "$OUT" 'auto-afk:' "auto-afk must fire first, at the shorter threshold"
  assert_absent "$dir/state/.captain-idle-handoff" \
    "arming away mode must not claim the handoff's stretch"
  assert_grep "$stretch" "$dir/state/.last-captain-input" \
    "arming away mode must not advance the shared clock"

  # Firstmate enters away mode through the ordinary path.
  date +%s > "$dir/state/.afk"

  # 18:00 - the captain comes back. The handoff hook defers to the away-mode
  # return procedure, which owns this message, and - the load-bearing part -
  # leaves the clock alone so the nine-hour gap is not silently erased.
  returned_at=$((stretch + 9 * HOUR))
  run_handoff "$dir" "$returned_at"
  [ -z "$HANDOFF_OUT" ] || fail "away mode owns the return message; the handoff must defer, got: $HANDOFF_OUT"
  assert_grep "$stretch" "$dir/state/.last-captain-input" \
    "deferring must preserve the quiet stretch, not consume it"
  assert_absent "$dir/state/.captain-idle-handoff" "a deferred handoff must claim nothing"

  # Away mode exits, and the very next captain message is measured against the
  # real gap: the handoff still fires at its own four-hour threshold.
  rm -f "$dir/state/.afk"
  next_at=$((returned_at + 2 * MINUTE))
  run_handoff "$dir" "$next_at"
  assert_contains "$HANDOFF_OUT" 'CLEAR BEFORE SESSION' \
    "the handoff must still fire at its own threshold after an auto-armed away session"
  assert_grep "$stretch" "$dir/state/.captain-idle-handoff" \
    "the handoff must claim the stretch it finally captured"
  pass "auto-afk: an auto-armed away session leaves the idle-handoff's threshold intact"
}

test_a_short_away_session_still_does_not_manufacture_a_handoff() {
  local dir stretch
  dir=$(make_primary_dir "$TMP_ROOT/short-away")
  seed_work "$dir"
  stretch=1800000000
  seed_stretch "$dir" "$stretch"
  # Preserving the stretch across away mode must not turn every short away
  # session into a handoff: the gap itself still has to clear four hours.
  date +%s > "$dir/state/.afk"
  run_handoff "$dir" $((stretch + 35 * MINUTE))
  rm -f "$dir/state/.afk"
  run_handoff "$dir" $((stretch + 40 * MINUTE))
  [ -z "$HANDOFF_OUT" ] || fail "a 40-minute gap is not a handoff-worthy stretch, got: $HANDOFF_OUT"
  pass "auto-afk: preserving the stretch does not manufacture a handoff for a short away session"
}

# --- the exit path stays the one the captain knows ----------------------------

test_never_sets_the_away_mode_flag_itself() {
  local body
  body=$(cat "$ROOT/bin/fm-auto-afk.sh")
  # Entering away mode means launching a harness-tracked daemon, which belongs to
  # the /afk skill. This script only ever ASKS. If it set the flag itself, the
  # flag could exist with no daemon behind it and supervision would be off.
  # shellcheck disable=SC2016  # single quotes are deliberate: a literal needle string, not an expansion
  assert_not_contains "$body" '> "$STATE/.afk"' "the detector must never set the away-mode flag"
  assert_not_contains "$body" 'fm-afk-start.sh' "the detector must never launch the daemon"
  assert_not_contains "$body" 'fm-supervise-daemon.sh' "the detector must never launch the daemon"
  pass "auto-afk: never sets the away-mode flag or launches the daemon itself"
}

test_no_second_away_mode_flavour_exists() {
  local body return_body
  body=$(cat "$ROOT/bin/fm-auto-afk.sh")
  return_body=$(cat "$ROOT/bin/fm-afk-return.sh")
  # state/.afk is the whole contract. An auto-armed away session must be
  # indistinguishable from a hand-typed one, so the return path may read the
  # auto-arm record ONLY to report it - never to decide anything.
  assert_not_contains "$body" '.afk-auto' "there must be no second away-mode flag"
  assert_contains "$return_body" 'auto_away_evidence' \
    "the return path must report an auto-armed away session"
  assert_contains "$return_body" 'append_evidence auto-away' \
    "the auto-arm notice must travel as ordinary catch-up evidence"
  pass "auto-afk: no second away-mode flag or flavour is introduced"
}

test_return_path_reports_the_auto_arm_once_and_clears_it() {
  local dir out rc
  dir="$TMP_ROOT/return-reports"
  install_return_runner "$dir"
  date +%s > "$dir/home/state/.afk"
  printf '1800000000\t1800002000\t2000\n' > "$dir/home/state/.auto-afk-armed"

  set +e
  out=$(run_return "$dir")
  rc=$?
  set -e
  expect_code 0 "$rc" "a clean return must still succeed: $out"
  assert_contains "$out" 'away mode started on its own after you were quiet 33m' \
    "the captain must be told, in one line, that away mode armed itself"
  assert_contains "$out" 'nothing was approved on your behalf' \
    "the notice must restate the authority boundary"
  assert_absent "$dir/home/state/.auto-afk-armed" \
    "the auto-arm record must be cleared so the same away session is not re-announced"
  assert_absent "$dir/home/state/.afk" "the ordinary exit path must still clear away mode"

  # A second return must not re-announce it.
  set +e
  out=$(run_return "$dir")
  set -e
  assert_not_contains "$out" 'away mode started on its own' \
    "a later return must not repeat a notice for an away session already reported"
  pass "auto-afk: the return path reports an auto-armed session once, then clears it"
}

test_return_notice_survives_a_gated_return() {
  local dir out rc
  dir="$TMP_ROOT/return-gated"
  install_return_runner "$dir"
  date +%s > "$dir/home/state/.afk"
  printf '1800000000\t1800002000\t2000\n' > "$dir/home/state/.auto-afk-armed"
  # A return that gates on a live blocker still clears the record, so the notice
  # has to survive in the durable catch-up evidence or the captain never learns
  # away mode armed itself.
  printf 'window=synthetic:auto-afk\nkind=ship\n' > "$dir/home/state/blocked-task.meta"
  printf 'blocked [key=synthetic]: needs firstmate\n' > "$dir/home/state/blocked-task.status"

  set +e
  out=$(run_return "$dir" begin)
  rc=$?
  set -e
  expect_code 3 "$rc" "a live blocker must still gate the return: $out"
  assert_contains "$out" 'away mode started on its own' \
    "the auto-arm notice must appear on a gated return too"

  # Clear the blocker and close the gate; the notice must still be there.
  printf 'resolved [key=synthetic]: handled\n' >> "$dir/home/state/blocked-task.status"
  set +e
  out=$(run_return "$dir" check)
  rc=$?
  set -e
  expect_code 0 "$rc" "the gate must close once the blocker is resolved: $out"
  assert_contains "$out" 'away mode started on its own' \
    "the auto-arm notice must survive into the closing catch-up"
  pass "auto-afk: the return notice survives a return that gated on a blocker"
}

test_return_path_is_unchanged_without_an_auto_arm() {
  local dir out rc
  dir="$TMP_ROOT/return-plain"
  install_return_runner "$dir"
  date +%s > "$dir/home/state/.afk"
  assert_absent "$dir/home/state/.auto-afk-armed" "this case must exercise a hand-typed away session"

  set +e
  out=$(run_return "$dir")
  rc=$?
  set -e
  expect_code 0 "$rc" "a hand-typed away session must return exactly as before: $out"
  assert_contains "$out" 'catch-up clear; ordinary captain work may proceed' \
    "the ordinary return outcome must be unchanged"
  assert_not_contains "$out" 'away mode started on its own' \
    "a hand-typed away session must produce no auto-arm notice"
  assert_absent "$dir/home/state/.afk" "the ordinary exit path must still clear away mode"
  pass "auto-afk: the away-mode exit path is unchanged when nothing auto-armed"
}

# --- authority ----------------------------------------------------------------

test_directive_carries_the_authority_boundary() {
  local dir now
  dir=$(make_primary_dir "$TMP_ROOT/authority")
  seed_work "$dir"
  now=1800000000
  seed_stretch "$dir" $((now - 45 * MINUTE))
  run_detector "$dir" "$now"
  assert_contains "$OUT" 'does NOT widen your approval authority' \
    "the directive must state that away mode grants no extra authority"
  assert_contains "$OUT" 'AGENTS.md section 8' \
    "the directive must point at the owning safety boundary"
  assert_contains "$OUT" 'sandbox override' \
    "the directive must deny the captain-present sandbox override"
  assert_contains "$OUT" 'wait for the captain' \
    "the directive must keep merges and ask-user findings with the captain"
  pass "auto-afk: the directive inherits and restates every authority limit"
}

test_agents_md_still_owns_the_authority_boundary() {
  local agents
  agents="$ROOT/AGENTS.md"
  assert_grep 'Away mode never expands approval authority for merges, ask-user findings, destructive actions, irreversible actions, or security-sensitive choices, and never confers the captain-present sandbox override' \
    "$agents" "AGENTS.md must still own the away-mode authority boundary verbatim"
  pass "auto-afk: AGENTS.md remains the owner of the away-mode authority boundary"
}

# --- wiring and documentation -------------------------------------------------

test_the_watcher_arm_consults_the_detector() {
  local arm
  arm="$ROOT/bin/fm-watch-arm.sh"
  local gate_line call_line
  assert_grep 'fm-auto-afk.sh' "$arm" "the arm must consult the detector"
  # The CALL must run after the arm gate, so the "is there work" question is
  # answered once, by one owner, and never re-derived in the detector.
  gate_line=$(grep -n '^arm_gate_allows || exit 0$' "$arm" | head -1 | cut -d: -f1)
  # shellcheck disable=SC2016  # single quotes are deliberate: a literal needle string, not an expansion
  call_line=$(grep -n '^"\$SCRIPT_DIR/fm-auto-afk.sh"' "$arm" | head -1 | cut -d: -f1)
  [ -n "$gate_line" ] || fail "the arm gate call was renamed; this wiring check needs updating"
  [ -n "$call_line" ] || fail "the arm must invoke the detector as its own statement"
  [ "$call_line" -gt "$gate_line" ] \
    || fail "the detector must run only after the arm gate has allowed an arm"
  # shellcheck disable=SC2016  # single quotes are deliberate: a literal needle string, not an expansion
  grep -q '^"\$SCRIPT_DIR/fm-auto-afk.sh" 2>/dev/null || true$' "$arm" \
    || fail "consulting the detector must never cost this home a watcher"
  pass "auto-afk: the watcher arm consults the detector after its own gate, harmlessly"
}

test_config_file_is_gitignored() {
  assert_grep 'config/auto-afk' "$ROOT/.gitignore" \
    "the local threshold file must stay out of the shared repo"
  pass "auto-afk: config/auto-afk is gitignored"
}

test_documentation_owns_the_threshold_and_the_default() {
  local doc config agents
  doc="$ROOT/docs/captain-idle-handoff.md"
  config="$ROOT/docs/configuration.md"
  agents="$ROOT/AGENTS.md"
  # One doc owns the shared clock and both thresholds; no parallel doc exists.
  assert_grep 'bin/fm-auto-afk.sh' "$doc" "the captain-idle doc must own the auto-arm"
  assert_grep '1800' "$doc" "the doc must state the default threshold"
  assert_grep 'config/auto-afk' "$config" "configuration.md must carry the config entry"
  assert_grep 'config/auto-afk' "$agents" "AGENTS.md must list the new local config file"
  [ -f "$ROOT/docs/auto-afk.md" ] && fail "a parallel auto-afk doc must not exist"
  pass "auto-afk: documentation lands with the existing captain-idle and configuration owners"
}

test_runs_fast() {
  local dir started elapsed now
  dir=$(make_primary_dir "$TMP_ROOT/fast")
  seed_work "$dir"
  now=1800000000
  seed_stretch "$dir" $((now - 45 * MINUTE))
  started=$(date +%s)
  run_detector "$dir" "$now"
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -le 5 ] || fail "the detector runs on every arm and must stay cheap (${elapsed}s)"
  pass "auto-afk: stays cheap enough to run on every arm"
}

run_case test_fires_past_the_default_threshold
run_case test_default_is_thirty_minutes_and_on
run_case test_silent_just_under_the_threshold
run_case test_fires_exactly_at_the_threshold
run_case test_off_disables_it_entirely
run_case test_bad_threshold_falls_back_to_the_default_never_shorter
run_case test_env_overrides_the_file
run_case test_one_quiet_stretch_arms_exactly_once
run_case test_no_work_under_way_does_not_arm
run_case test_an_idle_fleet_with_an_armed_poll_still_arms
run_case test_declines_while_away_mode_is_already_active
run_case test_declines_while_a_return_catch_up_is_open
run_case test_no_recorded_captain_input_is_not_a_quiet_captain
run_case test_a_clock_dated_in_the_future_never_arms
run_case test_silent_in_a_secondmate_home
run_case test_silent_in_a_task_worktree
run_case test_never_writes_the_shared_captain_clock
run_case test_an_auto_arm_does_not_consume_the_handoff_stretch
run_case test_a_short_away_session_still_does_not_manufacture_a_handoff
run_case test_never_sets_the_away_mode_flag_itself
run_case test_no_second_away_mode_flavour_exists
run_case test_return_path_reports_the_auto_arm_once_and_clears_it
run_case test_return_notice_survives_a_gated_return
run_case test_return_path_is_unchanged_without_an_auto_arm
run_case test_directive_carries_the_authority_boundary
run_case test_agents_md_still_owns_the_authority_boundary
run_case test_the_watcher_arm_consults_the_detector
run_case test_config_file_is_gitignored
run_case test_documentation_owns_the_threshold_and_the_default
run_case test_runs_fast
fm_case_summary "auto-armed away mode"
