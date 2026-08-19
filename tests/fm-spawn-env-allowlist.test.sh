#!/usr/bin/env bash
# Behavior tests for the worker launch-environment boundary: bin/fm-env-clean.sh
# and the way bin/fm-spawn.sh wraps every launch in it.
#
# Motivating incident (2026-07-31): fm-spawn typed the launch command into a pane
# whose login shell held the captain's whole environment, so a worker inherited
# every exported secret. `LINEAR_API_KEY` reached a worker that way and the
# pipeline's PR-body step serialized it verbatim into a public fork PR
# description, tripping GitHub secret scanning. The leaked variable was the
# symptom; blanket inheritance was the defect.
#
# The load-bearing test here is test_launch_drops_unexpected_launching_env: it
# takes the EXACT command line fm-spawn would type into the pane, runs it in a
# shell that has an unexpected variable set (exactly the 2026-07-31 condition),
# and asserts the launched agent's own environment does not contain it. That
# assertion fails on the pre-fix fm-spawn.
#
# The rest pin the other half of the contract - that the boundary does not starve
# a worker of what it legitimately needs (docs/worker-environment.md).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
ENV_CLEAN="$ROOT/bin/fm-env-clean.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-env-allowlist)

# A value that must never survive into an agent's environment. Distinctive so a
# substring search over the whole dumped environment is meaningful.
CANARY='fm-canary-a7b3c9-must-not-reach-the-worker'

# --- fixtures ---------------------------------------------------------------

# The fake tmux captures the literal launch line (`send-keys -l`), the same
# mechanism tests/fm-spawn-dispatch-profile.test.sh uses.
make_env_fakebin() {
  local dir=$1 fakebin agent_env
  fakebin=$(fm_fakebin "$dir")
  agent_env="$dir/agent-env.txt"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  # The fake harness stands in for the real agent process and records the
  # environment it was actually started with. The dump path is baked in at
  # creation time on purpose: it could not be passed through the very boundary
  # under test.
  cat > "$fakebin/claude" <<SH
#!/usr/bin/env bash
printenv > '$agent_env'
exit 0
SH
  chmod +x "$fakebin/claude"
  printf '%s\n' "$fakebin"
}

make_env_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_env_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_env_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
  AGENT_ENV="$CASE_DIR/fake/agent-env.txt"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# Run the captured launch line the way the pane's login shell would, in an
# environment that carries the leak canary. This is what makes the test a real
# regression test rather than a string assertion: the boundary either holds when
# the composed line actually executes, or it does not.
run_captured_launch() {  # <launch-line> <fakebin>
  local launch=$1 fakebin=$2
  # The multiplexer ids are part of the launching pane's environment for real, and
  # a worker's own fm_backend_detect / supervisor-target discovery read them, so
  # they have to be present here for the keep-what-is-needed assertions to mean
  # anything.
  env -u NO_PROXY \
    LINEAR_API_KEY="$CANARY" \
    SSH_AUTH_SOCK="/tmp/$CANARY.sock" \
    FM_TEST_UNEXPECTED_SECRET="$CANARY" \
    TMUX="/tmp/fm-test-tmux-sock,1,0" TMUX_PANE='%7' \
    HERDR_ENV=1 HERDR_PANE_ID='pane-fm-test' \
    PATH="$fakebin:$PATH" \
    bash -c "$launch"
}

# --- the 2026-07-31 regression ----------------------------------------------

test_launch_drops_unexpected_launching_env() {
  local rec id out status launch agent_env
  id=env-leak-guard-x1
  rec=$(make_env_case env-leak-guard "$id")
  read_env_case "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "spawn should succeed"
  assert_contains "$out" "spawned $id" "spawn did not report success"

  launch=$(cat "$LAUNCH_LOG")
  run_captured_launch "$launch" "$FAKEBIN_DIR"
  agent_env="$AGENT_ENV"
  assert_present "$agent_env" "the launch line did not start the agent at all"

  # The incident variable, the broader ssh-agent capability, and an arbitrary
  # unexpected variable must all be absent from the agent's environment.
  assert_no_grep 'LINEAR_API_KEY' "$agent_env" \
    "LINEAR_API_KEY from the launching environment reached the worker"
  assert_no_grep 'SSH_AUTH_SOCK' "$agent_env" \
    "the captain's ssh-agent socket reached the worker"
  assert_no_grep 'FM_TEST_UNEXPECTED_SECRET' "$agent_env" \
    "an unexpected variable in the launching environment reached the worker"
  assert_no_grep "$CANARY" "$agent_env" \
    "a launching-environment secret value reached the worker under some other name"
  pass "an unexpected variable in the launching environment never reaches the worker"
}

