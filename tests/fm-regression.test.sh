#!/usr/bin/env bash
# Behavior tests for bin/fm-regression.sh: the regression ledger's derive step, lint, and board.
# Hermetic: every effort folder is a fixture in a temp dir; the backlog reader is a fake.
#
# Matrix:
#   an empty effort renders, is never ready, and lints clean; init refuses to overwrite a ledger
#   each derived check state: proven, UI still owed, server layer still owed, stale, never
#   observed, code-only (never fixed, even when the code says still open), not run, not
#   testable, blocked, still open, as designed through a superseding correction, unknown build,
#   and a recorded UI n/a reason
#   an item takes its worst check's state; out-of-scope items are their own bucket
#   headline counts add up to the totals, every state is printed even at zero
#   readiness: all proven is ready; any unproven check or lint failure is not
#   lint: ticket with no item, Linear disagreeing, unregistered build, verdict not relayed (and a
#   relay clearing it), in-scope item with no checks, invalid records
#   panel B lists checks whose state changed between the last two rounds
#   decisions are read through the backlog reader as open, resolved, or not found
#   the page is self-contained, embeds its render time for the 24 h age check, and a stray
#   "</script>" in the data cannot end the data block
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REG="$ROOT/bin/fm-regression.sh"
TMP_ROOT=$(fm_test_tmproot fm-regression-tests)
export REGRESSION_NOW=2026-10-15T20:00:00Z
export REGRESSION_TASKS_CMD=none

OLD=aaaaaaa1111
NEW=bbbbbbb2222

# new_effort <name>: an initialized effort with one baseline, one superseded and one current
# local build and an unidentified current staging build. Prints the folder.
new_effort() {
  local d="$TMP_ROOT/$1"
  "$REG" init "$d" --title "Test effort" >/dev/null || fail "$1: init failed"
  jq '.envs = ["local-old", "local-new", "staging"] | .target_envs = ["local-new"]
      | .linear.done_statuses = ["QA Passed"]' "$d/effort.json" > "$d/e.tmp" && mv "$d/e.tmp" "$d/effort.json"
  printf '%s\n' \
    '{"env":"local-old","sha":"ccccccc3333","role":"baseline","current":true}' \
    "{\"env\":\"local-new\",\"sha\":\"$OLD\",\"role\":\"target\",\"current\":false}" \
    "{\"env\":\"local-new\",\"sha\":\"$NEW\",\"role\":\"target\",\"current\":true}" \
    '{"env":"staging","sha":"unidentified","role":"target","current":true}' > "$d/builds.jsonl"
  printf '%s\n' '{"id":"r1"}' '{"id":"r2"}' > "$d/rounds.jsonl"
  printf '%s\n' "$d"
}

# item <dir> <id> [extra-json]: append one item.
item() {
  local x=${3:-'{}'}
  jq -cn --arg id "$2" --argjson x "$x" '{id: $id, kind: "ticket", title: $id} + $x' >> "$1/items.jsonl"
}

# check <dir> <id> <item> [extra-json]: append one check.
check() {
  local x=${4:-'{}'}
  jq -cn --arg id "$2" --arg it "$3" --argjson x "$x" '{id: $id, item: $it, claim: "claim \($id)"} + $x' >> "$1/checks.jsonl"
}

# obs <dir> <id> <check> <env> <build> <layer> <result> [round] [extra-json]: append one observation.
obs() {
  local x=${9:-'{}'}
  jq -cn --arg id "$2" --arg c "$3" --arg e "$4" --arg b "$5" --arg l "$6" --arg r "$7" --arg rd "${8:-r1}" \
    --argjson x "$x" \
    '{id: $id, check: $c, env: $e, build: $b, layer: $l, result: $r, round: $rd, evidence: "ev/\($id)"} + $x' >> "$1/observations.jsonl"
}

state_of() {  # <dir> <check-id>
  "$REG" json "$1" | jq -r --arg c "$2" '.items[].checks[] | select(.id == $c) | .state'
}

