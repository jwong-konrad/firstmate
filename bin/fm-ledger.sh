#!/usr/bin/env bash
# Write a task's teardown ledger before its state and worktree are deleted.
# bin/fm-teardown.sh calls this after the landed-work checks have passed and before
# any destructive step; docs/archive.md owns the contract and the archive that picks
# the files up. This header owns the mechanics.
#
# Outputs, all under data/<id>/ and mode 0600 (an existing ledger.json is kept and the
# new one is written as ledger-<epoch>.json, so a repeated teardown never replaces a
# complete ledger with a degraded one):
#   ledger.json     schema fm-ledger.v1: task id, kind, project, harness, model, effort,
#                   mode, PR, worktree, backend, start and end times, the full state/<id>.status
#                   event history, the steer history (none is recorded today, said so in
#                   the file), the whole meta record, and every Claude session found for
#                   the worktree with its dedup'd token totals and cost
#   scrollback.txt  the last FM_LEDGER_SCROLLBACK_LINES (default 2000) lines of the pane
#   scratch/        status.txt (git status --porcelain), local-commits.txt and
#                   local-commits.bundle (commits no remote has), tracked.diff (git diff HEAD),
#                   untracked.diff (text files git does not track), each size-capped
#
# Sessions: transcripts under <claude>/projects/<worktree path with every non-alphanumeric
# turned into "-">/ whose last timestamp is at or after the task's start (the meta file's
# birth time) and whose first timestamp is not after now; pool worktrees are reused, so the
# time window is what separates this task's sessions from an earlier tenant's. Token totals
# count each API message once (a message id repeats across streamed lines); cost is the
# session's last cost-state record. Subagent transcripts are totalled separately.
#
# Fail soft: this script never blocks teardown. Every section is best effort; a failure
# adds a warning to the ledger or stderr and the exit status is 0 unless the task has no
# meta at all. FM_NO_LEDGER=1 skips it entirely (tests/lib.sh sets it for every suite).
# FM_LEDGER_TIMEOUT bounds git and pane capture (default 20 seconds each) and
# FM_LEDGER_TOTAL_TIMEOUT the whole run (default 120).
# Usage: fm-ledger.sh <task-id>
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_DATA_OVERRIDE, FM_ARCHIVE_CLAUDE_DIR
# (default ~/.claude), FM_LEDGER_SCRATCH_CAP_KIB (default 8192 total, per file 256),
# FM_LEDGER_BUNDLE_CAP_KIB (default 4096).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CLAUDE=${FM_ARCHIVE_CLAUDE_DIR:-$HOME/.claude}
# shellcheck source=bin/fm-archive-lib.sh
. "$SCRIPT_DIR/fm-archive-lib.sh"
umask 077