# --- the worker still has what it needs -------------------------------------

test_launch_keeps_what_the_worker_needs() {
  local rec id launch agent_env
  id=env-keeps-needs-x2
  rec=$(make_env_case env-keeps-needs "$id")
  read_env_case "$rec"

  run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" >/dev/null 2>&1
  launch=$(cat "$LAUNCH_LOG")
  run_captured_launch "$launch" "$FAKEBIN_DIR"
  agent_env="$AGENT_ENV"

  # Allowlisted context the worker cannot work without.
  assert_grep 'HOME=' "$agent_env" "HOME did not reach the worker"
  assert_grep 'PATH=' "$agent_env" "PATH did not reach the worker"
  # PATH must be the pane's PATH, not a rebuilt one: it is what resolves git, gh,
  # and the harness itself.
  assert_grep "$FAKEBIN_DIR" "$agent_env" "the pane's own PATH did not reach the worker"
  # Multiplexer identity. A worker that runs its own bootstrap, recovery, or
  # spawns needs these: fm_backend_detect reads TMUX/HERDR_ENV to pick the backend
  # adapter, and the supervisor-target discovery reads TMUX_PANE/HERDR_PANE_ID to
  # find the pane its wakes go to. Dropping them sends both to the wrong default.
  assert_grep 'TMUX=/tmp/fm-test-tmux-sock,1,0' "$agent_env" \
    "TMUX did not reach the worker, so its own backend detection cannot see this fleet"
  assert_grep 'TMUX_PANE=%7' "$agent_env" \
    "TMUX_PANE did not reach the worker, so its supervisor-target discovery has no pane"
  assert_grep 'HERDR_ENV=1' "$agent_env" \
    "HERDR_ENV did not reach the worker, so a herdr fleet auto-detects as tmux"
  assert_grep 'HERDR_PANE_ID=pane-fm-test' "$agent_env" \
    "HERDR_PANE_ID did not reach the worker, so its away-mode wakes target the default pane"
  # Firstmate's deliberate injections.
  assert_grep "GOTMPDIR=/tmp/fm-$id/gotmp" "$agent_env" \
    "the per-task GOTMPDIR injection did not reach the worker"
  # GROK_HOME is injected (not allowlisted) so the agent reads hooks from the same
  # home fm-spawn installed them into, even when the pane's value differs.
  assert_grep "GROK_HOME=$HOME_DIR/grok-home" "$agent_env" \
    "the GROK_HOME injection did not reach the worker, so an installed grok hook would be unreachable"
  assert_grep 'FM_MANAGED=1' "$agent_env" \
    "FM_MANAGED did not reach the worker"
  # The harness template's own env prefix must survive the wrapper unchanged.
  assert_grep 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false' "$agent_env" \
    "the harness launch template's env prefix did not reach the worker"
  pass "allowlisted context, firstmate's injections, and the harness env prefix all reach the worker"
}

test_unset_allowed_name_stays_unset() {
  local rec id launch
  id=env-unset-stays-x3
  rec=$(make_env_case env-unset-stays "$id")
  read_env_case "$rec"

  run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" >/dev/null 2>&1
  launch=$(cat "$LAUNCH_LOG")
  # run_captured_launch unsets NO_PROXY, which IS on the built-in allowlist.
  run_captured_launch "$launch" "$FAKEBIN_DIR"
  assert_no_grep 'NO_PROXY=' "$AGENT_ENV" \
    "an allowed but unset name was passed through as set-but-empty"
  pass "an allowed name that is unset in the pane stays unset, not set-but-empty"
}

