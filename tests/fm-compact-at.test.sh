#!/usr/bin/env bash
# Behavior tests for bin/fm-compact-at.sh: firstmate-driven /compact for matching
# Claude workers (config/compact-at). Hermetic: fake tmux, fake fm-send, fake
# fm-crew-state, and a synthetic transcript under a temp projects dir.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-compact-at)
ID=t1

# setup <name> <model> [harness] [kind]: print the case dir, with state/, config/,
# a worktree path, a fake tmux whose composer reads $dir/composer, a fake send
# that appends its args to $dir/sends, and a fake crew-state reading $dir/cs.
setup() {
  local dir="$TMP_ROOT/$1" model=$2 harness=${3:-claude} kind=${4:-ship} fakebin
  mkdir -p "$dir/state" "$dir/config" "$dir/projects"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\$1" in
  display-message) echo 0 ;;
  capture-pane) cat "$dir/composer" ;;
esac
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' '│ > │' > "$dir/composer"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/sends"\n' "$dir" > "$dir/send.sh"
  printf '#!/usr/bin/env bash\ncat "%s/cs"\n' "$dir" > "$dir/crew-state.sh"
  chmod +x "$dir/send.sh" "$dir/crew-state.sh"
  echo 'state: done · source: pane · idle' > "$dir/cs"
  {
    echo "window=w:1"
    echo "worktree=$dir/wt"
    echo "harness=$harness"
    echo "kind=$kind"
    [ -z "$model" ] || echo "model=$model"
  } > "$dir/state/$ID.meta"
  mkdir -p "$dir/projects/$(printf '%s' "$dir/wt" | sed 's/[^A-Za-z0-9]/-/g')"
  printf '%s\n' "$dir"
}

# set_fill <dir> <tokens>: a transcript whose latest usage is <tokens>.
set_fill() {
  local tdir
  tdir="$1/projects/$(printf '%s' "$1/wt" | sed 's/[^A-Za-z0-9]/-/g')"
  printf '{"type":"assistant","message":{"model":"claude-haiku-4-5","usage":{"input_tokens":%s,"output_tokens":0}}}\n' "$2" > "$tdir/s.jsonl"
}

run_at() {  # <dir>
  local dir=$1
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_CLAUDE_PROJECTS_DIR="$dir/projects" FM_COMPACT_AT_SEND="$dir/send.sh" \
    FM_COMPACT_AT_CREW_STATE="$dir/crew-state.sh" "$ROOT/bin/fm-compact-at.sh" "${2:-$ID}"
}

