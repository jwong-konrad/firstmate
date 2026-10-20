#!/usr/bin/env bash
# fm-regression.sh - the living regression dashboard: an append-only ledger of checks and
# observations for one regression effort, a derive step, and a self-contained HTML board.
#
# docs/regression-ledger.md owns the record contract (files, fields, result words, derived
# states, round coverage, lint rules). bin/fm-regression.jq owns the derivation and
# bin/fm-regression.html the page; this header owns the command mechanics.
#
# Usage:
#   fm-regression.sh init   [<effort-dir>] [--id <slug>] [--title <text>]
#   fm-regression.sh render [<effort-dir>] [--out <file>]
#   fm-regression.sh lint   [<effort-dir>]
#   fm-regression.sh json   [<effort-dir>]
#   fm-regression.sh round open  <round> [<effort-dir>] [--task <id>] [--checks <a,b>] [--items <x,y>] [--note <text>]
#   fm-regression.sh round check <round> [<effort-dir>]
#   fm-regression.sh round check --task <id> [<effort-dir>]
#   fm-regression.sh round close <round> [<effort-dir>] [--out <file>]
#   fm-regression.sh observe [<effort-dir>] --round <r> --check <id> --env <env> --build <sha>
#                    --layer <layer> --result <RESULT> [--reason <text>] [--evidence <path>]
#                    [--supersedes <line-id>] [--date <YYYY-MM-DD>] [--by <who>] [--id <line-id>]
#   fm-regression.sh brief-section <round> [<effort-dir>]
#
#   init    create the effort folder: effort.json plus one empty .jsonl file per record type.
#           Refuses when effort.json already exists, so it never overwrites a ledger.
#   render  read Linear once if due (below), derive every state, write one self-contained HTML
#           page (default <effort-dir>/board.html, mode 0600), append one renders.jsonl line,
#           then print the headline counts line. Lint failures do not stop a render.
#   lint    print one line per lint failure and exit 1 when there is any; print
#           "lint: clean" and exit 0 otherwise.
#   json    print the derived model (the page's embedded data) as JSON. Never reads Linear.
#   round open   append a rounds.jsonl line {id, task, opened, planned, note}. --checks names
#           planned check ids and --items adds every unretired check of those items; both take a
#           comma list and may repeat. Refuses an existing round id or an unknown check or item.
#   round check  print the round's coverage: every planned, unretired check needs at least one
#           well-formed observation line in that round (NOT-RUN with a reason counts). Exit 0
#           when covered, 1 when any planned check has no line. With --task, check every round
#           whose task is <id>; exit 0 when no round names it. bin/fm-teardown.sh calls this form.
#   round close  refuse (exit 1, listing the missing checks) unless the round is covered;
#           otherwise append {id, closed} to rounds.jsonl and render as above.
#   observe append one observation line after validating it (known check and round, layer,
#           result word, reason when the result needs one, unique id, supersedes an existing
#           line). The id defaults to <round>-<n>. An unregistered build is written with a
#           warning; lint counts it on the board.
#   brief-section print the round's "Ledger duty" Markdown block for a worker brief: the
#           planned checks, the builds, the exact observe command, and the coverage gate.
#
# Exit codes: 0 success, 1 lint failures or an uncovered round, 2 usage or ledger error.
# The effort folder comes from the argument, else REGRESSION_EFFORT_DIR.
# Environment:
#   REGRESSION_EFFORT_DIR   effort folder when no argument names one
#   REGRESSION_NOW          time to use, ISO 8601 UTC (default: now; tests pin it)
#   REGRESSION_TASKS_CMD    backlog reader for items' decision_keys (default tasks-axi); each key
#                           is read with "<cmd> show <key> --full" from REGRESSION_TASKS_DIR (default:
#                           the current directory). Set it to "none" to skip the read; the page
#                           then says the decisions were not read. A missing command is the same.
#   REGRESSION_LINEAR_CMD   read-only Linear status reader for render (default: none, so render
#                           reuses the recorded linear.jsonl). Run once per render, never once per
#                           ticket: it gets every item's linear_id on stdin, one per line, and
#                           prints JSON lines {"ticket","status","assignee"}; an optional line
#                           {"tokens": <n>} reports its token cost. Each status is appended to
#                           linear.jsonl with the render time. It must never write to Linear.
#   REGRESSION_LINEAR_MAX_AGE  minutes within which the last read attempt (a render that ran the
#                           reader, whether it succeeded or failed) is not repeated (default: effort.json linear.max_read_age_minutes,
#                           else 240). 0 reads at every render.
# Each render appends {rendered_at, linear: {action, reason, tickets_requested, tickets_returned,
# bytes, tokens, seconds, last_read_at, last_attempt_at}} to renders.jsonl, so the cost of every read can be judged.
# Requires jq. No other dependency: the tool reads only the effort folder and the two readers.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/fm-regression.sh"
DERIVE="$SCRIPT_DIR/fm-regression.jq"
TEMPLATE="$SCRIPT_DIR/fm-regression.html"
RECORDS="builds items checks observations rounds linear relays renders"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

