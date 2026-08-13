#!/usr/bin/env bash
# Bare-shell endpoints are a distinct liveness state, and a steer never lands in
# one silently.
#
# Incident being pinned (2026-08-13, task restore-reverted-learnings-r9): the
# task's agent had exited some time earlier, leaving a bare zsh prompt sitting in
# its worktree. Every liveness read firstmate had reported that pane as alive,
# because they all asked only whether the PANE existed. A steer was sent, exited
# 0 with no warning, and the text landed in the shell, which answered
# `zsh: parse error near 'do'`. The instruction was lost and firstmate had no
# idea; only a human peeking at the pane caught it.
#
# Two separate defects made that possible, and both are covered here:
#   1. Classification conflated "no agent, bare shell" with "endpoint gone" (and
#      presence-only callers saw neither), so nothing could name the state that
#      actually mattered. fm_backend_agent_liveness now reports it as `shell`.
#   2. fm-send treated an INCONCLUSIVE submit verdict as success. herdr reports
#      `unknown` for a bare-shell pane, and fm-send fell straight through to
#      exit 0 on it.
#
# The tests below assert both directions of each defect: a bare shell must be
# classified as no-agent AND refused, while a healthy agent and a merely
# inconclusive read must keep working exactly as before - an over-eager refusal
# would break every legitimate steer, including the trust-dialog keys sent
# moments after a spawn.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-liveness)

# A fake tmux whose pane_current_command is caller-controlled via
# FM_FAKE_PANE_COMMAND, which is the whole liveness signal for the tmux adapter.
# Every send command is logged so a test can prove nothing was typed.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0; target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    printf 'send-keys target=%s literal=%s arg=%s\n' "$target" "$literal" "${1:-}" >> "$FM_TMUX_LOG"
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_current_command*)
          # An empty setting models "tmux reports no command", which the adapter
          # then disambiguates with a pane_id existence probe.
          printf '%s\n' "${FM_FAKE_PANE_COMMAND-}"; exit 0 ;;
        *cursor_y*) printf '0\n'; exit 0 ;;
      esac
    done
    if [ -n "${FM_FAKE_TMUX_DEAD_TARGET:-}" ]; then printf '%%1\n'; exit 1; fi
    printf '%%1\n'; exit 0 ;;
  capture-pane)
    printf '\xe2\x94\x82 \xe2\x94\x82\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  # Keep the grace re-probe instant instead of really sleeping 1.5s.
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# run_send: <dir> <pane-command> <err-file> <log-file> -- <send args...>
# Echoes the exit code; the caller inspects the log and stderr.
run_send() {
  local dir=$1 comm=$2 err=$3 log=$4; shift 4
  [ "${1:-}" = -- ] && shift
  local fb home rc
  fb="$dir/fakebin"; home="$dir/home"
  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_FAKE_PANE_COMMAND="$comm" \
    "$SEND" "$@" >/dev/null 2>"$err"
  rc=$?
  printf '%s' "$rc"
}

setup_case() {  # <name> -> echoes dir (with fakebin + home + one task meta)
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state"
  make_stubs "$dir" >/dev/null
  fm_write_meta "$dir/home/state/liveness-t1.meta" "window=sess:fm-liveness-t1" "kind=ship"
  printf '%s\n' "$dir"
}

# --- defect 1: classification names the bare shell -------------------------

