#!/usr/bin/env bash
# Behavior tests for bin/fm-privacy-scan.sh, the check that keeps captain-private
# details and secret-shaped values out of published text.
#
# This file is itself tracked and scanned, so every fixture value is assembled
# at run time from fragments that do not match on their own. Never write a
# matching value literally here: it would fail the repository's own scan.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCAN="$ROOT/bin/fm-privacy-scan.sh"
TMP_ROOT=$(fm_test_tmproot fm-privacy-scan)
fm_git_identity

# Fixture fragments. Each joined value is fake and exists only in memory.
U="/Us""ers"
H="/ho""me"
TOKEN_TAIL=$(printf '%s' AbCdEfGhIjKlM nOpQrStUvWxYz 0123456789)

# scan_stdin <text> [args...]: run --stdin with no local patterns; sets OUT and RC.
scan_stdin() {
  local text=$1
  shift
  OUT=$(printf '%s\n' "$text" | FM_HOME="$TMP_ROOT/nohome" "$SCAN" --stdin "$@" 2>&1)
  RC=$?
}

test_each_pattern_class_is_found() {
  local name value
  # Quote-split fragments are joined here, outside the heredoc, where the shell
  # removes the quotes; inside a heredoc they would stay literal.
  local tmp="/var/fol""ders/ab/xyz123_abc/T/" linear="lin_""api_$TOKEN_TAIL"
  local ghtok="gh""p_$TOKEN_TAIL" ghpat="github_""pat_$TOKEN_TAIL" sk="sk""-$TOKEN_TAIL"
  local slack="xo""xb-1234567890-abcdef" aws="AK""IAABCDEFGHIJKLMNOP"
  local pem="-----BEGIN OPENSSH PRIV""ATE KEY-----" envdump="SERVICE_API""_KEY=$TOKEN_TAIL"
  while IFS='|' read -r name value; do
    scan_stdin "evidence: $value"
    expect_code 1 "$RC" "$name"
    assert_contains "$OUT" ": $name: " "$name is reported by name"
  done <<EOF
home-path-macos|$U/alice/src
home-path-linux|cd $H/alice/src
macos-temp-path|$tmp
linear-api-key|$linear
github-token|$ghtok
github-pat|$ghpat
sk-api-key|key $sk
slack-token|$slack
aws-access-key-id|$aws
private-key-block|$pem
secret-env-value|$envdump
EOF
  pass "every generic pattern class is reported by its name"
}

test_invalid_byte_does_not_hide_findings() {
  local secret="gh""p_$TOKEN_TAIL"
  OUT=$(printf 'bad byte \377 here\ntoken %s\n' "$secret" | FM_HOME="$TMP_ROOT/nohome" "$SCAN" --stdin 2>&1); RC=$?
  expect_code 1 "$RC" "an invalid byte does not turn the scan into a pass"
  assert_contains "$OUT" "stdin:2: github-token: " "the finding after the invalid byte is still reported"
  pass "a stray invalid byte cannot hide a finding"
}

test_findings_are_masked() {
  local secret="gh""p_$TOKEN_TAIL"
  scan_stdin "token $secret" --label "pull request"
  expect_code 1 "$RC" "a token is a finding"
  assert_contains "$OUT" "pull request:1: github-token: " "the location uses the label and line"
  assert_not_contains "$OUT" "$secret" "the full value is never echoed"
  assert_not_contains "$OUT" "$TOKEN_TAIL" "the value's tail is never echoed"
  assert_contains "$OUT" "*** (" "the masked form shows only a prefix and a length"
  pass "a finding names the pattern and masks the matched value"
}

test_clean_and_placeholder_input_passes() {
  scan_stdin "Ran the suite under <live-home>; \$TMP$H/state and $U/<name> are placeholders.
GITHUB_TOKEN=\${{ secrets.GITHUB_TOKEN }} and FM_TOKEN=\"\$VALUE\" are references.
Sample paths $U/me/x and $H/runner/work are generic."
  expect_code 0 "$RC" "clean input"
  [ -z "$OUT" ] || fail "clean input printed: $OUT"
  pass "clean prose, placeholders, references, and generic sample users pass silently"
}

# make_repo <dir>: a git repo with one clean commit.
make_repo() {
  fm_git_init_commit "$1" >/dev/null
}

