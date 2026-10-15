# fm-regression.jq - the derive step of bin/fm-regression.sh.
#
# Input arguments (all supplied by fm-regression.sh, never by hand):
#   $effort     [effort.json]          $builds  builds.jsonl     $items   items.jsonl
#   $checks     checks.jsonl           $observations  observations.jsonl
#   $rounds     rounds.jsonl           $linear  linear.jsonl     $relays  relays.jsonl
#   $decisions  [{key: {state, title}}] read through tasks-axi at render time
#   $now        render time, ISO 8601 UTC
# Output: one JSON model holding every derived state, count, panel, and lint failure.
# docs/regression-ledger.md owns the record contract; this file owns the derivation.
# Nothing here is stored back: every state is recomputed from the append-only records.

def layers: ["code", "API", "DB", "log", "UI"];
def results: ["FIXED", "STILL-OPEN", "AS-DESIGNED", "OBSERVED", "NOT-RUN", "NOT-TESTABLE", "BLOCKED"];
def needs_reason: ["NOT-RUN", "NOT-TESTABLE", "BLOCKED"];
def runtime: ["API", "DB", "log", "UI"];
def proof: ["FIXED", "AS-DESIGNED"];

# Check states, worst first. The item state is the worst of its checks' states, and
# readiness needs every check to be proven or as-designed.
def states: ["still-open", "never-observed", "unknown", "stale", "code-only", "blocked",
  "not-run", "not-testable", "layer-owed", "ui-owed", "as-designed", "proven"];
def labels: {
  "still-open": "confirmed still open", "never-observed": "never observed", "unknown": "unknown build",
  "stale": "stale (older build only)", "code-only": "code reading only", "blocked": "blocked",
  "not-run": "not run", "not-testable": "not testable here", "layer-owed": "server layer still owed",
  "ui-owed": "UI still owed", "as-designed": "as designed (ruled)", "proven": "proven fixed",
  "out-of-scope": "out of scope", "no-checks": "no checks yet", "baseline": "baseline only"};
def rank: . as $s | states | index($s);
def worst: if length == 0 then "never-observed" else min_by(rank) end;

# A derived state as a verdict a ticket can carry, or null when there is nothing to relay.
def verdict_class:
  if . == "proven" or . == "ui-owed" or . == "layer-owed" then "fixed"
  elif . == "still-open" then "still-open"
  elif . == "as-designed" then "as-designed"
  else null end;

