#!/usr/bin/env bash
# Behavior tests for the app-source refresh bin/fm-spawn.sh runs at spawn time
# from config/app-checkouts.
#
# Why it exists: a worker reads its project's app source - a checkout outside the
# firstmate home - read-only through an absolute path, and the project-write
# boundary correctly stops the worker from pulling that checkout itself. So the
# pull has to happen as the captain, at spawn. The scheduled recon dispatcher
# already does this for scheduled work.
#
# The contract these tests pin, in order of how much a regression would cost:
#   1. The pull actually advances the checkout (the config file was inert before).
#   2. Every failure mode is FAIL-OPEN - the spawn still happens.
#   3. The lock name matches the scheduled dispatcher's byte for byte, or the two
#      paths can double-pull one checkout while each believes it holds the lock.
#   4. A project clone in this home is never pulled, because fm-fleet-sync.sh is
#      the one owner of refreshing those (AGENTS.md rule 1).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-app-checkouts)

# --- fixtures ---------------------------------------------------------------

# A fake tmux/treehouse pair. The launch line itself does not matter here - these
# tests assert on the app-source checkout and on fm-spawn's own stderr - so the
# fake harness is a plain exit-0 stub.
make_checkout_fakebin() {
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
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse claude
  printf '%s\n' "$fakebin"
}

# An app-source checkout that is one commit BEHIND its origin, so a successful
# ff-pull is observable as a change in HEAD rather than inferred from output.
# Echoes "<checkout>|<origin-tip-sha>".
make_stale_app_checkout() {  # <dir>
  local dir=$1 upstream="$1/upstream" checkout="$1/app" tip
  mkdir -p "$dir"
  fm_git_init_commit "$upstream"
  git clone --quiet "$upstream" "$checkout"
  printf 'second\n' > "$upstream/second.txt"
  git -C "$upstream" add second.txt
  git -C "$upstream" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm second
  tip=$(git -C "$upstream" rev-parse HEAD)
  printf '%s|%s\n' "$checkout" "$tip"
}

checkout_head() {  # <checkout>
  git -C "$1" rev-parse HEAD
}

# The lock path the SCHEDULED recon dispatcher computes for a checkout, spelled
# exactly as it spells it (`echo "$checkout" | shasum | cut -c1-12`, so the hashed
# input carries the trailing newline). fm-spawn must land on this same path: if it
# hashes the path any other way the two lock names differ, each side takes a lock
# the other never sees, and they can pull one checkout concurrently.
dispatcher_lock_path() {  # <checkout>
  printf '/tmp/qa-recon-checkout-%s.lock\n' "$(echo "$1" | shasum | cut -c1-12)"
}

