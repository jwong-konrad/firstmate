#!/usr/bin/env bash
# tests/fm-memory-map.test.sh - behavior tests for bin/fm-memory-map.sh, the
# validator and flat-file splitter behind data/learnings/ and data/captain/.
#
# Coverage:
#   - validate: a good map passes; a missing listed file, an unlisted topic
#     file, a malformed Topics line, a duplicate listing, and a rules line
#     naming an unlisted file are each refused; a topic file past 30 KB is an
#     advisory note, not an error
#   - split: entries move verbatim (byte-identical when re-concatenated), the
#     generated MAP validates, always-loaded rules come from the entry's own
#     lead, and the flat source is untouched
#   - split refusals, each writing nothing: unassigned entry, entry assigned
#     twice, undeclared topic, assignment naming a non-entry line, empty
#     declared topic, text outside any entry without --allow-unowned, and an
#     existing output directory
#   - the independent post-check refusing output from a deliberately lossy writer
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MM="$ROOT/bin/fm-memory-map.sh"
TMP_ROOT=$(fm_test_tmproot fm-memory-map-tests)

# write_flat <path>: a small flat file with a title, a section heading, plain
# dated bullets (one multi-line), a dated "## " section with an inner bullet,
# and a trailing non-dated section with index-style lines. Entry starts at
# lines 7, 9 and 11.
write_flat() {
  cat > "$1" <<'FLAT'
# Learnings

Intro text.

## Section A

- 2026-01-01 First learning about merges.
  continued line
- 2026-01-02 Second about tools.

## 2026-02-03 Long dated section

body line
- inner bullet
## Archive index
- [x](y.md) - old
FLAT
}

