#!/usr/bin/env bash
# Local recall: a SQLite FTS5 index over firstmate's curated written record, plus a
# ripgrep (or grep) fallback over the raw archived transcripts. No embeddings, no
# network, nothing leaves the machine. docs/archive.md owns where the corpus lives and
# its privacy rules; this header owns the commands.
#
# Corpus (reports, handoffs, decisions, learnings and captain notes, and ledgers) comes
# from this home's data/ and from the archive staging root (tasks/ and handoffs/), with
# an archive copy skipped when data/ already holds the same file. Markdown is split into
# chunks at "#"-"###" headings, at most about 3000 characters each, and indexed with
# porter stemming; a hit prints the heading and a snippet, so a worker opens the one
# section that matters. Ledgers are indexed as a short summary (task, model, PR, status
# history). With --transcripts, each archived transcript is also indexed as a digest of
# the user prompts and assistant text (never tool output), capped per message.
#
# The index is derived and rebuildable: <archive root>/index/archive.db. It is built into
# a temp file and moved into place, so a failed build never leaves a half index. Every
# query prints when the index was built and what it searched, because a stale index
# answers confidently about an old world.
#
# Usage:
#   fm-recall.sh index [--transcripts]
#   fm-recall.sh query "<words>" [--kind report|handoff|ledger|decision|learning|captain|transcript]
#                                [--since YYYY-MM-DD] [--limit N]
#   fm-recall.sh grep "<regex>" [--limit N]      raw search of archived transcripts
#   fm-recall.sh status
# query ANDs the words (stemmed); write OR or NOT in capitals for those operators and a
# trailing * for a prefix. A query with --kind transcript on an index without transcript
# digests falls back to the raw search, where the query is a regex.
# Hit line: <task> | <heading> | <snippet> | <path>   (kind in brackets before the task)
# Environment: FM_HOME (data/ comes from it), FM_ARCHIVE_ROOT, FM_RECALL_DB.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-archive-lib.sh
. "$SCRIPT_DIR/fm-archive-lib.sh"
umask 077

ROOT=$(fm_archive_root)
DB="${FM_RECALL_DB:-$ROOT/index/archive.db}"
CHUNK_CHARS=3000
MSG_CAP=2000

command -v sqlite3 >/dev/null 2>&1 || { echo "error: sqlite3 not found" >&2; exit 1; }

sql_quote() { printf "%s" "$1" | sed "s/'/''/g"; }

file_date() {  # <path>: YYYY-MM-DD of the file's mtime
  if [ "$(uname)" = Darwin ]; then
    stat -f %Sm -t %Y-%m-%d "$1" 2>/dev/null
  else
    stat -c %y "$1" 2>/dev/null | cut -c1-10
  fi
}

# emit_chunks <kind> <task> <path> <date>: read text on stdin, print INSERT statements,
# one per heading section (split further at CHUNK_CHARS).
emit_chunks() {
  awk -v kind="$1" -v task="$2" -v path="$3" -v mdate="$4" -v cap="$CHUNK_CHARS" '
    function esc(s) { gsub(/\047/, "\047\047", s); return s }
    function flush() {
      if (buf != "") {
        printf "INSERT INTO d(path,kind,task,mtime,heading,body) VALUES(\047%s\047,\047%s\047,\047%s\047,\047%s\047,\047%s\047,\047%s\047);\n", esc(path), esc(kind), esc(task), mdate, esc(heading), esc(buf)
      }
      buf = ""; len = 0
    }
    BEGIN { heading = "(top)"; buf = ""; len = 0 }
    /^# / || /^## / || /^### / {
      flush()
      h = $0; sub(/^#+ /, "", h); heading = h
      next
    }
    {
      buf = buf $0 "\n"; len += length($0) + 1
      if (len > cap) flush()
    }
    END { flush() }
  '
}

