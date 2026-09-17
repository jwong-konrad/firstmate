#!/usr/bin/env bash
# Tests for bin/fm-upstream-gate.sh: the CI gate at the fork-ingestion boundary.
#
# Upstream is pull-only and unvetted, so the gate's whole job is to refuse a
# range that carries upstream commits the .upstream-pin vetting does not reach.
# Every case runs the real script against a real pair of git repositories - a
# fixture upstream and a fixture fork that genuinely merges from it - because a
# mocked git would prove nothing about the ancestry maths the gate relies on.
#
# Matrix:
#   (a) a clean push that ingests nothing passes
#   (b) an upstream merge with the pin left alone is REFUSED
#   (c) the same merge with the pin advanced to the merged commit passes
#   (d) a merge whose pin advance covers only part of the range is REFUSED
#   (e) a pin advanced to upstream work not yet ingested is REFUSED
#   (e2) a fork commit in `sha` is REFUSED, because it vets no upstream history
#   (e3) review_head records the fork side without changing any decision
#   (f) deleting .upstream-pin is REFUSED
#   (g) a malformed pin is REFUSED
#   (h) a pin that drops upstream coverage it used to have is REFUSED
#   (i) an unreachable upstream cannot be determined, and does not pass
#   (j) the real repo's own pin and branch pass the gate
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

GATE="$ROOT/bin/fm-upstream-gate.sh"
TMP_ROOT=$(fm_test_tmproot fm-upstream-gate-tests)

commit_file() {
  local repo=$1 name=$2 msg=$3
  printf '%s\n' "$msg" > "$repo/$name"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "$msg"
}

write_pin() {
  local fork=$1 url=$2 branch=$3 sha=$4
  cat > "$FORK/.upstream-pin" <<EOF
url=$url
branch=$branch
sha=$sha
EOF
}

# make_case <name>: build a fixture upstream with four commits and a fork that
# ingested the first two, then diverged. Sets the case globals rather than
# echoing, because run_case already gives every case its own subshell and a
# command substitution here would throw the commit ids away.
#   $FORK    the fork repo, the one the gate is run against
#   $UP_URL  the fork's pin URL for that fixture upstream
#   $U2..$U4 upstream commit ids; U2 is ingested, U3 and U4 are not
#   $BASE    the fork commit every case ranges from
make_case() {
  local name=$1 dir up
  dir="$TMP_ROOT/$name"
  up="$dir/upstream"
  FORK="$dir/fork"
  mkdir -p "$up"

  git -c init.defaultBranch=main init -q "$up"
  commit_file "$up" u1 "upstream one"
  commit_file "$up" u2 "upstream two"
  U2=$(git -C "$up" rev-parse HEAD)
  commit_file "$up" u3 "upstream three"
  U3=$(git -C "$up" rev-parse HEAD)
  commit_file "$up" u4 "upstream four"
  U4=$(git -C "$up" rev-parse HEAD)

  # The fork ingested upstream through u2 and then went its own way, so u2 is
  # both an upstream commit and already in the fork - exactly the shape a real
  # vetting pin has.
  git clone --quiet "$up" "$FORK"
  git -C "$FORK" checkout -q -B main "$U2"
  UP_URL="file://$(cd "$up" && pwd)"
  write_pin "$FORK" "$UP_URL" main "$U2"
  git -C "$FORK" add -A
  git -C "$FORK" commit -qm "pin upstream vetting at u2"
  commit_file "$FORK" f1 "fork one"
  BASE=$(git -C "$FORK" rev-parse HEAD)
}

# merge_upstream <fork> <upstream-commit>: bring that upstream commit into the
# fork the way a real ingestion would, as a merge commit.
merge_upstream() {
  local fork=$1 want=$2
  git -C "$fork" fetch --quiet "$UP_URL" main
  git -C "$fork" merge --quiet --no-ff -m "merge upstream" "$want"
}

run_gate() {
  "$GATE" --repo "$1" --base "$2" --head "$3" "${@:4}"
}

test_clean_push_passes() {
  local out rc=0
  make_case clean-push
  commit_file "$FORK" f2 "fork two"

  out=$(run_gate "$FORK" "$BASE" HEAD 2>&1) || rc=$?
  expect_code 0 "$rc" "a push with no upstream commits must pass"
  assert_contains "$out" "none from upstream main" "clean push should say nothing came from upstream"
  pass "a clean push that ingests no upstream commits passes the gate"
}

