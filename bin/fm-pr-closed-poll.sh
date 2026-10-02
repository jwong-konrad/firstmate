#!/usr/bin/env bash
# Closed-without-merge probe for a finished task's armed merge poll.
# Usage: fm-pr-closed-poll.sh <pr-or-mr-url>
#
# Prints `closed` when the PR or MR was closed without merging, `open` while it
# is still open, and nothing otherwise. A merged PR prints nothing because the
# merge poll (bin/fm-pr-poll.sh) owns that wake, and every error prints nothing
# so a failed lookup can never read as a closure.
#
# It exists because the merge poll is deliberately silent on a closed PR, and a
# finished task parked on its PR is otherwise reminded about only on the long
# merge-wait cadence. bin/fm-watch.sh runs it from its check sweep, only for a
# task task_done_awaiting_merge recognizes, at most once per
# FM_PR_CLOSED_PROBE_SECS. It is a separate trusted repository script rather
# than a change to the merge poll so that poll stays byte-static and every
# already-armed poll stays valid (docs/supervision-arming.md, "A finished task
# awaiting its merge").
#
# The URL is re-parsed with fm_pr_url_parse, the one owner of PR and MR URL
# validation, before any forge CLI sees it. Each provider is read the same way
# bin/fm-pr-poll.sh reads it: gh for GitHub, plain glab field output for GitLab.
set -u
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh" || exit 0

[ "$#" -eq 1 ] || exit 0
fm_pr_url_parse "$1" || exit 0

case "$FM_PR_PROVIDER" in
  github)
    state=$(gh pr view "$FM_PR_URL" --json state -q .state 2>/dev/null) || exit 0
    case "$state" in
      CLOSED) printf '%s\n' closed ;;
      OPEN)   printf '%s\n' open ;;
    esac
    ;;
  gitlab)
    raw=$(glab mr view "$FM_PR_NUMBER" -R "https://$FM_PR_HOST/$FM_PR_PATH" 2>/dev/null) || exit 0
    state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1) || exit 0
    case "$state" in
      closed) printf '%s\n' closed ;;
      opened) printf '%s\n' open ;;
    esac
    ;;
esac
exit 0