assert_eq() { [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"; }

sent() { [ -s "$1/sends" ] && wc -l < "$1/sends" | tr -d ' ' || echo 0; }

cfg_haiku() { printf 'haiku 99000\nclaude-haiku-* 99000\n' > "$1/config/compact-at"; }

test_haiku_at_threshold_sends_once() {
  local dir; dir=$(setup haiku haiku); cfg_haiku "$dir"
  set_fill "$dir" 99500
  run_at "$dir"
  assert_eq "$(sent "$dir")" 1 "one send at threshold" || return 1
  grep -q "^$ID /compact$" "$dir/sends" || { fail "send args: $(cat "$dir/sends")"; return 1; }
  run_at "$dir"; run_at "$dir"
  assert_eq "$(sent "$dir")" 1 "no second send in the same climb"
}

test_full_model_id_matches() {
  local dir; dir=$(setup fullid claude-haiku-4-5-20251001); cfg_haiku "$dir"
  set_fill "$dir" 120000
  run_at "$dir"
  assert_eq "$(sent "$dir")" 1 "full id matches claude-haiku-*"
}

test_rearms_after_fill_drops() {
  local dir; dir=$(setup rearm haiku); cfg_haiku "$dir"
  set_fill "$dir" 100000; run_at "$dir"
  set_fill "$dir" 20000; run_at "$dir"
  set_fill "$dir" 101000; run_at "$dir"
  assert_eq "$(sent "$dir")" 2 "second send after the fill dropped below the threshold"
}

test_below_threshold_sends_nothing() {
  local dir; dir=$(setup below haiku); cfg_haiku "$dir"
  set_fill "$dir" 98999
  run_at "$dir"
  assert_eq "$(sent "$dir")" 0 "below threshold"
}

test_non_matching_models_get_nothing() {
  local m dir n=0
  for m in opus sonnet fable claude-sonnet-5-5 ''; do
    n=$((n + 1))
    dir=$(setup "nm$n" "$m"); cfg_haiku "$dir"
    set_fill "$dir" 150000
    run_at "$dir"
    assert_eq "$(sent "$dir")" 0 "model '${m:-<unset>}' gets nothing" || return 1
  done
}

test_default_model_never_matches() {
  local dir; dir=$(setup dflt default); printf '* 99000\n' > "$dir/config/compact-at"
  set_fill "$dir" 150000
  run_at "$dir"
  assert_eq "$(sent "$dir")" 0 "default model never matches even a catch-all glob"
}

test_absent_config_unchanged() {
  local dir; dir=$(setup noconf haiku)
  set_fill "$dir" 150000
  run_at "$dir"
  assert_eq "$(sent "$dir")" 0 "absent config" || return 1
  [ ! -e "$dir/state/.compact-at.log" ] && [ ! -e "$dir/state/.compact-at-$ID" ] || { fail "absent config left records"; return 1; }
}

test_other_harness_and_secondmate_get_nothing() {
  local dir
  dir=$(setup codex haiku codex); cfg_haiku "$dir"; set_fill "$dir" 150000; run_at "$dir"
  assert_eq "$(sent "$dir")" 0 "non-claude harness" || return 1
  dir=$(setup sm haiku claude secondmate); cfg_haiku "$dir"; set_fill "$dir" 150000; run_at "$dir"
  assert_eq "$(sent "$dir")" 0 "secondmate"
}

test_busy_or_pending_composer_sends_nothing() {
  local dir; dir=$(setup busy haiku); cfg_haiku "$dir"
  set_fill "$dir" 150000
  printf '%s\n' '│ > half typed text │' > "$dir/composer"
  run_at "$dir"
  assert_eq "$(sent "$dir")" 0 "pending composer" || return 1
  printf '%s\n' '$ ' > "$dir/composer"
  run_at "$dir"
  assert_eq "$(sent "$dir")" 0 "unreadable/bare shell composer" || return 1
  printf '%s\n' '│ > │' > "$dir/composer"
  echo 'state: working · source: run-step · running' > "$dir/cs"
  run_at "$dir"
  assert_eq "$(sent "$dir")" 0 "active validation step" || return 1
  echo 'state: parked · source: run-step · gate' > "$dir/cs"
  run_at "$dir"
  assert_eq "$(sent "$dir")" 0 "parked gate" || return 1
  echo 'state: done · source: pane · idle' > "$dir/cs"
  run_at "$dir"
  assert_eq "$(sent "$dir")" 1 "sends once the worker is idle with an empty composer"
}

test_unreadable_fill_does_nothing() {
  local dir; dir=$(setup nofill haiku); cfg_haiku "$dir"
  run_at "$dir"
  assert_eq "$(sent "$dir")" 0 "no transcript lines" || return 1
  echo 'not json' > "$dir/projects/$(printf '%s' "$dir/wt" | sed 's/[^A-Za-z0-9]/-/g')/s.jsonl"
  run_at "$dir"
  assert_eq "$(sent "$dir")" 0 "garbage transcript"
}

test_failed_send_retries_next_turn() {
  local dir; dir=$(setup failsend haiku); cfg_haiku "$dir"
  set_fill "$dir" 150000
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/sends"\nexit 1\n' "$dir" > "$dir/send.sh"
  run_at "$dir"; run_at "$dir"
  assert_eq "$(sent "$dir")" 2 "a failed send is not recorded as sent"
}

run_case test_haiku_at_threshold_sends_once
run_case test_full_model_id_matches
run_case test_rearms_after_fill_drops
run_case test_below_threshold_sends_nothing
run_case test_non_matching_models_get_nothing
run_case test_default_model_never_matches
run_case test_absent_config_unchanged
run_case test_other_harness_and_secondmate_get_nothing
run_case test_busy_or_pending_composer_sends_nothing
run_case test_unreadable_fill_does_nothing
run_case test_failed_send_retries_next_turn
fm_case_summary "fm-compact-at"