test_empty_effort() {
  local d out rc=0
  d="$TMP_ROOT/empty"
  "$REG" init "$d" --id empty >/dev/null || fail "empty: init failed"
  for f in effort.json builds.jsonl items.jsonl checks.jsonl observations.jsonl rounds.jsonl linear.jsonl relays.jsonl; do
    assert_present "$d/$f" "empty: init did not create $f"
  done
  out=$("$REG" render "$d") || fail "empty: render failed: $out"
  assert_contains "$out" "0 items, 0 checks" "empty: headline totals"
  assert_contains "$out" "NOT READY FOR STAGE (no checks are tracked yet)" "empty: an empty effort must never read ready"
  assert_contains "$out" "lint: clean" "empty: lint should be clean"
  assert_present "$d/board.html" "empty: board not written"
  out=$("$REG" lint "$d") || fail "empty: lint should exit 0"
  assert_contains "$out" "lint: clean" "empty: lint output"
  out=$("$REG" init "$d" 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "empty: a second init must refuse, got rc=$rc"
  assert_contains "$out" "never overwrites" "empty: refusal names the reason"
  pass "an empty effort renders not-ready and lints clean; init refuses to overwrite"
}

test_derived_states() {
  local d
  d=$(new_effort states)
  item "$d" T1
  for c in proven uiowed layerowed stale never codeonly codeopen stalecode notrun nottestable blocked open designed unknown uina; do
    check "$d" "$c" T1
  done
  check "$d" uina2 T1 '{"required_layers":["API"],"ui_na":"server-only claim"}'
  check "$d" stg T1 '{"envs":["staging"],"required_layers":["UI"]}'
  obs "$d" o1 proven local-new "$NEW" API FIXED
  obs "$d" o2 proven local-new "$NEW" UI FIXED
  obs "$d" o3 uiowed local-new "$NEW" DB FIXED
  obs "$d" o4 layerowed local-new "$NEW" UI FIXED
  obs "$d" o5 stale local-new "$OLD" API FIXED
  obs "$d" o6 codeonly local-new "$NEW" code FIXED
  obs "$d" o7 codeopen local-new "$NEW" code STILL-OPEN
  obs "$d" o8 stalecode local-new "$OLD" API FIXED
  obs "$d" o9 stalecode local-new "$NEW" code FIXED
  obs "$d" o10 notrun local-new "$NEW" API NOT-RUN r1 '{"reason":"not allowlisted"}'
  obs "$d" o11 nottestable local-new "$NEW" API NOT-TESTABLE r1 '{"reason":"no identity"}'
  obs "$d" o12 blocked local-new "$NEW" UI BLOCKED r1 '{"reason":"no record"}'
  obs "$d" o13 open local-new "$NEW" API FIXED
  obs "$d" o14 open local-new "$NEW" DB STILL-OPEN
  obs "$d" o15 designed local-new "$NEW" API STILL-OPEN
  obs "$d" o16 designed local-new "$NEW" UI STILL-OPEN
  obs "$d" o17 designed local-new "$NEW" API AS-DESIGNED r1 '{"supersedes":"o15","reason":"ruling"}'
  obs "$d" o18 designed local-new "$NEW" UI AS-DESIGNED r1 '{"supersedes":"o16","reason":"ruling"}'
  obs "$d" o19 unknown local-new unidentified UI FIXED
  obs "$d" o20 uina2 local-new "$NEW" API FIXED
  obs "$d" o21 stg staging unidentified UI FIXED
  printf '%s\n' '{"env":"local-new","sha":"unidentified","role":"target","current":false}' >> "$d/builds.jsonl"
  local pair
  for pair in proven:proven uiowed:ui-owed layerowed:layer-owed stale:stale never:never-observed \
    codeonly:code-only codeopen:code-only stalecode:stale notrun:not-run nottestable:not-testable \
    blocked:blocked open:still-open designed:as-designed unknown:unknown uina2:proven stg:unknown; do
    [ "$(state_of "$d" "${pair%%:*}")" = "${pair#*:}" ] ||
      fail "states: check ${pair%%:*} should be ${pair#*:}, got $(state_of "$d" "${pair%%:*}")"
  done
  [ "$("$REG" json "$d" | jq -r '.items[0].state')" = still-open ] || fail "states: the item must take its worst check state"
  pass "every derived check state, and the item takes the worst"
}

test_counts_add_up_and_readiness() {
  local d out m
  d=$(new_effort counts)
  item "$d" T1 '{"linear_id":"KG-1"}'
  item "$d" T2
  item "$d" T3 '{"scope":"out","scope_reason":"not ours"}'
  check "$d" a T1
  check "$d" b T2
  obs "$d" o1 a local-new "$NEW" API FIXED
  obs "$d" o2 a local-new "$NEW" UI FIXED
  obs "$d" o3 b local-new "$NEW" API FIXED
  obs "$d" o4 b local-new "$NEW" UI FIXED
  printf '%s\n' '{"item":"T1","date":"2026-10-15","action":"comment","verdict":"fixed"}' \
    '{"item":"T2","date":"2026-10-15","action":"withheld","verdict":"fixed","note":"captain"}' > "$d/relays.jsonl"
  m=$("$REG" json "$d")
  [ "$(jq '[.check_counts[].count] | add' <<<"$m")" = "$(jq '.totals.checks' <<<"$m")" ] || fail "counts: check counts do not add up"
  [ "$(jq '[.item_counts[].count] | add' <<<"$m")" = 3 ] || fail "counts: item counts do not add up to 3"
  [ "$(jq -r '.items[] | select(.id == "T3") | .state' <<<"$m")" = out-of-scope ] || fail "counts: out-of-scope bucket"
  out=$("$REG" render "$d")
  assert_contains "$out" "READY FOR STAGE" "counts: all proven should be ready"
  assert_not_contains "$out" "NOT READY" "counts: all proven should be ready"
  for label in "0 confirmed still open" "0 never observed" "0 unknown build" "0 stale (older build only)" \
    "0 code reading only" "0 not run" "0 UI still owed" "2 proven fixed" "0 out of scope"; do
    assert_contains "$out" "$label" "counts: headline must show every state, zero included ($label)"
  done
  obs "$d" o5 b local-new "$NEW" UI NOT-RUN r2 '{"reason":"skipped"}'
  out=$("$REG" render "$d")
  assert_contains "$out" "NOT READY FOR STAGE (1 check(s) not yet proven" "counts: a not-run cell must block readiness"
  pass "headline counts add up and readiness needs every check proven"
}

test_lint_rules() {
  local d out rc=0
  d=$(new_effort lint)
  item "$d" T1 '{"linear_id":"KG-1"}'
  item "$d" T2 '{"linear_id":"KG-2"}'
  item "$d" T3
  check "$d" a T1
  check "$d" b T2
  obs "$d" o1 a local-new "$NEW" API NOT-RUN r1 '{"reason":"later"}'
  obs "$d" o2 b local-new "$NEW" API FIXED
  obs "$d" o3 b local-new "$NEW" UI FIXED
  obs "$d" o4 b local-new deadbeef99 API FIXED
  obs "$d" o5 b local-new "$NEW" DB NOT-RUN
  printf '%s\n' \
    '{"ticket":"KG-1","status":"QA Passed","read_at":"2026-10-15T17:45:00Z"}' \
    '{"ticket":"KG-2","status":"QA Passed","read_at":"2026-10-15T17:45:00Z"}' \
    '{"ticket":"KG-9","status":"Backlog","read_at":"2026-10-15T17:45:00Z"}' > "$d/linear.jsonl"
  out=$("$REG" lint "$d") || rc=$?
  [ "$rc" -eq 1 ] || fail "lint: failures must exit 1, got $rc"
  assert_contains "$out" "ticket-without-item: KG-9" "lint (a) ticket with no item"
  assert_contains "$out" "linear-disagrees: KG-1 is QA Passed" "lint (b) Linear disagreeing"
  assert_not_contains "$out" "linear-disagrees: KG-2" "lint (b) proven and QA Passed agree"
  assert_contains "$out" "unregistered-build: observation o4" "lint (d) unregistered build"
  assert_contains "$out" "not-relayed: KG-2" "lint (e) verdict with no relay"
  assert_contains "$out" "item-without-checks: T3" "lint (f) item with no checks"
  assert_contains "$out" "invalid-record: observation o5 is NOT-RUN with no reason" "lint: a not-run needs a reason"
  printf '%s\n' '{"item":"T2","date":"2026-10-15","action":"comment","verdict":"fixed"}' > "$d/relays.jsonl"
  out=$("$REG" lint "$d") || true
  assert_not_contains "$out" "not-relayed" "lint (e) a relay with the verdict clears it"
  out=$("$REG" render "$d")
  assert_contains "$out" "lint: 5 failure(s)" "lint failures are counted on the front page"
  assert_contains "$out" "NOT READY" "lint failures keep the board not ready"
  pass "lint flags each rule and a relay clears the not-relayed rule"
}

test_changed_since_last_round() {
  local d m
  d=$(new_effort diff)
  item "$d" T1
  check "$d" a T1
  check "$d" b T1
  obs "$d" o1 a local-new "$NEW" API NOT-RUN r1 '{"reason":"later"}'
  obs "$d" o2 a local-new "$NEW" API FIXED r2
  obs "$d" o3 b local-new "$NEW" API FIXED r1
  m=$("$REG" json "$d")
  [ "$(jq -c '.panel_b.rounds.cells' <<<"$m")" = '[{"check":"a","item":"T1","before":"not-run","after":"ui-owed"}]' ] ||
    fail "diff: expected only check a to change, got $(jq -c '.panel_b.rounds.cells' <<<"$m")"
  pass "panel B lists the checks whose state changed between the last two rounds"
}

test_decisions_read_from_backlog() {
  local d fb m
  d=$(new_effort decisions)
  item "$d" T1 '{"decision_keys":["k-open","k-done","k-gone"]}'
  check "$d" a T1
  fb=$(fm_fakebin "$TMP_ROOT/decisions-bin")
  cat > "$fb/fake-tasks" <<'EOS'
#!/usr/bin/env bash
case "$2" in
  k-open) printf 'task:\n  id: k-open\n  title: "Pick a fixture"\n  state: queued\n' ;;
  k-done) printf 'task:\n  id: k-done\n  title: "Old one"\n  state: done\n' ;;
  *) printf 'error: not found\ncode: NOT_FOUND\n'; exit 1 ;;
