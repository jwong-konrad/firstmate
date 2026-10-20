#!/usr/bin/env bash
# Behavior tests for bin/fm-sign-branch.sh.
# Signing uses a throwaway ed25519 test key through git's ssh signing with a
# test allowed-signers file, so no real signing key, agent, or touch is needed.
# That also means these tests do not verify any hardware-key behavior.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SIGN="$ROOT/bin/fm-sign-branch.sh"
TMP_ROOT=$(fm_test_tmproot fm-sign-branch)
# The helper ran in a command substitution, so its trap already removed the dir.
mkdir -p "$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT
fm_git_identity
KEY="$TMP_ROOT/testkey"
ssh-keygen -q -t ed25519 -N '' -C fmtest -f "$KEY" >/dev/null
printf 'fmtest@example.invalid %s\n' "$(cut -d' ' -f1,2 "$KEY.pub")" > "$TMP_ROOT/allowed"

configure_signing() {
  git -C "$1" config gpg.format ssh
  git -C "$1" config user.signingkey "$KEY.pub"
  git -C "$1" config gpg.ssh.allowedSignersFile "$TMP_ROOT/allowed"
}

# make_fixture <name>: sets ORIGIN and WT; WT is on fm/x with two unsigned
# commits already pushed to origin.
make_fixture() {
  local name=$1
  ORIGIN="$TMP_ROOT/$name.git"
  WT="$TMP_ROOT/$name"
  local seed="$TMP_ROOT/$name-seed"
  fm_git_init_commit "$seed"
  git -C "$seed" branch -M main
  git clone --quiet --bare "$seed" "$ORIGIN"
  git clone --quiet "file://$ORIGIN" "$WT"
  configure_signing "$WT"
  git -C "$WT" checkout -q -b fm/x
  printf one > "$WT/a.txt"; git -C "$WT" add a.txt; git -C "$WT" commit -qm one
  printf two > "$WT/b.txt"; git -C "$WT" add b.txt; git -C "$WT" commit -qm two
  git -C "$WT" push -q origin fm/x
}

run_sign() {
  OUT=$("$SIGN" "$@" 2>&1)
  RC=$?
}

sigs() { git -C "$1" log --format=%G? "$2"; }

test_signs_and_pushes() {
  make_fixture signs
  local old
  old=$(git -C "$WT" rev-parse HEAD)
  run_sign "$WT"
  expect_code 0 "$RC" "sign succeeds"
  assert_contains "$OUT" "$old" "old head printed"
  [ "$(git -C "$WT" rev-parse HEAD)" != "$old" ] || fail "head was rewritten"
  [ "$(git -C "$ORIGIN" rev-parse fm/x)" = "$(git -C "$WT" rev-parse HEAD)" ] || fail "origin has the new head"
  [ "$(sigs "$WT" main..HEAD | sort -u)" = G ] || fail "every commit reports G"
  git -C "$WT" diff --quiet "$old" HEAD || fail "tree unchanged"
  pass "re-signs the range and pushes"
}

test_dry_run_changes_nothing() {
  make_fixture dry
  local old
  old=$(git -C "$WT" rev-parse HEAD)
  run_sign "$WT" --dry-run
  expect_code 0 "$RC" "dry run succeeds"
  [ "$(git -C "$WT" rev-parse HEAD)" = "$old" ] || fail "local head untouched"
  [ "$(git -C "$ORIGIN" rev-parse fm/x)" = "$old" ] || fail "origin untouched"
  pass "dry run rewrites and pushes nothing"
}

test_fast_forwards_when_local_behind() {
  make_fixture behind
  local other="$TMP_ROOT/behind-other"
  git clone --quiet "file://$ORIGIN" "$other"
  git -C "$other" checkout -q fm/x
  printf three > "$other/c.txt"; git -C "$other" add c.txt; git -C "$other" commit -qm three
  git -C "$other" push -q origin fm/x
  local remote
  remote=$(git -C "$ORIGIN" rev-parse fm/x)
  run_sign "$WT"
  expect_code 0 "$RC" "sign after fast-forward"
  assert_contains "$OUT" "behind origin" "fast-forward announced"
  [ -f "$WT/c.txt" ] || fail "the commit that was only on origin is kept"
  [ "$(git -C "$WT" rev-list --count main..HEAD)" = 3 ] || fail "all three commits in the range"
  [ "$(sigs "$WT" main..HEAD | sort -u)" = G ] || fail "all signed"
  git -C "$WT" diff --quiet "$remote" HEAD || fail "content equals old origin head"
  pass "fast-forwards a strictly-behind local branch, then signs the full range"
}

test_refuses_when_local_ahead() {
  make_fixture ahead
  printf three > "$WT/c.txt"; git -C "$WT" add c.txt; git -C "$WT" commit -qm three
  local before
  before=$(git -C "$ORIGIN" rev-parse fm/x)
  run_sign "$WT"
  expect_code 1 "$RC" "ahead refused"
  assert_contains "$OUT" "ahead of origin" "reason names ahead"
  [ "$(git -C "$ORIGIN" rev-parse fm/x)" = "$before" ] || fail "origin untouched"
  pass "refuses a local branch ahead of origin"
}

