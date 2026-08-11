# Conditional arming and the progressing-task predicate

Design record for `arming-conditional-fix-m1`, written 2026-08-06.
It states the one root cause behind three measured supervision failures, the rule that replaces it, and exactly which seams are left to `supervision-deadlock-guard-d1` and `bin-integrity-tripwire-t3`.
The measurements it builds on live in `data/token-spend-investigation.md` section 4 (captain-private).

## The root cause

Every one of the three failures treats a proxy for work as if it were work itself.

The watcher treats an unchanging pane as a signal, so a parked worker is permanently "actionable".
The turn-end guard and the continuity gate treat the existence of `state/<id>.meta` as "work in flight", so a torn-down-but-not-yet-cleaned fleet and a live unsupervised fleet look identical.
Both proxies are cheap, which is why they were chosen, and both are wrong in the same direction: they report activity when there is none.

Measured on 2026-08-05 in the main home: 169 monitoring cycles in one day, 136 of them stale-pane wakes on parked workers.
Each actionable cycle costs a full main-session turn at roughly 105k cache-read tokens.
The same idle panes drove the continuity gate to deny `fm-brief` between watcher cycles again on 2026-08-06, during ordinary dispatch.

## The rule

A task is **progressing** when its reconciled run-step state says work is advancing on its own, without firstmate acting.
Everything else - parked at a gate, awaiting a decision firstmate owns, deliberately paused on an external wait, failed, or provably gone - is **idle**, because polling it cannot observe a change.

Reconciled state means `bin/fm-crew-state.sh`: an attributed no-mistakes run step, else the backend's busy state, else the status log's verb.
It explicitly does not mean pane presence or pane idleness, which is the proxy that caused the problem.

Three consequences follow, and all three are implemented here.

1. **Arming is conditional.** `bin/fm-watch-arm.sh` declines to arm when nothing is progressing and nothing else is watchable, and says so in one line.
2. **A stale pane on a task awaiting firstmate is not actionable.** The watcher absorbs it on the bounded pause cadence it already applies to declared external waits, rather than surfacing it once per changed pane hash.
3. **The guards count progressing tasks, not runtime records.** `bin/fm-turnend-guard.sh`, `bin/fm-guard.sh`, and `bin/fm-continuity-pretool-check.sh` all decide on the progressing count.

### Failing toward the alarm

The rule may only ever remove noise, never remove an alarm.
So the mapping is deliberately asymmetric: a state must be *positively* recognized as idle to be counted idle.

- `working` is progressing.
- `parked`, `blocked`, `paused`, `failed`, and `done` are idle: each changes only when firstmate acts.
- `unknown` is progressing, **except** when the endpoint is provably absent - no metadata, a torn-down worktree, no recorded backend target, or an unreadable target.
  A provably absent endpoint is the "dead" case and counts idle; every other `unknown` is indeterminate and counts progressing.
- A task with no verdict record at all counts progressing.

That last line is the load-bearing one.
A freshly spawned task has no record, so it counts progressing and the turn-end guard alarms until supervision is armed.
`bin/fm-spawn.sh` therefore needs no change to stay safe, which matters while it is a multi-task edit-contention point.

## Why the verdict is cached

Reconciliation is expensive: `fm-crew-state.sh` may make a bounded `no-mistakes` call per task, up to `FM_CREW_STATE_NM_TIMEOUT` (10s default) each.
The turn-end guard is a Stop hook and the continuity gate is a PreToolUse hook; neither can spend six tasks' worth of that on every turn.

So reconciliation and consumption are split.
`bin/fm-progress-lib.sh` owns a durable per-task verdict record at `state/.progress-<id>`.
The expensive reconcile runs where a delay is already acceptable and already happening - the arm decision, and the watcher's wedge state-change check - and writes the record.
The hooks only read records, which is pure filesystem work.

A record is valid only while the evidence behind it is unchanged.
It carries the `size:mtime` signature of the task's `state/<id>.meta`, `state/<id>.status`, and `state/<id>.turn-ended`, plus a long absolute expiry.
Any of those changing invalidates the record, so a parked worker that writes a status line, ends a turn, or has its metadata rewritten immediately reverts to counting progressing.
`bin/fm-send.sh` additionally invalidates the record for a steered task, because a steer is firstmate deliberately restarting work and must not wait for the worker's first turn-end marker to be believed.

Invalidation is one-directional by design: it can only move a task from idle to progressing, never the reverse.

### Where the stale suppression stops

The watcher's stale suppression covers exactly the awaiting-firstmate set: a declared external-wait pause, a verified captain-held transfer, and an open keyed `needs-decision`/`blocked` in the durable status fold.
It deliberately does not extend to a `done:` or `failed:` pane inside a running watcher, even though both count idle for arming and for the guards.

The asymmetry is intentional.
Arming is a one-shot decision about whether a cycle is worth starting at all, and a fleet of only finished or failed tasks has nothing to observe - so a fleet like that never reaches the stale path, because the arm declines first.
Inside a *running* watcher, though, a `done:` line is the one captain-relevant status with a documented false-positive history: it can be a leftover from before a validation run started, and widening suppression there would re-open that hole for a case the arm gate already covers from the front.

