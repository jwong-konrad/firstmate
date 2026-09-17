# The upstream-port phase log

The base-swap port rebuilds this fork on upstream's base rather than merging with it.
This page is the per-phase ledger of what was actually ported, what was deliberately left behind, and where the next phase picks up.

[`upstream-port-parallel-home.md`](upstream-port-parallel-home.md) owns the vehicle the phases run in, and `data/upstream-rebase-strategy-s5/report.md` is the plan of record that owns the phase sequence.
This page owns neither, and records only outcomes.

Baselines used throughout: merge-base `673b6ad39d01183a19c5bd8a52675a2ee8ea06e6`, fork head `8f8a475ba5778d88684426a95fc1c8cb59517f81`, upstream pin `3eb5b6334a80e06083e3837f0032a5cec39b8e52`.

## Phase 2 - the free files

Ported 2026-09-17.
Every genuinely-new fork-only file now sits on upstream's tree, and nothing is wired in.

| | |
| --- | --- |
| Branch | `fm/port-p2-free-files` in `/Users/jacksonwong/Code/github/firstmate-upstream` |
| Commit | `864bcb75c09f6c8a46b2ef516c45d64d89224da9` |
| Parent | `3eb5b6334a80e06083e3837f0032a5cec39b8e52` |
| Files added | 25 |
| Upstream files changed | 0 |

The branch is local to that checkout and was not pushed anywhere, matching the pull-only convention recorded for the parallel home.

### How absence was proved

The inventory was derived from the two trees rather than taken from the strategy report, then each candidate was proved absent one file at a time.

```
git -C <fork> ls-tree -r --name-only 8f8a475b            # 285 tracked files
git -C <upstream> ls-tree -r --name-only 3eb5b633        # 582 tracked files
git -C <upstream> cat-file -e 3eb5b633:<path>            # non-zero => absent at upstream
git -C <upstream> cat-file -e 673b6ad3:<path>            # zero     => existed at the merge-base
```

That yields 39 fork-only files.
Of those, 25 are absent at the merge-base as well and are therefore genuinely new, and 14 existed at the merge-base and were deleted upstream on purpose.
Only the 25 were ported.

Each ported file was additionally checked to be byte-identical to the fork and to carry the fork's file mode, by comparing the staged index entry against `git ls-tree` in the fork.

### The 25 files ported

Eighteen from the strategy report's free-files list:

```
bin/fm-banner-lib.sh                    docs/captain-idle-handoff.md
bin/fm-captain-idle-handoff.sh          docs/supervision-arming.md
bin/fm-env-clean.sh                     docs/supervision-deadlock-guard.md
bin/fm-pr-target-guard.sh               docs/worker-environment.md
bin/fm-progress-lib.sh                  .agents/skills/handoff/SKILL.md
tests/fm-captain-idle-handoff.test.sh   tests/fm-spawn-app-checkouts.test.sh
tests/fm-pr-target-guard.test.sh        tests/fm-spawn-collision-guard.test.sh
tests/fm-progress-arming.test.sh        tests/fm-spawn-env-allowlist.test.sh
tests/fm-send-liveness.test.sh          tests/lib.test.sh
```

Six added by fork PR 21 in `17cba07f`, the upstream pin guard:

```
.upstream-pin              docs/upstream-vetting.md
bin/fm-upstream-gate.sh    tests/fm-upstream-gate.test.sh
bin/fm-upstream-pin.sh     tests/fm-upstream-pin.test.sh
```

One added by fork PR 24 in `03b371f8`, the parallel-home record:

```
docs/upstream-port-parallel-home.md
```

### Differences from the report's list of 18

The report's 18 were all re-confirmed absent at the pin, so none of them dropped out.
The derived list is larger by exactly seven files, and every one of them postdates the report.

- The six PR 21 files are the ones the report's sequence already anticipated as "PR #21's six" without naming them, and this log names them.
- `docs/upstream-port-parallel-home.md` landed the same day the report was written, so the report could not have counted it.

No file the report listed has since appeared upstream, and no genuinely-new fork file was missing from the report other than those seven.

### The 14 files deliberately excluded

These re-add without conflict, which is exactly what makes them dangerous.
Each existed at the merge-base and was removed upstream by a named commit that shipped a replacement, so re-adding one here would silently reverse an upstream decision and force a second removal in Phase 4.

