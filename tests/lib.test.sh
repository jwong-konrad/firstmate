#!/usr/bin/env bash
# tests/lib.test.sh - contract tests for tests/lib.sh's per-case subshell
# dispatch (run_case / fm_case_summary).
#
# fail() exits the current shell. Before run_case existed, a suite that
# invoked its test_* case functions directly at the bottom of the file
# aborted at the first failing case and never ran the ones after it, so a red
# suite under-reported how much of it actually failed. These tests build a
# throwaway fixture suite (real bash, real subprocess) that mirrors that
# shape - some passing cases, one failing case in the middle, more passing
# cases after it - and prove run_case/fm_case_summary fixes it: every case
# still runs, and the fixture's own exit status is proven non-zero rather than
# merely asserted.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lib-dispatch)

# write_fixture <dir> <marker-file>: a small suite using this same lib.sh,
# with case_a/case_c/case_e passing (each appending its name to marker-file)
# and case_b/case_d failing (via fail()). Mirrors the real footer shape: bare
# case names dispatched through run_case, then one fm_case_summary call.
write_fixture() {  # <dir> <marker-file>
  local dir=$1 marker=$2
  cat > "$dir/fixture.test.sh" <<EOF
#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

MARKER="$marker"

case_a() { echo case_a >> "\$MARKER"; pass "case_a"; }
case_b() { echo case_b >> "\$MARKER"; fail "case_b deliberately fails"; }
case_c() { echo case_c >> "\$MARKER"; pass "case_c"; }
case_d() { echo case_d >> "\$MARKER"; fail "case_d deliberately fails"; }
case_e() { echo case_e >> "\$MARKER"; pass "case_e"; }

run_case case_a
run_case case_b
run_case case_c
run_case case_d
run_case case_e
fm_case_summary "fixture"
EOF
}

test_all_cases_run_despite_early_failure() {
  local dir marker out rc
  dir="$TMP_ROOT/fixture-early-failure"
  mkdir -p "$dir"
  marker="$dir/ran.log"
  : > "$marker"
  write_fixture "$dir" "$marker"

  out=$(bash "$dir/fixture.test.sh" 2>&1)
  rc=$?

  expect_code 1 "$rc" "a suite with any failing case must exit non-zero overall"

  assert_grep "case_a" "$marker" "case_a should have run"
  assert_grep "case_b" "$marker" "case_b (the first failure) should have run"
  assert_grep "case_c" "$marker" \
    "case_c, AFTER the first failing case, should still have run - this is the defect this harness fixes"
  assert_grep "case_d" "$marker" "case_d (a second failure) should have run"
  assert_grep "case_e" "$marker" \
    "case_e, AFTER a second failing case, should still have run"

  # All five cases actually executed, not just left markers from a stale file.
  [ "$(wc -l < "$marker" | tr -d ' ')" = 5 ] \
    || fail "expected exactly 5 case markers, got: $(cat "$marker")"

  assert_contains "$out" "case_b deliberately fails" \
    "the first failure's own message must still be visible in suite output"
  assert_contains "$out" "case_d deliberately fails" \
    "the second failure's own message must still be visible in suite output"
  assert_contains "$out" "not ok - 2/5 fixture failed: case_b case_d" \
    "the summary must name every failed case, not just the last one"

  pass "run_case dispatches every case in its own subshell: two failures neither abort the suite nor hide each other"
}

test_all_passing_reports_ok_summary() {
  local dir out rc
  dir="$TMP_ROOT/fixture-clean"
  mkdir -p "$dir"
  cat > "$dir/fixture.test.sh" <<EOF
#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
case_a() { pass "case_a"; }
case_b() { pass "case_b"; }
run_case case_a
run_case case_b
fm_case_summary "fixture-clean"
EOF

  out=$(bash "$dir/fixture.test.sh" 2>&1)
  rc=$?

  expect_code 0 "$rc" "a suite with no failing cases must still exit zero"
  assert_contains "$out" "# all 2 fixture-clean cases passed" \
    "an all-passing suite reports how many cases ran"
  # `ok - ` lines are counted as cases by callers (e.g. the stock-Bash job in
  # .github/workflows/ci.yml pins exact per-suite counts), so the summary must
  # not wear that prefix and inflate the count.
  [ "$(printf '%s\n' "$out" | grep -c '^ok - ')" = 2 ] \
    || fail "the summary must not add an 'ok - ' line: $out"
}