test_tracked_scan_and_allowlist() {
  local repo="$TMP_ROOT/tracked"
  make_repo "$repo"
  mkdir -p "$repo/tests" "$repo/docs"
  printf 'cwd=%s/alice/fixture\n' "$U" > "$repo/tests/fixture.test.sh"
  printf 'see %s/bob/notes\n' "$U" > "$repo/docs/guide.md"
  git -C "$repo" add -A
  git -C "$repo" commit -qm fixtures

  OUT=$(cd "$repo" && FM_HOME="$TMP_ROOT/nohome" "$SCAN" --tracked 2>&1); RC=$?
  expect_code 1 "$RC" "tracked scan before allowlisting"
  assert_contains "$OUT" "tests/fixture.test.sh:1: home-path-macos" "test fixture located by file:line"
  assert_contains "$OUT" "docs/guide.md:1: home-path-macos" "doc located by file:line"

  printf '# fixture user\ntests/*.test.sh home-path-macos %s/alice$\n' "$U" > "$repo/.privacy-allow"
  git -C "$repo" add -A
  git -C "$repo" commit -qm allow
  OUT=$(cd "$repo" && FM_HOME="$TMP_ROOT/nohome" "$SCAN" --tracked 2>&1); RC=$?
  expect_code 1 "$RC" "the allowlist is scoped, so the doc still fails"
  assert_not_contains "$OUT" "tests/fixture.test.sh" "the allowlisted fixture is dropped"
  assert_contains "$OUT" "docs/guide.md:1:" "an unlisted file still reports"

  printf 'see the notes\n' > "$repo/docs/guide.md"
  git -C "$repo" commit -qam clean
  OUT=$(cd "$repo" && FM_HOME="$TMP_ROOT/nohome" "$SCAN" --tracked 2>&1); RC=$?
  expect_code 0 "$RC" "tracked scan after cleanup: $OUT"
  pass "--tracked locates findings by file:line and honors a scoped allowlist"
}

test_allowlist_value_regex_is_narrow() {
  local repo="$TMP_ROOT/narrow"
  make_repo "$repo"
  printf '%s/alice/a\n%s/carol/b\n' "$U" "$U" > "$repo/notes.md"
  printf 'notes.md home-path-macos %s/alice$\n' "$U" > "$repo/.privacy-allow"
  git -C "$repo" add -A
  git -C "$repo" commit -qm notes
  OUT=$(cd "$repo" && FM_HOME="$TMP_ROOT/nohome" "$SCAN" --tracked 2>&1); RC=$?
  expect_code 1 "$RC" "a second user in an allowlisted file"
  assert_contains "$OUT" "notes.md:2: home-path-macos" "the unlisted value still reports"
  assert_not_contains "$OUT" "notes.md:1:" "the listed value is dropped"
  pass "an allowlist value regex drops only the value it names"
}

test_range_scans_added_lines_and_messages() {
  local repo="$TMP_ROOT/range" base
  make_repo "$repo"
  printf 'old %s/olduser/x\n' "$U" > "$repo/legacy.md"
  printf 'legacy.md home-path-macos %s/olduser$\nnew.md * \n' "$U" > "$repo/.privacy-allow"
  git -C "$repo" add -A
  git -C "$repo" commit -qm legacy
  base=$(git -C "$repo" rev-parse HEAD)
  printf 'fine\nadded %s/dave/y\n' "$U" > "$repo/added.md"
  printf 'anything %s/erin/z\n' "$U" > "$repo/new.md"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "evidence from $U/frank/capture"

  OUT=$(cd "$repo" && FM_HOME="$TMP_ROOT/nohome" "$SCAN" --range "$base..HEAD" 2>&1); RC=$?
  expect_code 1 "$RC" "range with an added path and a leaky message"
  assert_contains "$OUT" "added.md:2: home-path-macos" "an added line is located in the new file"
  assert_contains "$OUT" "commit " "the commit message is scanned"
  assert_not_contains "$OUT" "legacy.md" "lines outside the range are not rescanned"
  assert_not_contains "$OUT" "new.md" "a wildcard allowlist entry covers every pattern in its file"
  pass "--range scans added lines and commit messages, never older content"
}