$effort[0] as $E
| ($E.envs // ["local-old", "local-new", "staging-old", "staging-new", "prod"]) as $ENVS
| ($E.target_envs // ["local-new"]) as $TARGET_ENVS
| ($E.default_required_layers // ["API", "UI"]) as $DEFAULT_LAYERS
| ($E.linear.done_statuses // ["Done"]) as $DONE
| ($E.linear.closed_statuses // ["Canceled", "Won't Fix", "Duplicate"]) as $CLOSED
| ($rounds | map(.id)) as $ROUND_IDS
| ($observations | to_entries | map(.value + {_i: .key})) as $OBS_ALL
| ([$OBS_ALL[] | .supersedes // empty]) as $SUPERSEDED
| ($OBS_ALL | map(select(.id as $id | $SUPERSEDED | index($id) | not))) as $LIVE
| ($decisions[0] // {}) as $DEC

# A build reference matches a registered sha when either is a prefix of the other
# (at least 7 characters), so short and full shas name the same build.
| def same_build($a; $b):
    if $a == "unidentified" or $b == "unidentified" then $a == $b
    else ($a | length) >= 7 and ($b | length) >= 7 and ($a | startswith($b) or ($b | startswith($a))) end;
  def registered($o): any($builds[]; .env == $o.env and same_build(.sha; $o.build));
  def current_build($env): [$builds[] | select(.env == $env and .current == true)] | first;
  def round_rank($r): ($ROUND_IDS | index($r)) // 1e9;
  def required($c):
    ($c.required_layers // $DEFAULT_LAYERS) as $l
    | if ($c.ui_na // "") != "" then $l - ["UI"] else ($l + ["UI"] | unique) end;
  def latest_by_layer($os):
    $os | sort_by([round_rank(.round), ._i]) | group_by(.layer) | map({key: .[0].layer, value: last}) | from_entries;

  # One cell: one check in one environment, judged against that environment's current build.
  def cell($c; $env; $os):
    ($os | map(select(.check == $c.id and .env == $env))) as $mine
    | current_build($env) as $cur
    | if ($mine | length) == 0 then {state: "never-observed"}
      elif $cur == null then {state: "unknown", detail: "no current build is registered for \($env)"}
      elif $cur.role == "baseline" then {state: "baseline", detail: "baseline build: observations only, never pass or fail"}
      elif $cur.sha == "unidentified" then
        {state: "unknown", detail: "the current \($env) build is unidentified, so these results cannot be tied to a code version"}
      else
        ($mine | map(select(same_build(.build; $cur.sha)))) as $on
        | ($mine | map(select((same_build(.build; $cur.sha) | not) and (.layer | IN(runtime[]))))) as $older_rt
        | if ($on | length) == 0 then
            (if any($mine[]; .build == "unidentified")
             then {state: "unknown", detail: "results are on an unidentified build"}
             else {state: "stale", detail: "seen only on an older build"} end)
          else
            latest_by_layer($on) as $L
            | required($c) as $req
            | ([runtime[] as $k | $L[$k] // empty]) as $rt
            | ([$req[] as $k | $L[$k].result // "none"]) as $reqres
            | ($rt | map(select(.result | IN(proof[])))) as $rt_ok
            | ([$req[] | select(($L[.].result // "none") | IN(proof[]) | not)]) as $owed
            | if any($rt[]; .result == "STILL-OPEN") then {state: "still-open"}
              elif ($owed | length) == 0 then
                (if any($req[]; $L[.].result == "AS-DESIGNED") then {state: "as-designed"} else {state: "proven"} end)
              elif ($rt_ok | length) > 0 then
                (if ($owed | index("UI")) then {state: "ui-owed", owed: $owed} else {state: "layer-owed", owed: $owed} end)
              elif ($L.code.result // "none" | IN(["FIXED", "STILL-OPEN", "AS-DESIGNED"][])) then
                (if ($older_rt | length) > 0
                 then {state: "stale", detail: "the current build has a code reading only (\($L.code.result)); runtime results are on an older build"}
                 else {state: "code-only", detail: "code reading only (\($L.code.result)); never counts as fixed"} end)
              elif any($reqres[]; . == "BLOCKED") then {state: "blocked"}
              elif any($reqres[]; . == "NOT-RUN") then {state: "not-run"}
              elif any($reqres[]; . == "NOT-TESTABLE") then {state: "not-testable"}
              elif ($older_rt | length) > 0 then {state: "stale", detail: "seen only on an older build"}
              else {state: "never-observed", detail: "no result at a required layer"} end
          end
      end
    | . + {env: $env};

  def check_envs($c): $c.envs // $TARGET_ENVS;
  def check_state($c; $os): [check_envs($c)[] as $e | select(current_build($e).role != "baseline") | cell($c; $e; $os).state] | worst;

# ---- items, checks, cells ----------------------------------------------------
($items | map(.id)) as $ITEM_IDS
| ($checks | map(. as $c | {
    id, item: .item, claim, arm: (.arm // "other"), required: required($c), ui_na: (.ui_na // null),
    envs: check_envs($c), note: (.note // null), unblock: (.unblock // null),
    added_in_round: (.added_in_round // null),
    cells: [$ENVS[] as $e | cell($c; $e; $LIVE) + {
      required_env: (check_envs($c) | index($e) != null),
      observations: [$OBS_ALL[] | select(.check == $c.id and .env == $e)
        | . + {superseded: (.id as $id | $SUPERSEDED | index($id) != null)}]
    }],
    state: check_state($c; $LIVE)
  })) as $CHECKS
| ($linear | sort_by(.read_at) | group_by(.ticket) | map({key: .[0].ticket, value: {latest: last, previous: (if length > 1 then .[-2] else null end)}}) | from_entries) as $LIN
| ($items | map(. as $it
    | ($CHECKS | map(select(.item == $it.id))) as $cs
    | (if ($it.scope // "in") == "out" then "out-of-scope"
       elif ($cs | length) == 0 then "no-checks"
       else ($cs | map(.state) | worst) end) as $st
    | ($it.decision_keys // []) as $keys
    | $it + {
        scope: ($it.scope // "in"), checks: $cs, state: $st, verdict: ($st | verdict_class),
        linear: (if $it.linear_id then $LIN[$it.linear_id].latest else null end),
        decisions: [$keys[] as $k | {key: $k} + ($DEC[$k] // {state: "not-read"})],
        relays: [$relays[] | select(.item == $it.id)]
      })) as $ITEMS

# ---- lint --------------------------------------------------------------------
| ([ $ITEMS[] | select(.scope != "out" and .linear != null and (.linear.status | IN($CLOSED[]) | not))
    | (.linear.status | IN($DONE[])) as $done
    | select(($done and (.verdict | IN("fixed", "as-designed") | not)) or (($done | not) and (.verdict | IN("fixed", "as-designed"))))
    | {rule: "linear-disagrees", item: .id,
       message: "\(.linear_id) is \(.linear.status) in Linear (read \(.linear.read_at)), but our evidence says \(labels[.state])"} ]) as $L_B
| ([ $ITEMS[] | select(.verdict != null) | . as $it
    | select(any(.relays[]; .verdict == $it.verdict) | not)
    | {rule: "not-relayed", item: .id,
       message: "\(.linear_id // .id): our verdict is \(.verdict) and no relay or recorded hold-back carries it"} ]) as $L_E
| ([ ($LIN | keys[]) as $t | select(any($items[]; .linear_id == $t) | not)
    | {rule: "ticket-without-item", item: null, message: "\($t) is in the Linear snapshot but no item tracks it"} ]
  + $L_B
  + [ $OBS_ALL[] | select(registered(.) | not)
      | {rule: "unregistered-build", item: null, message: "observation \(.id // "?") on \(.env) build \(.build) names no registered build"} ]
  + $L_E
  + [ $ITEMS[] | select(.scope != "out" and (.checks | length) == 0)
      | {rule: "item-without-checks", item: .id, message: "\(.id) is in scope but has no checks"} ]
  + [ $OBS_ALL[] | select(.id == null or .check == null or .env == null or .build == null or .round == null)
      | {rule: "invalid-record", item: null, message: "observation line \(._i + 1) lacks one of id, check, env, build, round"} ]
  + [ $OBS_ALL[] | select(.layer as $l | layers | index($l) | not)
      | {rule: "invalid-record", item: null, message: "observation \(.id) has unknown layer \(.layer)"} ]
  + [ $OBS_ALL[] | select(.result as $r | results | index($r) | not)
      | {rule: "invalid-record", item: null, message: "observation \(.id) has unknown result \(.result)"} ]
  + [ $OBS_ALL[] | select((.result | IN(needs_reason[])) and ((.reason // "") == ""))
      | {rule: "invalid-record", item: null, message: "observation \(.id) is \(.result) with no reason"} ]
  + [ $OBS_ALL[] | select(.supersedes != null) | select(.supersedes as $s | any($OBS_ALL[]; .id == $s) | not)
      | {rule: "invalid-record", item: null, message: "observation \(.id) supersedes unknown line \(.supersedes)"} ]
  + [ $OBS_ALL[] | select(.round as $r | $r != null and ($ROUND_IDS | index($r)) == null)
      | {rule: "invalid-record", item: null, message: "observation \(.id) names unregistered round \(.round)"} ]
  + [ $OBS_ALL[] | select(.check as $k | any($checks[]; .id == $k) | not)
      | {rule: "invalid-record", item: null, message: "observation \(.id) names unknown check \(.check)"} ]
  + [ $OBS_ALL | group_by(.id)[] | select(length > 1 and .[0].id != null)
      | {rule: "invalid-record", item: null, message: "observation id \(.[0].id) is used \(length) times"} ]
  + [ $checks[] | select(.item as $i | $ITEM_IDS | index($i) | not)
      | {rule: "invalid-record", item: null, message: "check \(.id) names unknown item \(.item)"} ]
  + [ $checks | group_by(.id)[] | select(length > 1)
      | {rule: "invalid-record", item: null, message: "check id \(.[0].id) is used \(length) times"} ]
  + [ $checks[] | select(has("ui_na") and ((.ui_na // "") == ""))
      | {rule: "invalid-record", item: null, message: "check \(.id) marks UI n/a with no reason"} ]
  ) as $LINT

# ---- counts and readiness ----------------------------------------------------
| ($CHECKS | map(.item as $i | . + {out: any($ITEMS[]; .id == $i and .scope == "out")})) as $CK
| ([states[] as $s | {state: $s, count: ($CK | map(select((.out | not) and .state == $s)) | length)}]
   + [{state: "out-of-scope", count: ($CK | map(select(.out)) | length)}]) as $CHECK_COUNTS
| ([(states + ["no-checks", "out-of-scope"])[] as $s | {state: $s, count: ($ITEMS | map(select(.state == $s)) | length)}]) as $ITEM_COUNTS
| if ($CHECK_COUNTS | map(.count) | add) != ($CK | length) or ($ITEM_COUNTS | map(.count) | add) != ($ITEMS | length)
  then error("headline counts do not add up to the totals") else . end
| ($CK | map(select((.out | not) and (.state | IN("proven", "as-designed") | not))) | length) as $UNPROVEN
| ($ITEMS | map(select(.state == "no-checks")) | length) as $EMPTY_ITEMS
| ({ready: (($CK | length) > 0 and $UNPROVEN == 0 and $EMPTY_ITEMS == 0 and ($LINT | length) == 0),
    reason: (if ($CK | length) == 0 then "no checks are tracked yet"
             elif $UNPROVEN > 0 then "\($UNPROVEN) check(s) not yet proven on the target build"
             elif $EMPTY_ITEMS > 0 then "\($EMPTY_ITEMS) item(s) have no checks"
             elif ($LINT | length) > 0 then "\($LINT | length) lint failure(s)"
             else "every check is proven or ruled as designed" end)}) as $READY

# ---- panels ------------------------------------------------------------------
| ($ITEMS | map(select(.scope != "out" and (.state | IN("proven", "as-designed") | not)) | . as $it
    | (.checks | map(select(.state | IN("proven", "as-designed") | not))) as $open
    | ($open | map(.state) | worst) as $w
    | (if $it.unblock then $it.unblock
       elif any($it.decisions[]; .state == "open") then "decision"
       elif ([$open[].unblock // empty] | length) > 0 then [$open[].unblock // empty][0]
       elif ($open | length) == 0 then "define-checks"
       elif $w == "still-open" then "dev"
       elif $w == "not-testable" then "fixture"
       elif all($open[]; all(.envs[]; startswith("local") | not)) then "staging"
       else "round" end) as $why
    | {item: .id, title: .title, linear_id, state, unblock: $why, next_action: (.next_action // null),
       open_checks: [$open[] | {id, state}]})
  | group_by(.unblock) | map({unblock: .[0].unblock, items: .})) as $PANEL_A
| (if ($rounds | length) >= 2 then
    $rounds[-1].id as $last | $rounds[-2].id as $prev
    | ($LIVE | map(select(round_rank(.round) <= round_rank($prev)))) as $before
    | ($LIVE | map(select(round_rank(.round) <= round_rank($last)))) as $after
    | {from: $prev, to: $last,
       cells: [$checks[] as $c | {check: $c.id, item: $c.item,
         before: check_state($c; $before), after: check_state($c; $after)} | select(.before != .after)]}
   else {from: null, to: ($rounds[-1].id // null), cells: []} end) as $DIFF
| ([$LIN | to_entries[] | select(.value.previous != null and .value.previous.status != .value.latest.status)
    | {ticket: .key, from: .value.previous.status, to: .value.latest.status, read_at: .value.latest.read_at}]) as $LIN_MOVES
| ([$ITEMS[].decisions[]] | unique_by(.key)) as $ALL_DEC
| {
    labels: labels,
    effort: {id: $E.id, title: ($E.title // $E.id), envs: $ENVS, target_envs: $TARGET_ENVS,
      evidence_root: ($E.evidence_root // null), note: ($E.note // null)},
    rendered_at: $now,
    linear_read: {oldest: ([$LIN[] | .latest.read_at] | min), newest: ([$LIN[] | .latest.read_at] | max),
      tickets: ($LIN | length)},
    last_round: ($rounds[-1] // null),
    rounds: $rounds,
    builds: $builds,
    totals: {items: ($ITEMS | length), checks: ($CK | length)},
    check_counts: $CHECK_COUNTS, item_counts: $ITEM_COUNTS,
    ready: $READY,
    lint: $LINT,
    decisions_read: ($decisions[0] != null),
    panel_a: $PANEL_A,
    panel_b: {rounds: $DIFF, linear: $LIN_MOVES},
    panel_c: {decisions: $ALL_DEC, linear_disagrees: $L_B, not_relayed: $L_E},
    items: $ITEMS
  }
