# The upstream-port parallel home

The base-swap port rebuilds this fork on upstream's base rather than merging with it.
Phase 1 of that port stands up a second firstmate home that runs upstream's code against its own state, empty, beside the live fleet.
This page is the setup record, the isolation evidence, and the teardown procedure for that home.

`data/upstream-rebase-strategy-s5/report.md` is the plan of record and owns the phase sequence and the porting decisions.
This page owns only the vehicle those phases run in.

## Why a separate home and not a branch

`FM_HOME` selects an instance's private `data/`, `state/`, `config/`, and `projects/`, while scripts come from their own tracked code root.
A second home pointed at an upstream checkout therefore runs upstream's code against its own records without touching the live fleet's.

A branch in the live home would not be equivalent.
Firstmate's own scripts are what supervise in-flight tasks, so a half-ported `fm-watch.sh` or `fm-spawn.sh` is a live-fleet outage rather than a failed experiment.

## The two locations

| Purpose | Path |
| --- | --- |
| Upstream code root | `/Users/jacksonwong/Code/github/firstmate-upstream` |
| Parallel `FM_HOME` | `/Users/jacksonwong/Code/github/firstmate-upstream-home` |
| Parallel worktree pool | `/Users/jacksonwong/Code/github/firstmate-upstream-home/treehouse` |

Both sit outside the live home at `/Users/jacksonwong/Code/github/firstmate`, and neither is nested inside it.

The upstream checkout is pinned at `3eb5b6334a80e06083e3837f0032a5cec39b8e52`, committed `2026-09-17T03:21:19-07:00`, which was `upstream/main` on 2026-09-17.
It was cloned directly from `https://github.com/kunchenguid/firstmate.git` rather than from the live repo's `upstream` remote, so standing it up never wrote to the live repo's git state.

That pin is far ahead of `.upstream-pin`'s vetted `sha=673b6ad39d01183a19c5bd8a52675a2ee8ea06e6`, which is expected and is the entire point of the port.
Running unvetted upstream code in an isolated empty home is what makes the review in [`upstream-vetting.md`](upstream-vetting.md) possible without betting the fleet.

The checkout is pull-only, matching the live repo's convention.

```
$ git -C /Users/jacksonwong/Code/github/firstmate-upstream remote -v
upstream	https://github.com/kunchenguid/firstmate.git (fetch)
upstream	DISABLED-PULL-ONLY (push)
```

## Running it

One environment variable selects the parallel home.

```
FM_HOME=/Users/jacksonwong/Code/github/firstmate-upstream-home \
  /Users/jacksonwong/Code/github/firstmate-upstream/bin/fm-session-start.sh
```

`FM_HOME` is the only variable needed, and it must be set on every call.
The worktree pool is selected by a config file rather than by the environment, for the reason recorded under isolation 2.

Do not set `FM_ROOT_OVERRIDE`, because scripts resolve their own code root from their location and an override would cross the two trees.

### Two local choices this home makes

`config/backend` is pinned to `tmux`.
Without it the home inherits whatever runtime the caller happens to be running inside, which made the first session start auto-detect the experimental herdr backend purely because the operator's shell carried `HERDR_ENV=1`.
Pinning the backend makes the home behave the same no matter who launches it, and `tmux` is the verified reference backend.

`config/pr-target-deny` lists every repository this home must never open a pull request against.
See isolation 4 for what that file does and does not currently buy.

## The four isolations

These are namespaces the design shares on purpose.
Each one below names its mechanism and the command that demonstrates it, so a later phase can re-run the check rather than trust this page.

### 1. Multiplexer window namespace

Windows are named `fm-<task-id>` and lookup scans the multiplexer across every session, so isolation rests on the two homes never using the same task id.
Task ids in the parallel home are reserved with the prefix `upx-`, short for "upstream-port experiment".

Run this before any spawn in the parallel home, and stop if it returns anything other than `0`.

```
$ ls -1 /Users/jacksonwong/Code/github/firstmate/state/*.meta \
    | sed 's#.*/##; s#\.meta$##' | grep -c '^upx-'
0
```

The isolation itself is by recorded metadata, because each home resolves a task only from its own `state/<id>.meta`.
Both directions were measured with a live task id (`upstream-port-home-p1`) and a parallel one (`upx-probe-w1`).

```
$ FM_HOME=<parallel> <upstream>/bin/fm-crew-state.sh upstream-port-home-p1
state: unknown · source: none · no metadata for upstream-port-home-p1

$ FM_HOME=<live> <live>/bin/fm-crew-state.sh upx-probe-w1
state: unknown · source: none · no metadata for upx-probe-w1

$ FM_HOME=<live> <live>/bin/fm-crew-state.sh upstream-port-home-p1
state: working · source: pane · harness busy
```