die() {
  printf 'fm-regression: %s\n' "$*" >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || die "jq is required"

CMD=${1:-}
[ -n "$CMD" ] || { usage >&2; exit 2; }
shift
case "$CMD" in
  -h|--help|help) usage; exit 0 ;;
  init|render|lint|json|observe|brief-section) ;;
  round)
    CMD="round ${1:-}"
    [ "$#" -eq 0 ] || shift
    case "$CMD" in
      "round open"|"round check"|"round close") ;;
      *) die "round needs open, check or close (try --help)" ;;
    esac
    ;;
  *) die "unknown command: $CMD (try --help)" ;;
esac

# Options each command accepts; anything else is refused rather than silently ignored.
case "$CMD" in
  init) ALLOWED="id title" ;;
  render|"round close") ALLOWED="out" ;;
  "round open") ALLOWED="task checks items note" ;;
  "round check") ALLOWED="task" ;;
  observe) ALLOWED="round check env build layer result reason evidence supersedes date by id" ;;
  *) ALLOWED="" ;;
esac

POS=()
OPT_out='' OPT_id='' OPT_title='' OPT_task='' OPT_checks='' OPT_items='' OPT_note=''
OPT_round='' OPT_check='' OPT_env='' OPT_build='' OPT_layer='' OPT_result='' OPT_reason=''
OPT_evidence='' OPT_supersedes='' OPT_date='' OPT_by=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --*)
      name=${1#--}
      case " $ALLOWED " in *" $name "*) ;; *) die "$CMD does not take --$name" ;; esac
      [ "$#" -ge 2 ] || die "--$name needs a value"
      case "$name" in
        checks|items) eval "OPT_$name=\${OPT_$name:+\$OPT_$name,}\$2" ;;
        *) eval "OPT_$name=\$2" ;;
      esac
      shift 2
      ;;
    -*) die "unknown option: $1" ;;
    *) POS+=("$1"); shift ;;
  esac
done

# Positionals: the round id first for the round commands and brief-section, then the folder.
ROUND=
case "$CMD" in
  "round check")
    if [ -n "$OPT_task" ]; then
      [ "${#POS[@]}" -le 1 ] || die "round check --task takes one effort folder at most"
    else
      [ "${#POS[@]}" -ge 1 ] || die "round check needs a round id or --task <id>"
      ROUND=${POS[0]}; POS=("${POS[@]:1}")
      [ "${#POS[@]}" -le 1 ] || die "one effort folder only"
    fi
    ;;
  "round open"|"round close"|brief-section)
    [ "${#POS[@]}" -ge 1 ] || die "$CMD needs a round id"
    ROUND=${POS[0]}; POS=("${POS[@]:1}")
    [ "${#POS[@]}" -le 1 ] || die "one effort folder only"
    ;;
  *) [ "${#POS[@]}" -le 1 ] || die "one effort folder only" ;;
esac
DIR=${POS[0]:-${REGRESSION_EFFORT_DIR:-}}
[ -n "$DIR" ] || die "name the effort folder as an argument or in REGRESSION_EFFORT_DIR"
NOW=${REGRESSION_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}

