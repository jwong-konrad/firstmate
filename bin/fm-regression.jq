# fm-regression.jq - the derive step of bin/fm-regression.sh.
#
# Input arguments (all supplied by fm-regression.sh, never by hand):
#   $effort     [effort.json]          $builds  builds.jsonl     $items   items.jsonl
#   $checks     checks.jsonl           $observations  observations.jsonl
#   $rounds     rounds.jsonl           $linear  linear.jsonl     $relays  relays.jsonl
#   $renders    renders.jsonl          $decisions  [{key: {state, title}}] read through tasks-axi
#   $now        render time, ISO 8601 UTC
# Output: one JSON model holding every derived state, count, panel, and lint failure.
# docs/regression-ledger.md owns the record contract; this file owns the derivation.
# Nothing here is stored back: every state is recomputed from the append-only records.

def layers: ["code", "API", "DB", "log", "UI"];
def results: ["FIXED", "STILL-OPEN", "AS-DESIGNED", "OBSERVED", "NOT-RUN", "NOT-TESTABLE", "BLOCKED"];
def needs_reason: ["NOT-RUN", "NOT-TESTABLE", "BLOCKED"];
def runtime: ["API", "DB", "log", "UI"];
def proof: ["FIXED", "AS-DESIGNED"];

# Check states, worst first. The item state is the worst of its live checks' states.
# A retired check is counted in its own bucket and never sets an item's state.
def states: ["still-open", "never-observed", "unknown", "stale", "code-only", "blocked",
  "not-run", "not-testable", "layer-owed", "ui-owed", "as-designed", "proven"];
def labels: {
  "still-open": "confirmed still open", "never-observed": "never observed", "unknown": "unknown build",
  "stale": "stale (older build only)", "code-only": "code reading only", "blocked": "blocked",
  "not-run": "not run", "not-testable": "not testable here", "layer-owed": "server layer still owed",
  "ui-owed": "UI still owed", "as-designed": "as designed (ruled)", "proven": "proven fixed",
  "out-of-scope": "out of scope", "no-checks": "no checks yet", "baseline": "baseline only",
  "retired": "retired"};
def rank: . as $s | states | index($s);
def worst: if length == 0 then "never-observed" else min_by(rank) end;
def uniq_ordered: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);