test_refuses_when_diverged() {
  make_fixture diverged
  local other="$TMP_ROOT/diverged-other"
  git clone --quiet "file://$ORIGIN" "$other"
  git -C "$other" checkout -q fm/x
  printf r > "$other/r.txt"; git -C "$other" add r.txt; git -C "$other" commit -qm remote
  git -C "$other" push -q origin fm/x
  printf l > "$WT/l.txt"; git -C "$WT" add l.txt; git -C "$WT" commit -qm local
  local head before
  head=$(git -C "$WT" rev-parse HEAD)
  before=$(git -C "$ORIGIN" rev-parse fm/x)
  run_sign "$WT"
  expect_code 1 "$RC" "diverged refused"
  assert_contains "$OUT" "diverged" "reason names divergence"
  [ "$(git -C "$WT" rev-parse HEAD)" = "$head" ] || fail "local ref untouched"
  [ "$(git -C "$ORIGIN" rev-parse fm/x)" = "$before" ] || fail "origin untouched"
  pass "refuses a diverged branch"
}

test_refuses_dirty_detached_default() {
  make_fixture dirty
  printf x >> "$WT/a.txt"
  run_sign "$WT"
  expect_code 1 "$RC" "dirty refused"
  assert_contains "$OUT" "uncommitted" "dirty reason"
  git -C "$WT" checkout -q -- a.txt
  git -C "$WT" checkout -q --detach
  run_sign "$WT"
  expect_code 1 "$RC" "detached refused"
  assert_contains "$OUT" "detached" "detached reason"
  git -C "$WT" checkout -q main
  run_sign "$WT"
  expect_code 1 "$RC" "default branch refused"
  assert_contains "$OUT" "default branch" "default reason"
  pass "refuses dirty tree, detached HEAD, and the default branch"
}

test_refuses_and_restores_when_unsigned_result() {
  make_fixture nosig
  # A signing program that always fails, as a declined or missing key would.
  local old before
  old=$(git -C "$WT" rev-parse HEAD)
  before=$(git -C "$ORIGIN" rev-parse fm/x)
  printf '#!/bin/sh\nexit 1\n' > "$TMP_ROOT/badsign"; chmod +x "$TMP_ROOT/badsign"
  git -C "$WT" config gpg.ssh.program "$TMP_ROOT/badsign"
  run_sign "$WT"
  expect_code 1 "$RC" "failed signing refused"
  assert_contains "$OUT" "$old" "old head printed"
  [ "$(git -C "$WT" rev-parse HEAD)" = "$old" ] || fail "branch restored to old head"
  [ "$(git -C "$ORIGIN" rev-parse fm/x)" = "$before" ] || fail "nothing pushed"
  git -C "$WT" diff --quiet || fail "worktree clean after restore"
  pass "a failed signing run restores the branch and pushes nothing"
}

test_refuses_when_not_verifiable() {
  make_fixture unverifiable
  # Commits sign fine but the verifier does not trust the key, so %G? is not G.
  : > "$TMP_ROOT/empty-allowed"
  git -C "$WT" config gpg.ssh.allowedSignersFile "$TMP_ROOT/empty-allowed"
  local old before
  old=$(git -C "$WT" rev-parse HEAD)
  before=$(git -C "$ORIGIN" rev-parse fm/x)
  run_sign "$WT"
  expect_code 1 "$RC" "non-G refused"
  assert_contains "$OUT" "do not report G" "reason names the G check"
  assert_contains "$OUT" "$old" "old head printed"
  [ "$(git -C "$WT" rev-parse HEAD)" = "$old" ] || fail "branch restored"
  [ "$(git -C "$ORIGIN" rev-parse fm/x)" = "$before" ] || fail "nothing pushed"
  pass "refuses to push when a commit does not report G"
}

test_push_uses_lease() {
  make_fixture lease
  local other="$TMP_ROOT/lease-other" shim="$TMP_ROOT/lease-shim" real
  real=$(command -v git)
  # Move origin after the script's fetch by wrapping git push: advance origin
  # just before the real push runs, so only the lease can stop it.
  mkdir -p "$shim"
  git clone --quiet "file://$ORIGIN" "$other"
  git -C "$other" checkout -q fm/x
  cat > "$shim/git" <<SH
#!/bin/sh
for a in "\$@"; do
  if [ "\$a" = push ]; then
    printf z > "$other/z.txt"
    "$real" -C "$other" add z.txt
    "$real" -C "$other" commit -qm racer
    "$real" -C "$other" push -q origin fm/x
    break
  fi
done
exec "$real" "\$@"
SH
  chmod +x "$shim/git"
  local racer
  OUT=$(PATH="$shim:$PATH" "$SIGN" "$WT" 2>&1); RC=$?
  racer=$(git -C "$other" rev-parse HEAD)
  expect_code 1 "$RC" "lease rejection fails the run"
  [ "$(git -C "$ORIGIN" rev-parse fm/x)" = "$racer" ] || fail "racing commit on origin survives"
  pass "push is lease-pinned and cannot overwrite a branch that moved"
}

run_case test_signs_and_pushes
run_case test_dry_run_changes_nothing
run_case test_fast_forwards_when_local_behind
run_case test_refuses_when_local_ahead
run_case test_refuses_when_diverged
run_case test_refuses_dirty_detached_default
run_case test_refuses_and_restores_when_unsigned_result
run_case test_refuses_when_not_verifiable
run_case test_push_uses_lease
fm_case_summary "fm-sign-branch"
