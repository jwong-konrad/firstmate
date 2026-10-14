#!/usr/bin/env bash
# Install, remove, or inspect the nightly archive LaunchAgent (docs/archive.md).
# The captain runs this; firstmate never installs it. The agent runs bin/fm-archive.sh
# at 03:17 local time and once at every login, so a reboot or a sleeping laptop catches
# up at the next opportunity, and it survives reboots because a LaunchAgent in
# ~/Library/LaunchAgents is reloaded at login.
#
# The plist is rendered from docs/examples/com.firstmate.archive.plist.template and
# points at THIS checkout's bin/fm-archive.sh, so install from the primary checkout,
# never from a disposable task worktree (that path disappears when the worktree is
# recycled); a linked worktree is refused unless --allow-worktree is given.
#
# Usage:
#   fm-archive-install.sh install   [--hour H] [--minute M] [--home DIR] [--archive-root DIR]
#                                   [--plist-dir DIR] [--no-load] [--allow-worktree]
#   fm-archive-install.sh uninstall [--plist-dir DIR]
#   fm-archive-install.sh status    [--plist-dir DIR]
#   fm-archive-install.sh print     [same options as install]    render the plist, change nothing
# install is idempotent: it unloads a loaded agent, rewrites the plist, and loads it again.
# --no-load writes the plist without touching launchd.
# Environment: FM_ARCHIVE_LAUNCHCTL (default launchctl), FM_ARCHIVE_INSTALL_ROOT (checkout
# root override, used by tests), FM_HOME, FM_ARCHIVE_ROOT.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${FM_ARCHIVE_INSTALL_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
LABEL=com.firstmate.archive
LAUNCHCTL=${FM_ARCHIVE_LAUNCHCTL:-launchctl}
TEMPLATE="$REPO/docs/examples/com.firstmate.archive.plist.template"

CMD=${1:-}
[ "$#" -gt 0 ] && shift
HOUR=3
MINUTE=17
FMHOME=${FM_HOME:-$REPO}
ARCHIVE_ROOT=${FM_ARCHIVE_ROOT:-$HOME/Code/firstmate-archive}
PLIST_DIR="$HOME/Library/LaunchAgents"
LOAD=1
ALLOW_WT=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --hour) HOUR=${2:-}; shift ;;
    --minute) MINUTE=${2:-}; shift ;;
    --home) FMHOME=${2:-}; shift ;;
    --archive-root) ARCHIVE_ROOT=${2:-}; shift ;;
    --plist-dir) PLIST_DIR=${2:-}; shift ;;
    --no-load) LOAD=0 ;;
    --allow-worktree) ALLOW_WT=1 ;;
    *) echo "error: unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done
PLIST="$PLIST_DIR/$LABEL.plist"

xml_escape() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

# render: fill the template without regex or pattern substitution, so a path containing
# & or / or | cannot change what is written.
render() {
  local line key val
  local keys="@LABEL@ @ARCHIVE_SCRIPT@ @HOME@ @FM_HOME@ @ARCHIVE_ROOT@ @HOUR@ @MINUTE@ @LOG@"
  while IFS= read -r line; do
    for key in $keys; do
      case "$key" in
        @LABEL@) val=$LABEL ;;
        @ARCHIVE_SCRIPT@) val=$(xml_escape "$REPO/bin/fm-archive.sh") ;;
        @HOME@) val=$(xml_escape "$HOME") ;;
        @FM_HOME@) val=$(xml_escape "$FMHOME") ;;
        @ARCHIVE_ROOT@) val=$(xml_escape "$ARCHIVE_ROOT") ;;
        @HOUR@) val=$HOUR ;;
        @MINUTE@) val=$MINUTE ;;
        @LOG@) val=$(xml_escape "$ARCHIVE_ROOT/launchd.log") ;;
      esac
      while [ "${line#*"$key"}" != "$line" ]; do
        line="${line%%"$key"*}$val${line#*"$key"}"
      done
    done
    printf '%s\n' "$line"
  done < "$TEMPLATE"
}

