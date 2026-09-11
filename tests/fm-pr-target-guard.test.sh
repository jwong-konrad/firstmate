#!/usr/bin/env bash
# Behavior test for bin/fm-pr-target-guard.sh, the refusal that keeps this home's
# work from opening a pull request against a repository it must never reach.
#
# Motivating incidents (data/access-ledger.md section 1): four pull requests
# against the pull-only upstream template - #856 on 2026-07-22, then #1318,
# #1319 and #1320 on 2026-07-30. The store that actually decides the pipeline's
# target is no-mistakes' own database, not git or gh config, so every case here
# builds a real sqlite database with a `repos` row and drives the guard against
# it exactly as a spawn would.
#
# Each rule gets both halves: the regression is REFUSED, and the legitimate shape
# it could be confused with PASSES. A guard that goes red on legitimate work
# trains people to distrust the whole suite, so the pass cases are the point as
# much as the refusals. The suite closes with two integration cases that drive
# the real bin/fm-spawn.sh, because "refused before any push or PR can happen"
# is a claim about the spawn gate, not about the guard in isolation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-pr-target-guard.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-target-guard)

# The guard reads the pipeline's target out of sqlite. Without it every case
# would exercise only the fallback path, which would be a silent loss of
# coverage rather than a smaller suite, so say so instead.
command -v sqlite3 >/dev/null 2>&1 \
  || fail "fm-pr-target-guard tests need sqlite3 to build a no-mistakes database fixture"

FORK_SSH='git@github.com:jwong-konrad/firstmate.git'
FORK_HTTPS='https://github.com/jwong-konrad/firstmate.git'
UPSTREAM_HTTPS='https://github.com/kunchenguid/firstmate.git'

# make_case <name>: a git repo with one commit plus an isolated NM_HOME and
# firstmate config dir. Echoes "<case_dir>|<repo>|<nm_home>|<config>|<fakebin>".
# The repo starts with NO remotes and NO database row; each case adds exactly the
# state it is about, so a case never passes for a reason it did not set up.
make_case() {
  local name=$1 case_dir repo nm config fakebin
  case_dir="$TMP_ROOT/$name"
  repo="$case_dir/repo"
  nm="$case_dir/nm"
  config="$case_dir/config"
  fakebin=$(fm_fakebin "$case_dir")
  mkdir -p "$nm" "$config"
  fm_git_init_commit "$repo"
  # Never let the real no-mistakes binary be reached: the fallback path must be
  # driven by the fixture, not by whatever is installed on the host.
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s|%s|%s|%s|%s\n' "$case_dir" "$repo" "$nm" "$config" "$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR REPO NM_HOME_DIR CONFIG_DIR FAKEBIN_DIR <<EOF
$1
EOF
  NM_DB="$NM_HOME_DIR/state.sqlite"
  REPO_PHYS=$(cd "$REPO" && pwd -P)
}

# nm_init <upstream_url>: the state `no-mistakes init` leaves behind - the mirror
# remote in the repo and the repos row holding the pull-request target.
nm_init() {
  local upstream=$1
  git -C "$REPO" remote add no-mistakes "$NM_HOME_DIR/repos/fixture.git"
  sqlite3 "$NM_DB" "create table if not exists repos (
    id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE, upstream_url TEXT NOT NULL,
    fork_url TEXT, default_branch TEXT NOT NULL DEFAULT 'main', created_at INTEGER NOT NULL);"
  sqlite3 "$NM_DB" "insert into repos (id,working_path,upstream_url,fork_url,default_branch,created_at)
    values ('fixture','$REPO_PHYS','$upstream','','main',0);"
}

# mark_pull_only <remote> <url>: a fetch-only remote, the way this home marked
# its upstream on 2026-07-30 - a push URL that is not a URL at all.
mark_pull_only() {
  git -C "$REPO" remote add "$1" "$2"
  git -C "$REPO" config "remote.$1.pushurl" DISABLED-PULL-ONLY
}

run_guard() {
  NM_HOME="$NM_HOME_DIR" FM_CONFIG_OVERRIDE="$CONFIG_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$GUARD" "$REPO" "$@" 2>&1
}

# --- R1: the pipeline points at a denied repository -------------------------

