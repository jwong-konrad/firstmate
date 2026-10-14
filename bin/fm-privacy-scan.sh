#!/usr/bin/env bash
# fm-privacy-scan.sh - refuse captain-private details and secret-shaped values in
# text a repository is about to publish.
#
# Usage:
#   fm-privacy-scan.sh --tracked
#       Scan every tracked text file of the repository at the current directory.
#   fm-privacy-scan.sh --range <base>..<head>
#       Scan the lines added between the merge-base of <base> and <head> and
#       <head>, plus the message of every commit in <base>..<head>.
#   fm-privacy-scan.sh --stdin [--label <name>]
#       Scan text on stdin, for a PR description or a commit message before it
#       is published. Findings are located as <name>:<line> (default "stdin").
#   fm-privacy-scan.sh --pre-push <remote> [<url>]
#       Git pre-push hook mode: read git's "<local-ref> <local-sha> <remote-ref>
#       <remote-sha>" lines on stdin and scan every outgoing commit, meaning each
#       commit not already on a remote-tracking ref of <remote>, as --range does.
#
# Options:
#   --local <file>  site-specific extra patterns (default: $FM_PRIVACY_LOCAL,
#                   else <FM_HOME or this script's repo>/config/privacy-patterns.local
#                   when it exists). Same format as .privacy-patterns.
#   --no-local      ignore any local pattern file.
#   -h, --help      print this header.
#
# Patterns: .privacy-patterns beside this script's bin/ is the tracked, generic
# set; that file's header owns the line format. The local file adds terms that
# must never be published themselves, such as a hostname or a client name.
#
# Allowlist: .privacy-allow at the root of the SCANNED repository, one entry per
# line, blank lines and # comments ignored:
#   <path-glob> <pattern-name|*> [<extended-regex>]
# A finding in a file matching <path-glob> (bash glob, repo-relative) for that
# pattern is dropped, and when the regex is given only if the matched text also
# matches it. Keep entries narrow and say why in a comment. The allowlist never
# applies to --stdin text or to commit messages. .privacy-patterns and
# .privacy-allow themselves are never scanned, because they hold patterns.
#
# Output: one line per finding on stdout, "<location>: <pattern-name>: <masked>",
# where <masked> shows only the first few characters of the match and its
# length, so a report never republishes the value it found.
# Exit status: 0 clean, 1 findings, 2 usage or configuration error.
#
# Local pre-push hook (opt-in, never installed automatically): write this file as
# "$(git rev-parse --git-path hooks)/pre-push" and make it executable:
#   #!/bin/sh
#   exec "$(git rev-parse --show-toplevel)/bin/fm-privacy-scan.sh" --pre-push "$@"
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATTERNS_FILE="$CODE_ROOT/.privacy-patterns"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

die() {
  printf 'fm-privacy-scan: %s\n' "$*" >&2
  exit 2
}

MODE=
RANGE=
LABEL=stdin
REMOTE=
LOCAL_FILE=${FM_PRIVACY_LOCAL:-}
USE_LOCAL=1

while [ $# -gt 0 ]; do
  case "$1" in
    --tracked) MODE=tracked ;;
    --range) MODE=range; RANGE=${2:-}; shift ;;
    --stdin) MODE=stdin ;;
    --label) LABEL=${2:-}; shift ;;
    --pre-push) MODE=pre-push; REMOTE=${2:-}; shift; [ $# -ge 2 ] && shift ;;
    --local) LOCAL_FILE=${2:-}; shift ;;
    --no-local) USE_LOCAL=0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

[ -n "$MODE" ] || die "choose one of --tracked, --range, --stdin, --pre-push (see --help)"
[ -r "$PATTERNS_FILE" ] || die "pattern file not readable: $PATTERNS_FILE"

if [ "$USE_LOCAL" = 1 ] && [ -z "$LOCAL_FILE" ]; then
  candidate="${FM_HOME:-$CODE_ROOT}/config/privacy-patterns.local"
  [ -f "$candidate" ] && LOCAL_FILE=$candidate
fi
[ "$USE_LOCAL" = 1 ] || LOCAL_FILE=
if [ -n "$LOCAL_FILE" ] && [ ! -r "$LOCAL_FILE" ]; then
  die "local pattern file not readable: $LOCAL_FILE"
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-privacy-scan.XXXXXX") || die "cannot create a temp dir"
trap 'rm -rf "$WORK"' EXIT
LOCS="$WORK/locs"     # one location per corpus line
TEXT="$WORK/text"     # the corpus, line-aligned with LOCS
PATS="$WORK/pats"     # name<TAB>flags<TAB>regex
EXCEPT="$WORK/except" # name<TAB>regex
ALLOW="$WORK/allow"   # glob<TAB>name<TAB>regex
: > "$LOCS"; : > "$TEXT"; : > "$PATS"; : > "$EXCEPT"; : > "$ALLOW"

