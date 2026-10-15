#!/usr/bin/env bash
# PreToolUse write guard for sandboxed claude scouts: the file-tool half of the
# worker write boundary (bin/fm-sandbox-lib.sh owns the whole boundary and
# writes this hook; docs/configuration.md owns the posture contract).
#
# Claude Code's OS sandbox confines shell commands only; its own Edit, Write,
# MultiEdit, and NotebookEdit tools still write anywhere under
# --dangerously-skip-permissions (verified, Claude Code 2.1.296). Hooks fire
# under that flag and receive the tool's exact target path, so this check is
# reliable where a shell-string check is not.
#
# Usage:
#   <claude PreToolUse JSON on stdin> | fm-sandbox-guard.sh <allowed-root>...
#
# Reads tool_input.file_path (tool_input.notebook_path for NotebookEdit),
# resolving a relative path against the payload's cwd, then resolves it to the
# physical path the write would land on (fm_sandbox_resolve_path) and allows it
# only when that path is an allowed root or lies under one. Each root is
# resolved the same way.
#
# Exit contract (Claude PreToolUse):
#   ALLOW - exit 0, no output.
#   DENY  - exit 2, the reason on stderr, which Claude shows the worker.
# Fails closed: no roots, missing jq, an unreadable payload, a missing path, or
# a path that cannot be resolved safely all deny. A wrongly denied write is
# loud and recoverable; a wrongly allowed one is the hole this closes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-sandbox-lib.sh
. "$SCRIPT_DIR/fm-sandbox-lib.sh"

deny() {
  printf 'fm-sandbox-guard: %s\n' "$1" >&2
  exit 2
}

case "${1:-}" in
  -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

[ "$#" -gt 0 ] || deny "no allowed write roots are configured, so this write cannot be checked; refusing"
command -v jq >/dev/null 2>&1 || deny "jq is unavailable, so this write cannot be checked; refusing"

payload=$(cat)
target=$(printf '%s' "$payload" | jq -r '(.tool_input.file_path // .tool_input.notebook_path // "") | strings' 2>/dev/null) \
  || deny "unreadable hook payload; refusing"
cwd=$(printf '%s' "$payload" | jq -r '(.cwd // "") | strings' 2>/dev/null) || cwd=
[ -n "$target" ] || deny "no target path in the tool input; refusing"
case "$target" in
  /*) ;;
  *)
    case "$cwd" in /*) target="$cwd/$target" ;; *) deny "relative path '$target' with no absolute cwd; refusing" ;; esac
    ;;
esac

resolved=$(fm_sandbox_resolve_path "$target") \
  || deny "cannot safely resolve '$target' (symlink loop, dangling link, or . or .. in a missing directory); refusing"

for root in "$@"; do
  [ -n "$root" ] || continue
  r=$(fm_sandbox_resolve_path "$root") || continue
  [ "$r" != / ] || continue
  case "$resolved" in
    "$r"|"$r"/*) exit 0 ;;
  esac
done

deny "refusing to write '$target': it is outside this task's copy and its declared write paths. This scout runs inside a deliberate write boundary; report what you need to write and why instead of working around it."
