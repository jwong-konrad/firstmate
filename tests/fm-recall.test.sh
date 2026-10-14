#!/usr/bin/env bash
# Behavior tests for bin/fm-recall.sh: the SQLite FTS5 index over reports, handoffs,
# decisions, learnings, captain notes, and ledgers, plus the raw transcript fallback.
# Hermetic: fixture data/ and archive roots in a temp dir; no network, no embeddings.
#
# Matrix:
#   index builds from data/ and the archive and reports counts; a rebuild replaces it atomically
#   query ranks a hit, prints heading and snippet and path, and states when the index was built
#   stemming and the AND of several words work; a quoted single argument is split into words
#   --kind filters; --since filters by file date; --limit caps the rows
#   punctuation and FTS operators in a query cannot break it
#   an archive copy of a report already in data/ is not indexed twice; an archive-only report is found
#   ledgers are indexed as a summary (model, PR)
#   --transcripts indexes user and assistant text but never tool output; without it, --kind
#   transcript falls back to a raw regex search of the archived transcripts
#   a missing index is a clear error, a failed rebuild leaves the old index in place
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECALL="$ROOT/bin/fm-recall.sh"
TMP_ROOT=$(fm_test_tmproot fm-recall-tests)

make_corpus() {  # <name>: prints the sandbox dir
  local e="$TMP_ROOT/$1"
  mkdir -p "$e/home/data/t1" "$e/home/data/handoffs/h1" "$e/home/data/decisions" "$e/home/data/t2" \
    "$e/arch/tasks/t1" "$e/arch/tasks/t9" "$e/arch/transcripts/-proj/sess/subagents"
  printf '%s\n' '# Merge policy' '' 'intro text' '' '## Signed squash merges' '' \
    'We decided that squash merges break signed commits so we use merge commits.' '' \
    '## Unrelated' '' 'bananas and apples' > "$e/home/data/t1/report.md"
  printf '%s\n' '# Old report' '' 'zebra census of last year' > "$e/home/data/t2/report.md"
  touch -t 202001010000 "$e/home/data/t2/report.md"
  printf '%s\n' '# Handoff' '' 'the watcher arm failed twice in the night' > "$e/home/data/handoffs/h1/h.md"
  printf '%s\n' '# Decision' '' 'Fable is not used for scouts.' > "$e/home/data/decisions/d1.md"
  printf '%s\n' '# Duplicate' '' 'this archive copy must not be indexed twice: platypus' > "$e/arch/tasks/t1/report.md"
  printf '%s\n' '# Only archived' '' 'quarterly walrus ledger entry' > "$e/arch/tasks/t9/report.md"
  printf '%s\n' '{"schema":"fm-ledger.v1","task":"t9","model":"opus","effort":"low","pr":"https://github.com/x/y/pull/42","status_history":["working: a","done: PR checks green"],"totals":{"input":5,"output":7,"cost_usd":1.5}}' > "$e/arch/tasks/t9/ledger.json"
  printf '%s\n' \
    '{"type":"user","message":{"content":"please investigate the quokka outage"}}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"checking quokka logs"},{"type":"tool_use","name":"Bash","input":{"command":"grep okapi"}}]}}' \
    '{"type":"user","message":{"content":[{"type":"tool_result","content":"okapi tool output must not be indexed"}]}}' \
    > "$e/arch/transcripts/-proj/sess.jsonl"
  printf '%s\n' "$e"
}

recall() {  # <env-dir> <args...>
  local e=$1
  shift
  env FM_HOME="$e/home" FM_ARCHIVE_ROOT="$e/arch" "$RECALL" "$@"
}

test_index_and_query_ranked_sections() {
  local e out
  e=$(make_corpus basic)
  out=$(recall "$e" index) || fail "basic: index failed: $out"
  assert_contains "$out" "files" "basic: index did not report a file count"
  assert_present "$e/arch/index/archive.db" "basic: index file missing"
  out=$(recall "$e" query "squash signed merge") || fail "basic: query failed"
  assert_contains "$out" "# index built" "basic: the query must state when the index was built"
  assert_contains "$out" "[report] t1 | Signed squash merges" "basic: the right section was not returned first"
  assert_contains "$out" "$e/home/data/t1/report.md" "basic: the hit does not carry its path"
  assert_contains "$out" "[squash]" "basic: no highlighted snippet"
  pass "index and query return a ranked section with heading, snippet, and path"
}

test_stemming_and_multiple_arguments() {
  local e
  e=$(make_corpus stem)
  recall "$e" index >/dev/null || fail "stem: index failed"
  recall "$e" query decide merges | grep -q "Signed squash merges" || fail "stem: 'decide' should match 'decided' and AND with 'merges'"
  recall "$e" query "scout" | grep -q "d1.md" || fail "stem: singular query did not match the plural 'scouts'"
  pass "stemming works and words may arrive as one argument or several"
}

test_kind_since_and_limit_filters() {
  local e out
  e=$(make_corpus filters)
  recall "$e" index >/dev/null || fail "filters: index failed"
  out=$(recall "$e" query watcher --kind handoff)
  assert_contains "$out" "[handoff] h1" "filters: --kind handoff did not return the handoff"
  out=$(recall "$e" query watcher --kind report)
  assert_not_contains "$out" "[handoff]" "filters: --kind report returned a handoff"
  out=$(recall "$e" query zebra --since 2024-01-01)
  assert_not_contains "$out" "zebra" "filters: --since returned a 2020 file"
  out=$(recall "$e" query zebra --since 2019-01-01)
  assert_contains "$out" "[zebra]" "filters: --since excluded a file that is new enough"
  out=$(recall "$e" query "merge OR watcher" --limit 1 | grep -c '^\[')
  [ "$out" = 1 ] || fail "filters: --limit 1 returned $out rows"
  pass "--kind, --since, and --limit filter results"
}

