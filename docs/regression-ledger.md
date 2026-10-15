# Regression ledger and board

A regression effort keeps its evidence as append-only records in one folder, and `bin/fm-regression.sh` derives every state from them and renders one self-contained HTML board.
Nothing on the board is typed in by hand: counts, staleness, "UI still owed", "changed since the last round" and every lint failure are recomputed at each render.
This document owns the record contract and the meaning of each derived state.
`bin/fm-regression.jq` owns the derivation itself, `bin/fm-regression.html` the page, and the script header the command mechanics.

The tool reads only the effort folder (an argument or `REGRESSION_EFFORT_DIR`) and, for linked decisions, a backlog reader (`tasks-axi show <key>`).
It has no other firstmate dependency, so it can move to another orchestrator unchanged.
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
| `effort.json` | (one object) | `id`, `title`, `envs` (display order), `target_envs` (default required environments), `default_required_layers` (default `["API","UI"]`), `evidence_root` (prefix for relative evidence paths), `linear.done_statuses`, `linear.closed_statuses`, `note` |
| `builds.jsonl` | environment and code version | `env`, `sha` (or `unidentified`), `role` (`baseline`, `target` or `unknown`), `current`, `first_seen`, `evidence` |
| `items.jsonl` | tracked issue | `id`, `kind` (`ticket`, `finding`, `dev-question`), `linear_id`, `title`, `scope` (`in` or `out`), `scope_reason`, `owner_next`, `next_action`, `unblock`, `visibility`, `decision_keys`, `related`, `imported`, `note` |
| `checks.jsonl` | asserted claim | `id`, `item`, `claim`, `arm` (`refused`, `allowed`, `self`, `ui`, `logging`, `other`), `required_layers`, `ui_na` (reason), `envs`, `unblock`, `added_in_round`, `note` |
| `observations.jsonl` | result | `id`, `check`, `round`, `date`, `env`, `build`, `layer`, `result`, `reason`, `evidence`, `recorded_by`, `supersedes` |
| `rounds.jsonl` | testing round, in chronological order | `id`, `task`, `opened`, `closed`, `report`, `note` |
| `linear.jsonl` | ticket status read | `ticket`, `status`, `assignee`, `read_at`, `read_by` |
| `relays.jsonl` | result carried to the tracker, or held back | `item`, `date`, `action` (`comment`, `status`, `filed`, `withheld`, ...), `verdict` (`fixed`, `still-open`, `as-designed`), `evidence`, `note` |

Rules for observations:

- A line is never edited; a correction is a new line whose `supersedes` names the line it replaces.
- `layer` is one of `code`, `API`, `DB`, `log`, `UI`.
- `result` is one of `FIXED`, `STILL-OPEN`, `AS-DESIGNED`, `OBSERVED` (no verdict: baseline builds, or a layer the claim does not assert), `NOT-RUN`, `NOT-TESTABLE`, `BLOCKED`; the last three need a `reason`.
- `FIXED` means the check's claim holds on that build, whichever way the claim is phrased.
- `build` matches a registered build when either sha is a prefix of the other (at least 7 characters), or both are `unidentified`.

A check requires UI unless it records `ui_na` with a reason.
Its other required layers come from `required_layers`, else the effort's default.
A check's required environments come from `envs`, else the effort's `target_envs`.

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

Out-of-scope items and their checks are counted in their own bucket, and an in-scope item with no checks is "no checks yet".
The headline counts every state, zero included, and the counts always add up to the totals.
The board reads ready only when every in-scope check is proven fixed or as designed, every in-scope item has checks, and lint is clean; an empty effort is never ready.

## Lint

Every failure is listed on the board and counted in its freshness strip; `fm-regression.sh lint` exits 1 when there is any.

- `ticket-without-item`: a ticket in the latest Linear reads has no item.
- `linear-disagrees`: an in-scope ticket is done in Linear while our verdict is not fixed or as designed, or open in Linear while our verdict is.
- `unregistered-build`: an observation names a build that `builds.jsonl` does not register.
- `not-relayed`: an item's verdict (fixed, still open, or as designed) has no relay line carrying it; a `withheld` relay records a deliberate hold-back.
- `item-without-checks`: an in-scope item has no checks.
- `invalid-record`: a malformed line, such as an unknown layer or result, a missing reason, a dangling `supersedes`, or an unregistered round.

## The board

The page embeds its derived model and renders it in the browser with no external fetch.
Its freshness strip shows the render time, the oldest and newest Linear read, the last round, the lint count and whether decisions were read; it turns red once the embedded render time is more than 24 hours old.
Panel A lists outstanding items grouped by what unblocks them, Panel B the checks whose state changed between the last two rounds plus Linear moves between reads, and Panel C the open linked decisions, Linear disagreements and unrelayed verdicts.
Each item drills down to its checks, each check to one cell per environment with layer badges, and each cell to its observations with their evidence paths.