# load_patterns <file>: validate and append one pattern file's entries.
load_patterns() {
  local file=$1 n=0 line name re flags
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in ''|'#'*) continue ;; esac
    line=${line#"${line%%[![:space:]]*}"}
    [ -n "$line" ] || continue
    name=${line%%[[:space:]]*}
    re=${line#"$name"}
    re=${re#"${re%%[![:space:]]*}"}
    if [ "$name" = allow ]; then
      name=${re%%[[:space:]]*}
      re=${re#"$name"}
      re=${re#"${re%%[![:space:]]*}"}
      [ -n "$re" ] || die "$file:$n: allow needs a name and a regex"
      printf '%s\t%s\n' "$name" "$re" >> "$EXCEPT"
      continue
    fi
    flags=-E
    case "$name" in */i) name=${name%/i}; flags=-Ei ;; esac
    case "$name" in
      ''|*[!a-z0-9-]*) die "$file:$n: pattern name must be [a-z0-9-]: '$name'" ;;
    esac
    [ -n "$re" ] || die "$file:$n: pattern '$name' has no regex"
    grep -E -e "$re" </dev/null >/dev/null 2>&1
    [ $? -le 1 ] || die "$file:$n: pattern '$name' is not a valid extended regex"
    printf '%s\t%s\t%s\n' "$name" "$flags" "$re" >> "$PATS"
  done < "$file"
}

load_patterns "$PATTERNS_FILE"
[ -n "$LOCAL_FILE" ] && load_patterns "$LOCAL_FILE"

# --- corpus builders ---------------------------------------------------------

repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || die "not inside a git repository"
}

load_allowlist() {
  local file="$1/.privacy-allow" n=0 line glob name re
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line#"${line%%[![:space:]]*}"}
    case "$line" in ''|'#'*) continue ;; esac
    glob=${line%%[[:space:]]*}
    re=${line#"$glob"}
    re=${re#"${re%%[![:space:]]*}"}
    name=${re%%[[:space:]]*}
    re=${re#"$name"}
    re=${re#"${re%%[![:space:]]*}"}
    [ -n "$name" ] || die "$file:$n: expected '<path-glob> <pattern-name|*> [<regex>]'"
    printf '%s\t%s\t%s\n' "$glob" "$name" "$re" >> "$ALLOW"
  done < "$file"
}

# Every tracked text line, located as path:line.
# A failed git command dies rather than leaving an empty corpus that would pass.
add_tracked() {
  local rc=0
  git grep -I -n -z -e '' -- . ':(exclude).privacy-patterns' ':(exclude).privacy-allow' \
    > "$WORK/raw" || rc=$?
  [ "$rc" -le 1 ] || die "git grep failed (exit $rc)"
  tr '\000' '\034' < "$WORK/raw" \
    | awk -F "$(printf '\034')" -v locs="$LOCS" -v text="$TEXT" '{
        print $1 ":" $2 > locs
        print substr($0, length($1) + length($2) + 3) > text
      }'
}

# add_range <base> <head>: lines added since their merge-base, plus messages.
add_range() {
  local base=$1 head=$2 mb sha
  git rev-parse --verify --quiet "$head^{commit}" >/dev/null || die "unknown commit: $head"
  if [ -z "$base" ]; then
    mb=$(git hash-object -t tree /dev/null)
  else
    git rev-parse --verify --quiet "$base^{commit}" >/dev/null || die "unknown commit: $base"
    mb=$(git merge-base "$base" "$head") || die "no merge-base for $base and $head"
  fi
  git diff --no-color --no-ext-diff --no-renames -U0 "$mb" "$head" -- . \
      ':(exclude).privacy-patterns' ':(exclude).privacy-allow' > "$WORK/diff" \
    || die "git diff failed for $mb..$head"
  awk -v locs="$LOCS" -v text="$TEXT" '
        # "+++ " names the file only inside a header, so an added line whose
        # own text starts with "++ " is still scanned as content.
        /^diff --git / { hdr = 1; next }
        hdr && /^\+\+\+ / { file = substr($0, 5); sub(/^b\//, "", file); next }
        /^@@ / {
          hdr = 0; split($3, a, ","); line = substr(a[1], 2) + 0; next
        }
        !hdr && /^\+/ && file != "/dev/null" {
          print file ":" line >> locs; print substr($0, 2) >> text; line++
        }' "$WORK/diff"
  if [ -z "$base" ]; then
    git rev-list "$head" > "$WORK/revs"
  else
    git rev-list "$base..$head" > "$WORK/revs"
  fi || die "git rev-list failed for $base..$head"
  while read -r sha; do
    git log -1 --format=%B "$sha" \
      | awk -v locs="$LOCS" -v text="$TEXT" -v l="commit ${sha%"${sha#????????????}"}" '{
          print l ":" NR >> locs; print >> text
        }'
  done < "$WORK/revs"
}

add_stdin() {
  awk -v locs="$LOCS" -v text="$TEXT" -v l="$LABEL" '{ print l ":" NR > locs; print > text }'
}

add_pre_push() {
  local lref lsha rref rsha zero=0000000000000000000000000000000000000000 oldest base
  [ -n "$REMOTE" ] || die "--pre-push needs the remote name git passes the hook"
  while read -r lref lsha rref rsha; do
    : "$lref" "$rref" "$rsha"
    [ -n "$lsha" ] && [ "$lsha" != "$zero" ] || continue
    oldest=$(git rev-list --reverse "$lsha" --not --remotes="$REMOTE" | head -n 1)
    [ -n "$oldest" ] || continue
    base=$(git rev-parse --verify --quiet "$oldest^" || true)
    add_range "$base" "$lsha"
  done
}

ROOT=
case "$MODE" in
  tracked)
    ROOT=$(repo_root); cd "$ROOT" || exit 2
    load_allowlist "$ROOT"; add_tracked ;;
  range)
    case "$RANGE" in *..*) ;; *) die "--range needs <base>..<head>" ;; esac
    case "$RANGE" in *...*) die "--range takes two dots; the merge-base is applied already" ;; esac
    ROOT=$(repo_root); cd "$ROOT" || exit 2
    load_allowlist "$ROOT"; add_range "${RANGE%%..*}" "${RANGE#*..}" ;;
  stdin) add_stdin ;;
  pre-push)
    ROOT=$(repo_root); cd "$ROOT" || exit 2
    load_allowlist "$ROOT"; add_pre_push ;;
