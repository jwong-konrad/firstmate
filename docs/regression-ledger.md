# Regression ledger and board

A regression effort keeps its evidence as append-only records in one folder, and `bin/fm-regression.sh` derives every state from them and renders one self-contained HTML board.
Nothing on the board is typed in by hand: counts, staleness, "UI still owed", "changed since the last round" and every lint failure are recomputed at each render.
This document owns the record contract and the meaning of each derived state.
`bin/fm-regression.jq` owns the derivation itself, `bin/fm-regression.html` the page, and the script header the command mechanics.

The tool reads only the effort folder (an argument or `REGRESSION_EFFORT_DIR`), a backlog reader for linked decisions (`tasks-axi show <key>`), and an optional read-only Linear reader.
It has no other firstmate dependency, so it can move to another orchestrator unchanged.
Records are only ever appended, by hand or by the tool's `round`, `observe` and `render` commands; no command rewrites a line.
An effort folder holds private evidence, so keep it out of any shared repository; firstmate keeps its efforts under the gitignored `data/regressions/<effort>/`.

## Unit of record

The unit is the check: one thing asserted about one issue, phrased as the expected behaviour, for example "a user without the team-timesheet permission cannot add an entry to another person's timesheet".
Checks are grouped under an item, which is a tracked ticket or an untracked finding.
Results are observations: one per check, environment, build, layer and round.
An item's state is the worst of its checks' states, so a ticket's weakest arm is never hidden behind a stronger one.

## Files

Each record type is one JSON Lines file; `init` creates them empty.

| File | One line per | Fields |
|---|---|---|
| `effort.json` | (one object) | `id`, `title`, `envs` (display order), `target_envs` (default required environments), `default_required_layers` (default `["API","UI"]`), `evidence_root` (prefix for relative evidence paths), `linear.done_statuses`, `linear.closed_statuses`, `linear.max_read_age_minutes` (default 240), `note` |
| `builds.jsonl` | environment and code version | `env`, `sha` (or `unidentified`), `role` (`baseline`, `target` or `unknown`), `current`, `first_seen`, `evidence` |
| `items.jsonl` | tracked issue | `id`, `kind` (`ticket`, `finding`, `dev-question`), `linear_id`, `title`, `scope` (`in` or `out`), `scope_reason`, `owner_next`, `next_action`, `unblock`, `visibility`, `decision_keys`, `related`, `imported`, `note` |
| `checks.jsonl` | asserted claim, or an amendment of one | `id`, `item`, `claim`, `arm` (`refused`, `allowed`, `self`, `ui`, `logging`, `other`), `required_layers`, `ui_na` (reason), `envs`, `layer_envs` (`{layer: [env, ...]}`), `retired` (reason), `unblock`, `added_in_round`, `note`, `supersedes` |
| `observations.jsonl` | result | `id`, `check`, `round`, `date`, `env`, `build`, `layer`, `result`, `reason`, `evidence`, `recorded_by`, `supersedes` |
| `rounds.jsonl` | testing round in chronological order, or an amendment of one | `id`, `task`, `opened`, `planned` (check ids), `closed`, `report`, `note` |
| `linear.jsonl` | ticket status read | `ticket`, `status`, `assignee`, `read_at`, `read_by` |
| `relays.jsonl` | result carried to the tracker, or held back | `item`, `date`, `action` (`comment`, `status`, `filed`, `withheld`, ...), `verdict` (`fixed`, `still-open`, `as-designed`), `evidence`, `note` |
| `renders.jsonl` | render, written by `render` | `rendered_at`, `linear` (`action`, `reason`, `tickets_requested`, `tickets_returned`, `bytes`, `tokens`, `seconds`, `last_read_at`) |

Rules for observations:

- A line is never edited; a correction is a new line whose `supersedes` names the line it replaces.
- `layer` is one of `code`, `API`, `DB`, `log`, `UI`.
- `result` is one of `FIXED`, `STILL-OPEN`, `AS-DESIGNED`, `OBSERVED` (no verdict: baseline builds, or a layer the claim does not assert), `NOT-RUN`, `NOT-TESTABLE`, `BLOCKED`; the last three need a `reason`.
- `FIXED` means the check's claim holds on that build, whichever way the claim is phrased.
- `build` matches a registered build when either sha is a prefix of the other (at least 7 characters), or both are `unidentified`.

Rules for checks and rounds:

- A check is amended by a later line with the same `id` whose `supersedes` names that id; its fields replace the earlier ones, a `null` clears one, and fields it leaves out are kept.
  This is how a check is retired (`retired` with a reason), gains a `ui_na`, or moves a layer to other environments, without editing a line.
- A repeated check id without `supersedes`, and a `supersedes` that names no earlier line or not the line's own id, are lint failures.
- A rounds line with an already registered `id` amends that round the same way; `round close` appends `{id, closed}`.
  A round keeps the position of its first line.

