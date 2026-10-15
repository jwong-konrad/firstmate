#!/usr/bin/env bash
# fm-regression.sh - the living regression dashboard: an append-only ledger of checks and
# observations for one regression effort, a derive step, and a self-contained HTML board.
#
# docs/regression-ledger.md owns the record contract (files, fields, result words, derived
# states, lint rules). bin/fm-regression.jq owns the derivation and bin/fm-regression.html the
# page; this header owns the command mechanics.
#
# Usage:
#   fm-regression.sh init   [<effort-dir>] [--id <slug>] [--title <text>]
#   fm-regression.sh render [<effort-dir>] [--out <file>]
#   fm-regression.sh lint   [<effort-dir>]
#   fm-regression.sh json   [<effort-dir>]
#
#   init    create the effort folder: effort.json plus one empty .jsonl file per record type.
#           Refuses when effort.json already exists, so it never overwrites a ledger.
#   render  derive every state and write one self-contained HTML page (default
#           <effort-dir>/board.html, mode 0600), then print the headline counts line.
#           Lint failures do not stop a render; they are counted on the page.
#   lint    print one line per lint failure and exit 1 when there is any; print
#           "lint: clean" and exit 0 otherwise.
#   json    print the derived model (the page's embedded data) as JSON.
#
# The effort folder comes from the argument, else REGRESSION_EFFORT_DIR.
# Environment:
#   REGRESSION_EFFORT_DIR   effort folder when no argument names one
#   REGRESSION_NOW          render time to embed, ISO 8601 UTC (default: now; tests pin it)
#   REGRESSION_TASKS_CMD    backlog reader for items' decision_keys (default tasks-axi); each key
#                           is read with "<cmd> show <key> --full" from REGRESSION_TASKS_DIR (default:
#                           the current directory). Set it to "none" to skip the read; the page
#                           then says the decisions were not read. A missing command is the same.
# Requires jq. No other dependency: the tool reads only the effort folder and the backlog reader.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DERIVE="$SCRIPT_DIR/fm-regression.jq"
TEMPLATE="$SCRIPT_DIR/fm-regression.html"
RECORDS="builds items checks observations rounds linear relays"

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
  init|render|lint|json) ;;
  *) die "unknown command: $CMD (try --help)" ;;
esac

DIR=
OUT=
ID=
TITLE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out) [ "$#" -ge 2 ] || die "--out needs a file"; OUT=$2; shift 2 ;;
    --id) [ "$#" -ge 2 ] || die "--id needs a slug"; ID=$2; shift 2 ;;
    --title) [ "$#" -ge 2 ] || die "--title needs text"; TITLE=$2; shift 2 ;;
    -*) die "unknown option: $1" ;;
    *) [ -z "$DIR" ] || die "one effort folder only"; DIR=$1; shift ;;
  esac
done
DIR=${DIR:-${REGRESSION_EFFORT_DIR:-}}
[ -n "$DIR" ] || die "name the effort folder as an argument or in REGRESSION_EFFORT_DIR"

if [ "$CMD" = init ]; then
  [ ! -e "$DIR/effort.json" ] || die "$DIR/effort.json already exists; init never overwrites a ledger"
  [ -n "$ID" ] || ID=$(basename "$DIR")
  case "$ID" in ''|*[!A-Za-z0-9._-]*) die "effort id must be a slug: $ID" ;; esac
  mkdir -p "$DIR"
  jq -n --arg id "$ID" --arg title "${TITLE:-$ID}" '{
    id: $id, title: $title,
    envs: ["local-old", "local-new", "staging-old", "staging-new", "prod"],
    target_envs: ["local-new"],
    default_required_layers: ["API", "UI"],
    evidence_root: null,
    linear: {team_prefix: null, done_statuses: ["Done"], closed_statuses: ["Canceled", "Won'"'"'t Fix", "Duplicate"]}
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
trap 'rm -rf "$TMP"' EXIT

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

model() {
  local now args=() r
  now=${REGRESSION_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  for r in $RECORDS; do
    if [ -f "$DIR/$r.jsonl" ]; then
      args+=(--slurpfile "$r" "$DIR/$r.jsonl")
    else
      args+=(--argjson "$r" '[]')
    fi
  done
  if [ "$CMD" = lint ]; then
    printf 'null\n' > "$TMP/decisions.json"
  else
    read_decisions > "$TMP/decisions.json"
  fi
  jq -n --slurpfile effort "$DIR/effort.json" --slurpfile decisions "$TMP/decisions.json" \
    --arg now "$now" "${args[@]}" -f "$DERIVE"
}

headline() {
  jq -r '
    .labels as $lab
    | "\(.effort.title): \(.totals.items) items, \(.totals.checks) checks: "
      + ([.check_counts[] | "\(.count) \($lab[.state])"] | join(" · "))
      + " -> " + (if .ready.ready then "READY FOR STAGE" else "NOT READY FOR STAGE (\(.ready.reason))" end)
      + "; lint: " + (if (.lint | length) == 0 then "clean" else "\(.lint | length) failure(s)" end)'
}

model > "$TMP/model.json" || die "derive failed"

case "$CMD" in
  json)
    cat "$TMP/model.json"
    ;;
  lint)
    if jq -e '.lint | length == 0' "$TMP/model.json" >/dev/null; then
      printf 'lint: clean\n'
    else
      jq -r '.lint[] | "\(.rule): \(.message)"' "$TMP/model.json"
      exit 1
    fi
    ;;
  render)
    OUT=${OUT:-$DIR/board.html}
    # "<" never appears in JSON outside strings, so escaping it keeps a stray "</script>" inert.
    jq -c . "$TMP/model.json" | sed 's/</\\u003c/g' > "$TMP/data.json"
    umask 077
    awk -v data="$TMP/data.json" '
      /\/\*BOARD_DATA\*\// { while ((getline line < data) > 0) print line; next }
      { print }
    ' "$TEMPLATE" > "$TMP/board.html"
    mv "$TMP/board.html" "$OUT"
    headline < "$TMP/model.json"
    ;;
esac