# The shape this home is in right now: origin is the fork, the pipeline agrees,
# and the pull-only upstream is a remote. Nothing may refuse here - this is the
# case that runs on every spawn of every project, every day.
test_healthy_fork_target_passes() {
  local rec out status
  rec=$(make_case healthy); read_case "$rec"
  git -C "$REPO" remote add origin "$FORK_SSH"
  mark_pull_only upstream "$UPSTREAM_HTTPS"
  git -C "$REPO" config remote.origin.gh-resolved base
  nm_init "$FORK_SSH"

  out=$(run_guard --explain); status=$?
  expect_code 0 "$status" "the correct, everyday configuration must pass"
  assert_contains "$out" 'no denied pull-request target' "--explain must report the verdict"
  assert_contains "$out" 'github.com/jwong-konrad/firstmate' "--explain must name the resolved target"
  pass "origin, pipeline target, and gh base all on the fork passes"
}

# The regression the incident record calls the live risk: something re-inits or
# re-clones and the recorded target goes back to the pull-only upstream. With no
# denylist file at all, the broken push URL on the upstream remote is the only
# evidence - and it must be enough, or a lost config file silently disarms this.
test_pull_only_remote_denies_target_with_no_config() {
  local rec out status
  rec=$(make_case pull-only-remote); read_case "$rec"
  git -C "$REPO" remote add origin "$FORK_SSH"
  mark_pull_only upstream "$UPSTREAM_HTTPS"
  git -C "$REPO" config remote.origin.gh-resolved base
  nm_init "$UPSTREAM_HTTPS"

  assert_absent "$CONFIG_DIR/pr-target-deny" "this case must run with no denylist file"
  out=$(run_guard); status=$?
  expect_code 4 "$status" "a pipeline target on a pull-only remote must refuse"
  assert_contains "$out" 'REFUSED (R1)' "the refusal must be reported as R1"
  assert_contains "$out" 'github.com/kunchenguid/firstmate' "the refusal must name the denied target"
  assert_contains "$out" 'DISABLED-PULL-ONLY' "the refusal must name the evidence that denied it"
  assert_contains "$out" 'no-mistakes init' "the refusal must name the concrete fix"
  pass "a pipeline target that a pull-only remote names is refused with no config at all"
}

# The other regression path: a re-clone FROM the upstream, so origin and the
# recorded target agree and no remote is marked pull-only. Nothing local objects
# except the denylist, which is why the denylist exists.
test_denylisted_target_is_refused_when_origin_agrees() {
  local rec out status
  rec=$(make_case denylist); read_case "$rec"
  git -C "$REPO" remote add origin "$UPSTREAM_HTTPS"
  git -C "$REPO" config remote.origin.gh-resolved base
  nm_init "$UPSTREAM_HTTPS"

  out=$(run_guard); status=$?
  expect_code 0 "$status" "with no denylist there is no local evidence to refuse on"

  printf '# the upstream template is pull-only\nkunchenguid/firstmate\n' > "$CONFIG_DIR/pr-target-deny"
  out=$(run_guard); status=$?
  expect_code 4 "$status" "a denylisted target must refuse even when origin agrees with it"
  assert_contains "$out" 'REFUSED (R1)' "the refusal must be reported as R1"
  assert_contains "$out" 'pr-target-deny' "the refusal must name the denylist as its evidence"
  pass "a bare owner/name denylist entry refuses a target that origin itself points at"
}

# A denylist entry must not leak onto a different repository that merely shares
# an owner or a name.
test_denylist_does_not_match_a_different_repo() {
  local rec status
  rec=$(make_case denylist-precision); read_case "$rec"
  git -C "$REPO" remote add origin "$FORK_SSH"
  git -C "$REPO" config remote.origin.gh-resolved base
  nm_init "$FORK_SSH"
  printf 'kunchenguid/firstmate\njwong-konrad/something-else\n' > "$CONFIG_DIR/pr-target-deny"

  run_guard >/dev/null; status=$?
  expect_code 0 "$status" "a denylist must not match a repo sharing only an owner or only a name"
  pass "denylist entries match whole repositories, not owners or names alone"
}

# --- R2: the pipeline and origin disagree -----------------------------------

