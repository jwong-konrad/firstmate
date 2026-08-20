# Idle auto-handoff

This is the authoritative contract for the unprompted handoff capture referenced from the `handoff` skill and `docs/configuration.md`.
The predicate, the two outputs, and the state it owns live in `bin/fm-captain-idle-handoff.sh`, whose header and `--help` own exact mechanics.
The banner shape is owned by `bin/fm-banner-lib.sh`, shared with the turn-end supervision alarm.

## Gap closed

When the captain resumes the main session after a gap longer than the model's prompt-cache lifetime, the whole accumulated conversation is rebuilt at full price instead of being re-read cheaply.

Measured on 2026-08-20 from the main session's own transcripts under `~/.claude/projects/`:

| Measure | Value |
| --- | --- |
| Resumptions past the cache lifetime | 18 |
| Total rebuild | 4.3M tokens |
| Mean rebuild per resumption | ~239k tokens |
| Worst observed gap | 7.6h overnight |
| That gap's rebuild | 336,652 tokens |
| That gap's cheap re-read | 22,548 tokens |
| Share rebuilt | 94% |

The lever is NOT keeping a large session warm.
A keep-alive ping re-reads the whole session each time, and reads are roughly an order of magnitude cheaper than a rebuild, so about eight pings across a night costs what a single rebuild costs and is strictly worse beyond a day.
The lever is to make the thing that gets rebuilt small: capture a handoff, let the captain clear, and the next rebuild is the session-start block instead of a whole day of conversation - roughly 336k down to 36k.

## The signal: captain idleness, not fleet idleness

The hook measures the wall-clock gap between two consecutive things the captain actually typed.
That is deliberately not fleet idleness, which is a different quantity: an overnight fleet can be busy all night while the captain is asleep, and a parked fleet can be silent while the captain works.
Conflating the two would either suppress every capture on a busy night or fire one on a quiet afternoon.

Prior art was reviewed before adding a signal.
The away-mode daemon (`bin/fm-supervise-daemon.sh`) and the wedge alarm (`docs/wedge-alarm.md`) reason about quiet periods, but both reason about the *fleet* going quiet or an injection wedging, never about the captain.
`state/.last-watcher-beat` and the turn-end guard (`docs/turnend-guard.md`) track *watcher* liveness, which a live fleet refreshes regardless of whether the captain is at the keyboard.
No existing record answered "when did the captain last type something", so the hook records one.

The observation point is the harness's user-prompt event, so the observation and the decision are the same event: there is no timer, daemon, or background poll that could go stale, and nothing to arm or repair.
Two kinds of text arrive on that event without the captain typing:

- A leading bare U+2063 marks an away-mode daemon escalation (`bin/fm-supervise-daemon.sh`).
- The from-firstmate marker marks a supervisor relay (`bin/fm-marker-lib.sh`).

Neither counts as captain input, so neither refreshes the clock and neither can trigger a capture.

## Trigger point

The hook fires on the captain's first genuine message back after a long quiet stretch, and that timing is the design, not a limitation to work around.

No in-session hook can run while the session is idle, so a capture cannot be taken *during* the quiet stretch without an external daemon injecting into the session - which is away mode, rejected below.
Firing on return is also where the reminder is worth anything: the captain is present to read "CLEAR BEFORE SESSION" and act on it.
A capture taken at 3am that nobody sees is the quiet handoff this feature exists to avoid.
The rebuild for that one returning turn is already paid by the time any hook could run; what the capture buys is that the captain can now clear, so the *next* gap costs a session-start block instead of a full day.

## Threshold

The default is 14400 seconds, four hours, set in `DEFAULT_THRESHOLD`.

Cost is asymmetric.
Firing late costs one extra rebuild; nagging costs the captain's attention every time and trains them to ignore the banner, which destroys the feature.
A one-hour threshold would match the prompt-cache lifetime exactly and catch more rebuilds, but it would also fire after a lunch break or a long meeting, mid-thread, when clearing would cost the captain their working context and they would decline.
Four hours sits clear of any ordinary in-day break, comfortably inside an overnight gap, and captures the long tail where the measured 239k average actually comes from.

`config/idle-handoff` (local, gitignored) overrides it with a seconds value, or `off` to disable the hook entirely.
`FM_IDLE_HANDOFF_SECONDS` overrides the file.
An unreadable value falls back to the default and is logged, never to a shorter threshold.

## Two outputs on a fire

- **stdout** carries the capture directive, which the harness injects into that turn's context.
  It names the tracked script that produced it, tells the agent to run the existing `/handoff` capture through the `handoff` skill before answering the captain, and carries the banner to print afterwards.
  The `handoff` skill remains the single owner of what a handoff contains and where it is written; nothing about the capture itself changes when it is unprompted.
- **stderr** carries the same banner, best-effort, so the reminder still exists if the directive is dropped.

The banner leaves one field for the agent to fill: `{{HANDOFF_PATH}}`, replaced with the path of the document actually written, because the skill picks the dated slug and the script cannot know it in advance.

## Safety boundaries

- It never clears or compacts the session.
  The captain clears; this only captures and reminds.
- It never enters away mode.
  Away mode is a declared mode by design, it never widens approval authority (`AGENTS.md` section 8), and its escalations are injected into this same transcript - so it grows the very thing that later gets rebuilt.
  While `state/.afk` is present the hook stays out of the way entirely and only keeps the captain clock honest, because the away-mode return procedure owns the captain's first unmarked message.