if [ "$CMD" = init ]; then
  [ ! -e "$DIR/effort.json" ] || die "$DIR/effort.json already exists; init never overwrites a ledger"
  ID=${OPT_id:-$(basename "$DIR")}
  case "$ID" in ''|*[!A-Za-z0-9._-]*) die "effort id must be a slug: $ID" ;; esac
  mkdir -p "$DIR"
  jq -n --arg id "$ID" --arg title "${OPT_title:-$ID}" '{
    id: $id, title: $title,
    envs: ["local-old", "local-new", "staging-old", "staging-new", "prod"],
    target_envs: ["local-new"],
    default_required_layers: ["API", "UI"],
    evidence_root: null,
    linear: {team_prefix: null, done_statuses: ["Done"], closed_statuses: ["Canceled", "Won'"'"'t Fix", "Duplicate"],
      max_read_age_minutes: 240}
  }' > "$DIR/effort.json"
  for r in $RECORDS; do : >> "$DIR/$r.jsonl"; done
  printf 'fm-regression: initialized %s\n' "$DIR"
  exit 0
fi

[ -f "$DIR/effort.json" ] || die "$DIR has no effort.json (run init first)"
jq -e 'type == "object"' "$DIR/effort.json" >/dev/null 2>&1 || die "$DIR/effort.json is not a JSON object"
for r in $RECORDS; do
  [ -f "$DIR/$r.jsonl" ] || continue
  jq empty "$DIR/$r.jsonl" >/dev/null 2>&1 || die "$DIR/$r.jsonl has a line that is not JSON"
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-regression.XXXXXX")
LOCK=
trap 'rm -rf "$TMP"; [ -z "$LOCK" ] || rmdir "$LOCK" 2>/dev/null || true' EXIT

# lock: serialize appends that read before they write (ids, round state) across workers.
lock() {
  local tries=0
  until mkdir "$DIR/.append.lock" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -lt 100 ] || die "$DIR/.append.lock has been held for 10 seconds; remove it if no fm-regression.sh is running"
    sleep 0.1
  done
  LOCK="$DIR/.append.lock"
}

# append <record> <json>: append one compact JSON line to <record>.jsonl.
append() {
  printf '%s\n' "$(jq -c . <<<"$2")" >> "$DIR/$1.jsonl"
}

# read_decisions: one backlog read per distinct decision key, as {key: {state, title}}.
# state is open, resolved, or not-found; a failed read records the reader's first line.
read_decisions() {
  local cmd=${REGRESSION_TASKS_CMD:-tasks-axi} keys key out rc state title
  if [ "$cmd" = none ] || ! command -v "$cmd" >/dev/null 2>&1; then
    printf 'null\n'
    return 0
  fi
  keys=$(jq -r '.decision_keys // [] | .[]' "$DIR/items.jsonl" 2>/dev/null | sort -u)
  printf '{}\n' > "$TMP/dec.json"
  for key in $keys; do
    rc=0
    out=$(cd "${REGRESSION_TASKS_DIR:-.}" && "$cmd" show "$key" --full 2>&1) || rc=$?
    title=$(printf '%s\n' "$out" | awk '/^  title: / { sub(/^  title: /, ""); gsub(/^"|"$/, ""); print; exit }')
    if [ "$rc" -ne 0 ]; then
      case "$out" in
        *NOT_FOUND*|*"not found"*) state=not-found ;;
        *) state=unreadable; title=$(printf '%s\n' "$out" | head -n 1) ;;
      esac
    elif printf '%s\n' "$out" | grep -q '^  state: done'; then
      state=resolved
    else
      state=open
    fi
    jq --arg k "$key" --arg s "$state" --arg t "$title" '.[$k] = {state: $s, title: $t}' \
      "$TMP/dec.json" > "$TMP/dec.next" && mv "$TMP/dec.next" "$TMP/dec.json"
  done
  cat "$TMP/dec.json"
}

