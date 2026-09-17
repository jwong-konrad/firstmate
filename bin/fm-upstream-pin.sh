#!/usr/bin/env bash
# Single owner of the vetted upstream ingestion pin (.upstream-pin).
#
# The fork's relationship with its upstream template repo is PULL-ONLY. This
# script therefore only ever FETCHES: it never pushes, never merges, never
# fast-forwards a branch, and never changes what any branch points at. Its only
# write is the dedicated remote-tracking ref described below.
#
# Two consumers share this owner so the pin is parsed and validated once:
#   - bin/fm-upstream-gate.sh   the CI gate at the fork-ingestion boundary
#   - bin/fm-bootstrap.sh       the non-blocking session-start drift diagnostic
#
# Pin file format: `key=value` lines, `#` comments, blank lines ignored.
#   url=<upstream fetch URL>     https://, file://, or git@host:path
#   branch=<upstream branch>     the branch ingestion would come from
#   sha=<40-hex commit>          the UPSTREAM commit review has reached
#   review_head=<40-hex commit>  optional: the fork commit that review ended at
#
# `sha` vets an ancestry, not a single commit: upstream work counts as reviewed
# exactly when it is reachable from `sha`. That is why the drift count is
# `sha..<upstream branch>` - the upstream commits the pin does not reach.
#
# `review_head` is an audit record and nothing else. A fork commit and an
# upstream commit answer different questions, so they are kept under different
# names rather than one value pretending to be both; only `sha` decides
# anything here.
# A missing file, a missing or repeated key, or a malformed value is REFUSED
# rather than defaulted: a pin that cannot be trusted must not silently become a
# pin that permits everything.
#
# Usage: fm-upstream-pin.sh [--repo <dir>] [--pin-file <path>] <command>
#   --url | --branch | --sha | --review-head   print one validated field
#   --ref                      print the local ref the fetch writes
#   --fetch                    bounded read-only fetch of the upstream branch
#   --count                    print the unreviewed commit count (sha..ref)
#   --help
#
# --repo defaults to this script's own repo root; tests and CI point it at
# another checkout. --pin-file reads the pin from somewhere other than
# <repo>/.upstream-pin, so bin/fm-upstream-gate.sh can validate a pin blob it
# extracted from git history through this same owner instead of reimplementing
# the format. The fetch writes ONLY refs/fm-upstream/<branch>, a dedicated
# namespace outside refs/heads and refs/remotes, so it can never be confused
# with a local branch, never collides with an operator's own `upstream` remote,
# and resolves identically whether or not one is configured.
#
# The fetch downloads full upstream history (git refuses a partial-clone filter
# for an ad-hoc URL fetch), so it is bounded by FM_UPSTREAM_FETCH_TIMEOUT
# seconds, default 20, and after the first fetch it is incremental.
#
# Exit codes: 0 ok, 1 invalid pin or usage, 2 could not be determined (the fetch
# failed, or the refs needed for the count are not present locally).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  echo "usage: fm-upstream-pin.sh [--repo <dir>] [--pin-file <path>] --url|--branch|--sha|--review-head|--ref|--fetch|--count" >&2
}

die() { echo "fm-upstream-pin: $1" >&2; exit "${2:-1}"; }