The third line is the control.
Without it the first two prove only that the lookup returns nothing, not that it would have found a real task had one existed.

A second and independent separation happens to hold today: the live fleet runs `backend=herdr` in session `default`, while the parallel home is pinned to `tmux`, so the two currently address different multiplexers entirely.
Treat that as a bonus rather than the control, because a later phase could repoint either home.
The id prefix is the mechanism to rely on.

### 2. The worktree pool

The pool root comes from `treehouse.toml` in the checkout, not from the environment.

```
$ cat /Users/jacksonwong/Code/github/firstmate-upstream/treehouse.toml
max_trees = 8
root = "/Users/jacksonwong/Code/github/firstmate-upstream-home/treehouse"
```

Setting `TREEHOUSE_DIR` alone does not work, and this is worth stating plainly because the strategy report implies otherwise.
The first acquisition attempt set `TREEHOUSE_DIR` to the parallel pool and the worktree still landed in the live pool at `~/.treehouse/.treehouse/firstmate-upstream-7607a4`.
`treehouse` reads its root from `treehouse.toml` with a default of `$HOME`, and exports `TREEHOUSE_DIR` into the worktree subshell as an output rather than reading it as an input.
A later phase that relies on the environment variable would silently share the live fleet's pool.

With `root` set, an acquisition lands inside the parallel pool and the live pool inventory is unchanged.

```
$ cd /Users/jacksonwong/Code/github/firstmate-upstream && treehouse get --lease
/Users/jacksonwong/Code/github/firstmate-upstream-home/treehouse/.treehouse/firstmate-upstream-7607a4/1/firstmate-upstream
```

The live pool held 65 entries before and after, with no slot created for the upstream checkout.

```
$ ls -1 ~/.treehouse/.treehouse/ | wc -l
65
```

`treehouse.toml` is untracked upstream, so it shows as an untracked file in the checkout.
Leave it untracked and never commit it, because it carries a machine-local absolute path.

### 3. The shared no-mistakes daemon

One daemon instance serves every lane and home, so restarting it from the parallel home would kill other lanes' in-flight pipeline runs.
The parallel home ran no `no-mistakes` command at all.

Identity is the check, not liveness, because a restarted daemon is also running.

```
$ ps -eo pid,lstart,etime,comm | awk '$NF ~ /no-mistakes$/'
967 Mon 31 Aug 21:51:47 2026  16-15:30:06 /Users/jacksonwong/.local/bin/no-mistakes
```

The same pid and the same start timestamp were recorded before the work began and after it finished.
The 16-day uptime predates the task, so it is the original process rather than a same-pid coincidence.

If something in a later phase appears to need a daemon restart, stop and report it rather than restarting.

### 4. Project remotes

A parallel home that cloned a live project could push branches to the same `origin`, so this isolation is layered.

The operative layer today is that the parallel home has no project clones and no project registry.
`projects/` is empty and `data/projects.md` is absent, so there is no dispatch target and nothing that can reach a real origin.

```
$ ls -A /Users/jacksonwong/Code/github/firstmate-upstream-home/projects | wc -l
0
```

The second layer is `config/pr-target-deny`, which covers all six projects registered in the live home's `data/projects.md` plus the fork itself and the upstream template.

```
claude-qa            jwong-konrad/claude-qa             covered
api-probe-kit        jwong-konrad/api-probe-kit         covered
engagement-toolkit   jwong-konrad/engagement-toolkit    covered
konrad               jwong-konrad/konrad-qa             covered
brainstation         jwong-konrad/brainstation_web_qa   covered
polaris              jwong-konrad/polaris-qa            covered
uncovered: 0
```

That file is currently inert, and the honesty matters more than the coverage.
Upstream's base ships no `bin/fm-pr-target-guard.sh` and contains no reference to `pr-target-deny` anywhere, which is exactly what the strategy report records as item B.
The file is written now so that Phase 5's port of the guard has nothing left to remember, but until that port lands nothing reads it.

Until then, do not rely on the denylist.
Keep `projects/` empty, and when a later phase genuinely needs a project, give this home a throwaway clone rather than a clone of a real one.

## What upstream's base does not have here

Two findings from standing the home up bind later phases.

The pull-request target guard is absent, as recorded under isolation 4.

Upstream's toolchain floors are above what this machine has installed, so a clean session start still reports four tools as missing.

```
MISSING: no-mistakes (install: ...)
MISSING: gh-axi (install: ...)
PRESENTATION_UNAVAILABLE: lavish-axi (requires >=0.1.46; install: ...)
MISSING: quota-axi (install: ...)
MISSING: tasks-axi (install: ...)
```