# write_assignment <path> [extra lines]: the valid assignment for write_flat.
write_assignment() {
  local p=$1
  shift
  {
    printf '%s\n' '# comment lines and blanks are ignored' '' 'title Test map'
    printf '%s\n' 'topic merging Before any merge' 'topic tools When tools misbehave'
    printf '%s\n' '7 merging always' '9 tools' '11 tools'
    [ $# -eq 0 ] || printf '%s\n' "$@"
  } > "$p"
}

# make_map <dir>: a valid two-topic map directory.
make_map() {
  mkdir -p "$1"
  cat > "$1/MAP.md" <<'MAP'
# Map

## Rules that always apply

- Never do the dangerous thing -> merging.md

## Topics

- [merging](merging.md) - read when: before any merge
- [tools](tools.md) — read when: a tool misbehaves
MAP
  printf '%s\n' '- 2026-01-01 Never do the dangerous thing.' > "$1/merging.md"
  printf '%s\n' '- 2026-01-02 A tool note.' > "$1/tools.md"
}

# --- validate -----------------------------------------------------------------

test_validate_accepts_good_map() {
  local d="$TMP_ROOT/good" out
  make_map "$d"
  out=$("$MM" validate "$d") || fail "a valid map was refused: $out"
  assert_contains "$out" "OK: 2 topics, 1 always-loaded rules" "validate did not report the topic and rule counts"
  "$MM" validate "$d/MAP.md" >/dev/null || fail "validate did not accept a MAP.md path"
  pass "validate accepts a good map, with a hyphen or em dash"
}

test_validate_refuses_missing_listed_file() {
  local d="$TMP_ROOT/missing" out
  make_map "$d"
  rm "$d/tools.md"
  out=$("$MM" validate "$d" 2>&1) && fail "validate accepted a listed topic file that does not exist"
  assert_contains "$out" "listed topic file tools.md does not exist" "validate did not name the missing file"
  pass "validate refuses a listed file that does not exist"
}

test_validate_refuses_unlisted_topic_file() {
  local d="$TMP_ROOT/unlisted" out
  make_map "$d"
  printf '%s\n' '- 2026-01-03 stray' > "$d/stray.md"
  out=$("$MM" validate "$d" 2>&1) && fail "validate accepted a topic file the map does not list"
  assert_contains "$out" "topic file stray.md is not listed" "validate did not name the unlisted file"
  pass "validate refuses a topic file that is not listed"
}

test_validate_refuses_bad_topics_line() {
  local d="$TMP_ROOT/badline" out
  make_map "$d"
  printf '%s\n' '- tools: read when a tool misbehaves' >> "$d/MAP.md"
  out=$("$MM" validate "$d" 2>&1) && fail "validate accepted a malformed Topics line"
  assert_contains "$out" "bad Topics line" "validate did not report the malformed line"
  pass "validate refuses a Topics line that is not in the map line format"
}

test_validate_refuses_duplicate_and_bad_rules() {
  local d="$TMP_ROOT/dup" out
  make_map "$d"
  printf '%s\n' '- [merging](merging.md) - read when: again' >> "$d/MAP.md"
  out=$("$MM" validate "$d" 2>&1) && fail "validate accepted a topic listed twice"
  assert_contains "$out" "merging.md is listed twice" "validate did not report the duplicate listing"

  d="$TMP_ROOT/badrule"
  make_map "$d"
  sed -i.bak 's/-> merging.md/-> ghost.md/' "$d/MAP.md"
  out=$("$MM" validate "$d" 2>&1) && fail "validate accepted a rules line naming an unlisted file"
  assert_contains "$out" "ghost.md, which is not a listed topic file" "validate did not report the dangling rule target"
  pass "validate refuses duplicate listings and dangling rule targets"
}

test_validate_refuses_missing_map_and_topics_section() {
  local d="$TMP_ROOT/nomap" out
  mkdir -p "$d"
  out=$("$MM" validate "$d" 2>&1) && fail "validate accepted a directory with no MAP.md"
  assert_contains "$out" "MAP.md does not exist" "validate did not report the missing MAP.md"

  printf '%s\n' '# Map' > "$d/MAP.md"
  out=$("$MM" validate "$d" 2>&1) && fail "validate accepted a MAP.md with no Topics section"
  assert_contains "$out" 'exactly one "## Topics" section' "validate did not require a Topics section"
  pass "validate refuses a missing MAP.md and a missing Topics section"
}

test_validate_large_topic_file_is_advisory() {
  local d="$TMP_ROOT/large" out
  make_map "$d"
  head -c 31000 /dev/zero | tr '\0' 'x' >> "$d/tools.md"
  out=$("$MM" validate "$d") || fail "a large topic file made validate fail: $out"
  assert_contains "$out" "NOTE: tools.md is past 30 KB" "validate did not print the advisory note"
  assert_contains "$out" "OK:" "validate did not still report OK"
  pass "validate treats a topic file past 30 KB as advisory only"
}

# --- split --------------------------------------------------------------------

test_split_moves_entries_verbatim() {
  local flat="$TMP_ROOT/s1.flat" asg="$TMP_ROOT/s1.asg" out="$TMP_ROOT/s1.out" before
  write_flat "$flat"
  write_assignment "$asg"
  before=$(cksum < "$flat")

  "$MM" split --allow-unowned "$flat" "$asg" "$out" >/dev/null 2>&1 || fail "split of a valid assignment failed"
  [ "$(cksum < "$flat")" = "$before" ] || fail "split modified its flat source"

  assert_grep '- 2026-01-01 First learning about merges.' "$out/merging.md" "merging.md lost its entry"
  assert_grep '  continued line' "$out/merging.md" "the entry's continuation line was not moved with it"
  assert_grep '- inner bullet' "$out/tools.md" "the dated section's inner bullet was not folded into its entry"
  assert_no_grep 'Intro text.' "$out/merging.md" "outside-entry text leaked into a topic file"
  assert_grep 'Intro text.' "$out/.residue.txt" "outside-entry text was dropped instead of kept in the residue"
  assert_grep '- 2026-01-01 First learning about merges. -> merging.md' "$out/MAP.md" "the always-loaded rule was not generated from the entry lead"
  assert_no_grep 'Second about tools. ->' "$out/MAP.md" "an entry not marked always was listed as a rule"
  "$MM" validate "$out" >/dev/null || fail "the generated map did not validate"

  [ "$(cat "$out"/merging.md "$out"/tools.md "$out"/.residue.txt | wc -c | tr -d ' ')" = "$(wc -c < "$flat" | tr -d ' ')" ] \
    || fail "topic files plus residue do not add up to the source bytes"
  pass "split moves entries verbatim, keeps the residue, validates, and leaves the source untouched"
}

# refuse_split <name> <assignment-lines...>: split must fail and leave no output.
refuse_split() {
  local name=$1 want=$2 flat asg out msg stage
  shift 2
  flat="$TMP_ROOT/$name.flat"
  asg="$TMP_ROOT/$name.asg"
  out="$TMP_ROOT/$name.out"
  write_flat "$flat"
  {
    printf '%s\n' 'topic merging Before any merge' 'topic tools When tools misbehave'
    [ $# -eq 0 ] || printf '%s\n' "$@"
  } > "$asg"
  msg=$("$MM" split --allow-unowned "$flat" "$asg" "$out" 2>&1) && fail "$name: split succeeded but should have refused"
  assert_contains "$msg" "$want" "$name: refusal did not say why"
  assert_absent "$out" "$name: a refused split left an output directory"
  for stage in "$TMP_ROOT/$name.out.split."*; do
    [ -e "$stage" ] && fail "$name: a refused split left a staging directory"
  done
  return 0
}

test_split_refuses_unassigned_entry() {
  refuse_split unassigned "is unassigned" '7 merging' '9 tools'
  pass "split refuses when an entry would be lost because it is unassigned"
}

test_split_refuses_duplicate_assignment() {
  refuse_split twice "assigned twice" '7 merging' '7 tools' '9 tools' '11 tools'
  pass "split refuses when an entry would be duplicated by a second assignment"
}

test_split_refuses_undeclared_topic_and_bad_line() {
  refuse_split undeclared "undeclared topic" '7 merging' '9 ghost' '11 tools'
  refuse_split notentry "not an entry start" '7 merging' '9 tools' '11 tools' '8 tools'
  pass "split refuses an undeclared topic and a line that is not an entry start"
}

test_split_refuses_empty_topic() {
  refuse_split emptytopic "has no entries" '7 merging' '9 merging' '11 merging'
  pass "split refuses a declared topic that would be an empty file"
}

test_split_refuses_unowned_text_without_flag() {
  local flat="$TMP_ROOT/un.flat" asg="$TMP_ROOT/un.asg" out="$TMP_ROOT/un.out" msg
  write_flat "$flat"
  write_assignment "$asg"
  msg=$("$MM" split "$flat" "$asg" "$out" 2>&1) && fail "split dropped outside-entry text without --allow-unowned"
  assert_contains "$msg" "outside any entry" "refusal did not explain the unowned text"
  assert_absent "$out" "a refused split left an output directory"
  pass "split refuses text outside any entry unless --allow-unowned is given"
}

test_split_refuses_existing_output_dir() {
  local flat="$TMP_ROOT/ex.flat" asg="$TMP_ROOT/ex.asg" out="$TMP_ROOT/ex.out" msg
  write_flat "$flat"
  write_assignment "$asg"
  mkdir -p "$out"
  printf '%s\n' keep > "$out/keep.txt"
  msg=$("$MM" split --allow-unowned "$flat" "$asg" "$out" 2>&1) && fail "split overwrote an existing output directory"
  assert_contains "$msg" "already exists" "refusal did not say the output exists"
  assert_grep keep "$out/keep.txt" "an existing output directory was modified"
  pass "split refuses to write into an existing output directory"
}

test_split_postcheck_catches_a_lossy_writer() {
  local flat="$TMP_ROOT/pc.flat" asg="$TMP_ROOT/pc.asg" out="$TMP_ROOT/pc.out" bin="$TMP_ROOT/pc.bin" real msg
  write_flat "$flat"
  write_assignment "$asg"
  mkdir -p "$bin"
  real=$(command -v awk)
  # A deliberately lossy awk: runs the real writer, then drops the last line of
  # tools.md, as a buggy writer would. The independent post-check must catch it.
  cat > "$bin/awk" <<SHIM
#!/usr/bin/env bash
"$real" "\$@"
rc=\$?
for a in "\$@"; do
  case "\$a" in out=*) d=\${a#out=}; [ -f "\$d/tools.md" ] && sed -i.bak '\$d' "\$d/tools.md" && rm -f "\$d/tools.md.bak" ;; esac
done
exit \$rc
SHIM
  chmod +x "$bin/awk"
  msg=$(PATH="$bin:$PATH" "$MM" split --allow-unowned "$flat" "$asg" "$out" 2>&1) && fail "split accepted output that lost a line"
  assert_contains "$msg" "nothing written" "the post-check refusal did not say nothing was written"
  assert_absent "$out" "a split that failed its post-check left an output directory"
  pass "split's independent post-check refuses output that lost an entry line"
}

test_entries_lists_starts() {
  local flat="$TMP_ROOT/en.flat" out
  write_flat "$flat"
  out=$("$MM" entries "$flat")
  assert_contains "$out" "7	" "entries did not list the first entry start line"
  assert_contains "$out" "11	" "entries did not list the dated section start line"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 3 ] || fail "entries listed the wrong number of entries: $out"
  pass "entries lists each entry start line"
}

run_case test_validate_accepts_good_map
run_case test_validate_refuses_missing_listed_file
run_case test_validate_refuses_unlisted_topic_file
run_case test_validate_refuses_bad_topics_line
run_case test_validate_refuses_duplicate_and_bad_rules
run_case test_validate_refuses_missing_map_and_topics_section
run_case test_validate_large_topic_file_is_advisory
run_case test_split_moves_entries_verbatim
run_case test_split_refuses_unassigned_entry
run_case test_split_refuses_duplicate_assignment
run_case test_split_refuses_undeclared_topic_and_bad_line
run_case test_split_refuses_empty_topic
run_case test_split_refuses_unowned_text_without_flag
run_case test_split_refuses_existing_output_dir
run_case test_split_postcheck_catches_a_lossy_writer
run_case test_entries_lists_starts
fm_case_summary "fm-memory-map"