COMMAND=
PIN_FILE=
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      [ $# -ge 2 ] || { usage; exit 1; }
      REPO=$2
      shift 2
      ;;
    --pin-file)
      [ $# -ge 2 ] || { usage; exit 1; }
      PIN_FILE=$2
      shift 2
      ;;
    --url|--branch|--sha|--review-head|--ref|--fetch|--count)
      [ -z "$COMMAND" ] || { usage; exit 1; }
      COMMAND=${1#--}
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done
[ -n "$COMMAND" ] || { usage; exit 1; }

[ -n "$PIN_FILE" ] || PIN_FILE="$REPO/.upstream-pin"

# --- parse and validate -----------------------------------------------------
#
# Parsed by hand rather than sourced: a pin file is a data file, and reading it
# must not be able to execute anything.

PIN_URL=
PIN_BRANCH=
PIN_SHA=
PIN_REVIEW_HEAD=

read_pin() {
  local line key value seen_url=0 seen_branch=0 seen_sha=0 seen_review=0

  [ -f "$PIN_FILE" ] || die "missing pin file $PIN_FILE"

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    case "$line" in
      *=*) ;;
      *) die "malformed line in $PIN_FILE: $line" ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      url) seen_url=$((seen_url + 1)); PIN_URL=$value ;;
      branch) seen_branch=$((seen_branch + 1)); PIN_BRANCH=$value ;;
      sha) seen_sha=$((seen_sha + 1)); PIN_SHA=$value ;;
      review_head) seen_review=$((seen_review + 1)); PIN_REVIEW_HEAD=$value ;;
      *) die "unknown key '$key' in $PIN_FILE" ;;
    esac
  done < "$PIN_FILE"

  [ "$seen_url" -eq 1 ] || die "$PIN_FILE must set 'url' exactly once (got $seen_url)"
  [ "$seen_branch" -eq 1 ] || die "$PIN_FILE must set 'branch' exactly once (got $seen_branch)"
  [ "$seen_sha" -eq 1 ] || die "$PIN_FILE must set 'sha' exactly once (got $seen_sha)"

  [ "$seen_review" -le 1 ] || die "$PIN_FILE sets 'review_head' $seen_review times"

  # A full 40-hex commit id only: a short or abbreviated sha can become
  # ambiguous as upstream history grows, and an ambiguous trust boundary is not
  # a trust boundary.
  require_full_sha() {
    case "$2" in
      *[!0-9a-f]*|'') die "$1 must be a 40-character lowercase hex commit id, got '$2'" ;;
    esac
    [ ${#2} -eq 40 ] || die "$1 must be a 40-character lowercase hex commit id, got '$2'"
  }
  require_full_sha sha "$PIN_SHA"
  [ -z "$PIN_REVIEW_HEAD" ] || require_full_sha review_head "$PIN_REVIEW_HEAD"

  case "$PIN_BRANCH" in
    ''|-*|*[[:space:]]*|*'..'*|*'~'*|*'^'*|*':'*|*'?'*|*'*'*|*'['*|*\\*)
      die "branch must be a plain ref name, got '$PIN_BRANCH'" ;;
  esac

  # Fetch-only URL shapes. Anything else is refused rather than handed to git,
  # so a pin file can never talk git into a transport nobody reviewed.
  case "$PIN_URL" in
    *[[:space:]]*) die "url must not contain whitespace, got '$PIN_URL'" ;;
    https://?*|file://?*|git@?*:?*) ;;
    *) die "url must be an https://, file://, or git@host:path fetch URL, got '$PIN_URL'" ;;
  esac
}

# --- operations -------------------------------------------------------------

pin_ref() { printf 'refs/fm-upstream/%s\n' "$PIN_BRANCH"; }

fetch_timeout() {
  case "${FM_UPSTREAM_FETCH_TIMEOUT:-}" in
    ''|*[!0-9]*) echo 20 ;;
    *) echo "$FM_UPSTREAM_FETCH_TIMEOUT" ;;
  esac
}

# Bounded read-only fetch. Mirrors bin/fm-bootstrap.sh's fleet-sync timeout
# idiom (own process group, poll `jobs -r -p`, TERM the group on expiry) so the
# repo has one pattern for "network call that must not hang a session start".
upstream_fetch() {
  local timeout pid start elapsed monitor_was_on=0 rc=0
  timeout=$(fetch_timeout)
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  git -C "$REPO" fetch --no-tags --quiet "$PIN_URL" \
    "+refs/heads/$PIN_BRANCH:$(pin_ref)" >/dev/null 2>&1 &
  pid=$!
  start=$SECONDS
  while jobs -r -p | grep -qx "$pid"; do
    elapsed=$((SECONDS - start))
    if [ "$elapsed" -ge "$timeout" ]; then
      kill -TERM "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
      echo "fm-upstream-pin: upstream fetch timed out after ${elapsed}s" >&2
      return 2
    fi
    sleep 1
  done
  wait "$pid" 2>/dev/null || rc=$?
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
  if [ "$rc" -ne 0 ]; then
    echo "fm-upstream-pin: upstream fetch from $PIN_URL failed" >&2
    return 2
  fi
  return 0
}

# Unreviewed commits: everything reachable from the fetched upstream head that
# the vetted pin does not already cover.
upstream_count() {
  local ref count
  ref=$(pin_ref)
  git -C "$REPO" rev-parse --verify --quiet "$ref^{commit}" >/dev/null \
    || { echo "fm-upstream-pin: no local upstream ref $ref - fetch first" >&2; return 2; }
  git -C "$REPO" rev-parse --verify --quiet "$PIN_SHA^{commit}" >/dev/null \
    || { echo "fm-upstream-pin: pinned commit $PIN_SHA is not present locally" >&2; return 2; }
  count=$(git -C "$REPO" rev-list --count "$PIN_SHA..$ref" 2>/dev/null) \
    || { echo "fm-upstream-pin: could not count commits $PIN_SHA..$ref" >&2; return 2; }
  printf '%s\n' "$count"
}

git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 \
  || die "not a git repository: $REPO" 2

read_pin

case "$COMMAND" in
  url) printf '%s\n' "$PIN_URL" ;;
  branch) printf '%s\n' "$PIN_BRANCH" ;;
  sha) printf '%s\n' "$PIN_SHA" ;;
  review-head) printf '%s\n' "$PIN_REVIEW_HEAD" ;;
  ref) pin_ref ;;
  fetch) upstream_fetch || exit $? ;;
  count) upstream_count || exit $? ;;
esac