# An observation line that can count toward a round's coverage: well formed, with a reason
# when its result needs one.
def valid_line:
  .id != null and .check != null and .env != null and .build != null and .round != null
  and (.layer | IN(layers[])) and (.result | IN(results[]))
  and ((.result | IN(needs_reason[]) | not) or ((.reason // "") != ""));

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
# A later rounds line with the same id amends the round (round close appends {id, closed});
# a round keeps the position of its first line, so the file order stays chronological.
| (reduce ($rounds[] | select((.id | type) == "string")) as $r ([];
    (map(.id) | index($r.id)) as $at
    | if $at == null then . + [$r] else .[$at] = (.[$at] + $r) end)) as $ROUNDS
| ($ROUNDS | map(.id)) as $ROUND_IDS
# A later checks line whose supersedes names its own id amends that check: its fields replace
# the earlier ones and a null clears one. Any other repeated id is a lint failure.
| ($checks | to_entries | map(.value + {_i: .key})) as $CHECK_LINES
| ([$CHECK_LINES[] | . as $l
    | select(($l.supersedes // null) != null and $l.supersedes == $l.id
        and any($CHECK_LINES[]; .id == $l.id and ._i < $l._i))]) as $CHECK_AMENDS
| ([$CHECK_LINES[] | select((.id | type) == "string") | . as $l
    | select(any($CHECK_LINES[]; .id == $l.id and ._i < $l._i) | not)
    | reduce ($CHECK_AMENDS[] | select(.id == $l.id)) as $a ($l; . + $a)
    | . + {amendments: ([$CHECK_AMENDS[] | select(.id == $l.id)] | length)}
    | del(.supersedes, ._i) | with_entries(select(.value != null))]) as $CHECKS_LIVE
# A build is named by its env and sha together. A later builds line with the same env and sha
# whose supersedes names that sha amends the build the same way. The current build of an
# environment is the one whose latest line saying current: true comes last, so registering a
# newer current build wins over an older one without editing it.
| ($builds | to_entries | map(.value + {_i: .key})) as $BUILD_LINES
| ([$BUILD_LINES[] | . as $l
    | select(($l.supersedes // null) != null and $l.supersedes == $l.sha
        and any($BUILD_LINES[]; .env == $l.env and .sha == $l.sha and ._i < $l._i))]) as $BUILD_AMENDS
| ([$BUILD_LINES[] | select((.env | type) == "string" and (.sha | type) == "string") | . as $l
    | select(any($BUILD_LINES[]; .env == $l.env and .sha == $l.sha and ._i < $l._i) | not)
    | ([$l] + [$BUILD_AMENDS[] | select(.env == $l.env and .sha == $l.sha)]) as $ls
    | reduce $ls[1:][] as $a ($l; . + $a)
    | . + {amendments: ($ls | length - 1), _cur: ([$ls[] | select(.current == true) | ._i] | max)}
    | del(.supersedes) | with_entries(select(.value != null))]) as $BUILDS_MERGED
| ($BUILDS_MERGED | map(. as $b
    | . + {current: (.current == true
        and ([$BUILDS_MERGED[] | select(.env == $b.env and .current == true) | ._cur] | max) == $b._cur)}
    | del(._i, ._cur))) as $BUILDS
| ($observations | to_entries | map(.value + {_i: .key})) as $OBS_ALL
| ([$OBS_ALL[] | .supersedes // empty]) as $SUPERSEDED
| ($OBS_ALL | map(select(.id as $id | $SUPERSEDED | index($id) | not))) as $LIVE
| ($decisions[0] // {}) as $DEC

# A build reference matches a registered sha when either is a prefix of the other
# (at least 7 characters), so short and full shas name the same build.
| def same_build($a; $b):
    if $a == "unidentified" or $b == "unidentified" then $a == $b
    else ($a | length) >= 7 and ($b | length) >= 7 and ($a | startswith($b) or ($b | startswith($a))) end;
  def registered($o): any($BUILDS[]; .env == $o.env and same_build(.sha; $o.build));
  def current_build($env): [$BUILDS[] | select(.env == $env and .current == true)] | first;
  def round_rank($r): ($ROUND_IDS | index($r)) // 1e9;
  def required($c):
    ($c.required_layers // $DEFAULT_LAYERS) as $l
    | if ($c.ui_na // "") != "" then $l - ["UI"] else ($l + ["UI"] | unique) end;
  # layer_envs moves a layer to its own environments, for example UI on staging only; every
  # other required layer applies in the check's envs.
  def base_envs($c): $c.envs // $TARGET_ENVS;
  def required_in($c; $env):
    ($c.layer_envs // {}) as $le
    | [required($c)[] | select((if $le[.] then $le[.] else base_envs($c) end) | index($env) != null)];
  def check_envs($c):
    [(base_envs($c) + ([($c.layer_envs // {})[]] | add // [])) | uniq_ordered | .[]
     | select(required_in($c; .) | length > 0)];
  def required_at($c; $env): if check_envs($c) | index($env) != null then required_in($c; $env) else required($c) end;
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
            | required_at($c; $env) as $req
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

  def retired($c): ($c.retired // "") != "";
  def check_state($c; $os):
    if retired($c) then "retired"
    else [check_envs($c)[] as $e | select(current_build($e).role != "baseline") | cell($c; $e; $os).state] | worst end;

# ---- items, checks, cells ----------------------------------------------------
($items | map(.id)) as $ITEM_IDS
| ($CHECKS_LIVE | map(. as $c | {
    id, item: .item, claim, arm: (.arm // "other"), group: (.group // null), required: required($c), ui_na: (.ui_na // null),
    envs: check_envs($c), layer_envs: (.layer_envs // null), retired: (.retired // null),
    required_by_env: ([check_envs($c)[] as $e | {key: $e, value: required_in($c; $e)}] | from_entries),
    amendments, note: (.note // null), unblock: (.unblock // null),
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
    | ($cs | map(select(.state != "retired"))) as $live
    | (if ($it.scope // "in") == "out" then "out-of-scope"
       elif ($live | length) == 0 then "no-checks"
       else ($live | map(.state) | worst) end) as $st
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
  + [ $ITEMS[] | select(.state == "no-checks")
      | {rule: "item-without-checks", item: .id, message: "\(.id) is in scope but has no live checks"} ]
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
  + [ $OBS_ALL[] | select(.check as $k | any($CHECKS_LIVE[]; .id == $k) | not)
      | {rule: "invalid-record", item: null, message: "observation \(.id) names unknown check \(.check)"} ]
  + [ $OBS_ALL | group_by(.id)[] | select(length > 1 and .[0].id != null)
      | {rule: "invalid-record", item: null, message: "observation id \(.[0].id) is used \(length) times"} ]
  + [ $CHECK_LINES[] | select((.id | type) != "string" or (.supersedes == null and (.item == null or .claim == null)))
      | {rule: "invalid-record", item: null, message: "check line \(._i + 1) lacks one of id, item, claim"} ]
  + [ $CHECK_LINES[] | select(.supersedes != null) | . as $l
      | select($l.supersedes != $l.id or (any($CHECK_LINES[]; .id == $l.id and ._i < $l._i) | not))
      | {rule: "invalid-record", item: null,
         message: "check line \($l._i + 1) supersedes \($l.supersedes), but supersedes must name an earlier line's id, the same id as its own"} ]
  + [ $CHECK_LINES | map(select(.supersedes == null)) | group_by(.id)[] | select(length > 1)
      | {rule: "invalid-record", item: null, message: "check id \(.[0].id) is used \(length) times; a later line amends it only with supersedes"} ]
  + [ $CHECKS_LIVE[] | select(.item as $i | $ITEM_IDS | index($i) | not)
      | {rule: "invalid-record", item: null, message: "check \(.id) names unknown item \(.item)"} ]
  + [ $CHECKS_LIVE[] | select(has("ui_na") and ((.ui_na // "") == ""))
      | {rule: "invalid-record", item: null, message: "check \(.id) marks UI n/a with no reason"} ]
  + [ $CHECKS_LIVE[] | select(has("retired") and ((.retired | type) != "string" or .retired == ""))
      | {rule: "invalid-record", item: null, message: "check \(.id) is retired with no reason"} ]
  + [ $CHECKS_LIVE[] | select(has("layer_envs")) | . as $c
      | select((.layer_envs | type) != "object"
          or any(.layer_envs | to_entries[]; (.key | IN(layers[]) | not) or (.value | type) != "array"))
      | {rule: "invalid-record", item: null, message: "check \($c.id) has a layer_envs that is not {layer: [env, ...]}"} ]
  + [ $CHECKS_LIVE[] | select(has("group") and ((.group | type) != "string" or .group == ""))
      | {rule: "invalid-record", item: null, message: "check \(.id) has a group that is not a non-empty name"} ]
  + [ $BUILD_LINES[] | select((.env | type) != "string" or (.sha | type) != "string")
      | {rule: "invalid-record", item: null, message: "build line \(._i + 1) lacks one of env, sha"} ]
  + [ $BUILD_LINES[] | select(.supersedes != null) | . as $l
      | select($l.supersedes != $l.sha or (any($BUILD_LINES[]; .env == $l.env and .sha == $l.sha and ._i < $l._i) | not))
      | {rule: "invalid-record", item: null,
         message: "build line \($l._i + 1) supersedes \($l.supersedes), but supersedes must name an earlier line's sha in the same env, the same sha as its own"} ]
  + [ $BUILD_LINES | map(select(.supersedes == null and (.env | type) == "string" and (.sha | type) == "string"))
      | group_by([.env, .sha])[] | select(length > 1)
      | {rule: "invalid-record", item: null, message: "\(.[0].env) build \(.[0].sha) is registered \(length) times; a later line amends it only with supersedes"} ]
  + [ $ROUNDS[] | select(has("planned")) | . as $r
      | if (.planned | type) != "array" then {rule: "invalid-record", item: null, message: "round \($r.id) planned is not a list"}
        else (.planned[] | select(. as $k | any($CHECKS_LIVE[]; .id == $k) | not)
          | {rule: "invalid-record", item: null, message: "round \($r.id) plans unknown check \(.)"}) end ]
  ) as $LINT

# ---- counts ------------------------------------------------------------------
| ($CHECKS | map(.item as $i | . + {out: any($ITEMS[]; .id == $i and .scope == "out")})) as $CK
| ([states[] as $s | {state: $s, count: ($CK | map(select((.out | not) and .state == $s)) | length)}]
   + [{state: "out-of-scope", count: ($CK | map(select(.out)) | length)},
      {state: "retired", count: ($CK | map(select((.out | not) and .state == "retired")) | length)}]) as $CHECK_COUNTS
| ([(states + ["no-checks", "out-of-scope"])[] as $s | {state: $s, count: ($ITEMS | map(select(.state == $s)) | length)}]) as $ITEM_COUNTS
| if ($CHECK_COUNTS | map(.count) | add) != ($CK | length) or ($ITEM_COUNTS | map(.count) | add) != ($ITEMS | length)
  then error("headline counts do not add up to the totals") else . end
# The board reports what is not yet proven and never a readiness verdict: whether to move
# to the next stage is the team's decision, not the tool's.
| ({checks: ($CK | map(select((.out | not) and (.state | IN("proven", "as-designed", "retired") | not))) | length),
    items_without_checks: ($ITEMS | map(select(.state == "no-checks")) | length)}) as $NOT_PROVEN
# Round coverage: every planned, unretired check needs at least one well-formed line in the round.
| ($ROUNDS | map(. as $r
    | if has("planned") and (.planned | type) == "array" then
        ([.planned[] | select(. as $k | any($CHECKS_LIVE[]; .id == $k and (retired(.) | not)))] | uniq_ordered) as $need
        | ($OBS_ALL | map(select(.round == $r.id))) as $lines
        | . + {coverage: {
            planned: ($need | length),
            missing: [$need[] | select(. as $k | any($lines[]; .check == $k and valid_line) | not)],
            not_counted: [$lines[] | select(valid_line | not) | "line \(.id // ._i + 1) (\(.check // "no check"))"]}}
      else . end)) as $ROUNDS_COV

# ---- panels ------------------------------------------------------------------
| ($ITEMS | map(select(.scope != "out" and (.state | IN("proven", "as-designed") | not)) | . as $it
    | (.checks | map(select(.state | IN("proven", "as-designed", "retired") | not))) as $open
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
| (if ($ROUNDS | length) >= 2 then
    $ROUNDS[-1].id as $last | $ROUNDS[-2].id as $prev
    | ($LIVE | map(select(round_rank(.round) <= round_rank($prev)))) as $before
    | ($LIVE | map(select(round_rank(.round) <= round_rank($last)))) as $after
    | {from: $prev, to: $last,
       cells: [$CHECKS_LIVE[] as $c | {check: $c.id, item: $c.item,
         before: check_state($c; $before), after: check_state($c; $after)} | select(.before != .after)]}
   else {from: null, to: ($ROUNDS[-1].id // null), cells: []} end) as $DIFF
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
    last_render: ($renders[-1] // null),
    last_round: ($ROUNDS_COV[-1] // null),
    rounds: $ROUNDS_COV,
    builds: $BUILDS,
    totals: {items: ($ITEMS | length), checks: ($CK | length)},
    check_counts: $CHECK_COUNTS, item_counts: $ITEM_COUNTS,
    not_proven: $NOT_PROVEN,
    lint: $LINT,
    decisions_read: ($decisions[0] != null),
    panel_a: $PANEL_A,
    panel_b: {rounds: $DIFF, linear: $LIN_MOVES},
    panel_c: {decisions: $ALL_DEC, linear_disagrees: $L_B, not_relayed: $L_E},
    items: $ITEMS
  }