| Upstream commit | Decision | Files |
| --- | --- | --- |
| `b05eb244` | recover Claude supervision without the watcher-status gate (#1001) | `bin/fm-continuity-pretool-check.sh`, `bin/fm-continuity-command-policy.mjs`, `tests/fm-continuity-pretool-check.test.sh`, `tests/fm-claude-continuity-live-e2e.test.sh` |
| `a2d5f264` | replace source assertions with behavioral coverage (#1282) | `tests/fm-captain-translation-contract.test.sh`, `tests/fm-install-herdr.test.sh`, `tests/fm-instruction-owners.test.sh`, `tests/fm-no-mistakes-ownership.test.sh`, `tests/fm-stow-contract.test.sh` |
| `3f71cddd` | remove the vestigial dispatch selector (#1026) | `bin/fm-dispatch-select.sh`, `tests/fm-dispatch-select.test.sh` |
| `99b21d82` | collapse decisions into tasks held for the captain (#2728) | `docs/decision-hold-lifecycle.md`, `tests/fm-decision-hold-lifecycle.test.sh` |
| `9e3df47b` | retire legacy PR-check migration machinery (#3299) | `bin/fm-pr-check-migrate.sh` |

The brief for this phase named the first, third, and fifth rows, which is seven of the fourteen files.
The other seven were found by applying the same merge-base test to every derived candidate, and they are the same trap.
Upstream kept `.agents/skills/decision-hold-lifecycle/SKILL.md` while deleting the doc beside it, so `99b21d82` relocated that contract rather than dropping it.

All fourteen belong to Phase 4, the drops phase, and none of them is a Phase 2 omission.

### The revert check

The test of this phase is that removing the added files returns the tree to where it started, and it is checked by tree hash rather than by eye.

```
pin tree       dbf2f9fbbf8a1ac429f9851ccf4797b8143558e2
port tree      c02393ed764be484072441cf94f26ab5e5d03ebe
reverted tree  dbf2f9fbbf8a1ac429f9851ccf4797b8143558e2
```

The reverted tree is the pin tree, so deleting the 25 files restores `3eb5b633` exactly.
`git diff --cached --diff-filter=MDRT` against the port commit is empty, confirming no upstream file was modified, deleted, renamed, or retyped.

### Present is not the same as inert

Nothing in upstream's tree names any ported file, checked by grepping upstream's own files for each ported path.
Presence alone still changes two upstream checks, because upstream derives repo-wide inventories from the filesystem rather than from an enumerated list.
Both were measured on the pristine pin first, and both pass there, so each is attributable to this phase.

**The test-lane coverage guard now fails.**
`bin/fm-test-run.sh` discovers suites with `for f in tests/*.test.sh`, and its portable-serial lane is a derived remainder, so the ten ported test scripts join the lane the moment they exist.
The guard's set checks still pass, because the remainder absorbs them.
Its bound on unmeasured duration hints does not.

```
baseline  26 of 175 portable serial scripts unhinted  14.86%  passes
ported    36 of 185 portable serial scripts unhinted  19.46%  fails (cap 15%)
```

All ten of the added scripts are unhinted, which accounts for the whole difference.
Clearing it means recording measured durations in `docs/fm-test-portable-shards.md` from a green run, which needs the suites actually executed and therefore belongs to the Phase 7 verification rather than here.
Adding hints in this phase would mean editing upstream's runner, which is the wiring this phase excludes.

**The documentation-audience check now fails.**
`bin/fm-doc-audience-check.sh` requires every documentation file to be classified in `docs/documentation-audiences.json`, and reports seven ported files as unclassified.

```
fm-doc-audience-check: unclassified: .agents/skills/handoff/SKILL.md,
  docs/captain-idle-handoff.md, docs/supervision-arming.md,
  docs/supervision-deadlock-guard.md, docs/upstream-port-parallel-home.md,
  docs/upstream-vetting.md, docs/worker-environment.md
```

Classifying them is a one-file edit to upstream's inventory, which makes it a Phase 3 seam rather than a Phase 2 change.

Neither failure is a defect in the ported files, and neither is avoidable inside this phase.
A later phase that sees red CI on the ported tree should check these two first.

`bin/fm-lint.sh` on the ported tree reports no ShellCheck finding, and all 17 ported shell files pass upstream's pinned ShellCheck 0.11.0 with source following enabled.
That run also reports `actionlint` missing, which is the host toolchain gap already recorded for the parallel home and not a property of the port.

### Two corrections to the brief for this phase

The brief stated that the live repo has no `upstream` remote and that the port therefore could not be done as a branch against an upstream base in the live repo.
The live repo does have one, fetch-only, and `upstream/main` there already resolves to the pin.

```
$ git -C /Users/jacksonwong/Code/github/firstmate remote -v
no-mistakes  /Users/jacksonwong/.no-mistakes/repos/7fd9988b1391.git (fetch)
no-mistakes  /Users/jacksonwong/.no-mistakes/repos/7fd9988b1391.git (push)
origin       git@github.com:jwong-konrad/firstmate.git (fetch)
origin       git@github.com:jwong-konrad/firstmate.git (push)
upstream     https://github.com/kunchenguid/firstmate.git (fetch)
upstream     DISABLED-PULL-ONLY (push)
```

The conclusion still holds and the work was still done in the upstream checkout, because the parallel home is the vehicle of record and a half-ported `bin/` inside the live repo is the live-fleet outage the strategy report rules out.
No remote was added anywhere.

The brief also described the exclusions as three files.
They are four files across three upstream commits as the brief counted them, and fourteen files across five upstream commits once the same test is applied to the whole derived inventory.

### What Phase 3 picks up

Check out `fm/port-p2-free-files` at `864bcb75` in `/Users/jacksonwong/Code/github/firstmate-upstream` and build on it.
The checkout is left on that branch, with `main` still at the pin and `treehouse.toml` still untracked.

This log is itself a new fork-only file and is not on the ported branch, so whichever phase next syncs fork documentation onto upstream's tree should carry it across with any other docs written since `8f8a475b`.

## Maintaining this file

Append one section per completed phase, in phase order, and keep each one to outcomes.
Record what was ported, what was excluded and why, the branch and commit the next phase starts from, and the check that proves the phase is revertible.
Mechanism belongs in the script headers, the vehicle belongs in [`upstream-port-parallel-home.md`](upstream-port-parallel-home.md), and the plan belongs in the strategy report.
When the port reaches cutover, this log is the record of how the base was swapped and should outlive the parallel home.
