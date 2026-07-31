#!/usr/bin/env bash
# Regression test for fm-spawn.sh's double-allocation guard (the
# fm_spawn_collision_conflicting_task check after treehouse hands out a
# worktree, before the agent launches).
#
# Motivating incidents (2026-07-16, 2026-07-21): a crewmate whose agent
# process died or was relaunched by session id no longer holds its treehouse
# worktree lease, so a later fm-spawn for the same project was handed the SAME
# pool slot while the first task was still in flight - two agents briefly
# shared one workspace. This simulates a fake tmux/treehouse that always hands
# back one fixed worktree path and asserts: a path already recorded as
# worktree= in another live task's meta refuses the spawn immediately, on the
# first detection, with no second `treehouse get` and without touching the
# other task's worktree or meta (so an agent is never launched into the
# collision); a path with no other matching meta proceeds normally; and a path
# whose only prior owner's meta has already been removed (torn down) is freely
# reusable.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-collision-guard)

# make_collision_fakebin <dir>: a fake tmux whose #{pane_current_path} always
# reports FM_FAKE_PANE_PATH (no staleness - the settle loop's two-consecutive-
# reads requirement is satisfied on the second read either way), and a
# no-op treehouse/send-keys, matching the pattern in
# tests/fm-spawn-worktree-settle.test.sh.
make_collision_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_SENDKEYS_LOG:-}" ]; then
      printf '%s\n' "$*" >> "$FM_FAKE_SENDKEYS_LOG"
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_collision_case <name> <id>: a home, a primary project with a real
# worktree (the path treehouse will always hand back), and a brief for <id>.
make_collision_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_collision_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_collision_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
  SENDKEYS_LOG="$CASE_DIR/sendkeys.log"
}

run_collision_spawn() {
  local id=$1
  : > "$SENDKEYS_LOG"
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_FAKE_SENDKEYS_LOG="$SENDKEYS_LOG" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" 2>&1
}

# A worktree already recorded as worktree= in another IN-FLIGHT task's meta
# must refuse the spawn on the spot rather than launch an agent into the
# collision - no re-pool attempt (the pane already sits in the colliding
# worktree, so a second `treehouse get` proves nothing) and no cleanup of the
# other task's worktree.
test_collision_with_live_meta_is_refused() {
  local rec id other_id out status sends
  id=collide-new-z1
  other_id=collide-other-z1
  rec=$(make_collision_case collision-refused "$id")
  read_collision_record "$rec"

  fm_write_meta "$HOME_DIR/state/$other_id.meta" \
    "window=firstmate:fm-$other_id" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"

  out=$(run_collision_spawn "$id")
  status=$?
  expect_code 1 "$status" "spawn must refuse when the worktree collides with a live task's meta"
  assert_contains "$out" "$other_id" "refusal must name the colliding task id"
  assert_contains "$out" "$WT_DIR" "refusal must name the colliding worktree path"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must never write meta for the new task"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$other_id.meta" \
    "the other in-flight task's own meta must be left untouched"
  [ -d "$WT_DIR" ] || fail "the colliding task's worktree must never be removed by the guard"
  sends=$(grep -c 'treehouse get' "$SENDKEYS_LOG" 2>/dev/null || true)
  [ "${sends:-0}" = 1 ] \
    || fail "guard must refuse on first detection: expected exactly 1 'treehouse get', got ${sends:-0}"
  pass "a spawn colliding with another live task's recorded worktree is refused, never launched"
}

# No other task's meta references this worktree: an ordinary spawn is
# unaffected by the guard.
test_no_collision_spawn_proceeds() {
  local rec id out status
  id=collide-clean-z2
  rec=$(make_collision_case collision-none "$id")
  read_collision_record "$rec"

  out=$(run_collision_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn with no colliding meta should succeed"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the allocated worktree"
  pass "a spawn with no matching worktree= in any other meta proceeds normally"
}

# A prior task once recorded this same worktree, but its meta has already
# been removed (the fm-teardown.sh contract for a landed/torn-down task): the
# path is freely reusable and the guard must not refuse it.
test_torn_down_task_worktree_is_reusable() {
  local rec id former_id out status
  id=collide-reuse-z3
  former_id=collide-former-z3
  rec=$(make_collision_case collision-torndown "$id")
  read_collision_record "$rec"

  # former_id's meta is deliberately absent, simulating a completed teardown
  # (bin/fm-teardown.sh removes state/<id>.meta on success) - the path must
  # be reusable, and no residual file should reference former_id at all.
  assert_absent "$HOME_DIR/state/$former_id.meta" "test setup: former task's meta must be absent to model teardown"

  out=$(run_collision_spawn "$id")
  status=$?
  expect_code 0 "$status" "a worktree whose only prior owner was torn down must be reusable"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the reused worktree"
  pass "a worktree path with no live meta (prior owner torn down) is reusable"
}

test_collision_with_live_meta_is_refused
test_no_collision_spawn_proceeds
test_torn_down_task_worktree_is_reusable

echo "# all fm-spawn-collision-guard tests passed"
