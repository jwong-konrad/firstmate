# The continuity gate must not block its own remedy

Design record for `supervision-deadlock-guard-d1`, written 2026-08-06.
It builds directly on `arming-conditional-fix-m1` and lands on the same branch; read [`supervision-arming.md`](supervision-arming.md) first, because this change reuses its progressing predicate rather than adding a second notion of a deliberately quiet task.

The incident evidence is `data/learnings.md` under 2026-08-05 and `data/handoffs/2026-08-05-ten-worker-restart-and-supervision-deadlock/handoff.md` (both captain-private).

## The failure

On 2026-08-05 a deliberate staged restart of ten direct reports deadlocked supervision for hours.

1. Many idle direct reports sat past `FM_STALE_ESCALATE_SECS`. During a staged restart that idleness is the intended state.
2. Every `bin/fm-watch-arm.sh` cycle therefore closed within about a second, because a stale reason was instantly available.
3. `bin/fm-continuity-pretool-check.sh` saw no live watcher holding the home lock and denied `fm-send`, `fm-peek`, `fm-crew-state`, `fm-brief`, `fm-spawn`, and `fm-decision-hold`.
4. Those denied commands are exactly the ones that would have revived the panes and cleared the staleness.

The captain's workaround, `FM_STALE_ESCALATE_SECS=3600 bin/fm-watch-arm.sh &`, survived one cycle only because the environment was not persisted.
Away-mode entry was gated by the same mechanism; `fm-afk-start` was denied twice and landed on the third attempt only by winning a drain/arm/command race.
Winning a race is not a recovery procedure.

The handoff records that the only reliable workaround found was batching every fleet command into a single Bash call, because the hook evaluates the whole command string once.
That is a fragile trick rather than a procedure: it depends on the gate's evaluation granularity rather than on supervision actually being healthy, it forces unrelated commands to be written together and to succeed or fail together, and it stops working the moment a command has to be chosen based on what an earlier command in the same batch returned.
This change retires it, so the ordinary one-command-at-a-time path works during recovery.

## What m1 already fixed, and what it did not

m1 removed the **trigger** from both ends.
The arm gate declines to start a doomed cycle when nothing is progressing, and the three guards count progressing tasks instead of runtime records, so a parked fleet no longer looks like a live unsupervised one.

m1 did not change **how the continuity gate decides that supervision is present**, and that is the residual mechanism.

The gate tests instantaneous lock occupancy: a live PID in `state/.watch.lock` whose identity matches this home's watcher.
Nothing else in the repo defines liveness that way.
`bin/fm-guard.sh` and `bin/fm-turnend-guard.sh` both use `FM_GUARD_GRACE`, a 300-second beacon window that `bin/fm-watch-arm.sh` documents as "the single source of truth, shared with fm-watch.sh and fm-guard.sh".
So the gate is the strictest layer in the system, and it is strict about the wrong quantity.

The watcher is intentionally one-shot: one actionable reason closes one cycle.
Every wake therefore *guarantees* an interval with no lock holder, by design.
The gate reads that guaranteed interval as absent supervision.

When wakes are rare the interval is short and firstmate's drain/act/re-arm sequence usually fits inside it.
When a stale reason is instantly available the interval becomes essentially all of wall-clock time, and the gate is closed whenever firstmate tries to act.
The deadlock is not a threshold being too low.
It is a category error: **the gate cannot distinguish "supervision never happened" from "supervision just happened and handed control to firstmate".**

That is also why the deadlock is Claude-specific.
Pi and OpenCode start and verify a successor arm *before* delivering the wake ([`watcher-continuity.md`](watcher-continuity.md)), so a lock holder exists by the time their model sees it.
Claude relies on the model to re-arm, so on Claude the unlocked servicing interval is exposed to the gate.

## The rule

A watcher cycle that closed **because it delivered an actionable wake** is evidence that supervision is working, not evidence that it is missing.

So the gate now recognizes three states instead of two:

1. **Live** - an identity-matched watcher holds the home lock. Allow, unchanged.
2. **Serviced** - no lock holder, but the arm layer recorded a cycle that delivered an actionable wake within `FM_CONTINUITY_SERVICE_GRACE` (default `FM_GUARD_GRACE`, 300s). Allow: firstmate is inside the interval it was woken to act in.
3. **Absent** - neither. Deny, unchanged, with the unchanged reason text.