[ "${FM_NO_LEDGER:-0}" = 1 ] && exit 0
ID=${1:-}
case "$ID" in ''|*/*|*..*) echo "ledger: invalid task id" >&2; exit 2 ;; esac
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "ledger: no meta for $ID" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ledger: warning: jq not found, no ledger written" >&2; exit 0; }

# run_bounded <seconds> <command...>: stock macOS ships neither timeout nor gtimeout.
run_bounded() {
  local secs=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV or exit 127 } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; my $st = $?; exit(($st & 127) ? 128 + ($st & 127) : ($st >> 8))' "$secs" "$@"
  else
    "$@"
  fi
}

# Bound the whole run so a wedged git or a huge transcript can never hold teardown up.
if [ -z "${FM_LEDGER_INNER:-}" ]; then
  FM_LEDGER_INNER=1 run_bounded "${FM_LEDGER_TOTAL_TIMEOUT:-120}" bash "$0" "$@"
  rc=$?
  case "$rc" in
    0|1|2) exit "$rc" ;;
    *) echo "ledger: warning: ledger capture stopped early (status $rc)" >&2; exit 0 ;;
  esac
fi

TIMEOUT=${FM_LEDGER_TIMEOUT:-20}
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT=20 ;; esac
SCROLLBACK_LINES=${FM_LEDGER_SCROLLBACK_LINES:-2000}
SCRATCH_CAP=$(( ${FM_LEDGER_SCRATCH_CAP_KIB:-8192} * 1024 ))
BUNDLE_CAP=$(( ${FM_LEDGER_BUNDLE_CAP_KIB:-4096} * 1024 ))
FILE_CAP=262144

WARNINGS=()
warn() { WARNINGS+=("$1"); echo "ledger: warning: $1" >&2; }

meta_get() { grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2-; }

epoch_to_iso() {
  if [ "$(uname)" = Darwin ]; then
    date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
  else
    date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
  fi
}

file_birth() {  # <path>: birth epoch, falling back to mtime
  local b=0
  if [ "$(uname)" = Darwin ]; then
    b=$(stat -f %B "$1" 2>/dev/null || echo 0)
    [ "$b" -gt 0 ] 2>/dev/null || b=$(stat -f %m "$1" 2>/dev/null || echo 0)
  else
    b=$(stat -c %W "$1" 2>/dev/null || echo 0)
    [ "$b" -gt 0 ] 2>/dev/null || b=$(stat -c %Y "$1" 2>/dev/null || echo 0)
  fi
  printf '%s\n' "$b"
}

WT=$(meta_get worktree)
START_EPOCH=$(file_birth "$META")
NOW_EPOCH=$(date +%s)
START_ISO=$(epoch_to_iso "$START_EPOCH")
# Sessions are matched against the start with a minute of slack; sub-second stamps compare loosely.
WINDOW_START_ISO=$(epoch_to_iso $(( START_EPOCH - 60 )))
END_ISO=$(epoch_to_iso "$NOW_EPOCH")

# data/<id> is writable by the task's worker, so nothing is ever written through a
# symlink there: the folder itself must be a real directory we own, every output is
# written to a fresh temp file made with mktemp (exclusive create) and moved into place
# (a rename replaces a planted link instead of following it), and scratch/ is recreated.
OUT="$DATA/$ID"
if [ -L "$OUT" ]; then
  echo "ledger: warning: $OUT is a symlink; refusing to write a ledger through it" >&2
  exit 0
fi
mkdir -p "$OUT" 2>/dev/null
if [ ! -d "$OUT" ] || [ -L "$OUT" ] || [ ! -O "$OUT" ]; then
  echo "ledger: warning: $OUT is not a directory we own; no ledger written" >&2
  exit 0
fi

# ------------------------------------------------------------------ scrollback

SCROLLBACK_STATUS=unavailable
capture_scrollback() {
  local out="$OUT/scrollback.txt" tmp hit
  tmp=$(mktemp "$OUT/.tmp.XXXXXX") || { warn "cannot create a temp file for the scrollback"; return 0; }
  export FM_HOME
  # shellcheck disable=SC2016
  FM_STATE_OVERRIDE=$STATE run_bounded "$TIMEOUT" bash -c '
    . "$1" || exit 1
    t=$(fm_backend_resolve_selector "$2" "$3") || exit 1
    b=$(fm_backend_of_selector "$2" "$t" "$3") || exit 1
    l=$(fm_backend_expected_label_of_selector "$2" "$3")
    fm_backend_capture "$b" "$t" "$4" "$l"' _ \
    "$SCRIPT_DIR/fm-backend.sh" "$ID" "$STATE" "$SCROLLBACK_LINES" 2>/dev/null \
    | tail -n "$SCROLLBACK_LINES" > "$tmp"
  if [ -s "$tmp" ] && hit=$(secret_pattern_hit "$tmp"); then
    rm -f "$tmp" "$out"
    SCROLLBACK_STATUS=dropped-secret
    SCRATCH_NOTES+=("scrollback.txt dropped: matches the $hit pattern")
    warn "scrollback.txt dropped: matches the $hit pattern"
  elif [ -s "$tmp" ] && mv -f "$tmp" "$out"; then
    SCROLLBACK_STATUS=captured
  else
    rm -f "$tmp"
    SCROLLBACK_STATUS=empty-or-unreachable
    warn "pane scrollback unavailable (endpoint gone or empty)"
  fi
}

# --------------------------------------------------------------------- scratch

SCRATCH_STATUS=skipped
SCRATCH_NOTES=()
SCRATCH_DIR=
SCRATCH_LAST_SIZE=0

# secret_name_rule <relative path>: print the first name rule any path component matches
# (case-insensitive) and return 0, else return 1.
secret_name_rule() {
  local lc comp rule="" hit=1
  lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  set -f
  local IFS=/
  for comp in $lc; do
    case "$comp" in
      .env*) rule='.env*' ;;
      *.pem) rule='*.pem' ;;
      *.key) rule='*.key' ;;
      *.p12) rule='*.p12' ;;
      id_*) rule='id_*' ;;
      *credential*) rule='*credential*' ;;
      *secret*) rule='*secret*' ;;
      *.keychain*) rule='*.keychain*' ;;
      *) continue ;;
    esac
    hit=0
    break
  done
  set +f
  if [ "$hit" -eq 0 ]; then
    printf '%s' "$rule"
  fi
  return "$hit"
}

# secret_pattern_hit <file>: print the name of the first credential pattern the file
# matches and return 0, else return 1.
secret_pattern_hit() {
  local name pattern
  while IFS='|' read -r name pattern; do
    [ -n "$name" ] || continue
    if grep -aqE -e "$pattern" "$1" 2>/dev/null; then
      printf '%s' "$name"
      return 0
    fi
  done <<EOF
$(fm_archive_secret_patterns)
EOF
  return 1
}

# scratch_emit <name> <command...>: run the command with stdout into a fresh temp file in
# scratch/ and move it into place only when it succeeded. Sets SCRATCH_LAST_SIZE.
scratch_emit() {
  local name=$1 tmp
  shift
  SCRATCH_LAST_SIZE=0
  tmp=$(mktemp "$SCRATCH_DIR/.tmp.XXXXXX") || return 1
  if "$@" > "$tmp" 2>/dev/null && mv -f "$tmp" "$SCRATCH_DIR/$name"; then
    SCRATCH_LAST_SIZE=$(wc -c < "$SCRATCH_DIR/$name" | tr -d ' ')
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# scratch_drop_if_secret <name>: drop a scratch output that matches a credential pattern,
# recording only the file name and the pattern name.
scratch_drop_if_secret() {
  local name=$1 hit
  [ -f "$SCRATCH_DIR/$name" ] || return 0
  if hit=$(secret_pattern_hit "$SCRATCH_DIR/$name"); then
    rm -f "$SCRATCH_DIR/$name"
    SCRATCH_NOTES+=("$name dropped: matches the $hit pattern")
  fi
}

# scratch_snapshot: git runs against the worker's copy, whose repository config is
# worker-controlled, so config-driven command hooks (fsmonitor, hooks) are switched off
# and diffs never run external diff or textconv programs.
scratch_snapshot() {
  local dir="$OUT/scratch" used=0 branch f size n listed rule hit ut
  local WGIT=(git -C "$WT" -c core.fsmonitor=false -c core.hooksPath=/dev/null -c core.pager=cat)
  local EXCL=(':(exclude,glob,icase)**/.env*' ':(exclude,glob,icase)**/*.pem' ':(exclude,glob,icase)**/*.key'
    ':(exclude,glob,icase)**/*.p12' ':(exclude,glob,icase)**/id_*' ':(exclude,glob,icase)**/*credential*'
    ':(exclude,glob,icase)**/*secret*' ':(exclude,glob,icase)**/*.keychain*'
    ':(exclude,glob,icase)**/*credential*/**' ':(exclude,glob,icase)**/*secret*/**')
  if [ -z "$WT" ] || [ ! -d "$WT" ] || ! "${WGIT[@]}" rev-parse --git-dir >/dev/null 2>&1; then
    SCRATCH_STATUS="no worktree to snapshot"
    return 0
  fi
  if [ -L "$dir" ]; then
    warn "scratch is a symlink; refusing to write through it"
    SCRATCH_STATUS="refused: scratch is a symlink"
    return 0
  fi
  if [ -e "$dir" ] && ! rm -rf "$OUT/scratch"; then
    SCRATCH_STATUS="error: could not clear scratch"
    return 0
  fi
  if ! mkdir "$dir" 2>/dev/null || [ ! -d "$dir" ] || [ -L "$dir" ] || [ ! -O "$dir" ]; then
    warn "scratch is not a fresh directory we own; snapshot skipped"
    SCRATCH_STATUS="refused: scratch is not a fresh directory"
    return 0
  fi
  SCRATCH_DIR=$dir
  branch=$("${WGIT[@]}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)

  scratch_emit status.txt run_bounded "$TIMEOUT" "${WGIT[@]}" status --porcelain || warn "git status failed in the worktree"
  used=$(( used + SCRATCH_LAST_SIZE ))

  scratch_emit local-commits.txt run_bounded "$TIMEOUT" "${WGIT[@]}" log --oneline HEAD --not --remotes -- || warn "git log of local-only commits failed"
  if [ -s "$dir/local-commits.txt" ]; then
    # The bundle is packed, so it cannot be scanned directly: scan the patch text of the same commits.
    hit=""
    if ut=$(mktemp "$dir/.tmp.XXXXXX"); then
      run_bounded "$TIMEOUT" "${WGIT[@]}" log -p --no-ext-diff --no-textconv HEAD --not --remotes -- 2>/dev/null | head -c 16777216 > "$ut"
      hit=$(secret_pattern_hit "$ut") || hit=""
      rm -f "$ut"
    fi
    if [ -n "$hit" ]; then
      SCRATCH_NOTES+=("local-commits.bundle dropped: the commits match the $hit pattern; local-commits.txt lists them")
    elif run_bounded "$TIMEOUT" "${WGIT[@]}" bundle create "$dir/local-commits.bundle" HEAD --not --remotes >/dev/null 2>&1; then
      size=$(wc -c < "$dir/local-commits.bundle" | tr -d ' ')
      if [ "$size" -gt "$BUNDLE_CAP" ]; then
        rm -f "$dir/local-commits.bundle"
        SCRATCH_NOTES+=("local-commits.bundle dropped: $size bytes exceeds the cap; local-commits.txt lists the commits")
      else
        used=$(( used + size ))
      fi
    else
      rm -f "$dir/local-commits.bundle"
      warn "git bundle of local-only commits failed"
    fi
  else
    rm -f "$dir/local-commits.txt"
  fi

  scratch_emit tracked.diff.full run_bounded "$TIMEOUT" "${WGIT[@]}" diff HEAD --no-ext-diff --no-textconv -- . "${EXCL[@]}" || true
  if [ -s "$dir/tracked.diff.full" ]; then
    size=$(wc -c < "$dir/tracked.diff.full" | tr -d ' ')
    if [ "$size" -gt "$SCRATCH_CAP" ]; then
      head -c "$SCRATCH_CAP" "$dir/tracked.diff.full" > "$dir/tracked.diff"
      SCRATCH_NOTES+=("tracked.diff truncated at $SCRATCH_CAP of $size bytes")
    else
      mv -f "$dir/tracked.diff.full" "$dir/tracked.diff"
    fi
    used=$(( used + $(wc -c < "$dir/tracked.diff" | tr -d ' ') ))
  fi
  rm -f "$dir/tracked.diff.full"

  ut=$(mktemp "$dir/.tmp.XXXXXX") || { SCRATCH_STATUS="error: no temp file"; return 0; }
  listed=$(run_bounded "$TIMEOUT" "${WGIT[@]}" ls-files --others --exclude-standard -z 2>/dev/null | tr '\0' '\n' | grep -vE '^(\.claude/|\.fm-grok-turnend$)' || true)
  n=0
  if [ -n "$listed" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ -f "$WT/$f" ] && [ ! -L "$WT/$f" ] || continue
      if rule=$(secret_name_rule "$f"); then
        SCRATCH_NOTES+=("untracked $f skipped: name matches the $rule rule")
        continue
      fi
      size=$(wc -c < "$WT/$f" 2>/dev/null | tr -d ' ')
      if [ "${size:-0}" -gt "$FILE_CAP" ]; then
        SCRATCH_NOTES+=("untracked $f skipped: $size bytes exceeds the per-file cap")
        continue
      fi
      # Text only: a NUL byte in the first 8 KiB marks it binary.
      if [ "$(head -c 8192 "$WT/$f" | wc -c)" != "$(head -c 8192 "$WT/$f" | LC_ALL=C tr -d '\000' | wc -c)" ]; then
        SCRATCH_NOTES+=("untracked $f skipped: binary")
        continue
      fi
      if hit=$(secret_pattern_hit "$WT/$f"); then
        SCRATCH_NOTES+=("untracked $f dropped: matches the $hit pattern")
        continue
      fi
      if [ $(( used + size )) -gt "$SCRATCH_CAP" ]; then
        SCRATCH_NOTES+=("untracked $f and later files skipped: scratch cap reached")
        break
      fi
      ( cd "$WT" && git -c core.fsmonitor=false -c core.hooksPath=/dev/null diff --no-index --no-ext-diff --no-textconv -- /dev/null "$f" ) >> "$ut" 2>/dev/null
      used=$(( used + size ))
      n=$((n + 1))
    done <<EOF
$listed
EOF
  fi
  if [ -s "$ut" ]; then
    mv -f "$ut" "$dir/untracked.diff"
  else
    rm -f "$ut"
  fi
  # A final scan of every text output catches a credential in a tracked edit or a commit subject.
  scratch_drop_if_secret tracked.diff
  scratch_drop_if_secret untracked.diff
  scratch_drop_if_secret status.txt
  scratch_drop_if_secret local-commits.txt
  SCRATCH_STATUS="snapshotted branch $branch: $n untracked files, $used bytes"
}