# The cause that actually opened #1318 and #1319: origin was re-pointed to the
# fork and the row still held the value captured before the switch. Nothing here
# is denylisted - the disagreement itself is the fault.
test_stale_target_disagreeing_with_origin_is_refused() {
  local rec out status
  rec=$(make_case stale-row); read_case "$rec"
  git -C "$REPO" remote add origin "$FORK_SSH"
  git -C "$REPO" config remote.origin.gh-resolved base
  nm_init 'https://github.com/someone-else/firstmate.git'

  out=$(run_guard); status=$?
  expect_code 4 "$status" "a recorded target that disagrees with origin must refuse"
  assert_contains "$out" 'REFUSED (R2)' "the refusal must be reported as R2"
  assert_contains "$out" 'github.com/someone-else/firstmate' "the refusal must name the stale target"
  assert_contains "$out" 'github.com/jwong-konrad/firstmate' "the refusal must name what origin says instead"
  pass "a recorded target that no longer matches origin is refused as stale"
}

# The same repository written two ways is the same repository. If ssh and https
# forms did not compare equal, R2 would refuse every correctly configured repo -
# the worst possible false positive, because it would fire on all of them.
test_url_forms_of_one_repo_compare_equal() {
  local rec status
  rec=$(make_case url-forms); read_case "$rec"
  git -C "$REPO" remote add origin "$FORK_SSH"
  git -C "$REPO" config remote.origin.gh-resolved base
  nm_init "$FORK_HTTPS"

  run_guard >/dev/null; status=$?
  expect_code 0 "$status" "an ssh origin and an https target for one repo must compare equal"
  pass "ssh, https, and .git-suffixed forms of one repository are treated as one"
}

# --- R3 and R4: gh's own base repository ------------------------------------

test_gh_base_on_a_denied_repo_is_refused() {
  local rec out status
  rec=$(make_case gh-base-denied); read_case "$rec"
  git -C "$REPO" remote add origin "$FORK_SSH"
  mark_pull_only upstream "$UPSTREAM_HTTPS"
  git -C "$REPO" config remote.origin.gh-resolved kunchenguid/firstmate
  nm_init "$FORK_SSH"

  out=$(run_guard); status=$?
  expect_code 4 "$status" "a gh base repo on a denied repository must refuse"
  assert_contains "$out" 'REFUSED (R3)' "the refusal must be reported as R3"
  assert_contains "$out" 'gh repo set-default' "the refusal must name the concrete fix"
  pass "a gh base repository pointing at a denied repo is refused even when the pipeline is correct"
}

# The #856 shape: gh has no recorded base and falls back to the fork parent,
# which is a server-side fact this guard cannot read. Unset next to a pull-only
# remote is refused rather than assumed safe.
test_unset_gh_base_beside_a_denied_remote_is_refused() {
  local rec out status
  rec=$(make_case gh-base-unset); read_case "$rec"
  git -C "$REPO" remote add origin "$FORK_SSH"
  mark_pull_only upstream "$UPSTREAM_HTTPS"
  nm_init "$FORK_SSH"

  out=$(run_guard); status=$?
  expect_code 4 "$status" "an unset gh base beside a denied remote must refuse"
  assert_contains "$out" 'REFUSED (R4)' "the refusal must be reported as R4"
  assert_contains "$out" 'gh repo set-default jwong-konrad/firstmate' \
    "the refusal must name the exact command, with the repo derived from origin"
  pass "an unset gh base repository beside a pull-only remote is refused"
}

# The same unset base with nothing denied anywhere is the ordinary state of most
# repositories on most machines. It must not refuse, or the guard would fire on
# nearly every project in the fleet.
test_unset_gh_base_without_any_denied_repo_passes() {
  local rec status
  rec=$(make_case gh-base-unset-clean); read_case "$rec"
  git -C "$REPO" remote add origin "$FORK_SSH"
  nm_init "$FORK_SSH"

  run_guard >/dev/null; status=$?
  expect_code 0 "$status" "an unset gh base with nothing denied must pass"
  pass "an unset gh base repository alone is not a refusal"
}

# --- applicability and unknown states ---------------------------------------

# A repo no-mistakes has never initialized has no pipeline target to be wrong.
# Every fixture repo in firstmate's own test suite is this shape, so a refusal
# here would break suites that have nothing to do with pull-request targets.
test_repo_without_no_mistakes_passes() {
  local rec status
  rec=$(make_case uninitialized); read_case "$rec"
  git -C "$REPO" remote add origin "$FORK_SSH"

  run_guard >/dev/null; status=$?
  expect_code 0 "$status" "a repo no-mistakes never initialized must pass"
  pass "a repo with no no-mistakes wiring is not applicable and passes"
}