The evidence for state 2 already exists and is already owned.
`bin/fm-watch-arm.sh` appends one record per observed cycle to `state/.watch-cycle-exits.log`, and writes `reason=actionable-signal|actionable-stale|actionable-check|actionable-heartbeat` only when `watch_output_has_wake` confirmed the watcher genuinely produced a wake reason.
The record is written before the arm prints its output and exits, so it is present by the time firstmate sees the wake.

## The new invariant

> Whenever a watcher cycle has delivered an actionable wake within the service grace, the continuity gate permits every fleet command, including `fm-send`, `fm-peek`, `fm-crew-state`, `fm-brief`, `fm-spawn`, and `fm-decision-hold`.
> Since a stale-reason storm is precisely a sequence of cycles that each deliver an actionable wake, the condition that produced the deadlock is now the condition that proves supervision is functioning.

The deadlock inverts rather than being tuned away.
The worse the wake churn, the more continuously fresh the servicing evidence, and the more reliably the recovery commands are permitted.
There is no threshold to move, because the fix is not a threshold.

### Why this is not a no-op

Every close that is *not* a delivered wake writes a different `reason=` token, so none of them opens the grace:

- A declined arm (`watcher: not armed`) writes no cycle record at all, because the arming gate returns before `cycle_begin`.
- A failed arm writes `confirmation-timeout`.
- A clean close with no wake writes `unexpected-clean-exit`.
- A crashed or signalled watcher writes `nonzero-exit` or `signal-exit`.
- An interrupted arm writes `arm-interrupted`.

So the three cases the gate exists for all still deny: supervision never armed this session, the arm tried and failed, and a watcher that died without delivering anything.
An actionable record older than the grace also denies, so an abandoned wake re-closes the gate rather than holding it open forever.

Only the newest *dispositive* record in the ledger is read, and it opens the window only if it is itself actionable.
This is what makes the previous paragraph true in sequence rather than only in isolation: when a wake is delivered and the re-arm that follows it then fails, crashes, or is signalled, the failed close is the newest record and the window shuts at once instead of being held open by the delivered wake before it.
Servicing evidence is a claim about the state supervision is in now, so a superseded record cannot mask a newer failure until it ages out.
The reason and `ended_at` values are read from their own tab-delimited fields, so no value carried in `origin`, `successor`, `lock_before`, or `lock_after` can be mistaken for either.

Dispositive means the record reports supervision's disposition rather than one arm's own attachment, and that distinction is why the rule is owner-scoped.
Every arm in a home appends to the same ledger, but only the arm that forked the watcher (`origin=started`) reads its output, so only an owner row can say whether a wake was delivered.
A second arm that merely attached to that watcher writes `attached-cycle-ended` or `lock-replaced` when its own observation ends, which would otherwise shut the window seconds after a real wake - the same deadlock in a new place.
The owner writes one stand-down row of its own for the same reason: `unexpected-clean-exit` carrying `successor=attached:<pid>` means it handed a verified successor the lock and stopped watching, so it is skipped, while the same reason with `successor=none` is the arm failing and still denies.

`bin/fm-supervision-lib.sh` enumerates the four buckets - delivered, failed, owner stand-down, attached - in one place, alongside the other ledger literals the reader keys on: the owner and observer cycle origins, and both successor encodings - the `attached:` prefix that marks a hand-off and the `started:` prefix that does not.
A reason may appear in two buckets when the reason alone is not decisive: `unexpected-clean-exit` is split by the successor field and `arm-interrupted` by origin.
`tests/fm-continuity-pretool-check.test.sh` fails if `bin/fm-watch-arm.sh` grows a reason token that no bucket classifies, adds a third cycle origin, or changes either successor encoding at either of the two places that write the field (`cycle_log_append`'s append and `cycle_mark_predecessor_successor`'s in-place rewrite) - each of which would otherwise skip every owner row and make the gate deny always, reinstating the deadlock silently.
A new record type therefore forces a decision instead of silently inheriting whichever bucket the fallback happens to be.