esac
EOS
  chmod +x "$fb/fake-tasks"
  m=$(REGRESSION_TASKS_CMD="$fb/fake-tasks" "$REG" json "$d")
  [ "$(jq -c '[.panel_c.decisions[] | [.key, .state]]' <<<"$m")" = '[["k-done","resolved"],["k-gone","not-found"],["k-open","open"]]' ] ||
    fail "decisions: unexpected states $(jq -c '.panel_c.decisions' <<<"$m")"
  [ "$(jq -r '.panel_a[0].unblock' <<<"$m")" = decision ] || fail "decisions: an open decision groups the item under needs your decision"
  [ "$(jq -r '.decisions_read' <<<"$m")" = true ] || fail "decisions: decisions_read flag"
  pass "decisions are read through the backlog reader"
}

test_page_self_contained() {
  local d page
  d=$(new_effort page)
  item "$d" T1 '{"title":"breaks </script><script>alert(1)</script> out"}'
  check "$d" a T1
  "$REG" render "$d" --out "$d/out.html" >/dev/null || fail "page: render failed"
  page=$(cat "$d/out.html")
  assert_not_contains "$page" "BOARD_DATA" "page: the data marker must be replaced"
  assert_not_contains "$page" "</script><script>alert" "page: a stray </script> in the data must be escaped"
  assert_contains "$page" '"rendered_at":"2026-10-15T20:00:00Z"' "page: the render time is embedded for the age check"
  assert_contains "$page" "24 * 60 * 60 * 1000" "page: the board turns red after 24 hours"
  assert_contains "$page" "prefers-color-scheme: dark" "page: dark mode"
  if grep -Eq '(src|href)="(https?:)?//' "$d/out.html"; then fail "page: no external fetches"; fi
  [ "$(grep -c '<script' "$d/out.html")" -eq 2 ] || fail "page: expected exactly the data and code script blocks"
  pass "the page is self-contained, embeds its render time, and escapes stray script tags"
}

run_case test_empty_effort
run_case test_derived_states
run_case test_counts_add_up_and_readiness
run_case test_lint_rules
run_case test_changed_since_last_round
run_case test_decisions_read_from_backlog
run_case test_page_self_contained
fm_case_summary "fm-regression"