# read_linear: at most one batched Linear read per render, appended to linear.jsonl, and the
# render's read record (what was done, why, and its cost) written to $TMP/linear-read.json.
read_linear() {
  local cmd=${REGRESSION_LINEAR_CMD:-none} max_age last attempt age requested start rc=0 bytes tok
  jq -r 'select(.linear_id != null) | .linear_id' "$DIR/items.jsonl" 2>/dev/null | sort -u > "$TMP/tickets"
  requested=$(wc -l < "$TMP/tickets" | tr -d ' ')
  max_age=${REGRESSION_LINEAR_MAX_AGE:-$(jq -r '.linear.max_read_age_minutes // 240' "$DIR/effort.json")}
  case "$max_age" in ''|*[!0-9]*) die "the Linear re-read interval must be whole minutes, got: $max_age" ;; esac
  last=$(jq -rs '[.[] | .read_at // empty] | max // ""' "$DIR/linear.jsonl" 2>/dev/null || true)
  attempt=$(jq -rs '[.[] | select(.linear.action == "read" or .linear.action == "failed") | .rendered_at // empty] | max // ""' \
    "$DIR/renders.jsonl" 2>/dev/null || true)
  [ -n "$attempt" ] || attempt=$last
  age=$(jq -rn --arg now "$NOW" --arg last "$attempt" \
    'try ((($now | fromdateiso8601) - ($last | fromdateiso8601)) / 60 | floor) catch ""')
  # record <action> <reason> [extra-json]
  record() {
    local extra=${3:-}
    [ -n "$extra" ] || extra='{}'
    jq -cn --arg a "$1" --arg r "$2" --arg last "$last" --arg att "$attempt" --argjson n "$requested" --argjson x "$extra" \
      '{action: $a, reason: $r, tickets_requested: $n, last_read_at: (if $last == "" then null else $last end),
        last_attempt_at: (if $att == "" then null else $att end)} + $x' \
      > "$TMP/linear-read.json"
  }
  if [ "$cmd" = none ] || ! command -v "$cmd" >/dev/null 2>&1; then
    record not-read "no Linear reader is configured (REGRESSION_LINEAR_CMD)"
  elif [ "$requested" -eq 0 ]; then
    record not-read "no item has a linear_id"
  elif [ -n "$age" ] && [ "$age" -ge 0 ] && [ "$age" -lt "$max_age" ]; then
    record reused "the last read attempt is $age min old, under the $max_age min re-read interval"
  else
    start=$(date +%s)
    "$cmd" < "$TMP/tickets" > "$TMP/linear.out" 2> "$TMP/linear.err" || rc=$?
    bytes=$(wc -c < "$TMP/linear.out" | tr -d ' ')
    if [ "$rc" -ne 0 ]; then
      record failed "the reader exited $rc: $(head -n 1 "$TMP/linear.err")" "{\"bytes\": $bytes}"
    elif ! jq -c --arg now "$NOW" --arg by "render via $(basename "$cmd")" '
        select((.ticket | type) == "string" and (.status | type) == "string")
        | {ticket, status} + (if .assignee then {assignee} else {} end) + {read_at: $now, read_by: $by}' \
        "$TMP/linear.out" > "$TMP/linear.new" 2>/dev/null ||
      ! tok=$(jq -s '[.[] | select(.ticket == null and (.tokens | type) == "number") | .tokens] | if length > 0 then add else null end' \
        "$TMP/linear.out" 2>/dev/null); then
      record failed "the reader printed something other than JSON lines" "{\"bytes\": $bytes}"
    else
      cat "$TMP/linear.new" >> "$DIR/linear.jsonl"
      record read "read at this render" "$(jq -cn --argjson b "$bytes" --argjson s "$(($(date +%s) - start))" \
        --argjson got "$(wc -l < "$TMP/linear.new" | tr -d ' ')" --argjson tok "$tok" \
        '{tickets_returned: $got, bytes: $b, tokens: $tok, seconds: $s}')"
    fi
  fi
}

model() {
  local args=() r
  for r in $RECORDS; do
    if [ -f "$DIR/$r.jsonl" ]; then
      args+=(--slurpfile "$r" "$DIR/$r.jsonl")
    else
      args+=(--argjson "$r" '[]')
    fi
  done
  if [ "$CMD" = render ] || [ "$CMD" = json ]; then
    read_decisions > "$TMP/decisions.json"
  else
    printf 'null\n' > "$TMP/decisions.json"
  fi
  jq -n --slurpfile effort "$DIR/effort.json" --slurpfile decisions "$TMP/decisions.json" \
    --arg now "$NOW" "${args[@]}" -f "$DERIVE"
}

