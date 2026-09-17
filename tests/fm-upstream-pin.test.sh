#!/usr/bin/env bash
# Tests for bin/fm-upstream-pin.sh: the single owner of the .upstream-pin format,
# the bounded read-only upstream fetch, and the unreviewed-commit count.
#
# The pin is a trust boundary, so the theme of these cases is that a pin which
# cannot be trusted is REFUSED rather than defaulted: every malformed shape has
# to stop the script, because a pin quietly treated as absent is a pin that
# permits everything.
#
# Matrix:
#   (a) a well-formed pin prints each validated field
#   (b) review_head is optional and prints empty when absent
#   (c) a missing file, missing key, repeated key, or unknown key is refused
#   (d) a short/non-hex sha or review_head is refused
#   (e) an odd branch name or unsupported url transport is refused
#   (f) the fetch writes ONLY refs/fm-upstream/<branch> and touches no branch
#   (g) the count is upstream commits the pin does not reach, and 0 when level
#   (h) a count with nothing fetched, and a failing fetch, report undetermined
#   (i) the fetch is bounded by FM_UPSTREAM_FETCH_TIMEOUT
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PIN="$ROOT/bin/fm-upstream-pin.sh"
TMP_ROOT=$(fm_test_tmproot fm-upstream-pin-tests)

commit_file() {
  local repo=$1 name=$2 msg=$3
  printf '%s\n' "$msg" > "$repo/$name"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "$msg"
}

# make_case <name>: a fixture upstream with three commits and a fork holding the
# first. Sets $FORK, $UP_URL, and $U1..$U3.
make_case() {
  local name=$1 dir up
  dir="$TMP_ROOT/$name"
  up="$dir/upstream"
  FORK="$dir/fork"
  mkdir -p "$up"
  git -c init.defaultBranch=main init -q "$up"
  commit_file "$up" u1 "upstream one"
  U1=$(git -C "$up" rev-parse HEAD)
  commit_file "$up" u2 "upstream two"
  U2=$(git -C "$up" rev-parse HEAD)
  commit_file "$up" u3 "upstream three"
  U3=$(git -C "$up" rev-parse HEAD)
  git clone --quiet "$up" "$FORK"
  git -C "$FORK" checkout -q -B main "$U1"
  UP_URL="file://$(cd "$up" && pwd)"
  write_pin "$FORK" "url=$UP_URL" "branch=main" "sha=$U1"
}

write_pin() {
  local fork=$1 line
  shift
  : > "$fork/.upstream-pin"
  for line in "$@"; do
    printf '%s\n' "$line" >> "$fork/.upstream-pin"
  done
}

pin() { "$PIN" --repo "$FORK" "$@"; }

# refuses <label> <expected-exit> <arg>...: the call must fail with that code and
# say something on stderr rather than printing a value.
refuses() {
  local label=$1 want=$2 rc=0 out
  shift 2
  out=$(pin "$@" 2>&1) || rc=$?
  expect_code "$want" "$rc" "$label"
  [ -n "$out" ] || fail "$label: refused silently, with no reason on stderr"
}

test_valid_pin_prints_fields() {
  make_case valid
  write_pin "$FORK" "# a comment" "" "url=$UP_URL" "branch=main" "sha=$U1" "review_head=$U1"
  [ "$(pin --url)" = "$UP_URL" ] || fail "url did not round-trip"
  [ "$(pin --branch)" = "main" ] || fail "branch did not round-trip"
  [ "$(pin --sha)" = "$U1" ] || fail "sha did not round-trip"
  [ "$(pin --review-head)" = "$U1" ] || fail "review_head did not round-trip"
  [ "$(pin --ref)" = "refs/fm-upstream/main" ] || fail "unexpected ref name: $(pin --ref)"
  pass "a well-formed pin prints each validated field, ignoring comments and blanks"
}

test_review_head_is_optional() {
  make_case optional-review-head
  [ "$(pin --review-head)" = "" ] || fail "absent review_head should print empty"
  [ "$(pin --sha)" = "$U1" ] || fail "sha must still read with review_head absent"
  pass "review_head is optional and its absence is not an error"
}

test_unusable_pins_are_refused() {
  make_case refusals

  rm -f "$FORK/.upstream-pin"
  refuses "missing pin file" 1 --sha

  write_pin "$FORK" "url=$UP_URL" "branch=main"
  refuses "missing sha" 1 --sha

  write_pin "$FORK" "url=$UP_URL" "branch=main" "sha=$U1" "sha=$U2"
  refuses "repeated sha" 1 --sha

  write_pin "$FORK" "url=$UP_URL" "branch=main" "sha=$U1" "nonsense=1"
  refuses "unknown key" 1 --sha

  write_pin "$FORK" "url=$UP_URL" "branch=main" "sha=$U1" "bare-line"
  refuses "malformed line" 1 --sha

  pass "a missing, incomplete, repeated, or unknown-key pin is refused"
}