# --- the named passthrough seam ---------------------------------------------

test_allow_file_widens_by_exact_name() {
  local rec id launch
  id=env-allow-file-x4
  rec=$(make_env_case env-allow-file "$id")
  read_env_case "$rec"
  printf '# this home needs one extra name\nFM_TEST_PROJECT_FLAG\n' \
    > "$HOME_DIR/config/spawn-env-allow"

  run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" >/dev/null 2>&1
  launch=$(cat "$LAUNCH_LOG")
  FM_TEST_PROJECT_FLAG=widened run_captured_launch "$launch" "$FAKEBIN_DIR"
  assert_grep 'FM_TEST_PROJECT_FLAG=widened' "$AGENT_ENV" \
    "config/spawn-env-allow did not widen the allowlist by exact name"
  assert_no_grep 'LINEAR_API_KEY' "$AGENT_ENV" \
    "widening by one name leaked the rest of the launching environment"
  pass "config/spawn-env-allow widens the allowlist by exact name and nothing more"
}

test_injection_seam_reaches_the_agent() {
  local out
  # The seam fm-spawn uses is an explicit NAME=VALUE argument, not a pane export.
  # Pin that it crosses the boundary and that a set-but-empty assignment keeps that
  # exact shape, which is what the secondmate FM_*_OVERRIDE= prefixes rely on.
  out=$("$ENV_CLEAN" PW_MCP_AUTH_APP=polaris FM_ROOT_OVERRIDE= FM_HOME=/tmp/home printenv)
  assert_contains "$out" 'PW_MCP_AUTH_APP=polaris' \
    "an explicit injection did not reach the launched process"
  assert_contains "$out" 'FM_ROOT_OVERRIDE=' \
    "a set-but-empty injection was dropped instead of passed through empty"
  assert_contains "$out" 'FM_HOME=/tmp/home' \
    "the secondmate FM_HOME assignment did not reach the launched process"
  pass "explicit NAME=VALUE injections cross the boundary, including set-but-empty ones"
}

# --- per-project environment (config/project-env) ----------------------------
#
# Every other case in this file runs with no config/project-env at all, so the
# absent-file state - the normal one - is covered throughout rather than here.

# A minimal home that passes validate_firstmate_home_for_spawn, so the
# secondmate-skip case can be asserted without the full secondmate lifecycle
# fixture that tests/fm-secondmate-*.test.sh own.
make_secondmate_home() {  # <dir> <id>
  local dir=$1 id=$2
  mkdir -p "$dir/bin" "$dir/data" "$dir/state"
  printf '# firstmate\n' > "$dir/AGENTS.md"
  printf '%s\n' "$id" > "$dir/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$dir/data/charter.md"
}

test_project_env_reaches_the_agent() {
  local rec id launch
  id=env-project-env-x11
  rec=$(make_env_case env-project-env "$id")
  read_env_case "$rec"
  # Keyed by the projects/<name> clone basename, which make_env_case names
  # "project". PW_MCP_AUTH_APP is the motivating real entry, and it is
  # credential-shaped: config/spawn-env-allow would refuse it by name, so the
  # injection seam is the only path by which it can legitimately reach a worker.
  printf '# per-project worker environment\nproject      PW_MCP_AUTH_APP=polaris FM_TEST_PROJECT_ENV=on\n' \
    > "$HOME_DIR/config/project-env"

  run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" >/dev/null 2>&1
  launch=$(cat "$LAUNCH_LOG")
  run_captured_launch "$launch" "$FAKEBIN_DIR"
  assert_present "$AGENT_ENV" "the config/project-env launch did not start the agent at all"
  assert_grep 'PW_MCP_AUTH_APP=polaris' "$AGENT_ENV" \
    "config/project-env did not reach the agent process"
  assert_grep 'FM_TEST_PROJECT_ENV=on' "$AGENT_ENV" \
    "the second config/project-env entry on the line did not reach the agent process"
  # The mechanism matters as much as the result. Delivering this as a pane
  # `export` would satisfy an inspection of fm-spawn and still never reach the
  # agent, because a pane export does not cross env -i.
  assert_not_contains "$launch" 'export PW_MCP_AUTH_APP' \
    "project-env was typed into the pane as an export instead of injected at the seam"
  pass "config/project-env reaches the agent process through the injection seam"
}

