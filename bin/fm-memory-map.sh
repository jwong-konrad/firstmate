#!/usr/bin/env bash
# fm-memory-map.sh - validate a memory MAP and split a flat memory file into topic files.
#
# Owner of the mechanics behind data/learnings/ and data/captain/ (MAP.md plus
# topic files). docs/memory-maps.md owns the format and curation contract; this
# header owns the exact commands. Nothing here runs at session start:
# fm-session-start.sh only prints MAP.md when it exists.
#
# Usage:
#   fm-memory-map.sh validate <dir|MAP.md>
#       Check a map directory. Errors (exit 1): MAP.md missing; no "## Topics"
#       section; a Topics line that is not
#           - [<topic>](<file>.md) - read when: <trigger>
#       (the dash may be an em dash or a hyphen); a listed file that does not
#       exist or is listed twice; a topic file in the directory that is not
#       listed; a "## Rules that always apply" line that is not
#           - <lead> -> <file>.md
#       naming a listed topic file. A topic file over 30 KB prints an advisory
#       NOTE (exit stays 0): prune that file, never block work on it.
#   fm-memory-map.sh entries <flat-file>
#       List the entries of a flat file as "<start-line><TAB><bytes><TAB><lead>",
#       the line numbers an assignment file refers to.
#   fm-memory-map.sh split [--allow-unowned] <flat-file> <assignment-file> <out-dir>
#       Move every entry of <flat-file> verbatim into <out-dir>/<topic>.md and
#       write <out-dir>/MAP.md. <flat-file> is never modified and <out-dir> must
#       not exist. Refuses, writing nothing, when an entry is unassigned,
#       assigned twice, assigned to an undeclared topic, or when the independent
#       post-check (entry count, byte total, sorted-line multiset) shows any
#       entry lost or duplicated.
#
# Entry rule: an entry starts at a column-0 line beginning "- **", "- 20YY-"
# or "## 20YY-" and runs, blank lines included, until the next entry start or
# the next other column-0 "# " / "## " heading. Everything outside an entry
# (title, section headings, an old archive index) is residue: it is kept
# verbatim in <out-dir>/.residue.txt so nothing is dropped, and non-blank,
# non-heading residue lines make split refuse unless --allow-unowned is given.
#
# Assignment file (blank lines and "#" lines ignored):
#   title <text>                  heading of the generated MAP.md (optional)
#   topic <name> <trigger>        declare a topic and its read-when trigger
#   <start-line> <topic>          assign the entry starting at that line
#   <start-line> <topic> always   same, and list its lead in the MAP rules
# Topic names are [a-z0-9][a-z0-9-]* and never MAP.

set -u

DASH=$(printf '\342\200\224')
START_RE='^(- \*\*|- 20[0-9][0-9]-|## 20[0-9][0-9]-)'
ADVISORY_BYTES=30720

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }
die() { printf 'fm-memory-map: %s\n' "$*" >&2; exit 1; }