make_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_checkout_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$wt" "$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {  # <home> <wt> <fakebin> <spawn args...>
  local home=$1 wt=$2 fakebin=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# --- the defect this closes -------------------------------------------------

test_configured_checkout_is_pulled() {
  local rec id app tip out status
  id=appco-pull-x1
  rec=$(make_case appco-pull "$id")
  read_case "$rec"
  IFS='|' read -r app tip <<EOF
$(make_stale_app_checkout "$CASE_DIR/appsrc")
EOF
  [ "$(checkout_head "$app")" != "$tip" ] || fail "fixture checkout was not behind its origin"
  # Keyed by the projects/<name> clone basename, which make_case names "project".
  printf '# project    app-source checkout\nproject      %s\n' "$app" \
    > "$HOME_DIR/config/app-checkouts"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "the spawn should succeed"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  [ "$(checkout_head "$app")" = "$tip" ] || fail \
    "config/app-checkouts was read but the app-source checkout was not fast-forwarded"
  pass "a configured app-source checkout is fast-forwarded at spawn"
}

test_kill_switch_skips_the_pull() {
  local rec id app tip before out status
  id=appco-killswitch-x2
  rec=$(make_case appco-killswitch "$id")
  read_case "$rec"
  IFS='|' read -r app tip <<EOF
$(make_stale_app_checkout "$CASE_DIR/appsrc")
EOF
  printf 'project %s\n' "$app" > "$HOME_DIR/config/app-checkouts"
  before=$(checkout_head "$app")

  out=$(FM_NO_CHECKOUT_PULL=1 run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "the spawn should succeed with the kill switch set"
  [ "$(checkout_head "$app")" = "$before" ] || fail \
    "FM_NO_CHECKOUT_PULL=1 did not skip the app-source pull"
  [ "$before" != "$tip" ] || fail "fixture checkout was already at the origin tip"
  pass "FM_NO_CHECKOUT_PULL=1 skips the app-source pull"
}

test_held_lock_skips_the_pull_and_names_it() {
  local rec id app tip before lock out status
  id=appco-lock-x3
  rec=$(make_case appco-lock "$id")
  read_case "$rec"
  IFS='|' read -r app tip <<EOF
$(make_stale_app_checkout "$CASE_DIR/appsrc")
EOF
  printf 'project %s\n' "$app" > "$HOME_DIR/config/app-checkouts"
  before=$(checkout_head "$app")
  # Take the lock the way the scheduled dispatcher takes it. fm-spawn must see it.
  lock=$(dispatcher_lock_path "$app")
  mkdir "$lock" || fail "could not pre-create the dispatcher lock at $lock"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  status=$?
  rmdir "$lock" 2>/dev/null || true
  expect_code 0 "$status" "a held refresh lock should not refuse the spawn"
  [ "$(checkout_head "$app")" = "$before" ] || fail \
    "fm-spawn pulled a checkout whose dispatcher lock was held, so its lock name does not match the dispatcher's"
  assert_contains "$out" "lock held" "the skipped pull was not reported"
  assert_contains "$out" "$lock" "the report did not name the lock path, so a stale lock is not diagnosable"
  pass "a refresh lock held by the scheduled dispatcher skips the pull and names the lock"
}

# --- fail-open on every bad configuration -----------------------------------

test_absent_config_is_silent() {
  local rec id out status
  id=appco-absent-x4
  rec=$(make_case appco-absent "$id")
  read_case "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "an absent config/app-checkouts is the normal state, not an error"
  assert_not_contains "$out" "app-source" "an absent config/app-checkouts produced output"
  pass "an absent config/app-checkouts is silent and does not affect the spawn"
}

test_unlisted_project_is_silent() {
  local rec id out status
  id=appco-unlisted-x5
  rec=$(make_case appco-unlisted "$id")
  read_case "$rec"
  printf 'someotherproject /nonexistent/elsewhere\n' > "$HOME_DIR/config/app-checkouts"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "a config/app-checkouts with no line for this project should spawn"
  assert_not_contains "$out" "app-source" "an unrelated app-checkouts line produced output"
  pass "a project with no config/app-checkouts line is unaffected"
}

test_missing_path_warns_and_spawns() {
  local rec id out status
  id=appco-missing-x6
  rec=$(make_case appco-missing "$id")
  read_case "$rec"
  printf 'project %s/definitely-absent\n' "$CASE_DIR" > "$HOME_DIR/config/app-checkouts"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "a missing app-source path must not refuse the spawn"
  assert_contains "$out" "does not exist" "the missing path was not reported"
  assert_contains "$out" "spawned $id" "the spawn did not continue after the warning"
  pass "a config/app-checkouts path that does not exist warns and the spawn continues"
}

test_relative_path_warns_and_spawns() {
  local rec id out status
  id=appco-relative-x7
  rec=$(make_case appco-relative "$id")
  read_case "$rec"
  # A relative path resolves against whatever cwd fm-spawn was called from, so it
  # can silently name a different directory on every spawn.
  printf 'project ../somewhere\n' > "$HOME_DIR/config/app-checkouts"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "a relative app-source path must not refuse the spawn"
  assert_contains "$out" "not absolute" "the relative path was not reported"
  assert_contains "$out" "spawned $id" "the spawn did not continue after the warning"
  pass "a relative config/app-checkouts path is refused for pulling and the spawn continues"
}

test_non_git_path_warns_and_spawns() {
  local rec id out status
  id=appco-nongit-x8
  rec=$(make_case appco-nongit "$id")
  read_case "$rec"
  mkdir -p "$CASE_DIR/plaindir"
  printf 'project %s/plaindir\n' "$CASE_DIR" > "$HOME_DIR/config/app-checkouts"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "a non-git app-source path must not refuse the spawn"
  assert_contains "$out" "not a git checkout" "the non-git path was not reported"
  assert_contains "$out" "spawned $id" "the spawn did not continue after the warning"
  pass "a config/app-checkouts path that is not a git checkout warns and the spawn continues"
}

test_key_with_no_path_warns_and_spawns() {
  local rec id out status
  id=appco-nopath-x9
  rec=$(make_case appco-nopath "$id")
  read_case "$rec"
  printf 'project\n' > "$HOME_DIR/config/app-checkouts"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "a config/app-checkouts line with no path must not refuse the spawn"
  assert_contains "$out" "no checkout path" "the pathless line was not reported"
  assert_contains "$out" "spawned $id" "the spawn did not continue after the warning"
  pass "a config/app-checkouts line naming a project with no path warns and the spawn continues"
}

test_failed_pull_warns_and_spawns() {
  local rec id app out status
  id=appco-pullfail-x10
  rec=$(make_case appco-pullfail "$id")
  read_case "$rec"
  IFS='|' read -r app _ <<EOF
$(make_stale_app_checkout "$CASE_DIR/appsrc")
EOF
  # Diverge the checkout so --ff-only refuses. This is the case that must never
  # be "fixed" by force or a stash: the local commit has to survive untouched.
  printf 'local work\n' > "$app/local.txt"
  git -C "$app" add local.txt
  git -C "$app" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'local divergent commit'
  printf 'project %s\n' "$app" > "$HOME_DIR/config/app-checkouts"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "a failed ff-pull must not refuse the spawn"
  assert_contains "$out" "ff-pull failed" "the failed pull was not reported"
  assert_contains "$out" "spawned $id" "the spawn did not continue after the failed pull"
  assert_grep 'local work' "$app/local.txt" "the divergent local commit was not left intact"
  pass "a divergent checkout fails the ff-pull, keeps its local work, and the spawn continues"
}

# --- the project-write boundary ---------------------------------------------

test_project_clone_in_this_home_is_never_pulled() {
  local rec id clone before out status
  id=appco-projclone-x11
  rec=$(make_case appco-projclone "$id")
  read_case "$rec"
  # A hand-maintained map makes this typo easy to write and invisible afterwards:
  # pointing an app-checkout entry at one of this home's own project clones would
  # have fm-spawn run a state-changing git command inside a project clone, which
  # AGENTS.md rule 1 reserves for fm-fleet-sync.sh.
  clone="$HOME_DIR/projects/project"
  fm_git_init_commit "$CASE_DIR/cloneupstream"
  git clone --quiet "$CASE_DIR/cloneupstream" "$clone"
  printf 'second\n' > "$CASE_DIR/cloneupstream/second.txt"
  git -C "$CASE_DIR/cloneupstream" add second.txt
  git -C "$CASE_DIR/cloneupstream" -c user.name='Firstmate Tests' \
    -c user.email='tests@example.invalid' commit -qm second
  before=$(checkout_head "$clone")
  printf 'project %s\n' "$clone" > "$HOME_DIR/config/app-checkouts"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "the spawn should continue after refusing to pull a project clone"
  [ "$(checkout_head "$clone")" = "$before" ] || fail \
    "fm-spawn pulled a project clone in this home instead of leaving it to fm-fleet-sync.sh"
  assert_contains "$out" "project clone in this home" "the refusal was not reported"
  pass "an app-checkouts entry pointing at a project clone in this home is never pulled"
}

test_configured_checkout_is_pulled
test_kill_switch_skips_the_pull
test_held_lock_skips_the_pull_and_names_it
test_absent_config_is_silent
test_unlisted_project_is_silent
test_missing_path_warns_and_spawns
test_relative_path_warns_and_spawns
test_non_git_path_warns_and_spawns
test_key_with_no_path_warns_and_spawns
test_failed_pull_warns_and_spawns
test_project_clone_in_this_home_is_never_pulled
