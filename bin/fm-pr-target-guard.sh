#!/usr/bin/env bash
# fm-pr-target-guard.sh - refuse work in a checkout whose recorded pull-request
# target is a repository this home must never open a pull request against.
# Usage: fm-pr-target-guard.sh [<repo-path>] [--explain]
#        <repo-path> defaults to the current directory. Any worktree of a repo
#        resolves to that repo's main worktree, which is the key the pipeline
#        records its target under.
#        --explain prints what was inspected and what it resolved to, on a pass
#        as well as a refusal, so a worker can self-check before shipping.
#   Exit 0 = no denied target found (including "nothing here targets anything").
#   Exit 4 = REFUSED, with the reason and the concrete fix on stderr.
#   Exit 2 = usage error (unreadable argument, unknown option). A directory
#           that is not a git work tree is NOT an error: it has no pull-request
#           target at all, so it passes.
#
# THE INCIDENT THIS ENFORCES (data/learnings-archive/no-mistakes-pipeline.md and
# data/access-ledger.md section 1). `kunchenguid/firstmate`, the upstream
# firstmate template, is strictly pull-only for this home. Four pull requests
# were nevertheless opened against it - #856 on 2026-07-22, then #1318, #1319 and
# #1320 on 2026-07-30 - and every one had to be closed within minutes.
#
# The 2026-07-30 sequence is the reason this script reads what it reads. Two
# plausible causes were disproven IN ORDER, each by a fresh wrong-base pull
# request: re-pointing no-mistakes' mirror remote did not stop #1319, and
# `gh repo set-default` inside the task worktree did not stop #1320. The actual
# store is no-mistakes' OWN DATABASE - `repos.upstream_url` in
# `$NM_HOME/state.sqlite` - captured at `no-mistakes init` and refreshed by
# nothing else. Git config and gh config at any level do not reach it. That is
# why this guard reads the database rather than the remotes alone.
#
# The row is correct today, so the live hazard is REGRESSION: anything that
# re-inits or re-clones with an upstream origin silently restores the bad
# target, and the pipeline would open the pull request before a human saw it.
#
# WHAT IT READS, all read-only:
#
#   * The pipeline's own pull-request target for this repo, from
#     `$NM_HOME/state.sqlite` (`NM_HOME` defaults to `~/.no-mistakes`) via
#     `sqlite3 -readonly`, falling back to parsing the `remote:` line of
#     `no-mistakes status` when sqlite3 is unavailable. Both are read paths; the
#     database is never written, and the daemon is never touched.
#   * `origin`, to compare the pipeline's target against the repo this checkout
#     actually tracks.
#   * Every remote's fetch and push URL, to find remotes the operator has marked
#     pull-only (below).
#   * gh's recorded base repository (`remote.<name>.gh-resolved`), which governs
#     a worker's own direct `gh pr create` - a different path from the pipeline's.
#
# THE DENIED SET is the union of two sources, either of which alone is enough:
#
#   1. `config/pr-target-deny` in the active firstmate home - one entry per
#      line, `#` comments and blanks ignored. An entry may be a full URL, a
#      `host/owner/name`, or a bare `owner/name`; a bare `owner/name` matches on
#      any host, because a denylist should err toward matching.
#   2. Any remote whose push URL is set to something that is not a URL or a path
#      at all - the operator's way of saying "fetch from here, never push here".
#      This home's `upstream` remote carries `DISABLED-PULL-ONLY`, applied by
#      hand on 2026-07-30, so this guard has teeth here with no config file at
#      all, and a lost config file cannot silently disarm it.
#
# THE FOUR REFUSALS, each traceable to one of the four wrong-base pull requests:
#
#   R1  The pipeline's target is in the denied set. This is the re-clone
#       regression: origin itself points at the pull-only repo, so the target
#       agrees with origin and only the denied set catches it.
#   R2  The pipeline's target and `origin` are different repositories. This is
#       the stale-row regression that actually opened #1318 and #1319: origin
#       was re-pointed to the fork and the database row still held the value
#       captured before the switch. Skipped when there is no origin, which is a
#       repo that cannot push anywhere in the first place.
#   R3  gh's recorded base repository is in the denied set, so a worker's own
#       `gh pr create` would target it even when the pipeline would not.
#   R4  gh has NO recorded base repository while a remote of this repo is in the
#       denied set. gh then falls back to the fork PARENT, which is exactly how
#       #856 was opened, and that fallback is a server-side fact this guard
#       cannot read locally - so an unset base next to a pull-only remote is
#       refused rather than assumed safe.
#
# FALSE-POSITIVE SURFACE, deliberately kept empty. With no denylist and no
# pull-only remote the denied set is empty, R1/R3/R4 cannot fire, and R2 fires
# only on a genuine disagreement between the pipeline and origin. An ordinary
# upstream contributor who clones the parent and lets no-mistakes init from it
# has target == origin, no disabled push URL, and no denylist: every rule passes.
# That matters because firstmate is a shared template, and `CONTRIBUTING.md`
# describes pull requests to that same parent as the NORMAL contribution route
# for everyone who is not this home.
#
# UNKNOWN IS REFUSED, but only where unknown is meaningful. When no-mistakes has
# never been initialized for this repo - no `no-mistakes` mirror remote and no
# database row - there is no pipeline target to be wrong, so R1/R2 do not apply
# and the gh rules still run. When no-mistakes IS wired up here and the target
# cannot be read, that is refused: a guard that cannot see where the pipeline
# points must not report the checkout as safe. The one deliberate exception is a
# readable database holding no row for this path, which passes - an unusual
# checkout layout whose resolved main worktree does not match the string
# `no-mistakes init` recorded would otherwise refuse every spawn of that project
# over a path-shape difference, which is a worse failure than the gap it closes.
#
# WHAT IT DOES NOT COVER. Both call sites run this BEFORE work starts:
# `bin/fm-spawn.sh` refuses the spawn, and the generated no-mistakes ship brief
# makes it a precondition of invoking the pipeline. A regression introduced
# mid-task, by a worker that re-runs `no-mistakes init` after the spawn gate has
# already passed, is caught by the brief-level check only - which is an
# instruction a worker follows, not a control the runtime enforces. Closing that
# remaining gap needs a hook inside no-mistakes' own push path, or the
# platform-level fork detachment tracked as `private-fork-migration-p9`, neither
# of which is firstmate's to write.
#
# Called by bin/fm-spawn.sh (every non-secondmate spawn) and by the generated
# no-mistakes ship brief. docs/configuration.md owns the `config/pr-target-deny`
# schema; this header owns the guard's behavior.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
}