test_case_failure_does_not_leak_variables_or_directory_to_next_case() {
  local dir out rc
  dir="$TMP_ROOT/fixture-isolation"
  mkdir -p "$dir"
  # Normalize (e.g. a doubled slash from a trailing-slash TMPDIR) so this
  # literal matches what bash's own $PWD reports after cd, below.
  dir=$(cd "$dir" && pwd)
  cat > "$dir/fixture.test.sh" <<EOF
#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

case_mutates() {
  cd /tmp || exit 1
  LEAKED=yes
  fail "case_mutates deliberately fails after mutating cwd/env"
}

case_checks() {
  [ "\$PWD" = "$dir" ] || fail "cwd leaked across cases: PWD is \$PWD"
  [ -z "\${LEAKED:-}" ] || fail "a variable set in a failed case leaked into a later case"
  pass "case_checks: no leakage from the failed case before it"
}

cd "$dir" || exit 1
run_case case_mutates
run_case case_checks
fm_case_summary "fixture-isolation"
EOF

  out=$(bash "$dir/fixture.test.sh" 2>&1)
  rc=$?

  expect_code 1 "$rc" "the earlier deliberate failure still makes the suite exit non-zero"
  assert_contains "$out" "ok - case_checks: no leakage from the failed case before it" \
    "a later case must not inherit cwd/env mutations a failed case made before calling fail()"
  assert_not_contains "$out" "cwd leaked" "case dispatch must isolate cwd across cases"
  assert_not_contains "$out" "leaked into a later case" "case dispatch must isolate variables across cases"
}

test_errexit_inside_case_body_still_fails_the_case() {
  local dir out rc
  dir="$TMP_ROOT/fixture-errexit-body"
  mkdir -p "$dir"
  cat > "$dir/fixture.test.sh" <<EOF
#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

case_unchecked() { set -e; false; pass "case_unchecked"; }
case_after() { pass "case_after"; }

run_case case_unchecked
run_case case_after
fm_case_summary "fixture-errexit-body"
EOF

  out=$(bash "$dir/fixture.test.sh" 2>&1)
  rc=$?

  expect_code 1 "$rc" \
    "a case whose own set -e should abort it on an unchecked failing command must fail the suite"
  assert_not_contains "$out" "ok - case_unchecked" \
    "the failing case must not run past its unchecked failing command and report ok"
  assert_contains "$out" "ok - case_after" \
    "the case after the errexit failure must still run"
  assert_contains "$out" "not ok - 1/2 fixture-errexit-body failed: case_unchecked" \
    "the errexit-aborted case must be recorded as failed by name"

  pass "run_case preserves errexit set inside a case body: an unchecked failing command fails the case, not silently passes it"
}

test_file_scope_errexit_still_fails_the_case() {
  local dir out rc
  dir="$TMP_ROOT/fixture-errexit-file"
  mkdir -p "$dir"
  cat > "$dir/fixture.test.sh" <<EOF
#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

case_unchecked() { false; pass "case_unchecked"; }
case_after() { pass "case_after"; }

run_case case_unchecked
run_case case_after
fm_case_summary "fixture-errexit-file"
EOF

  out=$(bash "$dir/fixture.test.sh" 2>&1)
  rc=$?

  expect_code 1 "$rc" \
    "a file-scope set -e suite with an unchecked failing command in a case must exit non-zero overall"
  assert_not_contains "$out" "ok - case_unchecked" \
    "the failing case must not run past its unchecked failing command and report ok"
  assert_contains "$out" "ok - case_after" \
    "the suite must continue to its later cases after the errexit failure"
  assert_contains "$out" "not ok - 1/2 fixture-errexit-file failed: case_unchecked" \
    "the errexit-aborted case must be recorded as failed by name"

  pass "run_case propagates file-scope errexit into the case subshell: the failure is recorded and later cases still run"
}

run_case test_all_cases_run_despite_early_failure
run_case test_all_passing_reports_ok_summary
run_case test_case_failure_does_not_leak_variables_or_directory_to_next_case
run_case test_errexit_inside_case_body_still_fails_the_case
run_case test_file_scope_errexit_still_fails_the_case
fm_case_summary "lib"
