#!/usr/bin/env bash
# Read how full the primary session's context is, and where Claude Code will
# auto-compact it, from what a UserPromptSubmit hook can actually see.
# Sourced by bin/fm-captain-idle-handoff.sh; no side effects on source.
# docs/captain-idle-handoff.md "Context-fill trigger" owns the rationale and the
# measured accuracy; this header owns the mechanics.
#
# SIGNAL CHOICE, measured on 2026-09-22 against Claude Code 2.1.280.
#   - The UserPromptSubmit payload carries session_id, transcript_path, cwd,
#     prompt_id, permission_mode, hook_event_name, and prompt - no model, no
#     usage, no context field - and the hook environment carries no model id.
#   - Statusline data does carry a context window reading, but only to the
#     captain's own statusline command, which is private global config a tracked
#     hook must not depend on or rewrite.
#   - The transcript JSONL does carry both halves. Every main-chain assistant
#     line records the API usage of the request that produced it, and Claude
#     Code counts the context as input + cache-creation + cache-read + output
#     tokens of the latest such usage. A "model" attachment line records the
#     session's model identity including the "[1m]" window suffix, and Claude
#     Code re-emits it whenever that identity changes (it reads the LAST one).
#   So the fill comes from the transcript tail and the window from the latest
#   model identity line. Measured error at the moment a captain prompt is
#   submitted, over 419 prompts in two real primary transcripts: the reading
#   under-counts the next request by a median of about 350 tokens, p99 about
#   1,600, because the prompt being submitted is not in it yet. That is under
#   0.2 percentage points of a 1M window.
#
# COST. The fill read looks only at the last FM_CONTEXT_TAIL_BYTES (256 KiB) of
# the transcript. Over 767 captain prompts in the eight largest real primary
# transcripts, the latest assistant line sat a median 3.5 KiB and at most 73 KiB
# before the prompt, so the window has over three times the worst observed
# headroom; the read costs about 25 ms. The model identity line sits near the start of the file, so it is
# found once with one full scan per transcript and then cached; later prompts
# scan only what was appended since, plus a small overlap.
#
# NEVER GUESS. Every function returns 1 when its input cannot be determined, and
# the caller then does nothing.
#
# Results are returned in CTX_* globals for the sourcing hook to read.
# shellcheck disable=SC2034

FM_CONTEXT_TAIL_BYTES=${FM_CONTEXT_TAIL_BYTES:-262144}
FM_CONTEXT_1M_WINDOW=1000000
# Claude Code reserves min(model max output, 20000) tokens of the window for
# the reply, and fires auto-compact 13000 tokens short of what is left, unless
# CLAUDE_AUTOCOMPACT_PCT_OVERRIDE lowers it further.
FM_CONTEXT_OUTPUT_RESERVE=20000
FM_CONTEXT_SUMMARY_BUFFER=13000

# fm_context_truthy <value>: 0 when an env flag reads as set.
fm_context_truthy() {
  case "${1-}" in
    ''|0|false|FALSE|False|no|NO|No|off|OFF|Off) return 1 ;;
  esac
  return 0
}

# fm_context_fill <transcript>: set CTX_FILL (tokens) and CTX_FILL_SRC
# ("usage" or "compacted"). A compaction boundary newer than the latest usage
# means the session was just compacted; its recorded post-compaction size is the
# fill, or 0 when that is missing, which is the no-fire direction.
fm_context_fill() {
  local transcript=$1 last
  CTX_FILL=
  CTX_FILL_SRC=
  [ -f "$transcript" ] && [ -r "$transcript" ] || return 1
  last=$(tail -c "$FM_CONTEXT_TAIL_BYTES" "$transcript" 2>/dev/null \
    | grep -E '"type":"(assistant|system)"' \
    | jq -R -r '
        fromjson? | select(.isSidechain != true)
        | if .type == "assistant" and (.message.usage | type) == "object"
               and .message.model != "<synthetic>" then
            .message.usage
            | ((.input_tokens // 0) + (.cache_creation_input_tokens // 0)
               + (.cache_read_input_tokens // 0) + (.output_tokens // 0))
            | select(. > 0) | "usage \(.)"
          elif .type == "system" and .subtype == "compact_boundary" then
            "compacted \(.compactMetadata.postTokens // 0)"
          else empty end' 2>/dev/null \
    | tail -n 1)
  case "$last" in
    usage\ *|compacted\ *) : ;;
    *) return 1 ;;
  esac
  CTX_FILL_SRC=${last%% *}
  CTX_FILL=${last#* }
  case "$CTX_FILL" in
    ''|*[!0-9]*) CTX_FILL= ; CTX_FILL_SRC= ; return 1 ;;
  esac
  return 0
}

# fm_context_model <transcript> <cache-file>: set CTX_MODEL to the session's
# latest model identity. The cache line is "<transcript>\t<bytes-scanned>\t<id>".
fm_context_model() {
  local transcript=$1 cache=$2 size start=0 found cached_path='' cached_off='' cached_id=''
  CTX_MODEL=
  [ -f "$transcript" ] && [ -r "$transcript" ] || return 1
  size=$(wc -c < "$transcript" 2>/dev/null | tr -d '[:space:]')
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  if [ -f "$cache" ]; then
    IFS=$'\t' read -r cached_path cached_off cached_id < "$cache" 2>/dev/null || true
  fi
  case "$cached_off" in ''|*[!0-9]*) cached_path= ;; esac
  if [ "$cached_path" = "$transcript" ] && [ "$cached_off" -le "$size" ]; then
    start=$((cached_off > 65536 ? cached_off - 65536 : 0))
  else
    cached_id=
  fi
  found=$(tail -c +"$((start + 1))" "$transcript" 2>/dev/null \
    | grep -o '"type":"model","identity":{"modelId":"[^"]*"' | tail -n 1)
  found=${found##*\"modelId\":\"}
  found=${found%\"}
  [ -n "$found" ] || found=$cached_id
  case "$found" in
    ''|*[!A-Za-z0-9._:@/\[\]-]*) found= ;;
  esac
  printf '%s\t%s\t%s\n' "$transcript" "$size" "$found" > "$cache" 2>/dev/null || true
  [ -n "$found" ] || return 1
  CTX_MODEL=$found
}

# fm_context_tokens_value <value>: echo a plain token count, accepting the
# k/m suffixes Claude Code accepts for its window override. Anything else fails.
fm_context_tokens_value() {
  local v=$1 mult=1
  case "$v" in
    *[kK]) v=${v%?}; mult=1000 ;;
    *[mM]) v=${v%?}; mult=1000000 ;;
  esac
  case "$v" in ''|*[!0-9]*) return 1 ;; esac
  [ "$v" -gt 0 ] || return 1
  printf '%s' "$((v * mult))"
}

