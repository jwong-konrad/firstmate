#!/usr/bin/env bash
# Send one line of literal text to a crewmate endpoint, then Enter.
# Usage: fm-send.sh <target> <text...>
#   <target> may be an exact task id, a legacy fm-<id> task label resolved
#   through this home's state/<id>.meta, or an explicit well-formed backend
#   target. fm-send refuses unresolved guesses rather than falling back to a
#   tmux window search, because a "successful" send to the wrong endpoint is
#   worse than a loud failure.
# Special keys instead of text: fm-send.sh <target> --key Enter
# Key support is backend-specific: tmux/herdr support Escape, Enter, and C-c;
# Orca currently supports Enter and C-c only, and rejects Escape.
#
# Text submission is verified: the line is typed ONCE, then Enter is sent and
# retried (Enter only, never retyped) until the target backend confirms a
# submit or reports an inconclusive send. If a swallowed Enter is positively
# confirmed, fm-send exits NON-ZERO so the caller knows the steer did not land
# instead of silently leaving an unsubmitted instruction.
#
# A text send also refuses an endpoint whose AGENT is not running, before typing
# anything: a pane whose agent exited is a live shell that would EXECUTE the
# instruction instead of receiving it. An inconclusive submit no longer exits 0
# silently either - see the liveness preflight below for the whole contract and
# the incident behind it. The confirm-before-refusing re-probe budget is derived
# from FM_SEND_RETRIES / FM_SEND_SLEEP below; FM_SEND_LIVENESS_GRACE and
# FM_SEND_LIVENESS_ATTEMPTS override its interval and count.
# Submission dispatches through the target's recorded backend; the tmux adapter
# shares its composer/submit core with the away-mode daemon via bin/fm-tmux-lib.sh.
# Tune with FM_SEND_RETRIES (default 3) / FM_SEND_SLEEP (0.4).
# Slash commands, and codex `$...` skill invocations resolved through harness
# meta, get a longer pre-Enter settle so completion popups do not swallow Enter.
#
# From-firstmate marker: when the resolved target is a task selector whose meta
# records kind=secondmate, the text is prefixed with the from-firstmate marker
# (bin/fm-marker-lib.sh) so the secondmate routes its reply via its status file
# or a status-pointed doc instead of stranding it in chat the main firstmate
# never reads. A crewmate/scout target, an explicit backend-target escape-hatch
# target, and the --key path are never marked - their behavior is unchanged.
#
# Parent-owned pending-reply expectation: every newly marked secondmate request
# also receives a privacy-safe correlation id and a durable parent record under
# state/pending-replies/ before delivery (bin/fm-pending-reply-lib.sh). Delivery
# success and reply success are separate facts: a successful submit never
# resolves the expectation. Set FM_PENDING_REPLY_EXISTING_CORR=<id> when
# re-sending a recovery request for an already-open expectation so a second
# record is not created. Direct unmarked captain input never creates one.
#
# After a successful text submit fm-send pauses FM_SEND_SETTLE seconds (default 1,
# 0 disables) before returning: submit confirmation only proves the text was
# accepted, but the harness needs a beat to spin up the turn before its busy
# footer appears, so an immediate peek would otherwise see the stale idle pane.
# The pause is fm-send-only; the shared submit core (used by the away-mode daemon,
# which only needs "submitted") does not pay it, and the --key path is unaffected.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never steer
# a crewmate (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-send refuses to resolve targets without an explicit firstmate home" >&2
  exit 1
fi

STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
if [ ! -d "$FM_HOME" ]; then
  echo "error: FM_HOME '$FM_HOME' is not a directory; fm-send cannot resolve this home's state" >&2
  exit 1
fi
if [ ! -d "$STATE" ]; then
  echo "error: state dir '$STATE' is missing; fm-send cannot resolve targets for FM_HOME '$FM_HOME'" >&2
  exit 1
fi

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-progress-lib.sh
. "$SCRIPT_DIR/fm-progress-lib.sh"

FM_GUARD_CONTINUE_LINE='This is a supervision warning only; the requested message WILL still be sent.' "$SCRIPT_DIR/fm-guard.sh" || true

