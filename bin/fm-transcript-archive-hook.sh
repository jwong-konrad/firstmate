#!/usr/bin/env bash
# Claude Code hook for Stop, SubagentStop, and SessionEnd: append the new lines of
# the session transcript (and the subagent transcript, when the event carries one)
# to the archive staging root, so transcripts survive any later cleanup of
# ~/.claude. docs/archive.md owns the exact ~/.claude/settings.json entries.
#
# Reads the hook JSON on stdin (transcript_path, agent_transcript_path, and the
# ids, which are not needed to locate a file). Input is untrusted: a path is used only
# if it is absolute, free of ".." components, not a symlink, ends in .jsonl, and
# resolves to a file under ~/.claude/projects (fm_archive_transcript_rel); anything
# else is skipped and only the reason is logged. The destination is the same staged
# path bin/fm-archive.sh uses, and the staged size is the offset, so the hook and
# the nightly archiver never copy a byte twice and either may run first. A per-file
# lock serialises them; if the lock cannot be taken within two seconds the hook skips
# and the next event or the nightly run catches up.
#
# Contract: prints nothing to stdout or stderr, always exits 0, and never touches
# anything outside the archive root. It does nothing when the internal free-space
# floor (FM_ARCHIVE_MIN_FREE_GIB, default 15) is not met or FM_ARCHIVE_HOOK=off.
# Failures are appended to <root>/archive.log, never surfaced to Claude Code.
# Environment: FM_ARCHIVE_ROOT, FM_ARCHIVE_CLAUDE_DIR (default ~/.claude).
set +e
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
# shellcheck source=bin/fm-archive-lib.sh
. "$SCRIPT_DIR/fm-archive-lib.sh" >/dev/null 2>&1 || exit 0

archive_hook_main() {
  local input path root
  [ "${FM_ARCHIVE_HOOK:-on}" = off ] && return 0
  command -v jq >/dev/null 2>&1 || return 0
  input=$(cat) || return 0
  root=$(fm_archive_root)
  mkdir -p "$root/transcripts" 2>/dev/null || return 0
  fm_archive_floor_ok "$root" || { fm_archive_log "hook skipped: below the free-space floor"; return 0; }
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    # Only a regular, non-symlink .jsonl under ~/.claude/projects is ever read; a refusal
    # logs its reason, never the path or any content.
    if ! fm_archive_transcript_rel "$path"; then
      fm_archive_log "hook refused a transcript path: $FM_ARCHIVE_REJECT"
      continue
    fi
    if fm_archive_sync_append "$path" "$root/transcripts/$FM_ARCHIVE_REL" 20; then
      [ "$FM_ARCHIVE_SYNC" != rewritten ] || fm_archive_log "hook: a transcript was rewritten, the new source was saved beside the archived copy"
    else
      fm_archive_log "hook could not archive a transcript"
    fi
  done <<EOF
$(printf '%s' "$input" | jq -r '.transcript_path // empty, .agent_transcript_path // empty' 2>/dev/null)
EOF
  return 0
}

archive_hook_main >/dev/null 2>&1
exit 0
