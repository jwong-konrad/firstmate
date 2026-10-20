#!/usr/bin/env bash
# Re-sign an unsigned PR branch's commits and push them, for branches that the
# repository's "require signed commits" ruleset refuses to merge.
#
# It runs the manual recipe in one guarded pass: rebase the branch's commits onto
# the base with `git commit --amend --no-edit -S`, prove the result is the same
# content with every commit signed, then push with a lease pinned to the old
# remote sha.
#
# Usage: fm-sign-branch.sh <worktree> [--base <ref>] [--dry-run]
#   <worktree>   the task worktree, on its PR branch, with a clean tree
#   --base <ref> first commit NOT to re-sign; default is the merge-base with
#                origin's default branch
#   --dry-run    fetch and run every precondition check, print the commits that
#                would be re-signed, and change nothing
#
# Signing goes through whatever signing program git is configured to use (for
# example an SSH signing program backed by a Secure Enclave key). That key may
# require a touch per signature, depending on the key's agent setting, so this
# script is meant to run with a person present. It never changes git config.
#
# Refusals (exit 1, nothing rewritten or pushed):
#   - detached HEAD, the default branch, or a dirty worktree
#   - the branch is missing on origin, ahead of it, or diverged from it; a local
#     branch strictly behind origin is fast-forwarded first
#   - the range holds a merge commit (a rebase would flatten it)
#   - after signing, the tree differs from the old head or any commit in the
#     range does not report `G` in `git log --format=%G?`; the branch is then
#     reset to the old head
# Every outcome prints the old head sha, so the original commits stay
# recoverable (`git branch rescue <old-head>`) even after the rewrite.
#
# The push is `--force-with-lease=<branch>:<old remote sha>`, never a plain
# --force, so a branch that moved on origin since the fetch is not overwritten.
# Merging stays with fm-pr-merge.sh; this script does not merge.
set -eu

usage() {
  echo "usage: fm-sign-branch.sh <worktree> [--base <ref>] [--dry-run]" >&2
  exit 2
}

die() {
  echo "REFUSED: $*" >&2
  exit 1
}

WT=""
BASE=""
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --base) [ $# -ge 2 ] || usage; BASE=$2; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) [ -z "$WT" ] || usage; WT=$1; shift ;;
  esac
done
[ -n "$WT" ] || usage
[ -d "$WT" ] || { echo "error: no such directory: $WT" >&2; exit 2; }

g() { git -C "$WT" "$@"; }

g rev-parse --git-dir >/dev/null 2>&1 || { echo "error: $WT is not a git worktree" >&2; exit 2; }

BRANCH=$(g symbolic-ref --quiet --short HEAD 2>/dev/null || true)
[ -n "$BRANCH" ] || die "detached HEAD; check out the PR branch first"

default_branch() {
  local ref b
  ref=$(g symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for b in main master; do
    if g show-ref --verify --quiet "refs/remotes/origin/$b" || g show-ref --verify --quiet "refs/heads/$b"; then
      echo "$b"
      return 0
    fi
  done
  return 1
}

DEFAULT=$(default_branch) || die "cannot determine origin's default branch"
[ "$BRANCH" != "$DEFAULT" ] || die "$BRANCH is the default branch; refusing to rewrite it"

if [ -n "$(g status --porcelain)" ]; then
  die "worktree has uncommitted changes"
fi

g fetch --quiet origin "+refs/heads/$DEFAULT:refs/remotes/origin/$DEFAULT" || die "could not fetch origin/$DEFAULT"
g fetch --quiet origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" 2>/dev/null \
  || die "branch $BRANCH is not on origin (or the fetch failed); nothing to re-sign against"

LOCAL=$(g rev-parse HEAD)
REMOTE=$(g rev-parse "refs/remotes/origin/$BRANCH")

if [ "$LOCAL" != "$REMOTE" ]; then
  if g merge-base --is-ancestor "$LOCAL" "$REMOTE"; then
    echo "local $BRANCH is behind origin; fast-forwarding ($LOCAL -> $REMOTE)"
    if [ "$DRY" -eq 0 ]; then
      g merge --ff-only --quiet "$REMOTE" || die "fast-forward to origin/$BRANCH failed"
    fi
  elif g merge-base --is-ancestor "$REMOTE" "$LOCAL"; then
    die "local $BRANCH is ahead of origin (unpushed commits); push or reset it first (local $LOCAL, origin $REMOTE)"
  else
    die "local $BRANCH and origin/$BRANCH have diverged (local $LOCAL, origin $REMOTE)"
  fi
fi

OLD_HEAD=$REMOTE
if [ -z "$BASE" ]; then
  BASE=$(g merge-base "$OLD_HEAD" "refs/remotes/origin/$DEFAULT") || die "no merge-base with origin/$DEFAULT"
else
  BASE=$(g rev-parse --verify --quiet "$BASE^{commit}") || die "unknown base ref"
  g merge-base --is-ancestor "$BASE" "$OLD_HEAD" || die "base is not an ancestor of $BRANCH"
fi

COUNT=$(g rev-list --count "$BASE..$OLD_HEAD")
[ "$COUNT" -gt 0 ] || die "no commits between base and $BRANCH"
[ -z "$(g rev-list --merges "$BASE..$OLD_HEAD")" ] || die "range contains a merge commit; a rebase would flatten it"

echo "branch:   $BRANCH"
echo "base:     $BASE"
echo "old head: $OLD_HEAD"
echo "commits:  $COUNT"
g log --format='  %h %G? %s' "$BASE..$OLD_HEAD"

if [ "$DRY" -eq 1 ]; then
  echo "dry run: nothing rewritten or pushed"
  exit 0
fi

restore() {
  g rebase --abort >/dev/null 2>&1 || true
  g reset --hard --quiet "$OLD_HEAD"
  echo "branch reset to old head $OLD_HEAD" >&2
}

if ! g rebase -f --exec 'git commit --amend --no-edit -S' "$BASE" >/dev/null 2>&1; then
  restore
  die "signing rebase failed (signing key unavailable or declined?); old head $OLD_HEAD"
fi

if ! g diff --quiet "$OLD_HEAD" HEAD; then
  restore
  die "tree changed after re-signing; old head $OLD_HEAD"
fi

BAD=$(g log --format=%G? "$BASE..HEAD" | grep -vc '^G$' || true)
if [ "$BAD" -ne 0 ]; then
  restore
  die "$BAD commit(s) do not report G after re-signing; old head $OLD_HEAD"
fi

NEW_HEAD=$(g rev-parse HEAD)
echo "verified: tree unchanged, $COUNT commit(s) report G (new head $NEW_HEAD)"

if ! g push --force-with-lease="refs/heads/$BRANCH:$OLD_HEAD" origin "HEAD:refs/heads/$BRANCH"; then
  echo "push rejected; local branch keeps the signed commits, original head is $OLD_HEAD" >&2
  exit 1
fi
echo "pushed $BRANCH: $OLD_HEAD -> $NEW_HEAD"