- It never blocks, fails, or delays a turn.
  Every path exits 0.
  A failed banner print still counts the handoff as delivered: the failure is logged to `state/.captain-idle-handoff.log` and never escalated.
  Missing `jq` or an empty payload degrades to a silent no-op with no side effects, the same precedent the turn-end guard sets.
- One capture per quiet stretch.
  `state/.captain-idle-handoff` records the epoch that opened the stretch already captured, so a state directory that briefly refuses writes cannot produce a second reminder for the same gap.
- A live fleet is untouched.
  The hook reads and writes only the three records it owns and never consults or mutates watcher, lock, wake-queue, progress, or task state.
- Only the main home.
  A secondmate's own home is a real primary session, but it has no captain to remind and no long captain-facing thread to clear, so it is excluded even though `fm_primary_scope_matches` would include it.
  Crewmate and scout task worktrees are excluded by the same shared scope check the turn-end guard uses.

## State it owns

Under the effective state directory:

- `.last-captain-input` - epoch of the last genuine captain prompt.
- `.captain-idle-handoff` - epoch of the stretch a capture was already claimed for.
- `.captain-idle-handoff.log` - dated log of fires, skipped repeats, unreadable thresholds, and banner-print failures.

## Harness integrations

Only one reminder channel exists on purpose: one prominent banner beats three ignorable ones.
No Notification Center alert and no separate file the captain must remember to read were added, because the banner is reachable in the primary harness.

- `claude`: `.claude/settings.json` registers a `UserPromptSubmit` hook command anchored through `"$CLAUDE_PROJECT_DIR"/bin/fm-captain-idle-handoff.sh`.
  Verified first-hand on 2026-08-20; evidence below.
- `codex`, `opencode`, `pi`, `grok`: not wired.
  This repo carries no tracked user-prompt hook for those harnesses, and none of the four CLIs was installed on the measuring host, so their user-prompt event surfaces could not be inspected first-hand.
  Rather than guess at an adapter, the feature stays inert there: with no captain-input record, the hook never fires and nothing changes for those primaries.
  Wiring one later needs exactly two things from the harness - an event that fires when a human submits a prompt, carrying the prompt text so daemon injections and supervisor relays can be told apart, and a way to get the directive into that turn's context.

## Empirical validation

Claude Code, measured first-hand on 2026-08-20 (Darwin 25.6.0) in a scratch project outside the fleet.

Hook file used: a scratch `.claude/settings.json` registering a `UserPromptSubmit` command.
Command run: `claude -p "What is the secret word? Answer with just the word." --dangerously-skip-permissions --output-format json`, with a hook that dumped its stdin payload, printed `PROBE_INJECTED_CONTEXT: the secret word is PLUMBOB.` to stdout, and exited 0.

Observed payload:

```json
{"session_id":"387d3b14-...","transcript_path":"/Users/.../387d3b14-....jsonl","cwd":"/private/tmp/.../ups-probe","prompt_id":"7ad700f9-...","permission_mode":"bypassPermissions","hook_event_name":"UserPromptSubmit","prompt":"What is the secret word? Answer with just the word."}
```

Observed result: the model answered `PLUMBOB`, so exit-0 stdout from a `UserPromptSubmit` hook is injected into that turn's context.
The hook did not block or delay the turn.
The payload carries `prompt`, which is what makes the away-mode-injection and supervisor-relay exclusions possible.

One behavior worth keeping: the model reported that the injected text arrived in a `<system-reminder>` labeled "UserPromptSubmit hook" and read like an unattributed instruction, so it flagged it as untrusted.
The tracked directive therefore names `bin/fm-captain-idle-handoff.sh` as its source in its first line, so the agent can see it is this repo's own tracked hook rather than anonymous injected text.

### End-to-end, same host and date

The whole loop was then driven once against a live Claude session in a scratch primary-shaped checkout carrying the tracked hook, the tracked `.claude/settings.json` `UserPromptSubmit` entry, and this repo's `.agents/skills/`.
Seeded `state/.last-captain-input` to nine hours earlier, then ran `claude -p "Where did we leave the auth work?" --dangerously-skip-permissions --output-format json`.

Observed, in order, in a single turn:

1. The hook fired and the directive reached the model.
2. The model ran the capture through the `handoff` skill, writing `data/handoffs/2026-08-20-auth-refresh-status/handoff.md` and `data/handoffs/INDEX.md`.
3. It printed the banner verbatim as its first output, with `{{HANDOFF_PATH}}` replaced by that real path.
4. It then answered the captain's actual question normally.

`state/.captain-idle-handoff` recorded the stretch and `state/.captain-idle-handoff.log` recorded `fired stretch=... idle=32405s threshold=14400s(default)`.
A second prompt immediately afterwards produced no banner, confirming that the advanced clock closes the stretch.

An earlier run of the same probe against a deliberately empty scratch checkout produced no banner and one plain line saying the capture was skipped because there was nothing to capture, which is the directive's stated behavior when a capture cannot be completed - not an escalation, and not a blocked turn.

## Tests

`tests/fm-captain-idle-handoff.test.sh` covers firing past the threshold, staying silent below it, one capture per quiet stretch, a failed banner print still counting the handoff as delivered, the away-mode and supervisor-relay exclusions, away-mode deference, secondmate-home and task-worktree scoping, the missing-`jq` and empty-payload no-ops, threshold configuration and the `off` switch, a live actively-supervised fleet being unaffected, tracked hook registration, and the banner's captain-facing wording.
All cases are hermetic over temp dirs with an injected clock; none invokes a live language-model harness.