fm_send_id_from_meta() {  # <meta-file>
  local base
  base=${1##*/}
  printf '%s' "${base%.meta}"
}

fm_send_meta_for_key_value() {  # <state-dir> <key> <value>
  local state=$1 key=$2 value=$3 meta got
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    got=$(fm_meta_get "$meta" "$key")
    [ "$got" = "$value" ] || continue
    printf '%s' "$meta"
    return 0
  done
  return 1
}

fm_send_count_colons() {  # <string>
  local s=$1 no_colons
  no_colons=${s//:/}
  printf '%s' $(( ${#s} - ${#no_colons} ))
}

fm_send_resolve_target() {  # <raw-target>
  local raw=$1 meta pane_meta target backend assumed colons id session hint

  RESOLVED_TARGET=""
  TARGET_BACKEND=""
  TARGET_HARNESS=""
  EXPECTED_LABEL=""
  TARGET_META=""
  TARGET_SELECTOR=""
  RESOLUTION_TRIED=""

  meta=$(fm_backend_meta_for_selector "$raw" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    RESOLUTION_TRIED="meta=$meta; backend=from-meta"
    target=$(fm_backend_target_of_meta "$meta")
    if [ -z "$target" ]; then
      echo "error: no backend target recorded in $meta (tried $RESOLUTION_TRIED)" >&2
      return 1
    fi
    backend=$(fm_backend_of_meta "$meta")
    RESOLVED_TARGET=$target
    TARGET_BACKEND=$backend
    TARGET_META=$meta
    TARGET_HARNESS=$(fm_meta_get "$meta" harness)
    EXPECTED_LABEL=$(fm_backend_expected_label_of_selector "$raw" "$STATE")
    TARGET_SELECTOR=1
    return 0
  fi

  case "$raw" in
    fm-*)
      RESOLUTION_TRIED="meta=$STATE/$raw.meta; legacy-meta=$STATE/${raw#fm-}.meta; backend=none"
      echo "error: no metadata for $raw in $STATE (tried $RESOLUTION_TRIED); pass a well-formed explicit backend target only when targeting outside this firstmate home" >&2
      return 1
      ;;
  esac

  pane_meta=$(fm_send_meta_for_key_value "$STATE" herdr_pane_id "$raw" 2>/dev/null || true)
  if [ -n "$pane_meta" ]; then
    session=$(fm_meta_get "$pane_meta" herdr_session)
    hint="${session:-<herdr-session>}:$raw"
    id=$(fm_send_id_from_meta "$pane_meta")
    echo "error: target '$raw' matches herdr_pane_id in $pane_meta but is missing its herdr session prefix; expected <herdr-session>:<pane-id> such as '$hint' or use 'fm-$id' (tried meta=$STATE/$raw.meta; backend=herdr)" >&2
    return 1
  fi

  meta=$(fm_backend_meta_for_window "$raw" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    target=$(fm_backend_target_of_meta "$meta")
    if [ -z "$target" ]; then
      echo "error: no backend target recorded in $meta (tried explicit target '$raw' via recorded window/terminal; backend=from-meta)" >&2
      return 1
    fi
    RESOLVED_TARGET=$target
    TARGET_BACKEND=$(fm_backend_of_meta "$meta")
    TARGET_META=$meta
    TARGET_HARNESS=$(fm_meta_get "$meta" harness)
    RESOLUTION_TRIED="explicit target '$raw' matched $meta; backend=$TARGET_BACKEND"
    return 0
  fi

  case "$raw" in
    *:*)
      colons=$(fm_send_count_colons "$raw")
      if [ "$colons" -ge 2 ]; then
        assumed=herdr
      else
        assumed=tmux
      fi
      if ! fm_backend_target_exists "$assumed" "$raw"; then
        echo "error: explicit target '$raw' is not a live $assumed endpoint (tried meta=$STATE/$raw.meta; metadata window/terminal lookup; backend=$assumed). Use fm-<id> for a recorded task/lane, or pass a target whose backend endpoint can be verified." >&2
        return 1
      fi
      RESOLVED_TARGET=$raw
      TARGET_BACKEND=$assumed
      RESOLUTION_TRIED="meta=$STATE/$raw.meta; metadata window/terminal lookup; backend=$assumed; endpoint=verified"
      return 0
      ;;
  esac

  echo "error: target '$raw' is not resolvable (tried meta=$STATE/$raw.meta; metadata window/terminal lookup; backend=none). Use fm-$raw for a recorded task/lane, or pass a well-formed explicit backend target such as session:window." >&2
  return 1
}

RAW_TARGET=$1
fm_send_resolve_target "$RAW_TARGET" || exit 1
T=$RESOLVED_TARGET
shift

fm_backend_validate "$TARGET_BACKEND" || exit 1

# Classify a from-firstmate -> secondmate request. Only a task selector resolved
# through this home's meta whose authoritative kind is secondmate is marked: the
# secondmate then routes its reply via the status path (see fm-marker-lib.sh).
# An explicit backend target (the escape hatch for endpoints outside this home)
# and any crewmate/scout target are left unmarked, and so is the --key path.
MARK_FROM_FIRSTMATE=0
PENDING_REPLY_CORR=
PENDING_REPLY_CREATED=0
TARGET_TASK_ID=
if [ -n "$TARGET_SELECTOR" ] && [ -n "$TARGET_META" ] && [ "$(fm_meta_get "$TARGET_META" kind)" = secondmate ]; then
  MARK_FROM_FIRSTMATE=1
  TARGET_TASK_ID=$(fm_send_id_from_meta "$TARGET_META")
fi

# Steering a task is firstmate deliberately restarting work on it, so drop any
# cached "idle" verdict now rather than waiting out its freshness horizon
# (bin/fm-progress-lib.sh). This only ever moves a task from idle back to
# progressing, so the guards stay on the alarming side. Done BEFORE delivery: a
# steer that then fails to land must not leave a stale idle verdict behind.
#
# A latency optimization, not a correctness mechanism. No firstmate-side trigger
# can catch every resumption - a worker can resume itself, and the captain may
# steer one directly in its own window - so the horizon, not this call, is what
# guarantees a resumed task becomes visible again.
if [ -n "$TARGET_META" ]; then
  fm_progress_record_invalidate "$STATE" "$(fm_send_id_from_meta "$TARGET_META")"
fi

# Resolve the target's harness from its meta (recorded by fm-spawn), used only to
# scope the codex `$<skill>` popup-settle below. A task selector carries
# meta; an explicit backend-target escape hatch has none, so its harness is
# unknown and treated as non-codex (the safe default that keeps the fast path).
# The target's BACKEND comes from selector meta, from matching an explicit target
# back to recorded meta, or from strict explicit-target shape validation.
# Do not add a separate passive ENDPOINT-READINESS preflight here. Active send
# paths own backend readiness: herdr, for example, must route through its
# session-aware target_ready path before sending, while zellij verifies pane
# labels in its send implementation. A failed backend send is still surfaced
# below as a hard error with the attempted resolution attached.
#
# AGENT liveness is a different question, and no send path answers it: a pane
# whose agent has exited is perfectly "ready" - it is a live shell sitting in
# the task's worktree, and it accepts and EXECUTES whatever is typed into it.
# On 2026-08-13 a steer to such an endpoint exited 0 with no warning while zsh
# answered `parse error near 'do'`, and the instruction was lost silently; only
# a human peeking at the pane caught it. So a liveness preflight IS required,
# scoped to that question alone, and it refuses on the same principle this
# header already states for unresolved targets: a "successful" send that lands
# nowhere is worse than a loud failure.
#
# Scope, and the two ways this must not overreach:
#   - TEXT only, never the --key path. Text typed at a shell prompt is executed
#     by it; a bare Enter/Escape/C-c is a harmless no-op there. Meanwhile --key
#     Enter is exactly what accepts a harness trust dialog moments after a
#     spawn, before herdr has detected the new agent, so gating it on agent
#     liveness would refuse a legitimate key during normal startup.
#   - A confirmed-dead verdict is RE-PROBED before it refuses, because herdr
#     AUTO-DETECTS a built-in harness rather than being told about it at launch:
#     a just-spawned agent reads agent_not_found (hence `shell`) for a beat. A
#     genuinely exited agent is still a shell after the budget; a racing spawn is
#     not. Paid only on the would-refuse path, so the healthy send stays one
#     probe.
#     The budget is DERIVED, not guessed: it is the same
#     FM_SEND_RETRIES x FM_SEND_SLEEP window this script's verified submit
#     already allows this very endpoint to catch up in (see the header above and
#     docs/configuration.md) - the one endpoint-latency allowance in this repo
#     that was tuned against real harnesses - so an operator who widens the
#     submit budget for a slow machine widens this with it. It is re-probed each
#     interval rather than slept out in one block, so a detection that lands
#     early costs one interval instead of the whole budget.
#     FM_SEND_LIVENESS_GRACE overrides the per-probe interval (0 = re-probe with
#     no wait); FM_SEND_LIVENESS_ATTEMPTS overrides the re-probe count (0 = take
#     the first verdict as final).
FM_SEND_LIVENESS_GRACE=${FM_SEND_LIVENESS_GRACE:-${FM_SEND_SLEEP:-0.4}}
FM_SEND_LIVENESS_ATTEMPTS=${FM_SEND_LIVENESS_ATTEMPTS:-${FM_SEND_RETRIES:-3}}
fm_send_agent_liveness() {
  local verdict attempt=0
  verdict=$(fm_backend_agent_liveness "$TARGET_BACKEND" "$T" 2>/dev/null) || verdict=unknown
  while [ "$attempt" -lt "$FM_SEND_LIVENESS_ATTEMPTS" ]; do
    case "$verdict" in
      shell|no-endpoint) ;;
      *) break ;;
    esac
    [ "$FM_SEND_LIVENESS_GRACE" = 0 ] || sleep "$FM_SEND_LIVENESS_GRACE"
    verdict=$(fm_backend_agent_liveness "$TARGET_BACKEND" "$T" 2>/dev/null) || verdict=unknown
    attempt=$((attempt + 1))
  done
  printf '%s' "$verdict"
}
fm_send_liveness_refuse() {  # <verdict> <what-did-not-happen>
  printf 'error: refusing to send to %s - %s (tried %s). Nothing was %s. The task'"'"'s local copy is untouched, but this endpoint cannot receive instructions until a worker is running in it again.\n' \
    "$T" "$(fm_backend_agent_liveness_phrase "$1")" "$RESOLUTION_TRIED" "$2" >&2
}
# The POST-submit counterpart, which must not reuse the refusal above: by the
# time this fires the text has already been typed and Enter sent, so telling the
# operator nothing was delivered would be wrong in the reassuring direction and
# would hide the state a human has to inspect. On a `shell` verdict the
# instruction text was handed to that shell, which EXECUTES what is typed at it,
# so the pane and the task's worktree both need eyes before anything is resent.
fm_send_post_submit_refuse() {  # <verdict>
  case "$1" in
    shell)
      printf 'error: text was already typed into %s and Enter sent, but the submit was unconfirmed and the endpoint reads as %s (tried %s). Treat the text as EXECUTED BY THAT SHELL rather than delivered: the instruction is lost, and whatever it contained ran as shell commands in the task'"'"'s worktree. Inspect that pane and the worktree for side effects, relaunch a worker in it, then resend.\n' \
        "$T" "$(fm_backend_agent_liveness_phrase "$1")" "$RESOLUTION_TRIED" >&2
      ;;
    *)
      printf 'error: text was already typed into %s and Enter sent, but the submit was unconfirmed and the endpoint reads as %s (tried %s). Nothing there can have received it, so treat the instruction as lost; inspect the endpoint and respawn a worker before resending.\n' \
        "$T" "$(fm_backend_agent_liveness_phrase "$1")" "$RESOLUTION_TRIED" >&2
      ;;
  esac
}

if [ "${1:-}" = "--key" ]; then
  if ! fm_backend_send_key "$TARGET_BACKEND" "$T" "$2" "$EXPECTED_LABEL"; then
    echo "error: key '$2' not sent to $T ($TARGET_BACKEND send failed; tried $RESOLUTION_TRIED)" >&2
    exit 1
  fi
else
  # Liveness preflight: refuse BEFORE typing anything, and before any durable
  # pending-reply record is created, so a refusal leaves no trace to reconcile.
  # An inconclusive verdict proceeds - it is never treated as confirmed-alive,
  # but it is also not grounds to block a send that would otherwise work
  # (zellij/orca/cmux have no verified classifier and always read inconclusive).
  # The post-submit check below is what stops an unconfirmed delivery being
  # reported as a success.
  PREFLIGHT_LIVENESS=$(fm_send_agent_liveness)
  case "$PREFLIGHT_LIVENESS" in
    shell|no-endpoint)
      fm_send_liveness_refuse "$PREFLIGHT_LIVENESS" typed
      exit 1
      ;;
  esac
  MESSAGE=$*
  if [ "$MARK_FROM_FIRSTMATE" = 1 ]; then
    # Reuse an existing correlation id for recovery resends; otherwise create a
    # durable parent expectation before delivery. Transport success never
    # resolves that expectation (see fm-pending-reply-lib.sh).
    existing_corr=${FM_PENDING_REPLY_EXISTING_CORR:-$(fm_pending_reply_extract_corr "$MESSAGE")}
    if [ -n "$existing_corr" ] \
      && fm_pending_reply_corr_reusable "$STATE" "$existing_corr" "$TARGET_TASK_ID"; then
      PENDING_REPLY_CORR=$existing_corr
    else
      if [ -z "$TARGET_TASK_ID" ]; then
        echo "error: cannot create pending-reply expectation without a resolvable secondmate task id" >&2
        exit 1
      fi
      PENDING_REPLY_CORR=$(fm_pending_reply_create "$FM_HOME" "$STATE" "$TARGET_TASK_ID" "$MESSAGE") \
        || { echo "error: failed to create parent pending-reply expectation for $TARGET_TASK_ID" >&2; exit 1; }
      PENDING_REPLY_CREATED=1
    fi
    fm_pending_reply_embed_corr "$MESSAGE" "$PENDING_REPLY_CORR" MESSAGE
    if [ "$PENDING_REPLY_CREATED" = 1 ] \
      && ! fm_pending_reply_prepare_delivery "$STATE" "$PENDING_REPLY_CORR"; then
      fm_pending_reply_discard_undelivered "$STATE" "$PENDING_REPLY_CORR" || true
      echo "error: failed to durably prepare pending-reply delivery for $TARGET_TASK_ID" >&2
      exit 1
    fi
  fi
  # Slash commands open a completion popup in some TUIs (verified on codex);
  # submitting too fast selects nothing, so give the popup time to settle before
  # the (retried) Enter. Codex opens the same kind of popup for a `$<skill>`
  # invocation, so a `$...` message to a codex target gets the same settle. That
  # `$` case is scoped to codex on purpose: unlike `/`, a leading `$` commonly
  # starts ordinary text ("$5/month", "$HOME"), so a universal `$` rule would
  # needlessly slow plain text to claude/opencode/pi. The target backend's
  # verified submit retry still backs the settle up either way.
  case "$*" in
    /*) settle=1.2 ;;
    \$*)
      if [ "$TARGET_HARNESS" = codex ]; then settle=1.2; else settle=0.3; fi
      ;;
    *) settle=0.3 ;;
  esac
  retries=${FM_SEND_RETRIES:-3}
  sleep_s=${FM_SEND_SLEEP:-0.4}
  # Type once, submit, verify. Lenient: only a positively-confirmed swallow
  # (text still in the composer) is an error; an unreadable pane is assumed sent.
  if ! verdict=$(fm_backend_send_text_submit "$TARGET_BACKEND" "$T" "$MESSAGE" "$retries" "$sleep_s" "$settle" "$EXPECTED_LABEL"); then
    if [ "$PENDING_REPLY_CREATED" = 1 ] && [ -n "$PENDING_REPLY_CORR" ]; then
      fm_pending_reply_discard_undelivered "$STATE" "$PENDING_REPLY_CORR" || true
    fi
    echo "error: text not sent to $T ($TARGET_BACKEND send failed; tried $RESOLUTION_TRIED)" >&2
    exit 1
  fi
  case "$verdict" in
    pending)
      if [ "$PENDING_REPLY_CREATED" = 1 ] && [ -n "$PENDING_REPLY_CORR" ]; then
        fm_pending_reply_discard_undelivered "$STATE" "$PENDING_REPLY_CORR" || true
      fi
      echo "error: text not submitted to $T (Enter swallowed; text left in composer; tried $RESOLUTION_TRIED)" >&2
      exit 1
      ;;
    send-failed)
      if [ "$PENDING_REPLY_CREATED" = 1 ] && [ -n "$PENDING_REPLY_CORR" ]; then
        fm_pending_reply_discard_undelivered "$STATE" "$PENDING_REPLY_CORR" || true
      fi
      echo "error: text not sent to $T ($TARGET_BACKEND send failed; tried $RESOLUTION_TRIED)" >&2
      exit 1
      ;;
    unknown)
      # The backend could not confirm the submit. This branch used to fall
      # straight through to success on the "an unreadable pane is assumed sent"
      # leniency, which is precisely how the 2026-08-13 steer into a dead shell
      # exited 0. herdr DID report the submit as `unknown` for that pane: with
      # no registered agent its pre-Enter baseline is not idle, so it falls back
      # to fm_backend_herdr_composer_state, whose bare-composer shape matches
      # only the agent prompt glyphs (^[❯›]) - a shell prompt row deliberately
      # matches nothing, so no composer row is found and the verdict is
      # `unknown`. That narrowness is the same safety rule bin/fm-composer-lib.sh
      # owns fleet-wide: a bare shell prompt is never read as a ready composer.
      # The signal was there; fm-send discarded it.
      #
      # An inconclusive submit is now resolved rather than assumed: re-probe the
      # endpoint's agent liveness. A confirmed bare shell means the text was
      # executed by that shell and the instruction is gone, which is a hard
      # error. Anything still inconclusive keeps the original leniency - the
      # text most likely landed - but says so on stderr instead of silently
      # exiting 0, so an unconfirmed steer is never mistaken for a delivered one.
      POST_LIVENESS=$(fm_send_agent_liveness)
      case "$POST_LIVENESS" in
        shell|no-endpoint)
          if [ "$PENDING_REPLY_CREATED" = 1 ] && [ -n "$PENDING_REPLY_CORR" ]; then
            fm_pending_reply_discard_undelivered "$STATE" "$PENDING_REPLY_CORR" || true
          fi
          fm_send_post_submit_refuse "$POST_LIVENESS"
          exit 1
          ;;
        *)
          printf 'warning: text was sent to %s but its submission could not be confirmed (%s). Verify the worker picked it up before assuming it landed.\n' \
            "$T" "$(fm_backend_agent_liveness_phrase "$POST_LIVENESS")" >&2
          ;;
      esac
      ;;
  esac
  # Delivery confirmed. Mark the pending expectation delivered without resolving
  # it: only a correlated parent report acknowledges the request.
  if [ -n "$PENDING_REPLY_CORR" ]; then
    if fm_pending_reply_confirm_delivery "$STATE" "$PENDING_REPLY_CORR"; then
      :
    else
      delivery_commit_status=$?
      if [ "$delivery_commit_status" = 2 ]; then
        echo "error: text was delivered to $T, but its pending-reply delivery commit failed; a durable recovery marker was stored and the watcher will reconcile it. Do not resend." >&2
      else
        echo "error: text was delivered to $T, but its pending-reply delivery commit and recovery marker both failed. Do not resend; inspect $STATE manually." >&2
      fi
      exit 1
    fi
  fi
  # Submit landed (verdict was not pending/send-failed). Confirmation only proves
  # the text was accepted; the harness still needs a beat to spin up the
  # turn before its busy footer shows. Pause so an immediate peek catches the
  # crewmate actually working instead of the stale idle pane. FM_SEND_SETTLE=0
  # disables it. Scoped to this path only, never the shared submit core.
  [ "${FM_SEND_SETTLE:-1}" = 0 ] || sleep "${FM_SEND_SETTLE:-1}"
fi