# parse_awk: emits one record per source line: "<kind><TAB><entry-start-line>".
# kind: E = line inside an entry, H = structural heading, B = blank residue,
# U = unowned non-blank residue. Shared by entries and split.
# shellcheck disable=SC2016 # awk program, no shell expansion intended
parse_awk='
function is_start(s) { return s ~ /^- \*\*/ || s ~ /^- 20[0-9][0-9]-/ || s ~ /^## 20[0-9][0-9]-/ }
function is_heading(s) { return s ~ /^# / || s ~ /^## / }
{
  if (is_start($0)) { cur = NR; print "E\t" cur; next }
  if (is_heading($0)) { cur = 0; print "H\t0"; next }
  if (cur) { print "E\t" cur; next }
  if ($0 ~ /^[ \t]*$/) print "B\t0"; else print "U\t0"
}'

cmd_entries() {
  [ $# -eq 1 ] && [ -f "$1" ] || die "entries: need one existing flat file"
  awk '
    function flush() { if (start) printf "%d\t%d\t%s\n", start, bytes, lead }
    /^- \*\*/ || /^- 20[0-9][0-9]-/ || /^## 20[0-9][0-9]-/ {
      flush(); start = NR; bytes = 0; lead = substr($0, 1, 100)
    }
    (/^# / || /^## /) && !(/^## 20[0-9][0-9]-/) { flush(); start = 0 }
    start { bytes += length($0) + 1 }
    END { flush() }
  ' "$1"
}

cmd_validate() {
  [ $# -eq 1 ] || die "validate: need one directory or MAP.md path"
  local dir map errors=0 section="" line topic file rest f base n_topics=0 n_rules=0
  if [ -d "$1" ]; then dir=${1%/}; else dir=$(dirname "$1"); fi
  map="$dir/MAP.md"
  [ -f "$map" ] || { printf 'ERROR: %s does not exist\n' "$map"; exit 1; }
  local listed="" rule_targets="" saw_topics=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '## Topics') section=topics; saw_topics=$((saw_topics + 1)); continue ;;
      '## Rules that always apply') section=rules; continue ;;
      '#'*) section=other; continue ;;
    esac
    case "$section" in
      topics)
        case "$line" in ''|' '*) continue ;; esac
        # shellcheck disable=SC2016
        if [[ "$line" =~ ^-\ \[([a-z0-9][a-z0-9-]*)\]\(([a-z0-9][a-z0-9-]*\.md)\)\ (-|$DASH)\ read\ when:\ .+$ ]]; then
          topic=${BASH_REMATCH[1]}; file=${BASH_REMATCH[2]}
          if [ "$file" != "$topic.md" ]; then
            printf 'ERROR: topic line "%s" must link %s.md\n' "$topic" "$topic"; errors=$((errors + 1))
          fi
          case " $listed " in
            *" $file "*) printf 'ERROR: %s is listed twice\n' "$file"; errors=$((errors + 1)) ;;
          esac
          listed="$listed $file"; n_topics=$((n_topics + 1))
          [ -f "$dir/$file" ] || { printf 'ERROR: listed topic file %s does not exist\n' "$file"; errors=$((errors + 1)); }
        else
          printf 'ERROR: bad Topics line (want "- [<topic>](<file>.md) - read when: <trigger>"): %s\n' "$line"
          errors=$((errors + 1))
        fi ;;
      rules)
        case "$line" in ''|' '*) continue ;; esac
        case "$line" in
          '- '*' -> '*.md)
            rest=${line##* -> }
            rule_targets="$rule_targets $rest"; n_rules=$((n_rules + 1)) ;;
          *) printf 'ERROR: bad rules line (want "- <lead> -> <file>.md"): %s\n' "$line"; errors=$((errors + 1)) ;;
        esac ;;
    esac
  done < "$map"
  [ "$saw_topics" -eq 1 ] || { printf 'ERROR: MAP.md needs exactly one "## Topics" section (found %s)\n' "$saw_topics"; errors=$((errors + 1)); }
  for rest in $rule_targets; do
    case " $listed " in
      *" $rest "*) ;;
      *) printf 'ERROR: rules line points at %s, which is not a listed topic file\n' "$rest"; errors=$((errors + 1)) ;;
    esac
  done
  for f in "$dir"/*.md; do
    [ -e "$f" ] || continue
    base=${f##*/}
    [ "$base" = MAP.md ] && continue
    case " $listed " in
      *" $base "*) ;;
      *) printf 'ERROR: topic file %s is not listed in MAP.md\n' "$base"; errors=$((errors + 1)) ;;
    esac
    if [ "$(wc -c < "$f" | tr -d ' ')" -gt "$ADVISORY_BYTES" ]; then
      printf 'NOTE: %s is past 30 KB; prune or split that file when convenient\n' "$base"
    fi
  done
  if [ "$errors" -gt 0 ]; then
    printf 'INVALID: %s error(s) in %s\n' "$errors" "$map"
    exit 1
  fi
  printf 'OK: %s topics, %s always-loaded rules in %s\n' "$n_topics" "$n_rules" "$map"
}