headline() {
  jq -r '
    .labels as $lab
    | "\(.effort.title): \(.totals.items) items, \(.totals.checks) checks: "
      + ([.check_counts[] | "\(.count) \($lab[.state])"] | join(" · "))
      + " -> \(.not_proven.checks) check(s) not yet proven"
      + (if .not_proven.items_without_checks > 0 then ", \(.not_proven.items_without_checks) item(s) without checks" else "" end)
      + "; lint: " + (if (.lint | length) == 0 then "clean" else "\(.lint | length) failure(s)" end)'
}

# coverage <id|task> <value>: print the coverage of each planned round whose <field> is
# <value>; exit 1 when any planned check has no line.
coverage() {
  jq -r --arg k "$1" --arg v "$2" '
    [.rounds[] | select(.[$k] == $v and .coverage != null)] as $rs
    | if ($rs | length) == 0 then "no planned round has \($k) \($v)" else
      ($rs[] | .coverage as $c
        | if ($c.missing | length) == 0
          then "round \(.id): covered (\($c.planned) of \($c.planned) planned checks have a line)"
          else "round \(.id): \($c.missing | length) of \($c.planned) planned check(s) have no line: \($c.missing | join(", "))" end,
        ($c.not_counted[] | "  not counted (malformed, or no reason for a result that needs one): \(.)"))
      end' "$TMP/model.json"
  jq -e --arg k "$1" --arg v "$2" \
    'all(.rounds[] | select(.[$k] == $v and .coverage != null); (.coverage.missing | length) == 0)' "$TMP/model.json" >/dev/null
}

render() {
  OUT=${OPT_out:-$DIR/board.html}
  read_linear
  append renders "$(jq -cn --arg now "$NOW" --slurpfile l "$TMP/linear-read.json" '{rendered_at: $now, linear: $l[0]}')"
  model > "$TMP/model.json" || die "derive failed"
  # "<" never appears in JSON outside strings, so escaping it keeps a stray "</script>" inert.
  jq -c . "$TMP/model.json" | sed 's/</\\u003c/g' > "$TMP/data.json"
  (
    umask 077
    awk -v data="$TMP/data.json" '
      /\/\*BOARD_DATA\*\// { while ((getline line < data) > 0) print line; next }
      { print }
    ' "$TEMPLATE" > "$TMP/board.html"
  )
  mv "$TMP/board.html" "$OUT"
  headline < "$TMP/model.json"
}