test_bare_shell_is_classified_as_dead_agent_not_alive() {
  local fb out
  fb="$TMP_ROOT/classify/fakebin"; mkdir -p "$TMP_ROOT/classify"; make_stubs "$TMP_ROOT/classify" >/dev/null

  # THE regression: a pane sitting at a bare shell. The pane EXISTS, so every
  # presence-only check calls it alive; liveness must call it a dead agent.
  for shell_name in zsh bash sh fish; do
    out=$(PATH="$fb:$PATH" FM_FAKE_PANE_COMMAND="$shell_name" bash -c \
      '. "$0/bin/fm-backend.sh"; fm_backend_agent_liveness tmux sess:win' "$ROOT")
    [ "$out" = shell ] \
      || fail "a pane at a bare '$shell_name' prompt must classify as 'shell', got '$out'"

    out=$(PATH="$fb:$PATH" FM_FAKE_PANE_COMMAND="$shell_name" bash -c \
      '. "$0/bin/fm-backend.sh"; fm_backend_agent_liveness tmux sess:win' "$ROOT")
    [ "$out" != alive ] \
      || fail "a bare '$shell_name' prompt must never classify as alive"

    # And the coarse projection every existing caller uses must still say dead.
    out=$(PATH="$fb:$PATH" FM_FAKE_PANE_COMMAND="$shell_name" bash -c \
      '. "$0/bin/fm-backend.sh"; fm_backend_agent_alive tmux sess:win' "$ROOT")
    [ "$out" = dead ] \
      || fail "fm_backend_agent_alive must still project a bare '$shell_name' to dead, got '$out'"
  done

  # A real agent stays alive - the refusal must not be indiscriminate.
  out=$(PATH="$fb:$PATH" FM_FAKE_PANE_COMMAND=claude bash -c \
    '. "$0/bin/fm-backend.sh"; fm_backend_agent_liveness tmux sess:win' "$ROOT")
  [ "$out" = alive ] || fail "a live claude agent must classify as alive, got '$out'"

  # An unattributable command stays inconclusive, never optimistically alive.
  out=$(PATH="$fb:$PATH" FM_FAKE_PANE_COMMAND=node bash -c \
    '. "$0/bin/fm-backend.sh"; fm_backend_agent_liveness tmux sess:win' "$ROOT")
  [ "$out" = unknown ] || fail "an unattributable 'node' command must be unknown, got '$out'"

  pass "liveness: a bare-shell pane classifies as a dead agent (shell), never alive"
}

test_gone_endpoint_is_distinct_from_bare_shell() {
  local fb out
  fb="$TMP_ROOT/gone/fakebin"; mkdir -p "$TMP_ROOT/gone"; make_stubs "$TMP_ROOT/gone" >/dev/null

  # No command AND no pane: the endpoint itself is gone. Distinguishing this
  # from `shell` is the point of the three-way split - a gone endpoint needs a
  # respawn, a bare shell needs a relaunch in a pane that already exists.
  out=$(PATH="$fb:$PATH" FM_FAKE_PANE_COMMAND='' FM_FAKE_TMUX_DEAD_TARGET=sess:win bash -c \
    '. "$0/bin/fm-backend.sh"; fm_backend_agent_liveness tmux sess:win' "$ROOT")
  [ "$out" = no-endpoint ] || fail "a gone pane must classify as no-endpoint, got '$out'"

  # No command but the pane IS there: inconclusive, not a confirmed shell.
  out=$(PATH="$fb:$PATH" FM_FAKE_PANE_COMMAND='' bash -c \
    '. "$0/bin/fm-backend.sh"; fm_backend_agent_liveness tmux sess:win' "$ROOT")
  [ "$out" = unknown ] \
    || fail "an existing pane with no reported command must be unknown, got '$out'"

  pass "liveness: a gone endpoint is reported apart from a bare shell, and neither is guessed"
}

test_herdr_maps_no_agent_to_shell_and_gone_pane_to_no_endpoint() {
  local out
  # herdr already distinguished these internally; the regression was collapsing
  # them. `no-agent` is exactly the shape an exited agent leaves behind.
  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state() { printf "no-agent"; }; fm_backend_herdr_agent_liveness "sess:p1"' "$ROOT")
  [ "$out" = shell ] || fail "herdr no-agent must map to shell, got '$out'"

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state() { printf "dead"; }; fm_backend_herdr_agent_liveness "sess:p1"' "$ROOT")
  [ "$out" = no-endpoint ] || fail "herdr pane_not_found must map to no-endpoint, got '$out'"

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state() { printf "live"; }; fm_backend_herdr_agent_liveness "sess:p1"' "$ROOT")
  [ "$out" = alive ] || fail "herdr live must map to alive, got '$out'"

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state() { printf "unknown"; }; fm_backend_herdr_agent_liveness "sess:p1"' "$ROOT")
  [ "$out" = unknown ] || fail "herdr unknown must stay unknown, got '$out'"

  # The coarse projection existing callers gate on must be unchanged.
  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state() { printf "no-agent"; }; fm_backend_herdr_agent_alive "sess:p1"' "$ROOT")
  [ "$out" = dead ] || fail "herdr agent_alive must still project no-agent to dead, got '$out'"

  pass "liveness: herdr reports no-agent as a bare shell and a gone pane separately"
}