test_local_extension_file() {
  local home="$TMP_ROOT/home" term="Acme""Corp"
  mkdir -p "$home/config"
  printf '# site terms\nclient-name/i acmecorp\n' > "$home/config/privacy-patterns.local"

  OUT=$(printf 'Report for %s\n' "$term" | FM_HOME="$home" "$SCAN" --stdin 2>&1); RC=$?
  expect_code 1 "$RC" "a local term under FM_HOME"
  assert_contains "$OUT" "stdin:1: client-name:" "the /i local pattern matches case-insensitively"

  OUT=$(printf 'Report for %s\n' "$term" | FM_HOME="$home" "$SCAN" --stdin --no-local 2>&1); RC=$?
  expect_code 0 "$RC" "--no-local ignores the site file"

  printf 'host-name mybox-[0-9]+\n' > "$TMP_ROOT/explicit.local"
  OUT=$(printf 'on mybox-42\n' | FM_HOME="$home" "$SCAN" --stdin --local "$TMP_ROOT/explicit.local" 2>&1); RC=$?
  expect_code 1 "$RC" "an explicit --local file"
  assert_contains "$OUT" "host-name" "the explicit file replaces the default one"
  pass "an untracked local pattern file adds site-specific terms"
}

test_invalid_configuration_is_refused() {
  printf 'Bad_Name x\n' > "$TMP_ROOT/bad-name.local"
  OUT=$(printf 'x\n' | "$SCAN" --stdin --local "$TMP_ROOT/bad-name.local" 2>&1); RC=$?
  expect_code 2 "$RC" "a malformed pattern name"
  assert_contains "$OUT" "bad-name.local:1" "the refusal names the file and line"

  printf 'broken-regex a(b\n' > "$TMP_ROOT/bad-re.local"
  OUT=$(printf 'x\n' | "$SCAN" --stdin --local "$TMP_ROOT/bad-re.local" 2>&1); RC=$?
  expect_code 2 "$RC" "an invalid regex"

  OUT=$("$SCAN" 2>&1); RC=$?
  expect_code 2 "$RC" "no mode"
  OUT=$("$SCAN" --range HEAD 2>&1); RC=$?
  expect_code 2 "$RC" "a range without dots"
  pass "bad patterns and bad arguments refuse with exit 2 instead of passing"
}

test_pre_push_scans_outgoing_commits() {
  local repo="$TMP_ROOT/push" bare="$TMP_ROOT/push.git" sha zero=0000000000000000000000000000000000000000
  make_repo "$repo"
  fm_git_add_origin "$repo" "$bare"
  git -C "$repo" fetch -q origin
  printf 'clean\n' > "$repo/a.md"
  git -C "$repo" add a.md
  git -C "$repo" commit -qm clean
  sha=$(git -C "$repo" rev-parse HEAD)
  OUT=$(cd "$repo" && printf 'refs/heads/x %s refs/heads/x %s\n' "$sha" "$zero" \
    | FM_HOME="$TMP_ROOT/nohome" "$SCAN" --pre-push origin "file://$bare" 2>&1); RC=$?
  expect_code 0 "$RC" "a clean outgoing commit: $OUT"

  printf 'leak %s/grace/k\n' "$U" > "$repo/b.md"
  git -C "$repo" add b.md
  git -C "$repo" commit -qm leak
  sha=$(git -C "$repo" rev-parse HEAD)
  OUT=$(cd "$repo" && printf 'refs/heads/x %s refs/heads/x %s\n' "$sha" "$zero" \
    | FM_HOME="$TMP_ROOT/nohome" "$SCAN" --pre-push origin "file://$bare" 2>&1); RC=$?
  expect_code 1 "$RC" "a leaky outgoing commit"
  assert_contains "$OUT" "b.md:1: home-path-macos" "the outgoing file is reported"

  OUT=$(cd "$repo" && printf '(delete) %s refs/heads/x %s\n' "$zero" "$sha" \
    | FM_HOME="$TMP_ROOT/nohome" "$SCAN" --pre-push origin 2>&1); RC=$?
  expect_code 0 "$RC" "a branch deletion pushes no content"
  pass "--pre-push scans only commits the remote does not already have"
}

test_repository_is_clean() {
  OUT=$(cd "$ROOT" && "$SCAN" --tracked --no-local 2>&1); RC=$?
  expect_code 0 "$RC" "this repository's tracked files: $OUT"
  pass "this repository's tracked files pass the generic scan"
}

run_case test_each_pattern_class_is_found
run_case test_findings_are_masked
run_case test_invalid_byte_does_not_hide_findings
run_case test_clean_and_placeholder_input_passes
run_case test_tracked_scan_and_allowlist
run_case test_allowlist_value_regex_is_narrow
run_case test_range_scans_added_lines_and_messages
run_case test_local_extension_file
run_case test_invalid_configuration_is_refused
run_case test_pre_push_scans_outgoing_commits
run_case test_repository_is_clean
fm_case_summary "fm-privacy-scan"