# A directory that is not a checkout at all has no pull-request target to be
# wrong. It must pass rather than refuse, so that a caller handed a path before
# it is a repo gets its own clear error instead of a refusal it cannot act on.
test_non_git_directory_passes() {
  local rec out status
  rec=$(make_case non-git); read_case "$rec"
  mkdir -p "$CASE_DIR/plain"
  out=$(NM_HOME="$NM_HOME_DIR" FM_CONFIG_OVERRIDE="$CONFIG_DIR" PATH="$FAKEBIN_DIR:$PATH" \
    "$GUARD" "$CASE_DIR/plain" --explain 2>&1); status=$?
  expect_code 0 "$status" "a directory that is not a git work tree must pass, not refuse"
  assert_contains "$out" 'not a git work tree' "--explain must say why it did not apply"
  pass "a directory that is not a checkout has no pull-request target and passes"
}

# A missing path is a genuinely malformed invocation, which stays an error so a
# caller never reads a typo as a clean verdict.
test_missing_path_is_a_usage_error() {
  local status
  "$GUARD" "$TMP_ROOT/no-such-directory" >/dev/null 2>&1; status=$?
  expect_code 2 "$status" "a path that does not exist must be a usage error, not a pass"
  pass "a nonexistent path is a usage error rather than a clean verdict"
}

# Wired up here, but the target cannot be read. A guard that cannot see where the
# pipeline points must not report the checkout as safe.
test_initialized_but_unreadable_target_is_refused() {
  local rec out status
  rec=$(make_case unreadable); read_case "$rec"
  git -C "$REPO" remote add origin "$FORK_SSH"
  nm_init "$FORK_SSH"
  rm -f "$NM_DB"

  out=$(run_guard); status=$?
  expect_code 4 "$status" "an unreadable target in an initialized repo must refuse"
  assert_contains "$out" 'REFUSED (unreadable target)' "the refusal must say the target could not be read"
  pass "no-mistakes wired up with an unreadable target refuses instead of passing"
}

# The supported-command fallback for a host without sqlite3: the pipeline's
# target is read off the `remote:` line of `no-mistakes status` instead, and the
# same rules apply to it.
test_status_fallback_supplies_the_target_without_sqlite3() {
  local rec out status
  rec=$(make_case status-fallback); read_case "$rec"
  git -C "$REPO" remote add origin "$FORK_SSH"
  mark_pull_only upstream "$UPSTREAM_HTTPS"
  git -C "$REPO" config remote.origin.gh-resolved base
  nm_init "$FORK_SSH"

  cat > "$FAKEBIN_DIR/sqlite3" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$FAKEBIN_DIR/sqlite3"
  cat > "$FAKEBIN_DIR/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '    repo:  /fixture\n  remote:  https://github.com/kunchenguid/firstmate.git\n  daemon:  running\n'
SH
  chmod +x "$FAKEBIN_DIR/no-mistakes"

  out=$(run_guard); status=$?
  expect_code 4 "$status" "the status fallback must be read and judged like the database"
  assert_contains "$out" 'REFUSED (R1)' "the fallback-sourced target must go through the same rules"
  assert_contains "$out" 'github.com/kunchenguid/firstmate' "the refusal must name the target the fallback reported"
  pass "without sqlite3 the target is read from 'no-mistakes status' and judged identically"
}

# Reading another tool's live database must never change it.
test_database_is_never_written() {
  local rec before after status
  rec=$(make_case read-only); read_case "$rec"
  git -C "$REPO" remote add origin "$FORK_SSH"
  mark_pull_only upstream "$UPSTREAM_HTTPS"
  nm_init "$UPSTREAM_HTTPS"

  before=$(cksum < "$NM_DB")
  run_guard >/dev/null; status=$?
  expect_code 4 "$status" "test setup: this fixture is meant to refuse"
  after=$(cksum < "$NM_DB")
  [ "$before" = "$after" ] || fail "the guard must never write to the no-mistakes database"
  assert_absent "$NM_DB-wal" "the guard must not leave a write-ahead log behind"
  pass "the no-mistakes database is byte-identical after a guard run"
}

# --- integration: the spawn gate --------------------------------------------
#
# "Refused before any push or PR can happen" is a claim about bin/fm-spawn.sh,
# so these two drive the real script with a fake tmux/treehouse, exactly as
# tests/fm-spawn-collision-guard.test.sh does.

make_spawn_fakebin() {
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  send-keys)
    [ -z "${FM_FAKE_SENDKEYS_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_SENDKEYS_LOG"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/no-mistakes"
}