esac

# --- matching ----------------------------------------------------------------

HITS="$WORK/hits" # lineno<TAB>name<TAB>match
: > "$HITS"
while IFS="$(printf '\t')" read -r name flags re; do
  rc=0
  grep -n -o "$flags" -e "$re" "$TEXT" > "$WORK/matches" || rc=$?
  [ "$rc" -le 1 ] || die "grep failed for pattern '$name' (exit $rc)"
  awk -v name="$name" '{ i = index($0, ":"); print substr($0, 1, i - 1) "\t" name "\t" substr($0, i + 1) }' \
    "$WORK/matches" >> "$HITS"
done < "$PATS"

# mask <text>: a few leading characters and the length, never the whole value.
mask() {
  local v=$1 len keep
  len=${#v}
  keep=$((len / 4))
  [ "$keep" -le 6 ] || keep=6
  printf '%s*** (%s chars)' "${v:0:$keep}" "$len"
}

excepted() { # <name> <value>
  local n re
  while IFS="$(printf '\t')" read -r n re; do
    [ "$n" = "$1" ] && [[ $2 =~ $re ]] && return 0
  done < "$EXCEPT"
  return 1
}

allowed() { # <path> <name> <value>
  local glob n re
  while IFS="$(printf '\t')" read -r glob n re; do
    # shellcheck disable=SC2053
    [[ $1 == $glob ]] || continue
    [ "$n" = '*' ] || [ "$n" = "$2" ] || continue
    [ -z "$re" ] || [[ $3 =~ $re ]] || continue
    return 0
  done < "$ALLOW"
  return 1
}

FOUND=0
OUT="$WORK/out"
: > "$OUT"
sort -t "$(printf '\t')" -k1,1n -s "$HITS" \
  | awk -F '\t' 'NR == FNR { loc[FNR] = $0; next } { print loc[$1] "\t" $2 "\t" $3 }' "$LOCS" - \
  | while IFS="$(printf '\t')" read -r loc name value; do
      # Drop the boundary character some patterns consume before the value.
      value=${value#[!A-Za-z0-9/_-]}
      excepted "$name" "$value" && continue
      path=${loc%:*}
      case "$path" in
        "commit "*|"$LABEL") ;;
        *) [ "$MODE" != stdin ] && allowed "$path" "$name" "$value" && continue ;;
      esac
      printf '%s: %s: %s\n' "$loc" "$name" "$(mask "$value")"
    done > "$OUT"

if [ -s "$OUT" ]; then
  cat "$OUT"
  FOUND=$(wc -l < "$OUT" | tr -d ' ')
  printf 'fm-privacy-scan: %s finding(s); remove the value, or allowlist a deliberate fixture in .privacy-allow\n' "$FOUND" >&2
  exit 1
fi
exit 0
