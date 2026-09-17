#!/usr/bin/env bash
# The fork-ingestion gate: refuse commits that enter this fork from upstream
# without a vetting that covers them.
#
# The guard belongs HERE, where commits enter the fork, not where the fleet
# consumes them: bin/fm-update.sh and bin/fm-fleet-sync.sh stay fast-forward-only
# and deliberately know nothing about upstream. By the time a home fast-forwards
# from origin, unreviewed upstream work would already be inside the fork.
#
# Run from .github/workflows/ci.yml on every push and pull request to the
# default branch. It never writes to the repo beyond the read-only upstream
# fetch bin/fm-upstream-pin.sh owns, and it never pushes anywhere: the upstream
# relationship is PULL-ONLY.
#
# Usage: fm-upstream-gate.sh --base <ref> --head <ref> [--repo <dir>] [--no-fetch]
#
# The pin's `sha` is an UPSTREAM commit, and what it vets is that commit's
# ancestry. It must also already be reachable from <head>, so it sits exactly on
# the frontier of what this fork has both ingested and reviewed.
#
# What it decides, given the commits the range <base>..<head> would add:
#   - ingested = those commits that are also reachable from the upstream branch
#   - covered  = the commits reachable from the pin at <head>
# The range PASSES when it ingests nothing, or when every ingested commit is
# covered. It FAILS when:
#   - .upstream-pin is missing or unparseable at <head>
#   - the pin does not name an upstream commit, so it vets nothing upstream
#   - the pin is not already reachable from <head>, which would let a pin-only
#     change pre-authorize upstream work before anyone ingests it
#   - the pin covers less upstream work than it did at <base>
#   - upstream commits enter while the pin stays put
#   - upstream commits enter that the pin does not cover
#
# It fails CLOSED. A gate that cannot see upstream cannot prove the range is
# clean, so an unreachable upstream, an unresolvable ref, or an unparseable pin
# stops the run instead of waving it through. That is the opposite of the
# bootstrap drift diagnostic, which is advisory and must never block a session.
#
# --no-fetch reuses the refs already present (tests that built a fixture
# upstream locally, or a rerun that already fetched).
#
# Exit codes: 0 pass, 1 gate violation, 2 could not be determined.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
BASE=
HEAD_REF=
FETCH=1

usage() {
  echo "usage: fm-upstream-gate.sh --base <ref> --head <ref> [--repo <dir>] [--no-fetch]" >&2
}

# Refusals are the gate's product, so they say what entered, what covers it, and
# what the contributor has to do - never just "failed".
refuse() { echo "fm-upstream-gate: REFUSED: $1" >&2; exit 1; }
undetermined() { echo "fm-upstream-gate: cannot determine: $1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --base) [ $# -ge 2 ] || { usage; exit 2; }; BASE=$2; shift 2 ;;
    --head) [ $# -ge 2 ] || { usage; exit 2; }; HEAD_REF=$2; shift 2 ;;
    --repo) [ $# -ge 2 ] || { usage; exit 2; }; REPO=$2; shift 2 ;;
    --no-fetch) FETCH=0; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
[ -n "$HEAD_REF" ] || { usage; exit 2; }
[ -n "$BASE" ] || { usage; exit 2; }

PIN="$SCRIPT_DIR/fm-upstream-pin.sh"
[ -x "$PIN" ] || undetermined "missing $PIN"

git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 \
  || undetermined "not a git repository: $REPO"

base_sha=$(git -C "$REPO" rev-parse --verify --quiet "$BASE^{commit}") \
  || undetermined "base ref '$BASE' does not resolve to a commit"
head_sha=$(git -C "$REPO" rev-parse --verify --quiet "$HEAD_REF^{commit}") \
  || undetermined "head ref '$HEAD_REF' does not resolve to a commit"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-upstream-gate.XXXXXX") || undetermined "cannot create temp dir"
trap 'rm -rf "$TMP"' EXIT

# --- the pin on each side ---------------------------------------------------
#
# Both sides are read as git blobs, never from the working tree, so the gate
# judges what the range actually carries rather than whatever happens to be
# checked out.

pin_field() {
  local file=$1 field=$2
  "$PIN" --repo "$REPO" --pin-file "$file" "--$field" 2>>"$TMP/pin-errors"
}

if ! git -C "$REPO" cat-file -e "$head_sha:.upstream-pin" 2>/dev/null; then
  refuse "no .upstream-pin at $HEAD_REF - the upstream vetting pin must not be deleted"
fi
git -C "$REPO" show "$head_sha:.upstream-pin" >"$TMP/head-pin" \
  || undetermined "could not read .upstream-pin at $HEAD_REF"

head_pin=$(pin_field "$TMP/head-pin" sha) \
  || refuse "invalid .upstream-pin at $HEAD_REF: $(cat "$TMP/pin-errors" 2>/dev/null)"
upstream_branch=$(pin_field "$TMP/head-pin" branch) \
  || refuse "invalid .upstream-pin at $HEAD_REF: $(cat "$TMP/pin-errors" 2>/dev/null)"
upstream_ref=$(pin_field "$TMP/head-pin" ref) \
  || undetermined "could not resolve the upstream ref name"

base_pin=
if git -C "$REPO" cat-file -e "$base_sha:.upstream-pin" 2>/dev/null; then
  git -C "$REPO" show "$base_sha:.upstream-pin" >"$TMP/base-pin" \
    || undetermined "could not read .upstream-pin at $BASE"
  base_pin=$(pin_field "$TMP/base-pin" sha) \
    || undetermined "invalid .upstream-pin at $BASE: $(cat "$TMP/pin-errors" 2>/dev/null)"