# -------------------------------------------------------------------- sessions

SESSIONS_JSON='[]'
collect_sessions() {
  local slug pdir f sid summary first last list="" sub_files sub_json
  [ -n "$WT" ] || return 0
  slug=$(printf '%s' "$WT" | sed 's/[^A-Za-z0-9]/-/g')
  pdir="$CLAUDE/projects/$slug"
  [ -d "$pdir" ] || return 0
  for f in "$pdir"/*.jsonl; do
    [ -f "$f" ] || continue
    sid=$(basename "$f" .jsonl)
    summary=$(jq -nR '
      reduce (inputs | fromjson?) as $r ({first: null, last: null, msgs: {}, cost: null};
        if ($r | type) != "object" then .
        else
          (if $r.timestamp then (.first //= $r.timestamp | .last = $r.timestamp) else . end)
          | (if $r.type == "assistant" and (($r.message.usage // null) | type) == "object"
               then .msgs[($r.message.id // $r.uuid // "?")] = {m: ($r.message.model // "unknown"), u: $r.message.usage}
               else . end)
          | (if $r.type == "cost-state" then .cost = {usd: $r.totalCostUSD, models: ($r.modelUsage // {})} else . end)
        end)
      | {first_timestamp: .first, last_timestamp: .last,
         messages: (.msgs | length),
         tokens: ([.msgs[].u] | {
           input: (map(.input_tokens // 0) | add // 0),
           output: (map(.output_tokens // 0) | add // 0),
           cache_read: (map(.cache_read_input_tokens // 0) | add // 0),
           cache_creation: (map(.cache_creation_input_tokens // 0) | add // 0)}),
         models: ([.msgs[].m] | group_by(.) | map({key: .[0], value: length}) | from_entries),
         cost_usd: (.cost.usd // null),
         cost_by_model: (.cost.models // null)}' < "$f" 2>/dev/null) || continue
    [ -n "$summary" ] || continue
    first=$(printf '%s' "$summary" | jq -r '.first_timestamp // empty')
    last=$(printf '%s' "$summary" | jq -r '.last_timestamp // empty')
    # Inside the task's window: it ended at or after the start and began before now.
    [ -n "$last" ] || continue
    [ "$last" \> "$WINDOW_START_ISO" ] || continue
    [ -z "$first" ] || [ "$first" \< "$END_ISO" ] || [ "$first" = "$END_ISO" ] || continue
    sub_files=("$pdir/$sid"/subagents/agent-*.jsonl)
    sub_json='{"files":0}'
    if [ -f "${sub_files[0]}" ]; then
      sub_json=$(cat "${sub_files[@]}" 2>/dev/null | jq -nR '
        reduce (inputs | fromjson?) as $r ({msgs: {}};
          if ($r | type) == "object" and $r.type == "assistant" and (($r.message.usage // null) | type) == "object"
          then .msgs[($r.message.id // $r.uuid // "?")] = $r.message.usage else . end)
        | {messages: (.msgs | length),
           tokens: ([.msgs[]] | {
             input: (map(.input_tokens // 0) | add // 0),
             output: (map(.output_tokens // 0) | add // 0),
             cache_read: (map(.cache_read_input_tokens // 0) | add // 0),
             cache_creation: (map(.cache_creation_input_tokens // 0) | add // 0)})}' 2>/dev/null) || sub_json='{"files":0}'
      sub_json=$(printf '%s' "$sub_json" | jq -c --argjson n "${#sub_files[@]}" '. + {files: $n}')
    fi
    list="$list$(printf '%s' "$summary" | jq -c --arg sid "$sid" --arg path "$f" --argjson sub "$sub_json" \
      '{session_id: $sid, transcript: $path} + . + {subagents: $sub}')"$'\n'
  done
  [ -n "$list" ] || return 0
  SESSIONS_JSON=$(printf '%s' "$list" | jq -s -c '.') || SESSIONS_JSON='[]'
}

# ---------------------------------------------------------------------- ledger

capture_scrollback
scratch_snapshot
collect_sessions

STATUS_FILE="$STATE/$ID.status"
STATUS_JSON='[]'
if [ -f "$STATUS_FILE" ]; then
  STATUS_JSON=$(tail -n 1000 "$STATUS_FILE" | jq -R -s -c 'split("\n") | map(select(length > 0))') || STATUS_JSON='[]'
fi
META_JSON=$(jq -R -s -c 'split("\n") | map(select(contains("=")) | capture("^(?<k>[^=]+)=(?<v>.*)$")) | map({key: .k, value: .v}) | from_entries' < "$META") || META_JSON='{}'
WARN_JSON='[]'
[ "${#WARNINGS[@]}" -eq 0 ] || WARN_JSON=$(printf '%s\n' "${WARNINGS[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')
NOTES_JSON='[]'
[ "${#SCRATCH_NOTES[@]}" -eq 0 ] || NOTES_JSON=$(printf '%s\n' "${SCRATCH_NOTES[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')

LEDGER="$OUT/ledger.json"
if [ -e "$LEDGER" ] || [ -L "$LEDGER" ]; then
  LEDGER="$OUT/ledger-$NOW_EPOCH.json"
fi
LEDGER_TMP=$(mktemp "$OUT/.tmp.XXXXXX") || { echo "ledger: warning: cannot create a temp file in $OUT" >&2; exit 0; }

jq -n \
  --arg id "$ID" --arg kind "$(meta_get kind)" --arg project "$(meta_get project)" \
  --arg harness "$(meta_get harness)" --arg model "$(meta_get model)" --arg effort "$(meta_get effort)" \
  --arg mode "$(meta_get mode)" --arg yolo "$(meta_get yolo)" --arg pr "$(meta_get pr)" \
  --arg pr_head "$(meta_get pr_head)" --arg worktree "$WT" --arg window "$(meta_get window)" \
  --arg backend "$(meta_get backend)" \
  --arg started "$START_ISO" --argjson started_epoch "$START_EPOCH" \
  --arg ended "$END_ISO" --argjson ended_epoch "$NOW_EPOCH" \
  --argjson status_history "$STATUS_JSON" --argjson meta "$META_JSON" \
  --argjson sessions "$SESSIONS_JSON" --argjson warnings "$WARN_JSON" \
  --arg scrollback_status "$SCROLLBACK_STATUS" --argjson scrollback_lines "$SCROLLBACK_LINES" \
  --arg scratch_status "$SCRATCH_STATUS" --argjson scratch_notes "$NOTES_JSON" '
  def nz: if . == "" then null else . end;
  {schema: "fm-ledger.v1", task: $id, kind: ($kind | nz), project: ($project | nz), harness: ($harness | nz),
   model: ($model | nz), effort: ($effort | nz), mode: ($mode | nz), yolo: ($yolo | nz),
   pr: ($pr | nz), pr_head: ($pr_head | nz), worktree: ($worktree | nz), window: ($window | nz),
   backend: ($backend | nz),
   started: $started, started_epoch: $started_epoch, started_source: "meta file birth time",
   ended: $ended, ended_epoch: $ended_epoch,
   status_history: $status_history,
   steers: [], steers_note: "firstmate does not record steers; the pane scrollback and the firstmate session transcript hold them",
   sessions: $sessions,
   totals: {
     sessions: ($sessions | length),
     input: ($sessions | map(.tokens.input) | add // 0),
     output: ($sessions | map(.tokens.output) | add // 0),
     cache_read: ($sessions | map(.tokens.cache_read) | add // 0),
     cache_creation: ($sessions | map(.tokens.cache_creation) | add // 0),
     subagent_output: ($sessions | map(.subagents.tokens.output // 0) | add // 0),
     cost_usd: ($sessions | map(.cost_usd // 0) | add // 0)},
   scrollback: {file: "scrollback.txt", status: $scrollback_status, max_lines: $scrollback_lines},
   scratch: {dir: "scratch", status: $scratch_status, notes: $scratch_notes},
   meta: $meta, warnings: $warnings}' > "$LEDGER_TMP" 2>/dev/null
if ! mv -f "$LEDGER_TMP" "$LEDGER" 2>/dev/null; then
  rm -f "$LEDGER_TMP"
  echo "ledger: warning: could not write $LEDGER" >&2
  exit 0
fi

echo "ledger: wrote $LEDGER" >&2
exit 0