# The exit code every refusal uses, distinct enough for a caller or a test to
# recognize as "the pull-request target guard refused" rather than a usage error.
FM_PR_TARGET_REFUSE_EXIT=4

REPO=
EXPLAIN=0
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --explain) EXPLAIN=1 ;;
    --*) echo "error: unknown option $arg" >&2; exit 2 ;;
    *)
      [ -z "$REPO" ] || { echo "error: at most one repo path" >&2; exit 2; }
      REPO=$arg
      ;;
  esac
done
REPO=${REPO:-.}
[ -d "$REPO" ] || { echo "error: not a directory: $REPO" >&2; exit 2; }

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DENY_FILE="$CONFIG/pr-target-deny"
NM_HOME="${NM_HOME:-$HOME/.no-mistakes}"
NM_DB="$NM_HOME/state.sqlite"

# The delimiter inside the denied-set accumulators. A repository identity, a git
# remote name, and a filesystem path can all contain a tab or a space; none can
# contain a newline, and '|' is not valid in a remote name and never appears in a
# normalized identity, so it separates the two halves of a record unambiguously.
SEP='|'

note() {  # only under --explain; the quiet pass path prints nothing at all
  [ "$EXPLAIN" -eq 1 ] || return 0
  printf '%s\n' "$1"
}

lower() {
  printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'
}

strip_git_suffix() {
  local p=$1
  while [ "${p%/}" != "$p" ]; do p=${p%/}; done
  p=${p%.git}
  while [ "${p%/}" != "$p" ]; do p=${p%/}; done
  printf '%s\n' "$p"
}

# refuse <rule> <headline> <fix>: the single refusal shape. Everything goes to
# stderr so a caller capturing stdout still sees it, and the fix is always a
# concrete command or decision rather than "investigate".
refuse() {
  {
    printf 'REFUSED (%s): %s\n' "$1" "$2"
    printf '  repo: %s\n' "$MAIN_WT"
    printf '  fix:  %s\n' "$3"
    printf '  this guard exists because pull requests have reached a pull-only repository four times; see bin/fm-pr-target-guard.sh\n'
  } >&2
  exit "$FM_PR_TARGET_REFUSE_EXIT"
}

# A directory that is not a git work tree has no remotes, no gh base repository,
# and no row no-mistakes could key to it, so it has no pull-request target to be
# wrong. That is a determination, not a failed check: it passes rather than
# refusing, so a caller that hands this a directory before it is a checkout gets
# its own clearer error instead of a pull-request-target refusal it cannot act on.
if ! git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  note "repo:            $REPO"
  note 'result:          not a git work tree, so there is no pull-request target here'
  exit 0