test_malformed_values_are_refused() {
  make_case malformed-values

  write_pin "$FORK" "url=$UP_URL" "branch=main" "sha=${U1:0:7}"
  refuses "abbreviated sha" 1 --sha

  write_pin "$FORK" "url=$UP_URL" "branch=main" "sha=not-a-hex-commit-id-at-all-not-at-all-x"
  refuses "non-hex sha" 1 --sha

  write_pin "$FORK" "url=$UP_URL" "branch=main" "sha=$U1" "review_head=${U1:0:7}"
  refuses "abbreviated review_head" 1 --review-head

  write_pin "$FORK" "url=$UP_URL" "branch=--upload-pack=evil" "sha=$U1"
  refuses "option-shaped branch" 1 --branch

  write_pin "$FORK" "url=$UP_URL" "branch=main with space" "sha=$U1"
  refuses "branch with whitespace" 1 --branch

  write_pin "$FORK" "url=ext::sh -c evil" "branch=main" "sha=$U1"
  refuses "unsupported url transport" 1 --url

  pass "abbreviated ids, option-shaped refs, and unsupported transports are refused"
}

test_fetch_writes_only_the_dedicated_ref() {
  local before after
  make_case fetch-scope
  before=$(git -C "$FORK" for-each-ref --format='%(refname) %(objectname)' | LC_ALL=C sort)

  pin --fetch || fail "fetch from the fixture upstream failed"

  [ "$(git -C "$FORK" rev-parse refs/fm-upstream/main)" = "$U3" ] \
    || fail "the dedicated ref does not point at the upstream head"
  after=$(git -C "$FORK" for-each-ref --format='%(refname) %(objectname)' \
    | grep -v '^refs/fm-upstream/' | LC_ALL=C sort)
  [ "$before" = "$after" ] || {
    printf 'before:\n%s\nafter:\n%s\n' "$before" "$after" >&2
    fail "the fetch moved a ref other than refs/fm-upstream/main"
  }
  [ "$(git -C "$FORK" rev-parse HEAD)" = "$U1" ] || fail "the fetch moved the checkout"
  pass "the fetch writes only refs/fm-upstream/<branch> and moves no branch"
}

test_count_is_what_the_pin_does_not_reach() {
  make_case counting
  pin --fetch || fail "fetch failed"
  [ "$(pin --count)" = "2" ] || fail "expected 2 unreviewed commits, got $(pin --count)"

  # Level with upstream: nothing unreviewed, which is what bootstrap treats as
  # the silent case.
  write_pin "$FORK" "url=$UP_URL" "branch=main" "sha=$U3"
  [ "$(pin --count)" = "0" ] || fail "a pin level with upstream must count 0, got $(pin --count)"
  pass "the count is exactly the upstream commits the pin does not reach"
}

test_undeterminable_states_report_two() {
  make_case undeterminable
  refuses "count with nothing fetched" 2 --count

  write_pin "$FORK" "url=file:///nonexistent-upstream-repo.git" "branch=main" "sha=$U1"
  refuses "fetch from an unreachable upstream" 2 --fetch
  pass "a missing ref and an unreachable upstream report undetermined, not a number"
}

test_fetch_is_bounded_by_its_timeout() {
  local start elapsed rc=0 fakebin
  make_case timeout
  # A git that never returns, so the only way out is the timeout.
  fakebin=$(fm_fakebin "$TMP_ROOT/timeout")
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" fetch "*) sleep 120 ;;
  *) exec /usr/bin/git "$@" ;;
esac
SH
  chmod +x "$fakebin/git"

  start=$SECONDS
  PATH="$fakebin:$PATH" FM_UPSTREAM_FETCH_TIMEOUT=2 pin --fetch >/dev/null 2>&1 || rc=$?
  elapsed=$((SECONDS - start))
  expect_code 2 "$rc" "a hung fetch must report undetermined"
  [ "$elapsed" -lt 30 ] || fail "the fetch ran ${elapsed}s despite a 2s timeout"
  pass "a hung fetch is cut off by FM_UPSTREAM_FETCH_TIMEOUT instead of hanging a session"
}

run_case test_valid_pin_prints_fields
run_case test_review_head_is_optional
run_case test_unusable_pins_are_refused
run_case test_malformed_values_are_refused
run_case test_fetch_writes_only_the_dedicated_ref
run_case test_count_is_what_the_pin_does_not_reach
run_case test_undeterminable_states_report_two
run_case test_fetch_is_bounded_by_its_timeout
fm_case_summary "fm-upstream-pin"