fi

# --- upstream ---------------------------------------------------------------

if [ "$FETCH" -eq 1 ]; then
  "$PIN" --repo "$REPO" --pin-file "$TMP/head-pin" --fetch \
    || undetermined "upstream fetch failed, so this range cannot be proved clean"
fi
git -C "$REPO" rev-parse --verify --quiet "$upstream_ref^{commit}" >/dev/null \
  || undetermined "no upstream ref $upstream_ref - fetch upstream before running the gate"

git -C "$REPO" rev-parse --verify --quiet "$head_pin^{commit}" >/dev/null \
  || refuse "pinned commit $head_pin is not a commit in this repository"

# The pin vets upstream history, so it has to be part of it. A fork commit here
# would describe how far this fork had got, not how far the review had got.
git -C "$REPO" merge-base --is-ancestor "$head_pin" "$upstream_ref" \
  || refuse "pinned commit $head_pin is not on the upstream $upstream_branch branch - 'sha' must name an upstream commit (use 'review_head' for a fork commit)"

# The pin may only vouch for work that is already here. Without this, a
# pin-only change could quietly vouch for upstream commits nobody has ingested,
# and the ingestion that followed would sail through already covered.
git -C "$REPO" merge-base --is-ancestor "$head_pin" "$head_sha" \
  || refuse "pinned commit $head_pin is not reachable from $HEAD_REF - the pin must name a commit already in this branch, so it cannot vouch for upstream work ahead of ingesting it"

# review_head is an audit record, not an authority, so it is only checked for
# being a real commit on this branch - never consulted to decide the range.
review_head=$(pin_field "$TMP/head-pin" review-head) \
  || refuse "invalid .upstream-pin at $HEAD_REF: $(cat "$TMP/pin-errors" 2>/dev/null)"
if [ -n "$review_head" ]; then
  git -C "$REPO" rev-parse --verify --quiet "$review_head^{commit}" >/dev/null \
    || refuse "review_head $review_head is not a commit in this repository"
  git -C "$REPO" merge-base --is-ancestor "$review_head" "$head_sha" \
    || refuse "review_head $review_head is not reachable from $HEAD_REF - it must record a review that happened on this branch's history"
fi

git -C "$REPO" rev-list "$upstream_ref" | LC_ALL=C sort >"$TMP/upstream" \
  || undetermined "could not list upstream commits"
git -C "$REPO" rev-list "$head_pin" | LC_ALL=C sort >"$TMP/covered" \
  || undetermined "could not list commits covered by the pin"

# Coverage only ever grows. A pin that covers less upstream work than it did at
# base has lost review history, which is an invalid record even though it errs
# strict, so it is refused rather than quietly accepted.
if [ -n "$base_pin" ] && [ "$base_pin" != "$head_pin" ]; then
  git -C "$REPO" rev-list "$base_pin" | LC_ALL=C sort >"$TMP/base-reach" \
    || undetermined "could not list commits covered by the pin at $BASE"
  LC_ALL=C comm -12 "$TMP/base-reach" "$TMP/upstream" >"$TMP/base-covered"
  LC_ALL=C comm -23 "$TMP/base-covered" "$TMP/covered" >"$TMP/dropped"
  dropped_n=$(LC_ALL=C grep -c . "$TMP/dropped" || true)
  [ "$dropped_n" -eq 0 ] \
    || refuse "the pin moves from $base_pin to $head_pin and drops $dropped_n upstream commit(s) it used to cover - a vetting pin only ever covers more"
fi

# --- what this range ingests ------------------------------------------------

git -C "$REPO" rev-list "$base_sha..$head_sha" | LC_ALL=C sort >"$TMP/range" \
  || undetermined "could not list commits in $BASE..$HEAD_REF"
LC_ALL=C comm -12 "$TMP/range" "$TMP/upstream" >"$TMP/ingested"

ingested_n=$(LC_ALL=C grep -c . "$TMP/ingested" || true)
range_n=$(LC_ALL=C grep -c . "$TMP/range" || true)

if [ "$ingested_n" -eq 0 ]; then
  echo "fm-upstream-gate: ok - $range_n commit(s) in $BASE..$HEAD_REF, none from upstream $upstream_branch"
  exit 0
fi

if [ "$base_pin" = "$head_pin" ]; then
  refuse "$ingested_n upstream commit(s) enter the fork in $BASE..$HEAD_REF while the pin stays at $head_pin - review the ingested range and advance 'sha' in .upstream-pin to the reviewed commit"
fi

LC_ALL=C comm -23 "$TMP/ingested" "$TMP/covered" >"$TMP/uncovered"
uncovered_n=$(LC_ALL=C grep -c . "$TMP/uncovered" || true)

if [ "$uncovered_n" -gt 0 ]; then
  {
    echo "fm-upstream-gate: REFUSED: $uncovered_n of $ingested_n ingested upstream commit(s) reach past the pin $head_pin:"
    head -n 10 "$TMP/uncovered"
    [ "$uncovered_n" -le 10 ] || echo "  ... and $((uncovered_n - 10)) more"
    echo "Advance 'sha' in .upstream-pin to a reviewed commit that covers everything this range ingests."
  } >&2
  exit 1
fi

echo "fm-upstream-gate: ok - $ingested_n ingested upstream commit(s) in $BASE..$HEAD_REF are covered by the pin $head_pin"
exit 0