fi

# The repo's MAIN worktree, which is the path no-mistakes records its row under.
# A task runs in a linked worktree, so resolving this is what lets a crewmate run
# exactly the check its spawn ran. --git-common-dir may come back relative, in
# which case it is relative to the -C directory. Both the physical and the
# logical form are kept: the database holds whatever string `no-mistakes init`
# saw, which is the logical path when the checkout sits under a symlink.
MAIN_WT=
MAIN_WT_LOGICAL=
resolve_main_worktree() {
  local common
  common=$(git -C "$REPO" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) ;;
    *) common="$REPO/$common" ;;
  esac
  MAIN_WT=$(cd "$common" 2>/dev/null && pwd -P) || return 1
  MAIN_WT_LOGICAL=$(cd "$common" 2>/dev/null && pwd) || MAIN_WT_LOGICAL=$MAIN_WT
  MAIN_WT=${MAIN_WT%/.git}
  MAIN_WT_LOGICAL=${MAIN_WT_LOGICAL%/.git}
}
resolve_main_worktree \
  || { echo "error: could not resolve the main worktree of $REPO" >&2; exit 2; }

# --- repository identity ----------------------------------------------------

# identity <url>: echo a comparable "<host>/<owner>/<name>" for a remote URL, or
# "local/<path>" for a filesystem remote, and return 1 for anything that is not a
# URL or a path at all. That failure is load-bearing: a push URL this cannot
# parse is how the operator marks a remote pull-only, so it must not be
# generously coerced into looking like a real target.
identity() {
  local url=$1 rest host path
  url=${url#"${url%%[![:space:]]*}"}
  url=${url%"${url##*[![:space:]]}"}
  [ -n "$url" ] || return 1
  case "$url" in
    file://*)
      path=$(strip_git_suffix "${url#file://}")
      [ -n "$path" ] || return 1
      printf 'local/%s\n' "$path"
      return 0
      ;;
    /*)
      path=$(strip_git_suffix "$url")
      [ -n "$path" ] || return 1
      printf 'local/%s\n' "$path"
      return 0
      ;;
    *://*)
      rest=${url#*://}
      # Drop any user[:password]@, but only when the '@' is in the authority
      # segment - an '@' later in the path is part of the path, not credentials.
      case "${rest%%/*}" in
        *@*) rest=${rest#*@} ;;
      esac
      path=${rest#*/}
      [ "$rest" != "$path" ] || return 1
      host=${rest%%/*}
      host=${host%%:*}           # drop any :port
      ;;
    *:*)
      # scp-like: [user@]host:path, which has no "//" anywhere.
      case "$url" in *//*) return 1 ;; esac
      host=${url%%:*}
      host=${host#*@}
      path=${url#*:}
      path=${path#/}
      ;;
    *) return 1 ;;
  esac
  [ -n "$host" ] || return 1
  [ -n "$path" ] || return 1
  path=$(strip_git_suffix "$path")
  [ -n "$path" ] || return 1
  lower "$host/$path"
}

# --- the denied set ---------------------------------------------------------
#
# Two newline-separated accumulators of "<entry>|<why>" records. DENY_IDS holds
# full "<host>/<owner>/<name>" identities matched exactly; DENY_SUFFIXES holds
# bare "owner/name" denylist entries, matched on any host.

DENY_IDS=
DENY_SUFFIXES=

deny_add() {  # <identity> <why>
  DENY_IDS="$DENY_IDS$1$SEP$2
"
}

deny_add_suffix() {  # <owner/name> <why>
  DENY_SUFFIXES="$DENY_SUFFIXES$1$SEP$2
"
}

# deny_reason <identity>: echo why <identity> is denied, or return 1.
deny_reason() {
  local id=$1 line entry
  [ -n "$id" ] || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    entry=${line%%"$SEP"*}
    [ "$entry" = "$id" ] || continue
    printf '%s\n' "${line#*"$SEP"}"
    return 0
  done <<EOF
$DENY_IDS
EOF
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    entry=${line%%"$SEP"*}
    case "$id" in
      "$entry"|*/"$entry")
        printf '%s\n' "${line#*"$SEP"}"
        return 0
        ;;
    esac
  done <<EOF
$DENY_SUFFIXES
EOF
  return 1
}