All four are present on `PATH`, so these are version-floor failures rather than absences.
Upstream requires `no-mistakes` 1.46.0 against 1.37.0 installed, and `gh-axi` 0.1.29 against 0.1.27 installed.

This does not block Phase 1, because an empty home dispatches nothing.
It does block the Phase 7 soak, and upgrading `no-mistakes` replaces the shared daemon, so that upgrade is the captain's call and not a side effect of a porting phase.

## Verifying the live home was untouched

The live home's `data/`, `config/`, `state/`, and `projects/` were captured before the work began and again after it finished.

| Section | Before | After the parallel-home work |
| --- | --- | --- |
| `data/` | `de35e2be...` | `de35e2be...` |
| `config/` | `a3aa7c24...` | `a3aa7c24...` |
| `projects/` | `a0331769...` | `a0331769...` |
| `state/` | `8fdbe11c...` | `9882dc51...` |

`data/`, `config/`, and `projects/` were byte-identical across that window.
`state/` changed, and claiming otherwise would be false.
The live fleet's own watcher writes there continuously, and this task appends to its own status file by instruction.

A byte-identity check is not the durable control, because the live fleet keeps working while a phase runs.
A later re-measurement showed `data/` and `projects/` had moved as well, and the cause was the live fleet dispatching its own brainstation scout `bstn-pr102-scope-check-k4`: a new brief under `data/`, a new backlog entry, and one new ref in the brainstation clone.
That is the live fleet operating normally, which is what an isolated parallel home is supposed to permit.

Attribution is therefore the control, and it is mechanical rather than assumed.
Every changed path resolves to the live fleet's own watcher and dispatch or to this task's status file, and the watcher records its own home in its lock.

```
$ cat /Users/jacksonwong/Code/github/firstmate/state/.watch.lock.owner.*/fm-home
/Users/jacksonwong/Code/github/firstmate
/Users/jacksonwong/Code/github/firstmate

$ grep -rl 'firstmate-upstream' /Users/jacksonwong/Code/github/firstmate/state/ | wc -l
0
```

The parallel home's path appears in no live state file.

Re-run this check the same way after any later phase.
Attribute every delta rather than expecting any section to be byte-identical, because a live fleet that is still working will move `data/`, `state/`, and `projects/` on its own.
The claim to test is that nothing changed *because of* the parallel home, and the grep above is the cheapest way to test it.

## Teardown

Removing the parallel home is one pool destroy, two directory deletions, and a confirmation, and none of it touches the live home.

First return and destroy anything in the parallel pool, so no worktree is left holding a lease.
Name the checkout rather than the pool directory, because `treehouse` resolves the pool through that checkout's own `treehouse.toml`.

```
treehouse destroy /Users/jacksonwong/Code/github/firstmate-upstream --all --yes
```

Run it without `--yes` first, because destroy is a dry run by default and prints what it would remove.
A leased worktree is never removed by `--all`, so return it by path first if one is held.

Then remove both trees.

```
rm -rf /Users/jacksonwong/Code/github/firstmate-upstream-home
rm -rf /Users/jacksonwong/Code/github/firstmate-upstream
```

Then confirm the live fleet is intact.

```
ls -1 ~/.treehouse/.treehouse/ | wc -l
ps -eo pid,lstart,comm | awk '$NF ~ /no-mistakes$/'
git -C /Users/jacksonwong/Code/github/firstmate status --porcelain
```

The pool count should match what it was before the home existed, the daemon pid and start time should be unchanged, and the live repo should be clean.

Teardown is safe to run without the captain's approval only while the home is empty.
Once a later phase has real ported work in it, that work is unlanded work and the ordinary rule applies: do not discard it without explicit authority.

## Verification record

Stood up 2026-09-17 on macOS (Darwin 25.6.0).

- Upstream checkout at `3eb5b6334a80e06083e3837f0032a5cec39b8e52`, cloned from `https://github.com/kunchenguid/firstmate.git`.
- Fork at `d4db97722251c88bf3ead3cec40a156ba7d68271`.
- `git` 2.40.0, `no-mistakes` v1.37.0, `treehouse` dev build, `gh-axi` 0.1.27.
- `bin/fm-session-start.sh` from the upstream checkout exited `0` and reported no work under way, no orphan status logs, no queued wakes, and every context file absent.
- No worker was spawned against any project clone, and the parallel home has none.

## Maintaining this file

This page is the setup record for a temporary vehicle, so it should shrink as the port progresses.
When Phase 5 ports the pull-request target guard, replace the inert-denylist caveat in isolation 4 with the demonstrated refusal.
When the port reaches cutover, this page and the parallel home go away together.
Keep the four isolations and their verification commands accurate for as long as the home exists, because later phases trust them.
