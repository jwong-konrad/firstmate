#!/usr/bin/env bash
# Behavior tests for bin/fm-sandbox-guard.sh, the PreToolUse file-tool half of
# the claude scout write boundary. Each case pipes a Claude-shaped PreToolUse
# payload to the guard and asserts the allow (exit 0) or deny (exit 2) verdict.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-sandbox-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-sandbox-guard)

command -v jq >/dev/null 2>&1 || { echo "skip: jq unavailable"; exit 0; }

WT="$TMP_ROOT/wt"
STATE="$TMP_ROOT/home/state"
DATA="$TMP_ROOT/home/data/t1"
TASKTMP="$TMP_ROOT/task-tmp"
OUTSIDE="$TMP_ROOT/outside"
mkdir -p "$WT/src" "$STATE" "$DATA" "$TASKTMP" "$OUTSIDE" "$TMP_ROOT/wt-evil"
touch "$STATE/t1.status" "$STATE/t1.turn-ended" "$WT/src/a.txt"
ln -s "$OUTSIDE" "$WT/escape-dir"
ln -s "$OUTSIDE/target.txt" "$WT/escape-file"
ln -s "$WT/src/a.txt" "$WT/inside-link"
ln -s "$WT/missing-dir" "$WT/dangling"

payload() {  # <tool> <key> <path> [cwd]
  jq -cn --arg t "$1" --arg k "$2" --arg p "$3" --arg c "${4:-$WT}" \
    '{tool_name:$t, cwd:$c, tool_input:{($k):$p}}'
}

guard() {  # <payload> -> sets OUT and RC
  OUT=$(printf '%s' "$1" | "$GUARD" "$WT" "$STATE/t1.status" "$STATE/t1.turn-ended" "$DATA" "$TASKTMP" 2>&1)
  RC=$?
}

allows() {  # <payload> <label>
  guard "$1"
  expect_code 0 "$RC" "$2 should be allowed ($OUT)"
  [ -z "$OUT" ] || fail "$2: an allow must print nothing, got: $OUT"
}

denies() {  # <payload> <label>
  guard "$1"
  expect_code 2 "$RC" "$2 should be denied"
  assert_contains "$OUT" "fm-sandbox-guard:" "$2: the deny reason must reach the worker on stderr"
}

test_allows_the_task_write_set() {
  allows "$(payload Write file_path "$WT/src/a.txt")" "a write inside the worktree"
  allows "$(payload Write file_path "$WT/new/deep/file.txt")" "a new nested file inside the worktree"
  allows "$(payload Edit file_path "$DATA/report.md")" "the scout report"
  allows "$(payload Write file_path "$TASKTMP/scratch.txt")" "the task temp dir"
  allows "$(payload Edit file_path "$STATE/t1.status")" "the task's own status file"
  allows "$(payload MultiEdit file_path "src/a.txt")" "a relative path resolved against cwd"
  allows "$(payload NotebookEdit notebook_path "$WT/n.ipynb")" "a notebook inside the worktree"
  allows "$(payload Edit file_path "$WT/inside-link")" "a symlink that stays inside the worktree"
  pass "the guard allows the worktree, the report dir, task temp, and the task's own state files"
}

test_denies_everything_else() {
  denies "$(payload Write file_path "$OUTSIDE/x.txt")" "a write outside every root"
  denies "$(payload Write file_path "$STATE/other.status")" "another task's status file"
  denies "$(payload Write file_path "$TMP_ROOT/wt-evil/x")" "a sibling sharing the worktree's name prefix"
  denies "$(payload Write file_path "$WT/../outside/x.txt")" "a .. escape from the worktree"
  denies "$(payload Write file_path "$WT/escape-dir/x.txt")" "a write through a directory symlink pointing outside"
  denies "$(payload Edit file_path "$WT/escape-file")" "a write through a file symlink pointing outside"
  denies "$(payload Write file_path "$WT/dangling/x.txt")" "a write through a dangling symlink"
  denies "$(payload Write file_path "$WT/new/../../outside/x")" "a .. inside a missing directory"
  denies "$(payload NotebookEdit notebook_path "$OUTSIDE/n.ipynb")" "a notebook outside the worktree"
  pass "the guard denies outside paths, prefix tricks, .. escapes, and symlink escapes"
}

test_fails_closed() {
  local out rc
  denies '{"tool_name":"Write","tool_input":{}}' "a payload with no path"
  denies 'not json' "an unreadable payload"
  denies '{"tool_name":"Write","tool_input":{"file_path":"rel.txt"}}' "a relative path with no cwd"
  out=$(payload Write file_path "$WT/src/a.txt" | "$GUARD" 2>&1)
  rc=$?
  expect_code 2 "$rc" "no configured roots must deny"
  assert_contains "$out" "no allowed write roots" "no-roots refusal must say why"
  pass "the guard fails closed on missing roots, paths, and unreadable payloads"
}

run_case test_allows_the_task_write_set
run_case test_denies_everything_else
run_case test_fails_closed
fm_case_summary "fm-sandbox-guard"
