#!/usr/bin/env bash
# fm-banner-lib.sh - the single owner of firstmate's attention-banner shape.
#
# Several scripts need to shout at the captain from inside a hook or a guard:
# the turn-end supervision alarm (bin/fm-turnend-guard.sh), the pull-based
# worktree-tangle and watcher-down alarms (bin/fm-guard.sh), the read-only
# session notice (bin/fm-session-start.sh), and the idle auto-handoff reminder
# (bin/fm-captain-idle-handoff.sh).
#
# They all render the same block: a full-width horizontal rule, a short shouted
# headline, a few plain-English body lines, and a closing rule, with every line
# prefixed by a solid bullet so the block survives being interleaved with other
# terminal output. That shape is one visual vocabulary meaning "firstmate needs
# your attention", so it is defined once here instead of being re-rolled with a
# local rule constant in every caller.
#
# Callers keep owning their own headline and body text - only the shape lives
# here. Sourced by hook entrypoints and guards; no side effects on source.
# set -u / set -e safe.

# The horizontal rule, WITHOUT its leading bullet, so fm_banner_rule can render
# the bullet the same way every body line does.
FM_BANNER_RULE='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'

# fm_banner_rule: print one full-width bullet-prefixed rule line.
fm_banner_rule() {
  printf '●%s\n' "$FM_BANNER_RULE"
}

# fm_banner_line <printf-format> [args...]: print one bullet-prefixed body line.
# The format is a caller-supplied LITERAL, never interpolated data; pass variable
# text through %s arguments so a stray % in it cannot be read as a conversion.
fm_banner_line() {
  local fmt=$1
  shift
  # shellcheck disable=SC2059
  printf "●  $fmt\n" "$@"
}