test_pane_agent_state_survives_a_zsh_shell() {
  local out
  # The probe emitted a bare `unknown` for a genuinely LIVE task while the
  # incident was being diagnosed by hand. Cause: zsh makes `$status` read-only,
  # so `local status` aborted the declaration and the classifier collapsed to
  # unknown whenever it was sourced into an interactive zsh. Production runs
  # these under a bash shebang, but hand diagnosis is exactly when a misleading
  # verdict costs the most, so pin the function against a zsh source too.
  command -v zsh >/dev/null 2>&1 || { pass "liveness: zsh source check skipped (no zsh)"; return 0; }

  out=$(zsh -c '
    fm_backend_herdr_cli() { printf "%s" "{\"result\":{\"pane\":{\"pane_id\":\"w1:p1\"},\"agent\":{\"agent_status\":\"working\"}}}"; }
    . "$1/bin/backends/herdr.sh" 2>/dev/null
    fm_backend_herdr_cli() { printf "%s" "{\"result\":{\"pane\":{\"pane_id\":\"w1:p1\"},\"agent\":{\"agent_status\":\"working\"}}}"; }
    fm_backend_herdr_pane_agent_state default w1:p1
  ' zsh "$ROOT" 2>/dev/null)
  [ "$out" = live ] \
    || fail "sourced into zsh, a live agent must still classify as live, got '$out' (is a local named 'status' back?)"

  pass "liveness: the herdr classifier does not degrade to unknown when sourced into zsh"
}

# --- defect 2: fm-send refuses instead of silently succeeding --------------

test_send_refuses_a_bare_shell_and_types_nothing() {
  local dir err log rc got
  dir=$(setup_case send-shell); err="$dir/send.err"; log="$dir/tmux.log"

  rc=$(run_send "$dir" zsh "$err" "$log" -- liveness-t1 "for i in 1 2 3; do echo hi; done")

  # THE regression: this exited 0 and the text was executed by zsh.
  [ "$rc" -ne 0 ] \
    || fail "sending into a bare shell must NOT exit 0 (this is the 2026-08-13 silent loss)"

  got=$(cat "$log")
  case "$got" in
    *send-keys*) fail "nothing may be typed into a bare shell, but send-keys ran: $got" ;;
  esac

  assert_contains "$(cat "$err")" "refusing to send" "the refusal must say it refused"
  assert_contains "$(cat "$err")" "bare shell" "the refusal must name the bare shell"
  assert_contains "$(cat "$err")" "Nothing was typed" "the refusal must say nothing was typed"

  pass "fm-send: refuses a bare-shell endpoint loudly and types nothing into it"
}

test_send_refuses_a_gone_endpoint_without_typing() {
  local dir err log rc got
  dir=$(setup_case send-gone); err="$dir/send.err"; log="$dir/tmux.log"

  rc=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/home" \
    FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
    FM_FAKE_PANE_COMMAND='' FM_FAKE_TMUX_DEAD_TARGET=sess:fm-liveness-t1 \
    bash -c ': > "$FM_TMUX_LOG"; "$0" liveness-t1 "a steer" >/dev/null 2>"$1"; printf "%s" "$?"' \
    "$SEND" "$err")

  [ "$rc" -ne 0 ] || fail "sending to a gone endpoint must not exit 0"
  got=$(cat "$log")
  case "$got" in
    *send-keys*) fail "nothing may be typed to a gone endpoint, but send-keys ran: $got" ;;
  esac
  assert_contains "$(cat "$err")" "endpoint gone" "the refusal must name the gone endpoint"

  pass "fm-send: refuses a gone endpoint without typing"
}

