#!/usr/bin/env bash
# Behavior tests for bin/fm-regression.sh: the regression ledger's derive step, lint, and board.
# Hermetic: every effort folder is a fixture in a temp dir; the backlog reader is a fake.
#
# Matrix:
#   an empty effort renders, lints clean, and gives no readiness verdict; init refuses to
#   overwrite a ledger
#   each derived check state: proven, UI still owed, server layer still owed, stale, never
#   observed, code-only (never fixed, even when the code says still open), not run, not
#   testable, blocked, still open, as designed through a superseding correction, unknown build,
#   and a recorded UI n/a reason
#   an item takes its worst check's state; out-of-scope items are their own bucket
#   headline counts add up to the totals, every state is printed even at zero, and the headline
#   reports what is not yet proven instead of a READY / NOT READY verdict
#   superseding check lines: retire a check, move a layer to its own environments, add ui_na;
#   a duplicate id without supersedes and a dangling supersedes are lint failures
#   round lifecycle: open validates its plan, observe validates and appends one line, check
#   reports coverage (a reasonless NOT-RUN does not count), close refuses until covered and
#   then appends the close line and renders
#   the Ledger duty brief section names the round, the planned checks and the gate
#   Linear status at render: one batched read, reused while recent, measured per render, and a
#   failing reader never stops the render; json never reads Linear
#   teardown refuses a scout or tester whose round still has uncovered planned checks, and
#   leaves tasks no round names untouched
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
  assert_contains "$out" "-> 0 check(s) not yet proven" "empty: the headline reports what is not proven"
  assert_not_contains "$out" "READY" "empty: the board gives no readiness verdict"
  assert_contains "$out" "lint: clean" "empty: lint should be clean"
  assert_present "$d/board.html" "empty: board not written"
  out=$("$REG" lint "$d") || fail "empty: lint should exit 0"
  assert_contains "$out" "lint: clean" "empty: lint output"
  out=$("$REG" init "$d" 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "empty: a second init must refuse, got rc=$rc"
  assert_contains "$out" "never overwrites" "empty: refusal names the reason"
  pass "an empty effort renders with no verdict and lints clean; init refuses to overwrite"
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

test_counts_add_up_and_not_proven() {
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
  assert_contains "$out" "-> 0 check(s) not yet proven" "counts: all proven leaves nothing unproven"
  assert_not_contains "$out" "READY" "counts: the board gives no readiness verdict"
  for label in "0 confirmed still open" "0 never observed" "0 unknown build" "0 stale (older build only)" \
    "0 code reading only" "0 not run" "0 UI still owed" "2 proven fixed" "0 out of scope" "0 retired"; do
    assert_contains "$out" "$label" "counts: headline must show every state, zero included ($label)"
  done
  obs "$d" o5 b local-new "$NEW" UI NOT-RUN r2 '{"reason":"skipped"}'
  out=$("$REG" render "$d")
  assert_contains "$out" "-> 1 check(s) not yet proven" "counts: a not-run cell is counted as not proven"
  assert_not_contains "$out" "READY" "counts: still no readiness verdict"
  pass "headline counts add up and report what is not yet proven"
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
  assert_contains "$out" "1 item(s) without checks" "lint: an item with no checks is in the headline"
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

test_baseline_env_in_check_envs() {
  local d m out
  d=$(new_effort baselineenv)
  item "$d" T1
  check "$d" a T1 '{"envs":["local-old","local-new"]}'
  check "$d" b T1 '{"envs":["local-old"]}'
  obs "$d" o1 a local-new "$NEW" API FIXED
  obs "$d" o2 a local-new "$NEW" UI FIXED
  m=$("$REG" json "$d") || fail "baseline env: json failed"
  [ "$(jq -r '.items[].checks[] | select(.id == "a") | .state' <<<"$m")" = proven ] || fail "baseline env: got $(jq -c "[.items[].checks[]|[.id,.state]]" <<<"$m")"
  [ "$(jq -r '.items[].checks[] | select(.id == "b") | .state' <<<"$m")" = never-observed ] || fail "baseline env: an all-baseline check is never observed"
  [ "$(jq '[.check_counts[].count] | add' <<<"$m")" = "$(jq '.totals.checks' <<<"$m")" ] || fail "baseline env: counts do not add up"
  out=$("$REG" render "$d") || fail "baseline env: render failed"
  assert_contains "$out" "-> 1 check(s) not yet proven" "baseline env: a never-observed check is not proven"
  pass "baseline environments are excluded from the check state"
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
  assert_not_contains "$page" "READY FOR STAGE" "page: the page gives no readiness verdict"
  assert_contains "$page" '"not_proven":{"checks":1' "page: the page embeds the not-proven count"
  pass "the page is self-contained, embeds its render time, and escapes stray script tags"
}

test_superseding_checks() {
  local d m out rc=0
  d=$(new_effort supersede)
  item "$d" T1
  item "$d" T2
  check "$d" retire T1 '{"note":"first reading"}'
  check "$d" stg T1 '{"envs":["local-new"]}'
  check "$d" uina T1
  check "$d" only T2
  obs "$d" o1 stg local-new "$NEW" API FIXED
  obs "$d" o2 uina local-new "$NEW" API FIXED
  printf '%s\n' \
    '{"id":"retire","supersedes":"retire","retired":"captain ruling: not part of the ticket","note":null}' \
    '{"id":"stg","supersedes":"stg","layer_envs":{"UI":["staging"]}}' \
    '{"id":"uina","supersedes":"uina","ui_na":"server-only claim"}' \
    '{"id":"only","supersedes":"only","retired":"folded into another check"}' >> "$d/checks.jsonl"
  out=$("$REG" lint "$d") || rc=$?
  assert_not_contains "$out" "used 2 times" "supersede: a superseding duplicate id is valid"
  assert_not_contains "$out" "supersedes" "supersede: a valid supersedes is not flagged"
  assert_contains "$out" "item-without-checks: T2 is in scope but has no live checks" "supersede: an item whose checks are all retired has none"
  m=$("$REG" json "$d")
  [ "$(jq -r '.items[].checks[] | select(.id == "retire") | .state' <<<"$m")" = retired ] || fail "supersede: retired check state"
  [ "$(jq -c '.items[].checks[] | select(.id == "retire") | [.claim, .item, .note]' <<<"$m")" = '["claim retire","T1",null]' ] ||
    fail "supersede: a later line keeps the fields it leaves out and clears the ones it sets to null"
  [ "$(jq -c '.items[].checks[] | select(.id == "stg") | .required_by_env' <<<"$m")" = '{"local-new":["API"],"staging":["UI"]}' ] ||
    fail "supersede: layer_envs moves UI to staging, got $(jq -c '.items[].checks[] | select(.id == "stg") | .required_by_env' <<<"$m")"
  [ "$(jq -r '.items[].checks[] | select(.id == "stg") | .cells[] | select(.env == "local-new") | .state' <<<"$m")" = proven ] ||
    fail "supersede: local-new no longer owes UI"
  [ "$(jq -r '.items[].checks[] | select(.id == "uina") | .state' <<<"$m")" = proven ] || fail "supersede: ui_na added by a later line"
  [ "$(jq -r '.items[] | select(.id == "T2") | .state' <<<"$m")" = no-checks ] || fail "supersede: retired checks never set an item's state"
  [ "$(jq -r '.check_counts[] | select(.state == "retired") | .count' <<<"$m")" = 2 ] || fail "supersede: retired bucket"
  [ "$(jq '[.check_counts[].count] | add' <<<"$m")" = "$(jq '.totals.checks' <<<"$m")" ] || fail "supersede: counts do not add up"
  [ "$(jq -r '.items[].checks[] | select(.id == "uina") | .amendments' <<<"$m")" = 1 ] || fail "supersede: amendment count"
  check "$d" uina T1
  printf '%s\n' '{"id":"ghost","supersedes":"ghost"}' '{"id":"stg","supersedes":"uina"}' >> "$d/checks.jsonl"
  out=$("$REG" lint "$d") || true
  assert_contains "$out" "check id uina is used 2 times" "supersede: a duplicate id without supersedes stays invalid"
  assert_contains "$out" "supersedes ghost, but supersedes must name an earlier line" "supersede: a dangling supersedes is invalid"
  assert_contains "$out" "supersedes uina, but supersedes must name an earlier line's id, the same id as its own" \
    "supersede: supersedes must name the line's own id"
  pass "a later check line retires a check, moves a layer, or adds ui_na; lint guards the form"
}

test_round_lifecycle() {
  local d out rc m
  d=$(new_effort lifecycle)
  item "$d" T1
  item "$d" T2
  check "$d" a T1
  check "$d" b T1
  check "$d" c T2
  check "$d" gone T2 '{"retired":"no longer applies"}'
  rc=0; out=$("$REG" round open r3 "$d" --checks a,nope 2>&1) || rc=$?
  expect_code 2 "$rc" "lifecycle: open with an unknown check"
  assert_contains "$out" "unknown check nope" "lifecycle: open names the unknown check"
  rc=0; out=$("$REG" round open r3 "$d" --checks gone 2>&1) || rc=$?
  assert_contains "$out" "check gone is retired" "lifecycle: a retired check cannot be planned"
  rc=0; out=$("$REG" round open r1 "$d" --checks a 2>&1) || rc=$?
  assert_contains "$out" "already registered" "lifecycle: a round id is opened once"
  out=$("$REG" round open r3 "$d" --task task-r3 --checks a --items T2 --note "pilot") || fail "lifecycle: open failed: $out"
  assert_contains "$out" "opened round r3 with 2 planned check(s)" "lifecycle: --items adds the item's unretired checks"
  [ "$(tail -n 1 "$d/rounds.jsonl")" = '{"id":"r3","task":"task-r3","opened":"2026-10-15T20:00:00Z","planned":["a","c"],"note":"pilot"}' ] ||
    fail "lifecycle: open line, got $(tail -n 1 "$d/rounds.jsonl")"
  rc=0; out=$("$REG" round check r3 "$d") || rc=$?
  expect_code 1 "$rc" "lifecycle: an uncovered round"
  assert_contains "$out" "round r3: 2 of 2 planned check(s) have no line: a, c" "lifecycle: check lists the missing checks"
  rc=0; out=$("$REG" observe "$d" --round r3 --check a --env local-new --build "$NEW" --layer API --result NOT-RUN 2>&1) || rc=$?
  expect_code 2 "$rc" "lifecycle: NOT-RUN without a reason"
  assert_contains "$out" "NOT-RUN needs --reason" "lifecycle: the refusal names the missing reason"
  rc=0; out=$("$REG" observe "$d" --round r9 --check zz --env local-new --build "$NEW" --layer GUI --result PASS 2>&1) || rc=$?
  for want in "round r9 is not registered" "unknown check zz" "layer must be one of" "result must be one of"; do
    assert_contains "$out" "$want" "lifecycle: observe validation ($want)"
  done
  rc=0; out=$("$REG" observe "$d" --round r3 --check a --env local-new --build "$NEW" --layer API --result FIXED --supersedes nope 2>&1) || rc=$?
  assert_contains "$out" "--supersedes names no existing line nope" "lifecycle: a dangling supersedes is refused"
  rc=0; out=$("$REG" observe "$d" --round r3 --check a --env local-new --build "$NEW" --layer API --result FIXED --task x 2>&1) || rc=$?
  assert_contains "$out" "observe does not take --task" "lifecycle: options are checked per command"
  [ "$(grep -c '"round":"r3"' "$d/observations.jsonl")" -eq 0 ] || fail "lifecycle: a refused observation must write nothing"
  out=$("$REG" observe "$d" --round r3 --check a --env local-new --build "$NEW" --layer API --result FIXED --evidence ev/a --by task-r3) ||
    fail "lifecycle: observe failed: $out"
  assert_contains "$out" "recorded r3-1" "lifecycle: ids default to <round>-<n>"
  [ "$(tail -n 1 "$d/observations.jsonl")" = "{\"id\":\"r3-1\",\"check\":\"a\",\"round\":\"r3\",\"date\":\"2026-10-15\",\"env\":\"local-new\",\"build\":\"$NEW\",\"layer\":\"API\",\"result\":\"FIXED\",\"evidence\":\"ev/a\",\"recorded_by\":\"task-r3\"}" ] ||
    fail "lifecycle: observation line, got $(tail -n 1 "$d/observations.jsonl")"
  rc=0; out=$("$REG" observe "$d" --round r3 --check a --env local-new --build "$NEW" --layer UI --result FIXED --id r3-1 2>&1) || rc=$?
  assert_contains "$out" "line id r3-1 is already used" "lifecycle: duplicate ids are refused"
  out=$("$REG" observe "$d" --round r3 --check a --env local-new --build deadbeef99 --layer UI --result FIXED 2>&1) ||
    fail "lifecycle: an unregistered build is recorded with a warning: $out"
  assert_contains "$out" "is not registered in builds.jsonl; recorded anyway" "lifecycle: unregistered build warning"
  printf '%s\n' '{"id":"hand","check":"c","round":"r3","env":"local-new","build":"'"$NEW"'","layer":"API","result":"BLOCKED"}' >> "$d/observations.jsonl"
  rc=0; out=$("$REG" round close r3 "$d" 2>&1) || rc=$?
  expect_code 1 "$rc" "lifecycle: close refuses an uncovered round"
  assert_contains "$out" "round r3: 1 of 2 planned check(s) have no line: c" "lifecycle: a reasonless BLOCKED line does not count"
  assert_contains "$out" "not counted (malformed, or no reason for a result that needs one): line hand (c)" "lifecycle: the uncounted line is named"
  assert_contains "$out" "round r3 not closed" "lifecycle: close says why"
  [ "$(grep -c '"closed"' "$d/rounds.jsonl")" -eq 0 ] || fail "lifecycle: a refused close must append nothing"
  "$REG" observe "$d" --round r3 --check c --env local-new --build "$NEW" --layer API --result NOT-RUN --reason "no fixture" >/dev/null ||
    fail "lifecycle: NOT-RUN with a reason failed"
  out=$("$REG" round check --task task-r3 "$d") || fail "lifecycle: round check --task should pass once covered: $out"
  assert_contains "$out" "round r3: covered (2 of 2 planned checks have a line)" "lifecycle: NOT-RUN with a reason satisfies the gate"
  out=$("$REG" round check --task unrelated "$d") || fail "lifecycle: a task no round names passes"
  out=$("$REG" round close r3 "$d") || fail "lifecycle: close failed: $out"
  assert_contains "$out" "closed round r3" "lifecycle: close confirms"
  assert_contains "$out" "Test effort: 2 items" "lifecycle: close renders and prints the headline"
  assert_present "$d/board.html" "lifecycle: close writes the board"
  [ "$(tail -n 1 "$d/rounds.jsonl")" = '{"id":"r3","closed":"2026-10-15T20:00:00Z"}' ] || fail "lifecycle: close line"
  m=$("$REG" json "$d")
  [ "$(jq -c '.last_round | [.id, .task, .closed, .coverage.missing]' <<<"$m")" = '["r3","task-r3","2026-10-15T20:00:00Z",[]]' ] ||
    fail "lifecycle: the close line amends the round, got $(jq -c .last_round <<<"$m")"
  [ "$(jq '.rounds | length' <<<"$m")" = 3 ] || fail "lifecycle: an amended round is still one round"
  rc=0; out=$("$REG" round close r3 "$d" 2>&1) || rc=$?
  assert_contains "$out" "round r3 is already closed" "lifecycle: a round closes once"
  pass "round open, observe, check and close append validated lines and enforce coverage"
}

test_brief_section() {
  local d out rc=0 abs
  d=$(new_effort brief)
  abs=$(cd "$d" && pwd)
  item "$d" T1
  check "$d" a T1
  check "$d" b T1 '{"layer_envs":{"UI":["staging"]}}'
  rc=0; out=$("$REG" brief-section r1 "$d" 2>&1) || rc=$?
  expect_code 2 "$rc" "brief: a round with no plan"
  "$REG" round open r3 "$d" --task task-r3 --checks a,b >/dev/null || fail "brief: open failed"
  out=$("$REG" brief-section r3 "$d") || fail "brief: brief-section failed"
  assert_contains "$out" "# Ledger duty" "brief: heading"
  assert_contains "$out" "$REG observe '$abs' --round r3 --by task-r3" "brief: the exact observe command with absolute paths"
  assert_contains "$out" "- \`a\`: claim a. Layers: API, UI on local-new" "brief: planned check a with its layers"
  assert_contains "$out" "- \`b\`: claim b. Layers: API on local-new; UI on staging" "brief: per-environment layers"
  assert_contains "$out" "local-new \`$NEW\`" "brief: the current build"
  assert_contains "$out" "NOT-RUN with the reason. That always satisfies the gate" "brief: the honest-omission rule"
  assert_contains "$out" "$REG round check r3 '$abs'" "brief: the coverage command"
  pass "the Ledger duty section names the round, the planned checks, the command and the gate"
}

test_linear_read_at_render() {
  local d fb out m
  d=$(new_effort linear)
  item "$d" T1 '{"linear_id":"KG-1"}'
  item "$d" T2 '{"linear_id":"KG-2"}'
  check "$d" a T1
  check "$d" b T2
  fb=$(fm_fakebin "$TMP_ROOT/linear-bin")
  cat > "$fb/fake-linear" <<EOS
#!/usr/bin/env bash
echo run >> "$TMP_ROOT/linear-calls"
cat > "$TMP_ROOT/linear-stdin"
printf '%s\n' '{"ticket":"KG-1","status":"QA Passed","assignee":"dev"}' '{"ticket":"KG-2","status":"Backlog","extra":"ignored"}' '{"tokens":321}'
EOS
  printf '#!/usr/bin/env bash\necho "rate limited" >&2\nexit 3\n' > "$fb/broken-linear"
  chmod +x "$fb/fake-linear" "$fb/broken-linear"

  out=$("$REG" render "$d") || fail "linear: render without a reader failed"
  [ "$(tail -n 1 "$d/renders.jsonl" | jq -r .linear.action)" = not-read ] || fail "linear: no reader is recorded as not read"
  REGRESSION_LINEAR_CMD="$fb/fake-linear" "$REG" json "$d" >/dev/null
  assert_absent "$TMP_ROOT/linear-calls" "linear: json must never read Linear"

  REGRESSION_LINEAR_CMD="$fb/fake-linear" "$REG" render "$d" >/dev/null || fail "linear: render with a reader failed"
  [ "$(wc -l < "$TMP_ROOT/linear-calls" | tr -d ' ')" = 1 ] || fail "linear: one batched read per render"
  [ "$(cat "$TMP_ROOT/linear-stdin")" = $'KG-1\nKG-2' ] || fail "linear: every ticket goes to the one read on stdin"
  [ "$(tail -n 2 "$d/linear.jsonl" | jq -sc 'map([.ticket, .status, .assignee, .read_at, .extra])')" = \
    '[["KG-1","QA Passed","dev","2026-10-15T20:00:00Z",null],["KG-2","Backlog",null,"2026-10-15T20:00:00Z",null]]' ] ||
    fail "linear: statuses appended with the render time, got $(tail -n 2 "$d/linear.jsonl")"
  [ "$(tail -n 1 "$d/renders.jsonl" | jq -c '.linear | [.action, .tickets_requested, .tickets_returned, .tokens, (.bytes > 0)]')" = '["read",2,2,321,true]' ] ||
    fail "linear: the read and its cost are recorded, got $(tail -n 1 "$d/renders.jsonl")"
  m=$("$REG" json "$d")
  [ "$(jq -r '.last_render.linear.action' <<<"$m")" = read ] || fail "linear: the model carries the last render's read"
  [ "$(jq -r '.linear_read.newest' <<<"$m")" = 2026-10-15T20:00:00Z ] || fail "linear: the page shows the read time"

  REGRESSION_NOW=2026-10-15T23:00:00Z REGRESSION_LINEAR_CMD="$fb/fake-linear" "$REG" render "$d" >/dev/null
  [ "$(wc -l < "$TMP_ROOT/linear-calls" | tr -d ' ')" = 1 ] || fail "linear: a recent read is reused, not read again"
  assert_contains "$(tail -n 1 "$d/renders.jsonl")" "the last read attempt is 180 min old, under the 240 min re-read interval" "linear: reuse reason"
  REGRESSION_NOW=2026-10-15T23:00:00Z REGRESSION_LINEAR_MAX_AGE=0 REGRESSION_LINEAR_CMD="$fb/fake-linear" "$REG" render "$d" >/dev/null
  [ "$(wc -l < "$TMP_ROOT/linear-calls" | tr -d ' ')" = 2 ] || fail "linear: the re-read interval is configurable"

  out=$(REGRESSION_NOW=2026-10-15T23:30:00Z REGRESSION_LINEAR_MAX_AGE=0 REGRESSION_LINEAR_CMD="$fb/broken-linear" "$REG" render "$d") ||
    fail "linear: a failing reader must not stop the render"
  [ "$(tail -n 1 "$d/renders.jsonl" | jq -r .linear.reason)" = "the reader exited 3: rate limited" ] || fail "linear: failure recorded"
  [ "$(wc -l < "$d/linear.jsonl" | tr -d ' ')" = 4 ] || fail "linear: a failed read appends no statuses"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" '"'"'{"ticket":"KG-1","status":"Done"}'"'"' "not json"\n' > "$fb/malformed-linear"
  printf '#!/usr/bin/env bash\necho run >> "%s/empty-calls"\nexit 0\n' "$TMP_ROOT" > "$fb/empty-linear"
  chmod +x "$fb/malformed-linear" "$fb/empty-linear"
  out=$(REGRESSION_NOW=2026-10-15T23:45:00Z REGRESSION_LINEAR_MAX_AGE=0 REGRESSION_LINEAR_CMD="$fb/malformed-linear" "$REG" render "$d") ||
    fail "linear: a reader with a malformed line must not stop the render"
  [ "$(tail -n 1 "$d/renders.jsonl" | jq -r .linear.action)" = failed ] || fail "linear: malformed output is recorded as failed"
  [ "$(wc -l < "$d/linear.jsonl" | tr -d ' ')" = 4 ] || fail "linear: malformed output appends no partial statuses"

  d=$(new_effort linear-empty)
  item "$d" T1 '{"linear_id":"KG-1"}'
  check "$d" a T1
  REGRESSION_LINEAR_CMD="$fb/empty-linear" "$REG" render "$d" >/dev/null
  REGRESSION_LINEAR_CMD="$fb/empty-linear" "$REG" render "$d" >/dev/null
  [ "$(wc -l < "$TMP_ROOT/empty-calls" | tr -d ' ')" = 1 ] || fail "linear: a reader that returns no rows is not re-run within the interval"
  pass "Linear status is one batched read per render, reused while recent, and measured"
}

test_teardown_refuses_uncovered_round() {
  local home efforts d out rc
  home="$TMP_ROOT/teardown-home"
  efforts="$home/data/regressions"
  mkdir -p "$efforts" "$home/state" "$home/config" "$home/projects"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fm_fake_exit0 "$(fm_fakebin "$home")" tmux treehouse no-mistakes gh gh-axi tasks-axi
  d="$efforts/effort"
  "$REG" init "$d" >/dev/null
  jq '.envs = ["local-new"]' "$d/effort.json" > "$d/e.tmp" && mv "$d/e.tmp" "$d/effort.json"
  printf '%s\n' "{\"env\":\"local-new\",\"sha\":\"$NEW\",\"role\":\"target\",\"current\":true}" > "$d/builds.jsonl"
  item "$d" T1
  check "$d" a T1
  "$REG" round open r1 "$d" --task round-task --checks a >/dev/null || fail "teardown: open failed"
  for id in round-task other-task; do
    fm_write_meta "$home/state/$id.meta" "window=firstmate:fm-$id" "worktree=$home/projects/missing-$id" \
      "project=$home/projects/sample" "harness=codex" "kind=tester" "mode=tester"
    mkdir -p "$home/data/$id"
    printf '# Report\n' > "$home/data/$id/report.md"
  done
  run_td() {
    PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-teardown.sh" "$1" 2>&1
  }
  rc=0; out=$(run_td round-task) || rc=$?
  [ "$rc" -ne 0 ] || fail "teardown: an uncovered round must refuse"
  assert_contains "$out" "REFUSED: tester task round-task ran a regression round with planned checks that have no recorded result" "teardown: plain refusal"
  assert_contains "$out" "round r1: 1 of 1 planned check(s) have no line: a" "teardown: the refusal lists the missing checks"
  assert_present "$home/state/round-task.meta" "teardown: a refused teardown keeps the task"
  rc=0; out=$(run_td other-task) || rc=$?
  assert_not_contains "$out" "regression round" "teardown: a task no round names is untouched"
  "$REG" observe "$d" --round r1 --check a --env local-new --build "$NEW" --layer API --result NOT-RUN --reason "no fixture" >/dev/null
  rc=0; out=$(run_td round-task) || rc=$?
  assert_not_contains "$out" "regression round" "teardown: a covered round no longer refuses"
  pass "teardown refuses a tester whose round has uncovered checks and leaves other tasks alone"
}

run_case test_empty_effort
run_case test_derived_states
run_case test_counts_add_up_and_not_proven
run_case test_lint_rules
run_case test_changed_since_last_round
run_case test_baseline_env_in_check_envs
run_case test_decisions_read_from_backlog
run_case test_page_self_contained
run_case test_superseding_checks
run_case test_round_lifecycle
run_case test_brief_section
run_case test_linear_read_at_render
run_case test_teardown_refuses_uncovered_round
fm_case_summary "fm-regression"