test_project_env_ignores_other_projects() {
  local rec id out status launch
  id=env-project-env-other-x12
  rec=$(make_env_case env-project-env-other "$id")
  read_env_case "$rec"
  printf 'someotherproject PW_MCP_AUTH_APP=polaris\n' > "$HOME_DIR/config/project-env"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "a config/project-env with no line for this project should spawn"
  assert_not_contains "$out" 'warning' "an unrelated project-env line produced a warning"
  launch=$(cat "$LAUNCH_LOG")
  run_captured_launch "$launch" "$FAKEBIN_DIR"
  assert_no_grep 'PW_MCP_AUTH_APP' "$AGENT_ENV" \
    "another project's config/project-env entry reached this project's worker"
  pass "a project with no config/project-env line is unaffected"
}

test_project_env_skipped_for_secondmate() {
  local rec id sub launch
  id=env-project-env-sub-x13
  rec=$(make_env_case env-project-env-sub "$id")
  read_env_case "$rec"
  sub="$CASE_DIR/subhome"
  make_secondmate_home "$sub" "$id"
  # Keyed by the secondmate home's own basename, which is the only key a
  # secondmate spawn could ever match if the project-env path ran for it.
  printf 'subhome PW_MCP_AUTH_APP=polaris\n' > "$HOME_DIR/config/project-env"

  run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sub" claude --secondmate >/dev/null 2>&1
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" 'FM_HOME=' "the secondmate launch line was not captured"
  assert_not_contains "$launch" 'PW_MCP_AUTH_APP' \
    "config/project-env was injected into a secondmate spawn"
  pass "a secondmate spawn is unaffected by config/project-env"
}

test_project_env_invalid_name_refuses_spawn() {
  local rec id out status
  id=env-project-env-badname-x14
  rec=$(make_env_case env-project-env-badname "$id")
  read_env_case "$rec"
  # bin/fm-env-clean.sh parses leading NAME=VALUE arguments the way `env` does, so
  # an entry that is not a valid assignment would be taken as the COMMAND: the
  # spawn would report success and then die on the launch line inside the pane.
  printf 'project 9NOPE=x\n' > "$HOME_DIR/config/project-env"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "an invalid config/project-env name should refuse the spawn"
  assert_contains "$out" "not a valid environment variable name" \
    "the refusal did not explain the invalid entry"
  assert_contains "$out" "9NOPE" "the refusal did not name the offending entry"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "the spawn was refused but still wrote task metadata"
  pass "an invalid config/project-env name refuses the spawn before anything is created"
}

test_project_env_non_assignment_refuses_spawn() {
  local rec id out status
  id=env-project-env-noassign-x15
  rec=$(make_env_case env-project-env-noassign "$id")
  read_env_case "$rec"
  printf 'project JUSTAWORD\n' > "$HOME_DIR/config/project-env"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "a config/project-env entry that is not an assignment should refuse the spawn"
  assert_contains "$out" "is not a NAME=VALUE assignment" \
    "the refusal did not explain the malformed entry"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "the spawn was refused but still wrote task metadata"
  pass "a config/project-env entry that is not a NAME=VALUE assignment refuses the spawn"
}

test_project_env_other_project_malformed_line_still_spawns() {
  local rec id out status launch
  id=env-project-env-otherbad-x16
  rec=$(make_env_case env-project-env-otherbad "$id")
  read_env_case "$rec"
  # Only the spawned project's own line is validated. Another project's bad line
  # is that project's spawn to refuse, not this one's.
  printf 'someotherproject 9NOPE=x\nproject FM_TEST_PROJECT_ENV=on\n' \
    > "$HOME_DIR/config/project-env"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "another project's malformed line should not refuse this spawn"
  launch=$(cat "$LAUNCH_LOG")
  run_captured_launch "$launch" "$FAKEBIN_DIR"
  assert_grep 'FM_TEST_PROJECT_ENV=on' "$AGENT_ENV" \
    "this project's valid entry did not reach the worker"
  pass "a malformed config/project-env line for another project does not affect this spawn"
}