cmd_split() {
  local allow_unowned=0
  if [ "${1:-}" = --allow-unowned ]; then allow_unowned=1; shift; fi
  [ $# -eq 3 ] || die "split: need <flat-file> <assignment-file> <out-dir>"
  local src=$1 asg=$2 out=${3%/}
  [ -f "$src" ] || die "split: $src is not a file"
  [ -f "$asg" ] || die "split: $asg is not a file"
  [ ! -e "$out" ] || die "split: $out already exists; refusing to overwrite"
  local tmp
  tmp=$(mktemp -d "${out}.split.XXXXXX") || die "split: cannot create a staging directory next to $out"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT

  # Step 1: classify every source line.
  awk "$parse_awk" "$src" > "$tmp/.kinds"
  local unowned
  unowned=$(grep -c '^U' "$tmp/.kinds")
  if [ "$unowned" -gt 0 ] && [ "$allow_unowned" -ne 1 ]; then
    die "split refused: $unowned non-blank line(s) sit outside any entry (title text, an old index); rerun with --allow-unowned to keep them in .residue.txt"
  fi

  # Step 2: assign and write, with every refusal rule inside awk.
  awk -v asg="$asg" -v out="$tmp" -v kinds="$tmp/.kinds" '
    function fail(msg) { print "refused: " msg > "/dev/stderr"; failed = 1; exit 1 }
    BEGIN {
      while ((getline l < asg) > 0) {
        if (l ~ /^[ \t]*(#.*)?$/) continue
        n = split(l, w, /[ \t]+/)
        if (w[1] == "title") { title = substr(l, 7); continue }
        if (w[1] == "topic") {
          if (w[2] !~ /^[a-z0-9][a-z0-9-]*$/ || w[2] == "MAP") fail("bad topic name \"" w[2] "\"")
          if (w[2] in trig) fail("topic \"" w[2] "\" declared twice")
          t = l; sub(/^topic[ \t]+[^ \t]+[ \t]*/, "", t)
          if (t == "") fail("topic \"" w[2] "\" has no trigger")
          trig[w[2]] = t; order[++nt] = w[2]; continue
        }
        if (w[1] !~ /^[0-9]+$/) fail("unparseable assignment line: " l)
        if (w[1] in topic_of) fail("entry at line " w[1] " assigned twice")
        if (!(w[2] in trig)) fail("entry at line " w[1] " assigned to undeclared topic \"" w[2] "\"")
        if (n > 2 && w[3] != "always") fail("unknown flag \"" w[3] "\" on line " w[1])
        topic_of[w[1]] = w[2]; always_of[w[1]] = (n > 2)
      }
      close(asg)
    }
    {
      getline kline < kinds
      split(kline, k, "\t")
      if (k[1] == "E") {
        s = k[2] + 0
        if (!(s in seen_start)) {
          seen_start[s] = 1; n_entries++
          if (!(s in topic_of)) fail("entry at line " s " is unassigned: " substr($0, 1, 60))
          lead[s] = substr($0, 1, 115); sub(/^- /, "", lead[s])
        }
        f = out "/" topic_of[s] ".md"
        print $0 >> f; used[topic_of[s]]++
      } else {
        print $0 >> (out "/.residue.txt")
      }
    }
    END {
      if (failed) exit 1
      for (s in topic_of) if (!(s in seen_start)) fail("assignment names line " s ", which is not an entry start")
      for (i = 1; i <= nt; i++) if (!(order[i] in used)) fail("topic \"" order[i] "\" has no entries")
      m = out "/MAP.md"
      print "# " (title == "" ? "Memory map" : title) > m
      print "" > m
      print "Read the topic file named by a line below only when its trigger applies." > m
      print "" > m
      print "## Rules that always apply" > m
      print "" > m
      for (s = 1; s <= NR; s++) if ((s in seen_start) && always_of[s]) print "- " lead[s] " -> " topic_of[s] ".md" > m
      print "" > m
      print "## Topics" > m
      print "" > m
      for (i = 1; i <= nt; i++) print "- [" order[i] "](" order[i] ".md) '"$DASH"' read when: " trig[order[i]] > m
      printf "%d entries into %d topics\n", n_entries, nt > "/dev/stderr"
    }
  ' "$src" 2>"$tmp/.err" || { cat "$tmp/.err" >&2; die "split refused; nothing written"; }
  cat "$tmp/.err" >&2
  [ -f "$tmp/.residue.txt" ] || : > "$tmp/.residue.txt"

  # Step 3: independent post-check (different tools from the writer).
  local src_entries out_entries src_bytes out_bytes
  src_entries=$(grep -cE "$START_RE" "$src")
  out_entries=0
  local f
  for f in "$tmp"/*.md; do
    [ "${f##*/}" = MAP.md ] && continue
    out_entries=$((out_entries + $(grep -cE "$START_RE" "$f")))
  done
  [ "$src_entries" -eq "$out_entries" ] || die "split refused: $src_entries entries in the source but $out_entries in the topic files; nothing written"
  src_bytes=$(wc -c < "$src" | tr -d ' ')
  out_bytes=$(cat "$tmp/.residue.txt" | wc -c | tr -d ' ')
  for f in "$tmp"/*.md; do
    [ "${f##*/}" = MAP.md ] && continue
    out_bytes=$((out_bytes + $(wc -c < "$f" | tr -d ' ')))
  done
  [ "$src_bytes" -eq "$out_bytes" ] || die "split refused: source is $src_bytes bytes but topic files plus residue hold $out_bytes; nothing written"
  sort "$src" > "$tmp/.sorted-src"
  { for f in "$tmp"/*.md; do [ "${f##*/}" = MAP.md ] || cat "$f"; done; cat "$tmp/.residue.txt"; } | sort > "$tmp/.sorted-out"
  cmp -s "$tmp/.sorted-src" "$tmp/.sorted-out" || die "split refused: the sorted lines of the source and the output differ (an entry was lost or duplicated); nothing written"
  "$0" validate "$tmp" >/dev/null || die "split refused: the generated MAP.md failed validation; nothing written"

  rm -f "$tmp/.plan" "$tmp/.err" "$tmp/.kinds" "$tmp/.sorted-src" "$tmp/.sorted-out"
  mv "$tmp" "$out" || die "split: could not move the staged result into place"
  trap - EXIT
  printf 'split %s: %s entries, %s bytes verified lossless -> %s\n' "$src" "$src_entries" "$src_bytes" "$out"
}

case "${1:-}" in
  validate) shift; cmd_validate "$@" ;;
  entries) shift; cmd_entries "$@" ;;
  split) shift; cmd_split "$@" ;;
  -h|--help|help|'') usage ;;
  *) usage >&2; exit 2 ;;
esac