test_upstream_merge_without_pin_advance_is_refused() {
  local out rc=0
  make_case merge-no-advance
  merge_upstream "$FORK" "$U4"

  out=$(run_gate "$FORK" "$BASE" HEAD 2>&1) || rc=$?
  expect_code 1 "$rc" "an upstream merge with a standing pin must be refused"
  assert_contains "$out" "REFUSED" "refusal must be explicit"
  assert_contains "$out" "enter the fork" "refusal must name the ingestion"
  assert_contains "$out" ".upstream-pin" "refusal must name the file to advance"
  pass "an upstream merge that does not advance the pin is refused"
}

test_upstream_merge_with_pin_advance_passes() {
  local out rc=0
  make_case merge-with-advance
  merge_upstream "$FORK" "$U4"
  write_pin "$FORK" "$UP_URL" main "$U4"
  git -C "$FORK" add -A
  git -C "$FORK" commit -qm "advance the vetting pin to u4"

  out=$(run_gate "$FORK" "$BASE" HEAD 2>&1) || rc=$?
  expect_code 0 "$rc" "a reviewed ingestion must pass: $out"
  assert_contains "$out" "covered by the pin" "pass message should say the range is covered"
  pass "an upstream merge whose pin advance covers the range passes"
}

test_partial_pin_advance_is_refused() {
  local out rc=0
  make_case partial-advance
  merge_upstream "$FORK" "$U4"
  # Reviewed only as far as u3 while the merge actually brought u4 in.
  write_pin "$FORK" "$UP_URL" main "$U3"
  git -C "$FORK" add -A
  git -C "$FORK" commit -qm "advance the vetting pin to u3"

  out=$(run_gate "$FORK" "$BASE" HEAD 2>&1) || rc=$?
  expect_code 1 "$rc" "an ingestion reaching past the pin must be refused"
  assert_contains "$out" "reach past the pin" "refusal must say the range outruns the pin"
  pass "an ingestion that reaches past the advanced pin is refused"
}

test_pin_cannot_vouch_for_uningested_upstream() {
  local out rc=0
  make_case preauthorize
  # No merge at all - just a pin jumped forward to upstream work that is not in
  # this branch. Allowing it would pre-clear the next range's ingestion.
  write_pin "$FORK" "$UP_URL" main "$U4"
  git -C "$FORK" add -A
  git -C "$FORK" commit -qm "jump the vetting pin ahead of any ingestion"

  out=$(run_gate "$FORK" "$BASE" HEAD 2>&1) || rc=$?
  expect_code 1 "$rc" "a pin ahead of ingestion must be refused"
  assert_contains "$out" "not reachable from" "refusal must say the pin is not in this branch"
  pass "a pin advanced ahead of any ingestion is refused"
}

# The mistake this rule exists for: a fork commit looks like a perfectly good
# commit id, sits in the right file, and vets nothing at all upstream.
test_fork_commit_as_sha_is_refused() {
  local out rc=0 fork_commit
  make_case fork-commit-sha
  fork_commit=$(git -C "$FORK" rev-parse HEAD)
  write_pin "$FORK" "$UP_URL" main "$fork_commit"
  git -C "$FORK" add -A
  git -C "$FORK" commit -qm "point the vetting pin at a fork commit"

  out=$(run_gate "$FORK" "$BASE" HEAD 2>&1) || rc=$?
  expect_code 1 "$rc" "a fork commit in sha must be refused"
  assert_contains "$out" "is not on the upstream main branch" "refusal must say the pin is not upstream"
  assert_contains "$out" "review_head" "refusal should point at the field that does take a fork commit"
  pass "a fork commit in 'sha' is refused because it vets no upstream history"
}

test_review_head_is_recorded_without_deciding_anything() {
  local out rc=0 fork_commit
  make_case review-head
  fork_commit=$(git -C "$FORK" rev-parse HEAD)
  # An upstream sha plus the fork commit the review ended at: the shipped shape.
  cat > "$FORK/.upstream-pin" <<EOF
url=$UP_URL
branch=main
sha=$U2
review_head=$fork_commit
EOF
  git -C "$FORK" add -A
  git -C "$FORK" commit -qm "record the fork commit the review ended at"

  out=$(run_gate "$FORK" "$BASE" HEAD 2>&1) || rc=$?
  expect_code 0 "$rc" "a recorded review_head must not change the verdict: $out"

  # And it is still validated: a review_head that is not on this branch is a
  # broken record, so it is refused rather than ignored.
  write_pin "$FORK" "$UP_URL" main "$U2"
  printf 'review_head=%s\n' "$U4" >> "$FORK/.upstream-pin"
  git -C "$FORK" add -A
  git -C "$FORK" commit -qm "record a review_head that never happened here"
  rc=0
  out=$(run_gate "$FORK" "$BASE" HEAD 2>&1) || rc=$?
  expect_code 1 "$rc" "a review_head off this branch must be refused"
  assert_contains "$out" "review_head" "refusal must name review_head"
  pass "review_head is validated as an audit record and decides nothing"
}