## Escalation requires a state change

`wedge_timer_check` used to re-escalate an unchanged pane every `FM_STALE_ESCALATE_SECS`, incrementing the escalation count each time; 8 and 11 consecutive escalations on one pane were both observed.
The count is the urgency signal, so bumping it without new evidence is misinformation, not just noise.

An escalation now requires the task's reconciled state to differ from the state recorded at the previous escalation.
An unchanged state still gets a bounded recheck on the long `FM_PAUSE_RESURFACE_SECS` cadence, deliberately not counted as an escalation, because a wedged crew reconciles as `working` and suppression must never fully swallow a task that reads as progressing.

## Every harness had to learn the third outcome

An arm previously ended in exactly two ways: it reported a wake, or it failed.
A decline is neither, and the harness adapters that own continuity had to be taught the difference before the gate was safe to ship.

The Pi extension and the OpenCode plugin both classified any close with no wake reason and no `watcher: FAILED` line as a failure, and answered it with bounded exponential retry.
Left alone, a declined arm on a parked fleet would have retried forever - the same busy-loop the gate exists to remove, relocated from the watcher into the adapter.
Both now recognize a `watcher: not armed` close as a third `idle` kind: reset the retry counter, deliver no wake, stand down.

Claude and Grok read the arm's status line directly, so their emitted protocols name the decline as a healthy resting state rather than a failure to repair.
Codex checkpoints in the foreground and never shells the arm on its normal path, so it only needed the same instruction.
`docs/watcher-continuity.md` owns the three-way close contract; the per-harness protocols under `docs/supervision-protocols/` own the wording each primary sees.

## What this leaves to `supervision-deadlock-guard-d1`

The deadlock has two halves.
The **trigger** half - a fleet of parked panes producing an instantly-available stale reason on every cycle, so the continuity gate denies the commands that would fix those panes - is resolved here, from both ends: the arm declines rather than spinning a doomed cycle, and the gate no longer counts parked tasks as in-flight work.

The **mechanism** half stays with d1, and none of it is implemented here:

- A sanctioned way for firstmate to raise the stale threshold for a declared window, given `bin/fm-arm-pretool-check.sh` denies an env-prefixed arm as a wrapper.
- A parked-task or mid-staged-restart exemption inside the continuity gate's own arm-freshness logic, as distinct from its in-flight count.
- Making the arm hold the watcher lock for a bounded minimum so a cycle cannot exit within seconds.
- Widening the gate's teardown escape hatch, which today accepts only the literal invocation.

The seam between the two is the progressing predicate.
d1 should build its exemptions on `fm_progress_*` rather than adding a second notion of "this task is deliberately quiet"; a second notion is exactly the drift the one-owner rule forbids.

[`supervision-deadlock-guard.md`](supervision-deadlock-guard.md) resolves that half on this branch, and honors the seam: it adds no task-state notion at all.
It found the residual mechanism elsewhere than the four bullets above - the gate tested instantaneous lock occupancy while every other layer uses a grace, so it read the unlocked interval every one-shot wake guarantees as absent supervision.
The gate now also allows while the arm ledger shows a cycle that genuinely delivered a wake, which turns the stale-reason storm from the deadlock's cause into positive evidence supervision is running.
The stale-threshold window and the minimum lock hold are rejected there with reasons - the first as exactly the forbidden second quietness notion, the second because it delays real wakes to compensate for a misread interval - and the teardown hatch is left as strict as it is.

## What this leaves to `bin-integrity-tripwire-t3`

Nothing here depends on t3, and nothing here provides any of it.

t3's tripwire refuses an allowlisted `bin/` call when tracked guard scripts are dirty or diverged, on the reasoning that a permission rule matches the command string rather than the file contents.
That premise is currently unmet: `.claude/settings.local.json` holds only the single `Bash(bin/fm-watch-arm.sh *)` rule, so there is no six-rule classifier allowlist for a tripwire to gate.
This design assumes no allowlisted `bin/` call is prompt-free, and adds no new allowlist entry.

The composition point, when t3 lands, is that `bin/fm-progress-lib.sh` joins the tracked guard-script set the tripwire covers.
It is read by three hooks and by the arm, so a tampered copy would silence exactly the alarms this design is meant to preserve.
t3 should also cover `state/.progress-*` records as *untrusted input* rather than trusted content: they are gitignored runtime state, and the fail-toward-progressing default already makes a deleted or corrupt record safe, but a record cannot be treated as authority the way a content-bound check is.

## Owners

`bin/fm-progress-lib.sh` owns the record format, the state-token mapping, and both the cheap and authoritative predicates.
`bin/fm-crew-state.sh` remains the single owner of reconciled current state; this design reads it and never re-derives it.
`bin/fm-classify-lib.sh` remains the single owner of status vocabulary, including the awaiting-firstmate predicate the watcher's stale suppression uses.
`bin/fm-supervision-lib.sh` exposes the progressing count to the three guards so they share one predicate rather than three copies.