case "$CMD" in
  "round open")
    case "$ROUND" in *[!A-Za-z0-9._-]*) die "round id must be a slug: $ROUND" ;; esac
    lock
    model > "$TMP/model.json" || die "derive failed"
    ! jq -e --arg r "$ROUND" 'any(.rounds[]; .id == $r)' "$TMP/model.json" >/dev/null ||
      die "round $ROUND is already registered; a round is opened once"
    planned=$(jq -c --arg cs "$OPT_checks" --arg is "$OPT_items" '
      [.items[].checks[]] as $all
      | ($cs | split(",") | map(select(. != ""))) as $want
      | ($is | split(",") | map(select(. != ""))) as $its
      | (([$want[] | select(. as $k | any($all[]; .id == $k) | not)] | map("unknown check \(.)"))
        + ([$its[] | select(. as $i | any($all[]; .item == $i) | not)] | map("item \(.) has no checks"))
        + ([$want[] | select(. as $k | any($all[]; .id == $k and .state == "retired"))] | map("check \(.) is retired")))
        as $bad
      | if ($bad | length) > 0 then {bad: $bad}
        else {planned: ($want + [$all[] | select((.item | IN($its[])) and .state != "retired") | .id]
          | reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end))} end' "$TMP/model.json")
    if jq -e '.bad' <<<"$planned" >/dev/null; then
      die "round $ROUND not opened: $(jq -r '.bad | join("; ")' <<<"$planned")"
    fi
    append rounds "$(jq -cn --arg id "$ROUND" --arg task "$OPT_task" --arg now "$NOW" --arg note "$OPT_note" \
      --argjson p "$(jq -c .planned <<<"$planned")" \
      '{id: $id} + (if $task != "" then {task: $task} else {} end) + {opened: $now, planned: $p}
       + (if $note != "" then {note: $note} else {} end)')"
    printf 'fm-regression: opened round %s with %s planned check(s)\n' "$ROUND" "$(jq '.planned | length' <<<"$planned")"
    ;;
  "round check")
    model > "$TMP/model.json" || die "derive failed"
    if [ -n "$OPT_task" ]; then
      coverage task "$OPT_task" || exit 1
    else
      jq -e --arg r "$ROUND" 'any(.rounds[]; .id == $r)' "$TMP/model.json" >/dev/null || die "round $ROUND is not registered"
      jq -e --arg r "$ROUND" 'any(.rounds[]; .id == $r and .coverage != null)' "$TMP/model.json" >/dev/null ||
        die "round $ROUND has no planned checks (it was not opened with round open)"
      coverage id "$ROUND" || exit 1
    fi
    ;;
  "round close")
    lock
    model > "$TMP/model.json" || die "derive failed"
    jq -e --arg r "$ROUND" 'any(.rounds[]; .id == $r)' "$TMP/model.json" >/dev/null || die "round $ROUND is not registered"
    ! jq -e --arg r "$ROUND" 'any(.rounds[]; .id == $r and .closed != null)' "$TMP/model.json" >/dev/null ||
      die "round $ROUND is already closed"
    if ! coverage id "$ROUND" > "$TMP/coverage.txt"; then
      cat "$TMP/coverage.txt"
      printf 'fm-regression: round %s not closed: every planned check needs a line first (NOT-RUN with a reason counts)\n' "$ROUND" >&2
      exit 1
    fi
    append rounds "$(jq -cn --arg id "$ROUND" --arg now "$NOW" '{id: $id, closed: $now}')"
    printf 'fm-regression: closed round %s\n' "$ROUND"
    rmdir "$LOCK" 2>/dev/null || true
    LOCK=
    CMD=render
    render
    ;;
  observe)
    for f in round check env build layer result; do
      eval "[ -n \"\$OPT_$f\" ]" || die "observe needs --$f"
    done
    lock
    model > "$TMP/model.json" || die "derive failed"
    bad=$(jq -r --arg r "$OPT_round" --arg c "$OPT_check" --arg l "$OPT_layer" --arg res "$OPT_result" \
      --arg why "$OPT_reason" --arg sup "$OPT_supersedes" --arg id "$OPT_id" \
      --slurpfile obs "$DIR/observations.jsonl" '
      [ (if any(.rounds[]; .id == $r) then empty else "round \($r) is not registered (round open it first)" end),
        (if any(.items[].checks[]; .id == $c) then empty else "unknown check \($c)" end),
        (if $l | IN("code", "API", "DB", "log", "UI") then empty else "layer must be one of code, API, DB, log, UI" end),
        (if $res | IN("FIXED", "STILL-OPEN", "AS-DESIGNED", "OBSERVED", "NOT-RUN", "NOT-TESTABLE", "BLOCKED") then empty
         else "result must be one of FIXED, STILL-OPEN, AS-DESIGNED, OBSERVED, NOT-RUN, NOT-TESTABLE, BLOCKED" end),
        (if ($res | IN("NOT-RUN", "NOT-TESTABLE", "BLOCKED")) and $why == "" then "\($res) needs --reason" else empty end),
        (if $sup != "" and (any($obs[]; .id == $sup) | not) then "--supersedes names no existing line \($sup)" else empty end),
        (if $id != "" and any($obs[]; .id == $id) then "line id \($id) is already used" else empty end) ]
      | join("; ")' "$TMP/model.json")
    [ -z "$bad" ] || die "observation not recorded: $bad"
    jq -e --arg e "$OPT_env" --arg b "$OPT_build" '
      any(.builds[]; .sha as $s | .env == $e and (if $s == "unidentified" or $b == "unidentified" then $s == $b
        else ($s | length) >= 7 and ($b | length) >= 7 and ($s | startswith($b) or ($b | startswith($s))) end))' \
      "$TMP/model.json" >/dev/null ||
      printf 'fm-regression: warning: %s build %s is not registered in builds.jsonl; recorded anyway, and lint will count it\n' \
        "$OPT_env" "$OPT_build" >&2
    LINE_ID=$OPT_id
    if [ -z "$LINE_ID" ]; then
      n=$(jq -s --arg r "$OPT_round" '[.[] | select(.round == $r)] | length' "$DIR/observations.jsonl")
      while :; do
        n=$((n + 1))
        LINE_ID="$OPT_round-$n"
        jq -e -s --arg id "$LINE_ID" 'any(.[]; .id == $id)' "$DIR/observations.jsonl" >/dev/null || break
      done
    fi
    append observations "$(jq -cn --arg id "$LINE_ID" --arg c "$OPT_check" --arg r "$OPT_round" \
      --arg d "${OPT_date:-${NOW%%T*}}" --arg e "$OPT_env" --arg b "$OPT_build" --arg l "$OPT_layer" \
      --arg res "$OPT_result" --arg why "$OPT_reason" --arg ev "$OPT_evidence" --arg by "$OPT_by" \
      --arg sup "$OPT_supersedes" '
      {id: $id, check: $c, round: $r, date: $d, env: $e, build: $b, layer: $l, result: $res}
      + ({reason: $why, evidence: $ev, recorded_by: $by, supersedes: $sup} | with_entries(select(.value != "")))')"
    printf 'fm-regression: recorded %s\n' "$LINE_ID"
    ;;
  brief-section)
    model > "$TMP/model.json" || die "derive failed"
    jq -e --arg r "$ROUND" 'any(.rounds[]; .id == $r and .coverage != null)' "$TMP/model.json" >/dev/null ||
      die "round $ROUND was not opened with round open, so it has no planned checks"
    jq -r --arg r "$ROUND" --arg dir "$(cd "$DIR" && pwd)" --arg self "$SELF" '
      (.rounds[] | select(.id == $r)) as $round
      | [.items[].checks[]] as $all
      | [$round.planned[] as $k | $all[] | select(.id == $k and .state != "retired")] as $plan
      | ([$plan[].envs[]] | unique) as $envs
      | ($dir | @sh) as $qdir
      | "# Ledger duty",
        "",
        "This task is round `\($r)` of the regression effort \"\(.effort.title)\", whose append-only ledger is \($qdir).",
        "Record every result with the command below, one line per check, environment and layer you tested; never edit or delete a ledger file.",
        "",
        "```",
        "\($self) observe \($qdir) --round \($r) --by \($round.task // "<task>") \\",
        "  --check <check-id> --env <env> --build <sha> --layer <layer> --result <RESULT> \\",
        "  --evidence <path> [--reason \"<why>\"] [--supersedes <line-id>]",
        "```",
        "",
        "- Layers: code, API, DB, log, UI. A code reading never counts as fixed, so test the runtime layers too.",
        "- Results: FIXED (the claim holds on that build, whichever way it is phrased), STILL-OPEN, AS-DESIGNED, OBSERVED (no verdict), NOT-RUN, NOT-TESTABLE, BLOCKED; the last three need --reason.",
        "- A check you could not run still needs a line: NOT-RUN with the reason. That always satisfies the gate.",
        "- A correction is a new line with --supersedes <the line id it replaces>.",
        "- Current builds: " + ([$envs[] as $e | (.builds[] | select(.env == $e and .current == true) | "\($e) `\(.sha)`") // "\($e) (none registered)"] | join(", ")) + ". If the build you test differs, report that before recording; registering builds is not part of this task.",
        "",
        "Planned checks (\($plan | length)):",
        "",
        ($plan[] | "- `\(.id)`: \(.claim). Layers: "
          + ([.required_by_env | to_entries[] | "\(.value | join(", ")) on \(.key)"] | join("; "))
          + (if .ui_na then " (UI n/a: \(.ui_na))" else "" end)),
        "",
        "Before you report done, run `\($self) round check \($r) \($qdir)`.",
        "It must print \"round \($r): covered\"; until it does, this task cannot be closed or cleaned up."' "$TMP/model.json"
    ;;
  json)
    model > "$TMP/model.json" || die "derive failed"
    cat "$TMP/model.json"
    ;;
  lint)
    model > "$TMP/model.json" || die "derive failed"
    if jq -e '.lint | length == 0' "$TMP/model.json" >/dev/null; then
      printf 'lint: clean\n'
    else
      jq -r '.lint[] | "\(.rule): \(.message)"' "$TMP/model.json"
      exit 1
    fi
    ;;
  render)
    render
    ;;
esac