test_deleting_the_pin_is_refused() {
  local out rc=0
  make_case deleted-pin
  git -C "$FORK" rm -q .upstream-pin
  git -C "$FORK" commit -qm "remove the vetting pin"

  out=$(run_gate "$FORK" "$BASE" HEAD 2>&1) || rc=$?
  expect_code 1 "$rc" "removing the pin must be refused"
  assert_contains "$out" "must not be deleted" "refusal must say the pin cannot be removed"
  pass "deleting .upstream-pin is refused"
}

test_malformed_pin_is_refused() {
  local out rc=0
  make_case malformed-pin
  printf 'url=%s\nbranch=main\nsha=nonsense\n' "$UP_URL" > "$FORK/.upstream-pin"
  git -C "$FORK" add -A
  git -C "$FORK" commit -qm "corrupt the vetting pin"

  out=$(run_gate "$FORK" "$BASE" HEAD 2>&1) || rc=$?
  expect_code 1 "$rc" "a malformed pin must be refused, never defaulted"
  assert_contains "$out" "invalid .upstream-pin" "refusal must name the invalid pin"
  pass "a malformed pin is refused rather than treated as permissive"
}

test_pin_coverage_regression_is_refused() {
  local out rc=0 base_after_ingest
  make_case coverage-regression
  merge_upstream "$FORK" "$U4"
  write_pin "$FORK" "$UP_URL" main "$U4"
  git -C "$FORK" add -A
  git -C "$FORK" commit -qm "advance the vetting pin to u4"
  base_after_ingest=$(git -C "$FORK" rev-parse HEAD)
  # Now walk the pin back to u2, dropping the review record for u3 and u4.
  write_pin "$FORK" "$UP_URL" main "$U2"
  git -C "$FORK" add -A
  git -C "$FORK" commit -qm "walk the vetting pin back to u2"

  out=$(run_gate "$FORK" "$base_after_ingest" HEAD 2>&1) || rc=$?
  expect_code 1 "$rc" "a pin that drops coverage must be refused"
  assert_contains "$out" "drops" "refusal must say coverage was dropped"
  pass "a pin that drops upstream coverage it already had is refused"
}

test_unreachable_upstream_cannot_be_determined() {
  local out rc=0
  make_case unreachable-upstream
  commit_file "$FORK" f2 "fork two"
  rm -rf "$TMP_ROOT/unreachable-upstream/upstream"

  out=$(run_gate "$FORK" "$BASE" HEAD 2>&1) || rc=$?
  expect_code 2 "$rc" "an unreachable upstream must not report a pass"
  assert_contains "$out" "cannot determine" "must say the range could not be proved clean"
  assert_not_contains "$out" "ok - " "must never print a pass line when upstream is unreadable"
  pass "an unreachable upstream fails closed instead of passing"
}

# The fixtures prove the rules; this proves the rules hold for the shipped pin
# and the branch this suite is running on, so a bad real pin cannot pass CI here
# and only be caught on the push to main.
test_real_repo_pin_passes_its_own_gate() {
  local out rc=0 base
  base=$(git -C "$ROOT" rev-parse --verify --quiet main) \
    || { pass "skip: no local main to range against"; return 0; }
  git -C "$ROOT" rev-parse --verify --quiet refs/fm-upstream/main >/dev/null \
    || { pass "skip: no upstream ref fetched in this checkout"; return 0; }

  out=$("$GATE" --repo "$ROOT" --base "$base" --head HEAD --no-fetch 2>&1) || rc=$?
  expect_code 0 "$rc" "this repo's own branch must pass its own gate: $out"
  pass "the real repo's pin and current branch pass the gate"
}

run_case test_clean_push_passes
run_case test_upstream_merge_without_pin_advance_is_refused
run_case test_upstream_merge_with_pin_advance_passes
run_case test_partial_pin_advance_is_refused
run_case test_pin_cannot_vouch_for_uningested_upstream
run_case test_fork_commit_as_sha_is_refused
run_case test_review_head_is_recorded_without_deciding_anything
run_case test_deleting_the_pin_is_refused
run_case test_malformed_pin_is_refused
run_case test_pin_coverage_regression_is_refused
run_case test_unreachable_upstream_cannot_be_determined
run_case test_real_repo_pin_passes_its_own_gate
fm_case_summary "fm-upstream-gate"