A check requires UI unless it records `ui_na` with a reason.
Its other required layers come from `required_layers`, else the effort's default.
A check's required environments come from `envs`, else the effort's `target_envs`.
`layer_envs` moves a layer to its own environments: `{"UI": ["staging"]}` requires UI only on staging and every other layer only in the check's environments, so staging becomes a required environment for UI alone.
A retired check keeps its observations, is counted in its own "retired" bucket, never sets its item's state, and is never planned in a round.

## Derived states

Each check is judged per required environment against that environment's current build, and the check takes the worst cell. A `baseline` build's cell is observation only and never counts toward the check's state.
States, worst first:

| State | Meaning |
|---|---|
| still open | the latest result at a runtime layer (API, DB, log, UI) on the current build is `STILL-OPEN` |
| never observed | no observation at all in that environment |
| unknown build | results exist but cannot be tied to a code version: the current build, or the observed build, is `unidentified` |
| stale | results exist only on a build that is not current, or the current build has only a code reading while runtime results are older |
| code reading only | the current build has only a code-layer verdict; this never counts as fixed |
| blocked, not run, not testable here | the latest result at a required layer says so |
| server layer still owed | a runtime layer proves it, but a required non-UI layer has no proof |
| UI still owed | a runtime layer proves it, but UI is required and not proven |
| as designed | every required layer is proven, at least one by a captain ruling (`AS-DESIGNED`) |
| proven fixed | every required layer's latest result on the current build is `FIXED` |

Out-of-scope items and their checks are counted in their own bucket, retired checks in theirs, and an in-scope item with no live checks is "no checks yet".
The headline counts every state, zero included, and the counts always add up to the totals.
It then states how many in-scope checks are not yet proven fixed or as designed, and how many items have no checks.
The board gives no readiness verdict: whether the work moves to the next stage is the team's decision, not the tool's.

## Rounds and the coverage gate

A round is opened before testing starts and closed when its worker reports done.

1. `round open <round> --task <task-id> --checks ... --items ...` registers the round with its planned checks.
2. `brief-section <round>` prints the round's "Ledger duty" block for the worker's brief: the planned checks with their required layers per environment, the current builds, and the exact `observe` command.
3. The worker records each result with `observe`, which validates the line before appending it.
4. `round check <round>` reports coverage; the worker runs it before reporting done.
5. `round close <round>` refuses until the round is covered, then appends the close line and renders the board.

A round is covered when every planned, unretired check has at least one well-formed observation line in that round.
`NOT-RUN`, `NOT-TESTABLE` or `BLOCKED` with a reason always counts, so the gate blocks only a silent omission, never honest work; the same results without a reason do not count.
`bin/fm-teardown.sh` applies the same gate to a scout or tester task that a round names in its `task` field: the task cannot be cleaned up until `round check --task <id>` passes.
Tasks that no round names are untouched.

## Linear status at render

`render` reads Linear at most once, never once per ticket: it runs the reader named by `REGRESSION_LINEAR_CMD` with every item's `linear_id` on standard input and appends each returned status to `linear.jsonl` with the render time.
It skips the read and reuses the newest recorded one while that is younger than the re-read interval (`linear.max_read_age_minutes`, or `REGRESSION_LINEAR_MAX_AGE`).
Each render appends a `renders.jsonl` line recording whether Linear was read, reused, not read or failed, and for a read its output bytes and any token count the reader reports, so the cost of the read can be judged over time.
A failed read is recorded and never stops the render.
The reader must only read: the tool never writes to Linear, and nothing it runs may.
`json`, `lint` and the round commands other than `close` never read Linear.
The intended render points are round close and session start, which keeps the reads to a few a day.

## Lint

Every failure is listed on the board and counted in its freshness strip; `fm-regression.sh lint` exits 1 when there is any.

- `ticket-without-item`: a ticket in the latest Linear reads has no item.
- `linear-disagrees`: an in-scope ticket is done in Linear while our verdict is not fixed or as designed, or open in Linear while our verdict is.
- `unregistered-build`: an observation names a build that `builds.jsonl` does not register.
- `not-relayed`: an item's verdict (fixed, still open, or as designed) has no relay line carrying it; a `withheld` relay records a deliberate hold-back.
- `item-without-checks`: an in-scope item has no checks.
- `invalid-record`: a malformed line, such as an unknown layer or result, a missing reason, a dangling `supersedes` on an observation or check, a repeated check id without `supersedes`, a retirement or `ui_na` without a reason, a malformed `layer_envs`, a round planning an unknown check, or an unregistered round.

## The board

The page embeds its derived model and renders it in the browser with no external fetch.
Its freshness strip shows the render time, the oldest and newest Linear read, what this render did about Linear and its cost, the last round with its coverage, the lint count and whether decisions were read; it turns red once the embedded render time is more than 24 hours old.
Panel A lists outstanding items grouped by what unblocks them, Panel B the checks whose state changed between the last two rounds plus Linear moves between reads, and Panel C the open linked decisions, Linear disagreements and unrelayed verdicts.
Each item drills down to its checks, each check to one cell per environment with layer badges, and each cell to its observations with their evidence paths.