# Source 1: the home's denylist file.
if [ -f "$DENY_FILE" ]; then
  while IFS= read -r deny_line || [ -n "$deny_line" ]; do
    deny_line=${deny_line%%#*}
    deny_line=${deny_line#"${deny_line%%[![:space:]]*}"}
    deny_line=${deny_line%"${deny_line##*[![:space:]]}"}
    [ -n "$deny_line" ] || continue
    if deny_id=$(identity "$deny_line"); then
      deny_add "$deny_id" "listed in $DENY_FILE"
    else
      # No scheme and no host: a bare owner/name, or a host/owner/name written
      # plainly. Two segments match on any host; three or more are already a
      # full identity.
      deny_id=$(lower "$(strip_git_suffix "$deny_line")")
      case "$deny_id" in
        */*/*) deny_add "$deny_id" "listed in $DENY_FILE" ;;
        */*) deny_add_suffix "$deny_id" "listed in $DENY_FILE" ;;
        *) echo "warning: ignoring unreadable entry in $DENY_FILE: $deny_line" >&2 ;;
      esac
    fi
  done < "$DENY_FILE"
fi

# Source 2: remotes the operator marked pull-only by breaking the push URL.
# REMOTE_IDS records every remote's fetch identity, which rule R4 walks.
REMOTE_IDS=
while IFS= read -r remote; do
  [ -n "$remote" ] || continue
  fetch_url=$(git -C "$REPO" config --get "remote.$remote.url" 2>/dev/null || true)
  [ -n "$fetch_url" ] || continue
  fetch_id=$(identity "$fetch_url") || continue
  REMOTE_IDS="$REMOTE_IDS$fetch_id$SEP$remote
"
  push_url=$(git -C "$REPO" config --get "remote.$remote.pushurl" 2>/dev/null || true)
  [ -n "$push_url" ] || continue
  identity "$push_url" >/dev/null 2>&1 && continue
  deny_add "$fetch_id" "the '$remote' remote is marked pull-only (its push URL is '$push_url')"
done <<EOF
$(git -C "$REPO" remote 2>/dev/null || true)
EOF

# --- the pipeline's recorded pull-request target ----------------------------

ORIGIN_URL=$(git -C "$REPO" config --get remote.origin.url 2>/dev/null || true)
ORIGIN_ID=
[ -z "$ORIGIN_URL" ] || ORIGIN_ID=$(identity "$ORIGIN_URL" 2>/dev/null || true)

# no-mistakes is wired up here when it has planted its mirror remote. That is a
# git-only signal, so it survives a database this host cannot open - which is the
# whole point: it lets "initialized but unreadable" refuse instead of passing as
# "never initialized".
NM_REMOTE=$(git -C "$REPO" config --get remote.no-mistakes.url 2>/dev/null || true)

sql_quote() {
  printf '%s\n' "$1" | sed "s/'/''/g"
}

TARGET_URL=
TARGET_SOURCE=
DB_USABLE=0
if [ -f "$NM_DB" ] && command -v sqlite3 >/dev/null 2>&1; then
  if db_out=$(sqlite3 -readonly "$NM_DB" \
      "select upstream_url from repos where working_path in ('$(sql_quote "$MAIN_WT")','$(sql_quote "$MAIN_WT_LOGICAL")') limit 1;" 2>/dev/null); then
    DB_USABLE=1
    TARGET_URL=$db_out
    [ -z "$TARGET_URL" ] || TARGET_SOURCE="no-mistakes database ($NM_DB)"
  fi
fi