# fm_context_window <model-id>: set CTX_WINDOW (tokens) and CTX_WINDOW_SRC.
#   FM_CONTEXT_WINDOW_TOKENS  explicit declaration, wins; malformed fails
#   "<model>[1m]"             1000000, unless CLAUDE_CODE_DISABLE_1M_CONTEXT
#   anything else             undeterminable: fail rather than guess
# CLAUDE_CODE_AUTO_COMPACT_WINDOW then caps it, as it caps Claude Code's own.
fm_context_window() {
  local model=$1 cap
  CTX_WINDOW=
  CTX_WINDOW_SRC=
  if [ -n "${FM_CONTEXT_WINDOW_TOKENS-}" ]; then
    CTX_WINDOW=$(fm_context_tokens_value "$FM_CONTEXT_WINDOW_TOKENS") || { CTX_WINDOW=; return 1; }
    CTX_WINDOW_SRC='env'
  else
    case "$model" in
      *'[1m]'|*'[1M]')
        fm_context_truthy "${CLAUDE_CODE_DISABLE_1M_CONTEXT-}" && return 1
        CTX_WINDOW=$FM_CONTEXT_1M_WINDOW
        CTX_WINDOW_SRC=model
        ;;
      *) return 1 ;;
    esac
  fi
  if [ -n "${CLAUDE_CODE_AUTO_COMPACT_WINDOW-}" ]; then
    cap=$(fm_context_tokens_value "$CLAUDE_CODE_AUTO_COMPACT_WINDOW") || { CTX_WINDOW=; return 1; }
    if [ "$cap" -lt "$CTX_WINDOW" ]; then
      CTX_WINDOW=$cap
      CTX_WINDOW_SRC="$CTX_WINDOW_SRC+autocompact-window"
    fi
  fi
  return 0
}

# fm_context_compact_point <window>: set CTX_EFFECTIVE (window minus the reply
# reservation), CTX_COMPACT_AT (tokens at which Claude Code auto-compacts), and
# CTX_PCT (that point as a percentage of CTX_EFFECTIVE, the units
# CLAUDE_AUTOCOMPACT_PCT_OVERRIDE is written in). Fails when auto-compact is
# disabled - there is nothing to precede - or the override is not a number.
fm_context_compact_point() {
  local window=$1 reserve=$FM_CONTEXT_OUTPUT_RESERVE pct=${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE-} out
  CTX_EFFECTIVE=
  CTX_COMPACT_AT=
  CTX_PCT=
  CTX_PCT_SRC=
  fm_context_truthy "${DISABLE_AUTO_COMPACT-}" && return 1
  fm_context_truthy "${DISABLE_COMPACT-}" && return 1
  case "${CLAUDE_CODE_MAX_OUTPUT_TOKENS-}" in
    ''|*[!0-9]*) : ;;
    *) [ "$CLAUDE_CODE_MAX_OUTPUT_TOKENS" -gt 0 ] && [ "$CLAUDE_CODE_MAX_OUTPUT_TOKENS" -lt "$reserve" ] \
         && reserve=$CLAUDE_CODE_MAX_OUTPUT_TOKENS ;;
  esac
  if [ -n "$pct" ]; then
    printf '%s' "$pct" | grep -Eq '^[0-9]+(\.[0-9]+)?$' || return 1
  fi
  out=$(awk -v w="$window" -v r="$reserve" -v b="$FM_CONTEXT_SUMMARY_BUFFER" -v p="$pct" 'BEGIN {
    e = w - r; base = e - b
    if (e <= 0 || base <= 0) exit 1
    t = base; src = "default"
    if (p != "" && p > 0 && p <= 100) { src = "override"; o = int(e * p / 100); if (o < t) t = o }
    printf "%d %d %.4f %s\n", e, t, t * 100 / e, src
  }') || return 1
  read -r CTX_EFFECTIVE CTX_COMPACT_AT CTX_PCT CTX_PCT_SRC <<EOF
$out
EOF
  [ -n "$CTX_COMPACT_AT" ]
}