test_project_env_line_with_no_entries_spawns_cleanly() {
  local rec id out status
  id=env-project-env-bare-x18
  rec=$(make_env_case env-project-env-bare "$id")
  read_env_case "$rec"
  # A line naming the project and nothing else declares no environment. It is not
  # a malformed assignment, so it must not refuse - it must simply inject nothing.
  printf 'project\n' > "$HOME_DIR/config/project-env"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "a config/project-env line with no entries should spawn"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  pass "a config/project-env line declaring no entries injects nothing and spawns cleanly"
}

test_project_env_value_holding_a_glob_is_not_expanded() {
  local rec id launch
  id=env-project-env-glob-x17
  rec=$(make_env_case env-project-env-glob "$id")
  read_env_case "$rec"
  printf 'project FM_TEST_PROJECT_GLOB=*\n' > "$HOME_DIR/config/project-env"

  run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" >/dev/null 2>&1
  launch=$(cat "$LAUNCH_LOG")
  run_captured_launch "$launch" "$FAKEBIN_DIR"
  assert_grep 'FM_TEST_PROJECT_GLOB=*' "$AGENT_ENV" \
    "a config/project-env value holding a glob was expanded against the filesystem"
  pass "a config/project-env value holding a glob character reaches the worker verbatim"
}

# --- refusals ----------------------------------------------------------------

test_credential_shaped_allow_entry_refuses_spawn() {
  local rec id out status
  id=env-cred-refuse-x5
  rec=$(make_env_case env-cred-refuse "$id")
  read_env_case "$rec"
  printf 'LINEAR_API_KEY\n' > "$HOME_DIR/config/spawn-env-allow"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "a credential-shaped allow entry should refuse the spawn"
  assert_contains "$out" "LINEAR_API_KEY" "the refusal did not name the offending entry"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "the spawn was refused but still wrote task metadata"
  pass "a credential-shaped config/spawn-env-allow entry refuses the spawn before anything is created"
}

test_invalid_allow_entry_refuses_spawn() {
  local rec id out status
  id=env-invalid-refuse-x6
  rec=$(make_env_case env-invalid-refuse "$id")
  read_env_case "$rec"
  # A wildcard would be a blanket passthrough wearing an allowlist's clothes.
  printf 'FM_TEST_*\n' > "$HOME_DIR/config/spawn-env-allow"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "a wildcard allow entry should refuse the spawn"
  assert_contains "$out" "not a valid environment variable name" \
    "the refusal did not explain the invalid entry"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "the spawn was refused but still wrote task metadata"
  pass "a wildcard config/spawn-env-allow entry refuses the spawn instead of widening the boundary"
}

test_allow_entry_holding_two_names_refuses_spawn() {
  local rec id out status
  id=env-two-names-refuse-x7
  rec=$(make_env_case env-two-names-refuse "$id")
  read_env_case "$rec"
  # Two names on one line used to be concatenated into one valid-looking name, so
  # the spawn succeeded and neither name ever reached the worker.
  printf 'FM_TEST_ONE FM_TEST_TWO\n' > "$HOME_DIR/config/spawn-env-allow"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "an allow entry holding two names should refuse the spawn"
  assert_contains "$out" "not a valid environment variable name" \
    "the refusal did not explain the invalid entry"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "the spawn was refused but still wrote task metadata"
  pass "an allow-file line holding two names refuses the spawn instead of silently allowing neither"
}

test_raw_launch_with_shell_operator_refuses_spawn() {
  local rec id out status
  id=env-raw-operator-x8
  rec=$(make_env_case env-raw-operator "$id")
  read_env_case "$rec"
  # The pane shell would split on '&&' and run the tail outside the wrapper, with
  # the pane's full environment.
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" 'claude --flag && echo done')
  status=$?
  expect_code 1 "$status" "a raw launch command with a shell operator should refuse the spawn"
  assert_contains "$out" "&&" "the refusal did not name the rejected operator"
  assert_contains "$out" "argv-style" "the refusal did not say what to pass instead"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "the spawn was refused but still wrote task metadata"
  pass "a raw launch command carrying a shell operator refuses the spawn before anything is created"
}