# The supported-command fallback for a host without sqlite3. `no-mistakes status`
# prints the pipeline's target on its `remote:` line, verified 2026-09-11 against
# v1.37.0 in two repos whose recorded rows differ.
if [ "$DB_USABLE" != 1 ] && command -v no-mistakes >/dev/null 2>&1; then
  if status_out=$(cd "$REPO" && no-mistakes status 2>/dev/null); then
    while IFS= read -r status_line; do
      case "$status_line" in
        *remote:*)
          status_line=${status_line#*remote:}
          status_line=${status_line#"${status_line%%[![:space:]]*}"}
          status_line=${status_line%"${status_line##*[![:space:]]}"}
          [ -n "$status_line" ] || continue
          TARGET_URL=$status_line
          TARGET_SOURCE='no-mistakes status'
          break
          ;;
      esac
    done <<EOF
$status_out
EOF
  fi
fi

note "repo:            $MAIN_WT"
note "origin:          ${ORIGIN_ID:-<none>}"
note "pipeline target: ${TARGET_URL:-<none recorded>}${TARGET_SOURCE:+ [$TARGET_SOURCE]}"

if [ -n "$TARGET_URL" ]; then
  TARGET_ID=$(identity "$TARGET_URL") || TARGET_ID=
  if [ -z "$TARGET_ID" ]; then
    refuse "unreadable target" \
      "no-mistakes records '$TARGET_URL' as this repo's pull-request target, which is not a repository URL this guard can check" \
      "re-run 'no-mistakes init' in $MAIN_WT so the target is recaptured from origin"
  fi

  # R1: the pipeline points straight at a denied repository.
  if deny_why=$(deny_reason "$TARGET_ID"); then
    refuse R1 \
      "no-mistakes would open this repo's pull requests against $TARGET_ID, which is denied: $deny_why" \
      "point origin at the repository this work should land in, then re-run 'no-mistakes init' in $MAIN_WT and confirm 'no-mistakes status' shows the right remote"
  fi

  # R2: the pipeline and origin disagree, which is the stale-row regression.
  if [ -n "$ORIGIN_ID" ] && [ "$ORIGIN_ID" != "$TARGET_ID" ]; then
    refuse R2 \
      "no-mistakes would open this repo's pull requests against $TARGET_ID, but origin is $ORIGIN_ID - the recorded target is stale" \
      "re-run 'no-mistakes init' in $MAIN_WT; it recaptures the target from origin, and nothing else refreshes it"
  fi
elif [ -n "$NM_REMOTE" ] && [ "$DB_USABLE" != 1 ]; then
  # Wired up here, yet the target could not be read. Unknown is not safe.
  refuse "unreadable target" \
    "no-mistakes is initialized in this repo (its mirror remote is present) but its recorded pull-request target could not be read" \
    "install sqlite3 so $NM_DB can be read, or run 'no-mistakes status' in $MAIN_WT and confirm its remote yourself"
fi

# --- gh's own base repository (a worker's direct `gh pr create`) -------------

GH_RESOLVED=
GH_REMOTE=
while IFS= read -r gh_line; do
  [ -n "$gh_line" ] || continue
  gh_key=${gh_line%% *}
  gh_val=${gh_line#* }
  [ "$gh_key" != "$gh_val" ] || continue
  GH_REMOTE=${gh_key#remote.}
  GH_REMOTE=${GH_REMOTE%.gh-resolved}
  GH_RESOLVED=$gh_val
  break
done <<EOF
$(git -C "$REPO" config --get-regexp '^remote\..*\.gh-resolved$' 2>/dev/null || true)
EOF

GH_BASE_ID=
if [ -n "$GH_RESOLVED" ]; then
  if [ "$GH_RESOLVED" = base ]; then
    # "base" means this remote IS the base repository.
    gh_url=$(git -C "$REPO" config --get "remote.$GH_REMOTE.url" 2>/dev/null || true)
    [ -z "$gh_url" ] || GH_BASE_ID=$(identity "$gh_url" 2>/dev/null || true)
  else
    # gh writes OWNER/REPO for github.com and HOST/OWNER/REPO elsewhere.
    GH_BASE_ID=$(lower "$(strip_git_suffix "$GH_RESOLVED")")
    case "$GH_BASE_ID" in
      */*/*) ;;
      */*) GH_BASE_ID="github.com/$GH_BASE_ID" ;;
      *) GH_BASE_ID= ;;
    esac
  fi
fi
note "gh base repo:    ${GH_BASE_ID:-<unset>}"

# R3: gh would target a denied repository directly.
if [ -n "$GH_BASE_ID" ] && deny_why=$(deny_reason "$GH_BASE_ID"); then
  refuse R3 \
    "gh would open this repo's pull requests against $GH_BASE_ID, which is denied: $deny_why" \
    "run 'gh repo set-default <owner>/<name>' in $MAIN_WT naming the repository this work should land in"
fi

# R4: gh has no recorded base while a denied repository is a remote here, so its
# unreadable fork-parent fallback could reach that repository.
if [ -z "$GH_BASE_ID" ]; then
  gh_fix_target=${ORIGIN_ID#*/}
  [ -n "$ORIGIN_ID" ] || gh_fix_target='<owner>/<name>'
  while IFS= read -r remote_line; do
    [ -n "$remote_line" ] || continue
    remote_id=${remote_line%%"$SEP"*}
    remote_name=${remote_line#*"$SEP"}
    deny_why=$(deny_reason "$remote_id") || continue
    refuse R4 \
      "gh has no recorded base repository for this checkout, and its '$remote_name' remote is $remote_id, which is denied: $deny_why - gh then falls back to the fork parent, which cannot be checked from here" \
      "run 'gh repo set-default $gh_fix_target' in $MAIN_WT so gh can never default to the denied repository"
  done <<EOF
$REMOTE_IDS
EOF
fi

note 'result:          no denied pull-request target'
exit 0