# make_spawn_case <name> <id> <upstream_url>: a firstmate home, a project repo
# with a worktree, a brief, and a no-mistakes row holding <upstream_url>.
make_spawn_case() {
  local name=$1 id=$2 upstream=$3 case_dir home proj wt nm fakebin proj_phys
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  nm="$case_dir/nm"
  fakebin=$(fm_fakebin "$case_dir")
  make_spawn_fakebin "$fakebin"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$nm"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  proj_phys=$(cd "$proj" && pwd -P)
  git -C "$proj" remote add origin "$FORK_SSH"
  git -C "$proj" remote add no-mistakes "$nm/repos/fixture.git"
  git -C "$proj" config remote.origin.gh-resolved base
  git -C "$proj" remote add upstream "$UPSTREAM_HTTPS"
  git -C "$proj" config remote.upstream.pushurl DISABLED-PULL-ONLY
  sqlite3 "$nm/state.sqlite" "create table repos (
    id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE, upstream_url TEXT NOT NULL,
    fork_url TEXT, default_branch TEXT NOT NULL DEFAULT 'main', created_at INTEGER NOT NULL);"
  sqlite3 "$nm/state.sqlite" "insert into repos (id,working_path,upstream_url,fork_url,default_branch,created_at)
    values ('fixture','$proj_phys','$upstream','','main',0);"
  printf '%s|%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$wt" "$nm" "$fakebin"
}

read_spawn_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR NM_DIR FAKEBIN_DIR <<EOF
$1
EOF
  SENDKEYS_LOG="$CASE_DIR/sendkeys.log"
}

run_spawn() {
  local id=$1
  : > "$SENDKEYS_LOG"
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" NM_HOME="$NM_DIR" \
    FM_FAKE_SENDKEYS_LOG="$SENDKEYS_LOG" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" 2>&1
}

# The acceptance case: a project whose recorded pull-request target points at the
# pull-only upstream must never reach a worker at all - no worktree handed out,
# no agent launched, no task record written.
test_spawn_is_refused_when_the_target_is_denied() {
  local rec id out status
  id=prguard-denied-g7
  rec=$(make_spawn_case spawn-denied "$id" "$UPSTREAM_HTTPS")
  read_spawn_case "$rec"

  out=$(run_spawn "$id"); status=$?
  expect_code 1 "$status" "a spawn into a project with a denied pull-request target must fail"
  assert_contains "$out" 'REFUSED (R1)' "the spawn must surface the guard's refusal"
  assert_contains "$out" 'github.com/kunchenguid/firstmate' "the refusal must name the denied target"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must never write a task record"
  assert_no_grep 'treehouse get' "$SENDKEYS_LOG" \
    "a refused spawn must never allocate a worktree"
  pass "a spawn is refused before any worktree, agent, or task record exists"
}

# The same project with a correct recorded target spawns exactly as before, so
# the gate is not a blanket refusal.
test_spawn_proceeds_when_the_target_is_correct() {
  local rec id out status
  id=prguard-clean-g7
  rec=$(make_spawn_case spawn-clean "$id" "$FORK_SSH")
  read_spawn_case "$rec"

  out=$(run_spawn "$id"); status=$?
  expect_code 0 "$status" "a spawn into a correctly targeted project must proceed: $out"
  assert_present "$HOME_DIR/state/$id.meta" "a passing spawn must still write its task record"
  assert_grep 'treehouse get' "$SENDKEYS_LOG" "a passing spawn must still allocate its worktree"
  pass "a correctly targeted project spawns unchanged"
}

run_case test_healthy_fork_target_passes
run_case test_pull_only_remote_denies_target_with_no_config
run_case test_denylisted_target_is_refused_when_origin_agrees
run_case test_denylist_does_not_match_a_different_repo
run_case test_stale_target_disagreeing_with_origin_is_refused
run_case test_url_forms_of_one_repo_compare_equal
run_case test_gh_base_on_a_denied_repo_is_refused
run_case test_unset_gh_base_beside_a_denied_remote_is_refused
run_case test_unset_gh_base_without_any_denied_repo_passes
run_case test_repo_without_no_mistakes_passes
run_case test_non_git_directory_passes
run_case test_missing_path_is_a_usage_error
run_case test_initialized_but_unreadable_target_is_refused
run_case test_status_fallback_supplies_the_target_without_sqlite3
run_case test_database_is_never_written
run_case test_spawn_is_refused_when_the_target_is_denied
run_case test_spawn_proceeds_when_the_target_is_correct
fm_case_summary "fm-pr-target-guard"