test_send_to_a_live_agent_is_unchanged() {
  local dir err log rc got
  dir=$(setup_case send-live); err="$dir/send.err"; log="$dir/tmux.log"

  rc=$(run_send "$dir" claude "$err" "$log" -- liveness-t1 "carry on")

  expect_code 0 "$rc" "a send to a live agent must still succeed"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:fm-liveness-t1 literal=1 arg=carry on" \
    "a live agent must still receive the literal text"
  assert_contains "$got" "target=sess:fm-liveness-t1 literal=0 arg=Enter" \
    "a live agent must still get its Enter"

  pass "fm-send: a live agent still receives its steer unchanged"
}

test_send_on_an_inconclusive_read_still_delivers() {
  local dir err log rc got
  dir=$(setup_case send-unknown); err="$dir/send.err"; log="$dir/tmux.log"

  # An inconclusive verdict must not block a send that would otherwise work.
  # zellij/orca/cmux have no verified classifier and ALWAYS read inconclusive,
  # so refusing here would break steering on those backends outright.
  rc=$(run_send "$dir" node "$err" "$log" -- liveness-t1 "carry on")

  expect_code 0 "$rc" "an inconclusive liveness read must not block a send"
  assert_contains "$(cat "$log")" "literal=1 arg=carry on" \
    "an inconclusive read must still type the text"

  pass "fm-send: an inconclusive liveness read still delivers (no over-eager refusal)"
}

test_key_path_is_never_gated_on_agent_liveness() {
  local dir err log rc
  dir=$(setup_case send-key); err="$dir/send.err"; log="$dir/tmux.log"

  # --key must stay ungated: it is how a harness trust dialog is accepted
  # moments after a spawn, before the backend has detected the new agent, and a
  # bare key is a harmless no-op at a shell prompt anyway. Gating it would
  # refuse a legitimate key during normal startup.
  rc=$(run_send "$dir" zsh "$err" "$log" -- liveness-t1 --key Enter)

  expect_code 0 "$rc" "the --key path must not be refused on agent liveness"
  assert_contains "$(cat "$log")" "arg=Enter" "the key must still be sent"

  pass "fm-send: the --key path stays ungated so trust dialogs still work"
}

test_bare_shell_refusal_precedes_any_pending_reply_record() {
  local dir err log rc
  dir="$TMP_ROOT/send-secondmate"
  mkdir -p "$dir/home/state"
  make_stubs "$dir" >/dev/null
  fm_write_meta "$dir/home/state/liveness-s1.meta" "window=sess:fm-liveness-s1" "kind=secondmate"

  err="$dir/send.err"; log="$dir/tmux.log"
  rc=$(run_send "$dir" zsh "$err" "$log" -- liveness-s1 "please report")

  [ "$rc" -ne 0 ] || fail "a marked secondmate request into a bare shell must not exit 0"
  # A refusal must leave nothing to reconcile: no durable expectation was ever
  # created, because the preflight runs before the pending-reply record.
  if [ -d "$dir/home/state/pending-replies" ]; then
    if find "$dir/home/state/pending-replies" -type f -print -quit 2>/dev/null | grep -q .; then
      fail "a refused send must not leave a pending-reply record behind"
    fi
  fi

  pass "fm-send: refusing a bare shell leaves no pending-reply record to reconcile"
}

test_bare_shell_is_classified_as_dead_agent_not_alive
test_gone_endpoint_is_distinct_from_bare_shell
test_herdr_maps_no_agent_to_shell_and_gone_pane_to_no_endpoint
test_pane_agent_state_survives_a_zsh_shell
test_send_refuses_a_bare_shell_and_types_nothing
test_send_refuses_a_gone_endpoint_without_typing
test_send_to_a_live_agent_is_unchanged
test_send_on_an_inconclusive_read_still_delivers
test_key_path_is_never_gated_on_agent_liveness
test_bare_shell_refusal_precedes_any_pending_reply_record

echo "# all fm-send-liveness tests passed"