The grace is deliberately narrower than simply reusing the beacon window the other two guards use.
A bare beacon grace would also have fixed the deadlock, because a watcher that just exited leaves a fresh beacon.
It would have allowed on a crashed or failed watcher too, since those leave an equally fresh beacon.
Requiring the delivered-wake record distinguishes them, so this is the tighter of the two sufficient fixes.

### Why the turn-end guard gets no grace

`bin/fm-turnend-guard.sh` is unchanged and still requires `fm_watcher_healthy` - live lock *and* fresh beacon - before a turn may end.

The two guards answer different questions, and the asymmetry is the reason the grace cannot be abused.
The PreToolUse gate asks "may firstmate mutate the fleet right now", and firstmate acting on a wake it was just handed is the opposite of blind.
The Stop hook asks "may this turn end", and a delivered wake that has not been re-armed by the end of the turn *is* blind.

So the grace buys a bounded window to act and cannot become a way to run unsupervised: the turn cannot end until supervision is restored.
This is what keeps the mechanism honest without a second timer to tune.

### The tempting tightening that recreates the bug

It looks safer to condition the grace on `state/.wake-queue` being empty, on the reasoning that an undrained wake proves firstmate has not serviced anything.

That would restore the deadlock in a new place.
With ten stale panes, a new wake lands while firstmate is still mid-recovery, the queue becomes non-empty again, and the gate slams shut in the middle of the repair.
That is precisely the drain/arm/command race the 2026-08-06 away-mode entry had to win three times.
The gate already names `bin/fm-wake-drain.sh` in its deny text and the policy already exempts it, so drain-first discipline is enforced where it belongs and does not need to be re-enforced by a condition that reintroduces the failure.

## Options considered and rejected

The task named three candidate directions. Two are rejected with reasons.

**A sanctioned bounded stale-threshold window.** Rejected.
It is a second notion of "this task is deliberately quiet", which is exactly the drift [`supervision-arming.md`](supervision-arming.md) tells d1 not to introduce and the one-owner rule forbids.
The case it would serve is already served: the sanctioned staged-restart procedure has idle workers append `paused:`, which m1 both suppresses in the watcher and counts idle in the progressing predicate.
A worker too dead to declare its own pause is covered by m1's provably-absent-endpoint path.
Adding a fleet-wide threshold override on top would give two mechanisms for one fact, and the first one to be edited would drift from the other.
It also does not remove the deadlock; it lowers the probability of triggering it, which is the "larger constant moves the deadlock" outcome this design was asked to avoid.

**A bounded minimum lock hold in the arm.** Rejected.
It treats the fast exit as the defect, but the fast exit is correct behavior: a wake was available, so the watcher delivered it.
Holding the lock past that point delays every genuine wake - a merged PR, an X-mode mention, a real wedge - to compensate for a gate that misreads the interval.
It also only narrows the window rather than closing it, so the race remains, merely rarer.

**Widening the teardown escape hatch.** Not pursued.
Teardown is the wrong remedy for this failure and the task says so: during recovery it correctly refuses scouts without a report and ship tasks with unlanded work, so a fleet of live parked workers has nothing teardown may legally remove.
With the servicing grace in place, the escape hatch stops being load-bearing, so widening it would relax a safety refusal for no remaining benefit.

## Owners

`bin/fm-watch-arm.sh` remains the single owner of the cycle-ledger record format and of which closes count actionable.
`bin/fm-supervision-lib.sh` owns the reader, `fm_supervision_serviced_wake_age`, so the gate does not parse the ledger itself.
`bin/fm-progress-lib.sh` remains the single owner of the progressing predicate; this change adds no second quietness notion and reads no task state.
[`watcher-continuity.md`](watcher-continuity.md) owns the harness-facing continuity contract, including the gate's three-state liveness test.

## Regression coverage

`tests/fm-continuity-pretool-check.test.sh` covers both directions.
It reproduces the 2026-08-05 scenario - ten progressing tasks, every pane idle past the stale threshold, no lock holder, an actionable-stale cycle record - and asserts that all six named recovery commands are permitted.
It then asserts the still-guards direction: an empty ledger, each non-actionable close reason, and an actionable record aged past the grace all still deny, and that the deny text is unchanged.