test_punctuation_cannot_break_a_query() {
  local e out rc
  e=$(make_corpus punct)
  recall "$e" index >/dev/null || fail "punct: index failed"
  for q in 'squash"' "o'brien" 'AND' 'a (b' 'merge* -x' 'col:on'; do
    set +e
    out=$(recall "$e" query "$q" 2>&1)
    rc=$?
    set -e
    case "$out" in *"syntax error"*|*"fts5:"*) fail "punct: query '$q' reached FTS as a syntax error: $out" ;; esac
    [ "$rc" -le 1 ] || fail "punct: query '$q' exited $rc"
  done
  recall "$e" query 'merg*' | grep -q "Signed squash merges" || fail "punct: a trailing * should be a prefix match"
  pass "punctuation and operators in a query cannot cause a syntax error"
}

test_archive_copy_is_deduplicated_and_archive_only_is_found() {
  local e out
  e=$(make_corpus dedupe)
  recall "$e" index >/dev/null || fail "dedupe: index failed"
  out=$(recall "$e" query platypus)
  assert_not_contains "$out" "platypus" "dedupe: an archive copy of a report already in data/ was indexed"
  out=$(recall "$e" query walrus)
  assert_contains "$out" "$e/arch/tasks/t9/report.md" "dedupe: an archive-only report was not indexed"
  pass "archive copies of live reports are skipped and archive-only reports are found"
}

test_ledgers_are_indexed_as_a_summary() {
  local e out
  e=$(make_corpus ledgers)
  recall "$e" index >/dev/null || fail "ledgers: index failed"
  out=$(recall "$e" query opus --kind ledger)
  assert_contains "$out" "[ledger] t9" "ledgers: the ledger was not indexed"
  out=$(recall "$e" query pull 42 --kind ledger)
  assert_contains "$out" "[ledger] t9" "ledgers: the PR is not searchable"
  pass "ledgers are indexed as a searchable summary"
}

test_transcripts_digest_and_raw_fallback() {
  local e out
  e=$(make_corpus transcripts)
  recall "$e" index >/dev/null || fail "transcripts: index failed"
  out=$(recall "$e" query quokka --kind transcript)
  assert_contains "$out" "raw search" "transcripts: without digests the query should fall back to the raw search"
  assert_contains "$out" "sess.jsonl" "transcripts: the raw fallback found no file"
  recall "$e" index --transcripts >/dev/null || fail "transcripts: index --transcripts failed"
  out=$(recall "$e" query quokka --kind transcript)
  assert_contains "$out" "[transcript]" "transcripts: the digest was not indexed"
  assert_contains "$out" "[quokka]" "transcripts: no snippet from the digest"
  out=$(recall "$e" query okapi --kind transcript)
  assert_not_contains "$out" "okapi tool output" "transcripts: tool output leaked into the digest"
  out=$(recall "$e" grep okapi)
  assert_contains "$out" "sess.jsonl" "transcripts: grep did not search the raw transcripts"
  pass "transcript digests index prompts and replies only, and the raw search works without an index"
}

test_missing_index_and_failed_rebuild() {
  local e rc out before
  e=$(make_corpus missing)
  set +e
  recall "$e" query anything >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "missing: a query with no index must fail"
  recall "$e" index >/dev/null || fail "missing: index failed"
  before=$(cksum < "$e/arch/index/archive.db")
  # A rebuild that fails part-way (sqlite3 stubbed to fail) must leave the old index in place.
  mkdir -p "$e/fakebin"
  printf '#!/bin/sh\ncase "$*" in *tmp*) exit 1 ;; esac\nexec "%s" "$@"\n' "$(command -v sqlite3)" > "$e/fakebin/sqlite3"
  chmod +x "$e/fakebin/sqlite3"
  set +e
  out=$(env FM_HOME="$e/home" FM_ARCHIVE_ROOT="$e/arch" PATH="$e/fakebin:$PATH" "$RECALL" index 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "missing: a failed rebuild must exit non-zero"
  assert_contains "$out" "existing index is unchanged" "missing: a failed rebuild should say the index is unchanged"
  [ "$(cksum < "$e/arch/index/archive.db")" = "$before" ] || fail "missing: a failed rebuild replaced the index"
  pass "a missing index is a clear error and a failed rebuild keeps the old index"
}

test_status_reports_counts() {
  local e out
  e=$(make_corpus status)
  recall "$e" index >/dev/null || fail "status: index failed"
  out=$(recall "$e" status)
  assert_contains "$out" "chunks:" "status: no chunk count"
  assert_contains "$out" "report|" "status: no per-kind counts"
  pass "status reports the build date and per-kind counts"
}

run_case test_index_and_query_ranked_sections
run_case test_stemming_and_multiple_arguments
run_case test_kind_since_and_limit_filters
run_case test_punctuation_cannot_break_a_query
run_case test_archive_copy_is_deduplicated_and_archive_only_is_found
run_case test_ledgers_are_indexed_as_a_summary
run_case test_transcripts_digest_and_raw_fallback
run_case test_missing_index_and_failed_rebuild
run_case test_status_reports_counts
fm_case_summary "fm-recall"