validate_options() {
  case "$HOUR" in ''|*[!0-9]*) echo "error: --hour must be 0-23" >&2; return 1 ;; esac
  case "$MINUTE" in ''|*[!0-9]*) echo "error: --minute must be 0-59" >&2; return 1 ;; esac
  [ "$HOUR" -le 23 ] && [ "$MINUTE" -le 59 ] || { echo "error: hour 0-23 and minute 0-59" >&2; return 1; }
  [ -f "$TEMPLATE" ] || { echo "error: missing template $TEMPLATE" >&2; return 1; }
  case "$ARCHIVE_ROOT" in /*) ;; *) echo "error: --archive-root must be an absolute path" >&2; return 1 ;; esac
  case "$FMHOME" in /*) ;; *) echo "error: --home must be an absolute path" >&2; return 1 ;; esac
}

refuse_worktree() {
  local gd cd
  [ "$ALLOW_WT" -eq 0 ] || return 0
  gd=$(git -C "$REPO" rev-parse --git-dir 2>/dev/null) || return 0
  cd=$(git -C "$REPO" rev-parse --git-common-dir 2>/dev/null) || return 0
  gd=$(cd "$REPO" && cd "$gd" && pwd -P)
  cd=$(cd "$REPO" && cd "$cd" && pwd -P)
  if [ "$gd" != "$cd" ]; then
    echo "error: $REPO is a linked worktree; its path will not outlive the task. Run this from the primary checkout (or pass --allow-worktree)." >&2
    return 1
  fi
}

domain() { printf 'gui/%s' "$(id -u)"; }

case "$CMD" in
  print)
    validate_options || exit 1
    render
    ;;
  install)
    validate_options || exit 1
    refuse_worktree || exit 1
    mkdir -p "$PLIST_DIR" "$ARCHIVE_ROOT" || exit 1
    if [ "$LOAD" -eq 1 ]; then
      "$LAUNCHCTL" bootout "$(domain)/$LABEL" >/dev/null 2>&1 || true
    fi
    if ! { render > "$PLIST.tmp.$$" && mv "$PLIST.tmp.$$" "$PLIST"; }; then
      rm -f "$PLIST.tmp.$$"
      echo "error: could not write $PLIST" >&2
      exit 1
    fi
    if [ "$LOAD" -eq 1 ]; then
      "$LAUNCHCTL" bootstrap "$(domain)" "$PLIST" || { echo "error: launchctl could not load $PLIST" >&2; exit 1; }
      echo "installed and loaded $PLIST (daily at $(printf '%02d:%02d' "$HOUR" "$MINUTE") and at login)"
    else
      echo "wrote $PLIST (not loaded)"
    fi
    ;;
  uninstall)
    "$LAUNCHCTL" bootout "$(domain)/$LABEL" >/dev/null 2>&1 || true
    if [ -e "$PLIST" ]; then
      rm -f "$PLIST"
      echo "removed $PLIST"
    else
      echo "no agent installed at $PLIST"
    fi
    ;;
  status)
    if [ -f "$PLIST" ]; then
      echo "plist: $PLIST"
    else
      echo "plist: not installed ($PLIST)"
    fi
    if "$LAUNCHCTL" print "$(domain)/$LABEL" >/dev/null 2>&1; then
      echo "launchd: loaded"
    else
      echo "launchd: not loaded"
    fi
    if [ -f "$ARCHIVE_ROOT/.state/last-run" ]; then
      echo "last run:"
      sed 's/^/  /' "$ARCHIVE_ROOT/.state/last-run"
    else
      echo "last run: none recorded under $ARCHIVE_ROOT"
    fi
    ;;
  -h|--help|'')
    sed -n '2,/^set -u$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
    ;;
  *)
    echo "error: unknown command: $CMD (install, uninstall, status, print)" >&2
    exit 1
    ;;
esac