ledger_text() {  # <ledger.json>
  jq -r '
    "# ledger " + .task,
    "task: \(.task) kind: \(.kind // "") project: \(.project // "") harness: \(.harness // "") model: \(.model // "") effort: \(.effort // "") mode: \(.mode // "")",
    "pr: \(.pr // "") started: \(.started // "") ended: \(.ended // "")",
    "tokens in: \(.totals.input // 0) out: \(.totals.output // 0) cost usd: \(.totals.cost_usd // 0)",
    "## status history",
    (.status_history[]? // empty)' "$1" 2>/dev/null
}

transcript_text() {  # <transcript.jsonl>
  jq -rR --argjson cap "$MSG_CAP" '
    fromjson? | select(type == "object" and (.type == "user" or .type == "assistant"))
    | .type as $t
    | (.message.content // "") as $c
    | (if ($c | type) == "string" then $c
       else ([$c[]? | select(type == "object" and .type == "text") | .text] | join("\n")) end)
    | select(length > 0)
    | "[" + $t + "] " + .[0:$cap]' "$1" 2>/dev/null
}

cmd_index() {
  local with_transcripts=0 tmpdb seen files=0 f task rel n_chunks n_trans=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --transcripts) with_transcripts=1 ;;
      *) echo "error: unknown index option: $1" >&2; return 1 ;;
    esac
    shift
  done
  mkdir -p "$(dirname "$DB")" || return 1
  tmpdb="$DB.tmp.$$"
  rm -f "$tmpdb"
  seen=$(mktemp "${TMPDIR:-/tmp}/fm-recall.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -f '$tmpdb' '$seen'" EXIT
  {
    echo "CREATE VIRTUAL TABLE d USING fts5(path UNINDEXED, kind UNINDEXED, task UNINDEXED, mtime UNINDEXED, heading, body, tokenize='porter unicode61');"
    echo "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);"
    echo "BEGIN;"
    add_md() {  # <kind> <task> <dedupe-key> <path>
      [ -f "$4" ] || return 0
      grep -qxF -- "$3" "$seen" && return 0
      printf '%s\n' "$3" >> "$seen"
      # shellcheck disable=SC2094
      emit_chunks "$1" "$2" "$4" "$(file_date "$4")" < "$4"
      files=$((files + 1))
    }
    add_ledger() {  # <task> <dedupe-key> <path>
      [ -f "$3" ] || return 0
      grep -qxF -- "$2" "$seen" && return 0
      printf '%s\n' "$2" >> "$seen"
      ledger_text "$3" | emit_chunks ledger "$1" "$3" "$(file_date "$3")"
      files=$((files + 1))
    }
    # Live data first, so an archive copy of the same file is skipped.
    for f in "$DATA"/*/report.md; do
      [ -f "$f" ] || continue
      task=$(basename "$(dirname "$f")")
      add_md report "$task" "report:$task" "$f"
    done
    for f in "$DATA"/handoffs/*/*.md "$DATA"/handoffs/*.md; do
      [ -f "$f" ] || continue
      rel=${f#"$DATA/handoffs/"}
      add_md handoff "${rel%%/*}" "handoff:$rel" "$f"
    done
    for f in "$DATA"/decisions/*.md "$DATA"/decisions/*/*.md; do
      [ -f "$f" ] || continue
      rel=${f#"$DATA/decisions/"}
      add_md decision "$(basename "$f" .md)" "decision:$rel" "$f"
    done
    for f in "$DATA"/learnings.md "$DATA"/learnings/*.md; do
      [ -f "$f" ] || continue
      add_md learning "$(basename "$f" .md)" "learning:${f#"$DATA/"}" "$f"
    done
    for f in "$DATA"/captain.md "$DATA"/captain-shared.md "$DATA"/captain/*.md; do
      [ -f "$f" ] || continue
      add_md captain "$(basename "$f" .md)" "captain:${f#"$DATA/"}" "$f"
    done
    for f in "$DATA"/*/ledger*.json "$ROOT"/tasks/*/ledger*.json; do
      [ -f "$f" ] || continue
      task=$(basename "$(dirname "$f")")
      add_ledger "$task" "ledger:$task:$(basename "$f")" "$f"
    done
    for f in "$ROOT"/tasks/*/report.md; do
      [ -f "$f" ] || continue
      task=$(basename "$(dirname "$f")")
      add_md report "$task" "report:$task" "$f"
    done
    for f in "$ROOT"/handoffs/*/*.md "$ROOT"/handoffs/*.md; do
      [ -f "$f" ] || continue
      rel=${f#"$ROOT/handoffs/"}
      add_md handoff "${rel%%/*}" "handoff:$rel" "$f"
    done
    if [ "$with_transcripts" -eq 1 ]; then
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        rel=${f#"$ROOT/transcripts/"}
        task=${rel%%/*}
        transcript_text "$f" | emit_chunks transcript "$task" "$f" "$(file_date "$f")"
        n_trans=$((n_trans + 1))
      done <<EOF
$(find "$ROOT/transcripts" -type f -name '*.jsonl' 2>/dev/null | sort)
EOF
    fi
    echo "COMMIT;"
    printf "INSERT INTO meta VALUES('built_at','%s');\n" "$(fm_archive_now_iso)"
    printf "INSERT INTO meta VALUES('data_dir','%s');\n" "$(sql_quote "$DATA")"
    printf "INSERT INTO meta VALUES('archive_root','%s');\n" "$(sql_quote "$ROOT")"
    printf "INSERT INTO meta VALUES('files','%s');\n" "$files"
    printf "INSERT INTO meta VALUES('transcripts','%s');\n" "$n_trans"
  } | sqlite3 "$tmpdb" || { echo "error: index build failed; the existing index is unchanged" >&2; return 1; }
  mv "$tmpdb" "$DB" || return 1
  n_chunks=$(sqlite3 "$DB" "select count(*) from d;")
  printf 'index: %s files, %s chunks, %s transcripts -> %s\n' "$(meta_value files)" "$n_chunks" "$(meta_value transcripts)" "$DB"
}

meta_value() {  # <key>
  sqlite3 "$DB" "select value from meta where key='$1';" 2>/dev/null
}

banner() {
  printf '# index built %s; data=%s archive=%s; %s files, %s transcript digests\n' \
    "$(meta_value built_at)" "$(meta_value data_dir)" "$(meta_value archive_root)" \
    "$(meta_value files)" "$(meta_value transcripts)"
}

fts_expression() {  # <words...>: AND the words, quoting each so punctuation cannot break the query
  local w out="" prefix have_term=0 last_op=0
  for w in "$@"; do
    case "$w" in
      AND|OR|NOT)
        # An operator needs a term on both sides; drop one that would not have them.
        [ "$have_term" -eq 1 ] && [ "$last_op" -eq 0 ] || continue
        out="$out $w"
        last_op=1
        continue
        ;;
    esac
    prefix=
    case "$w" in *'*') prefix='*'; w=${w%'*'} ;; esac
    w=$(printf '%s' "$w" | tr -d '"')
    [ -n "$w" ] || continue
    out="$out \"$w\"$prefix"
    have_term=1
    last_op=0
  done
  if [ "$last_op" -eq 1 ]; then
    out=${out% *}
  fi
  printf '%s' "${out# }"
}

raw_search() {  # <regex> <limit>
  local pattern=$1 limit=$2 rg_bin
  [ -d "$ROOT/transcripts" ] || { echo "no archived transcripts under $ROOT/transcripts" >&2; return 0; }
  rg_bin=$(type -P rg 2>/dev/null || true)
  echo "# raw search of $ROOT/transcripts (regex, no index)"
  if [ -n "$rg_bin" ]; then
    "$rg_bin" -n --no-heading --glob '*.jsonl' -e "$pattern" "$ROOT/transcripts" 2>/dev/null
  else
    grep -rnE --include='*.jsonl' -e "$pattern" "$ROOT/transcripts" 2>/dev/null
  fi | awk '{ print substr($0, 1, 400) }' | head -n "$limit"
}

cmd_query() {
  local kind="" since="" limit=10 words=() expr sql
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --kind) kind=${2:-}; shift ;;
      --since) since=${2:-}; shift ;;
      --limit) limit=${2:-10}; shift ;;
      *) words+=("$1") ;;
    esac
    shift
  done
  [ "${#words[@]}" -gt 0 ] || { echo "error: query needs words" >&2; return 1; }
  # The words may arrive as one quoted argument or several; either way they are ANDed.
  read -r -a words <<< "${words[*]}"
  case "$limit" in ''|*[!0-9]*) limit=10 ;; esac
  if [ ! -f "$DB" ]; then
    echo "error: no index at $DB; run: fm-recall.sh index" >&2
    return 1
  fi
  if [ "$kind" = transcript ] && [ "$(meta_value transcripts)" = 0 ]; then
    raw_search "${words[*]}" "$limit"
    return 0
  fi
  expr=$(fts_expression "${words[@]}")
  [ -n "$expr" ] || { echo "error: query has no searchable words" >&2; return 1; }
  sql="select '[' || kind || '] ' || task || ' | ' || heading || ' | ' || replace(snippet(d, 5, '[', ']', '...', 16), char(10), ' ') || ' | ' || path from d where d match '$(sql_quote "$expr")'"
  [ -z "$kind" ] || sql="$sql and kind = '$(sql_quote "$kind")'"
  [ -z "$since" ] || sql="$sql and mtime >= '$(sql_quote "$since")'"
  sql="$sql order by bm25(d, 0, 0, 0, 0, 3, 1) limit $limit;"
  banner
  sqlite3 "$DB" "$sql"
}

cmd_grep() {
  local pattern="" limit=20
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --limit) limit=${2:-20}; shift ;;
      *) pattern=$1 ;;
    esac
    shift
  done
  [ -n "$pattern" ] || { echo "error: grep needs a regex" >&2; return 1; }
  case "$limit" in ''|*[!0-9]*) limit=20 ;; esac
  raw_search "$pattern" "$limit"
}

cmd_status() {
  if [ ! -f "$DB" ]; then
    echo "no index at $DB"
    return 0
  fi
  banner
  echo "chunks: $(sqlite3 "$DB" 'select count(*) from d;')"
  sqlite3 "$DB" "select kind, count(*) from d group by kind order by 2 desc;"
}

case "${1:-}" in
  index) shift; cmd_index "$@" ;;
  query) shift; cmd_query "$@" ;;
  grep) shift; cmd_grep "$@" ;;
  status) shift; cmd_status "$@" ;;
  -h|--help|'') sed -n '2,/^set -u$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "error: unknown command: $1 (index, query, grep, status)" >&2; exit 1 ;;
esac