test_raw_launch_allows_command_substitution() {
  local rec id out status launch
  id=env-raw-cmdsub-x10
  rec=$(make_env_case env-raw-cmdsub "$id")
  read_env_case "$rec"

  # The escape hatch exists to trial a new adapter against the same shape the
  # generated templates use, and those carry "$(cat <brief>)". The pane shell
  # evaluates the substitution and only its output becomes an argument, so it is
  # not a boundary escape and must not be refused.
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    "claude --prompt \"\$(cat '$HOME_DIR/data/$id/brief.md')\"")
  status=$?
  expect_code 0 "$status" "a raw launch command using command substitution should spawn"
  launch=$(cat "$LAUNCH_LOG")
  run_captured_launch "$launch" "$FAKEBIN_DIR"
  assert_present "$AGENT_ENV" "the command-substitution raw launch did not start the agent"
  assert_no_grep 'FM_TEST_UNEXPECTED_SECRET' "$AGENT_ENV" \
    "the command-substitution raw launch escaped the clean-environment boundary"
  pass "a raw launch command using command substitution is accepted and stays inside the boundary"
}

test_raw_launch_argv_still_works() {
  local rec id launch
  id=env-raw-argv-x9
  rec=$(make_env_case env-raw-argv "$id")
  read_env_case "$rec"

  run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" 'claude --always-approve' >/dev/null 2>&1
  launch=$(cat "$LAUNCH_LOG")
  run_captured_launch "$launch" "$FAKEBIN_DIR"
  assert_present "$AGENT_ENV" "an argv-style raw launch command did not start the agent"
  assert_no_grep 'FM_TEST_UNEXPECTED_SECRET' "$AGENT_ENV" \
    "an argv-style raw launch command escaped the clean-environment boundary"
  pass "an argv-style raw launch command still launches, inside the boundary"
}

# --- invariants on the built-in list ----------------------------------------

test_builtin_allowlist_holds_no_credential_shaped_name() {
  local offenders
  offenders=$("$ENV_CLEAN" --print-allowed \
    | grep -Ei 'KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|AUTH|PRIVATE|COOKIE|SIGNING' || true)
  [ -z "$offenders" ] || fail \
    "the built-in allowlist holds a credential-shaped name"$'\n'"$offenders"
  pass "the built-in allowlist holds no credential-shaped name"
}

test_missing_allow_file_is_not_an_error() {
  local out status
  out=$("$ENV_CLEAN" --allow-file "$TMP_ROOT/definitely-absent" --print-allowed) || status=$?
  status=${status:-0}
  expect_code 0 "$status" "an absent allow file is the default state, not an error"
  assert_contains "$out" "PATH" "the built-in allowlist was not printed"
  pass "an absent config/spawn-env-allow is the default state, not an error"
}

run_case test_launch_drops_unexpected_launching_env
run_case test_launch_keeps_what_the_worker_needs
run_case test_unset_allowed_name_stays_unset
run_case test_allow_file_widens_by_exact_name
run_case test_injection_seam_reaches_the_agent
run_case test_project_env_reaches_the_agent
run_case test_project_env_ignores_other_projects
run_case test_project_env_skipped_for_secondmate
run_case test_project_env_invalid_name_refuses_spawn
run_case test_project_env_non_assignment_refuses_spawn
run_case test_project_env_other_project_malformed_line_still_spawns
run_case test_project_env_line_with_no_entries_spawns_cleanly
run_case test_project_env_value_holding_a_glob_is_not_expanded
run_case test_credential_shaped_allow_entry_refuses_spawn
run_case test_invalid_allow_entry_refuses_spawn
run_case test_allow_entry_holding_two_names_refuses_spawn
run_case test_raw_launch_with_shell_operator_refuses_spawn
run_case test_raw_launch_allows_command_substitution
run_case test_raw_launch_argv_still_works
run_case test_builtin_allowlist_holds_no_credential_shaped_name
run_case test_missing_allow_file_is_not_an_error
fm_case_summary "fm-spawn-env-allowlist"
