# The upstream vetting boundary

This repo is a fork of an upstream template repo, and that relationship is PULL-ONLY.
Firstmate fetches from upstream and never pushes, opens a pull request, or creates any other artifact there.
Upstream work is unvetted until someone reviews it, and this page explains the machinery that keeps unvetted work from entering the fork unnoticed.

`.upstream-pin`'s own comments own the file format, and `bin/fm-upstream-pin.sh`, `bin/fm-upstream-gate.sh`, and `bin/fm-bootstrap.sh` own their behavior in their headers.
This page is the rationale and the verification record, not a second copy of those contracts.

## Why the pin exists

Upstream once landed code that injected the maintainer's own 1Password secrets into every agent launch, gated on their personal Keychain account name.
It was reverted about seven hours later.
A fork that fast-forwards from upstream on trust would have shipped that to every agent this fleet spawns.
Ingestion is therefore treated as adversarial by default: reviewed means reviewed, and the review is weighted onto the trust surface rather than onto the line count.

The trust surface is the code that launches, tears down, updates, and configures agents.
In practice that means `bin/fm-spawn.sh`, `bin/fm-teardown.sh`, `bin/fm-bootstrap.sh`, `bin/fm-update.sh`, and the harness hook configuration under `.claude/`, `.codex/`, `.opencode/`, `.pi/`, and `.grok/`.
A large diff in documentation or tests is not the same risk as a small diff in any of those.

## The two values, and why they are not one value

`.upstream-pin` carries `sha` and `review_head`, and they answer different questions.

`sha` is an upstream commit and says how far upstream has been reviewed.
It is the only value the drift count and the CI gate compute from, because coverage is defined as "reachable from `sha`".

`review_head` is a commit in this fork and says which state of the fork the review ended at.
It is an audit record, validated but never consulted for a decision.

Collapsing them into one value looks harmless and is not.
A fork commit and an upstream commit are both valid commit ids in the same repository, so nothing about the file's shape catches the substitution.
It was caught here during implementation: the first draft pinned `sha` to the fork commit the clean review ended at, and the gate's own upstream-ancestry rule refused it.
`bin/fm-upstream-gate.sh` now refuses a fork commit in `sha` outright, and `tests/fm-upstream-gate.test.sh` pins that refusal so the mistake cannot come back quietly.

For the record, the substitution happened to produce the same drift count on the day it was caught, because `A..B` excludes commits reachable from `A` and the fork-only commits excluded no upstream commits.
That is luck, not a property worth relying on, and it is exactly why the two values are named separately.

## Where the guard sits, and where it deliberately does not

The gate runs where commits ENTER the fork: `.github/workflows/ci.yml`'s `upstream-pin` job, on every push and pull request to `main`.
It does not run where the fleet CONSUMES commits.
`bin/fm-update.sh` and `bin/fm-fleet-sync.sh` stay fast-forward-only from `origin` and know nothing about upstream, because by the time a home fast-forwards, unreviewed upstream work would already be inside the fork.

The gate fails closed: an unreachable upstream, an unresolvable ref, or an unparseable pin stops the run rather than waving it through.
The session-start drift diagnostic is the opposite by design.
It is advisory, silent when there is no drift and when nothing is known, and no failure inside it can stop a session start, because a network problem is not a reason to stop the fleet.

## Advancing the pin

Advancing `sha` is a claim that everything newly reachable from it was reviewed.
The review is captain-authorized work, separate from the merge that ingests it.
In the ordinary flow the ingesting change merges upstream and sets `sha` to the upstream commit it merged, in the same range, so the gate sees the ingestion covered.

The gate does not stop a maintainer who advances the pin without doing the review.
It is not trying to: its job is to make ingestion deliberate and visible rather than silent.
A pin advance is a one-line diff that states, in the permanent record, exactly how much upstream history someone claimed to have read.

## Verification record

Dated 2026-09-16, against this repo at `bin/fm-upstream-pin.sh` and `bin/fm-upstream-gate.sh` as committed.

Drift measured live, and the pin's coverage checked against it:

```
$ bin/fm-upstream-pin.sh --fetch && bin/fm-upstream-pin.sh --count
423
$ git merge-base main refs/fm-upstream/main
673b6ad39d01183a19c5bd8a52675a2ee8ea06e6
$ git merge-base --is-ancestor 673b6ad3... refs/fm-upstream/main && echo YES
YES
$ git merge-base --is-ancestor f157a6b6... refs/fm-upstream/main || echo NO
NO
```

Upstream commits reachable from the pin: 238.
Upstream commits not reachable from the pin: 423, which is the reported drift.

The behavior tests are the proof that the rules hold, not these numbers, which move every time upstream commits.
`tests/fm-upstream-gate.test.sh` builds a real fixture upstream and a fork that genuinely merges from it, then proves the refusals and the passes.
`tests/fm-upstream-pin.test.sh` proves the format refusals, that the fetch writes only `refs/fm-upstream/<branch>` and moves no branch, and that a hung fetch is cut off by its timeout.
The drift diagnostic's cases live in `tests/fm-bootstrap.test.sh`.

## Harness and runtime backend applicability

Both axes were inspected rather than assumed.

Primary harnesses (`claude`, `codex`, `opencode`, `pi`, `grok`): applicable uniformly, with no per-harness code path.
`bin/fm-session-start.sh` captures bootstrap's output and prints it verbatim on both the locked and the read-only path, with no prefix allowlist that a new diagnostic line could fall outside of.
No tracked harness hook under `.claude/`, `.codex/`, `.opencode/`, `.pi/`, or `.grok/` reads bootstrap diagnostic lines, so no adapter needed changing.

Runtime backends (`tmux`, `herdr`, `zellij`, `orca`, `cmux`, and the Codex App thread coordination): not applicable.
The drift diagnostic runs before bootstrap's mutating sweeps and calls no `fm_backend_*` function and no backend CLI; it uses `git` alone.
The CI gate runs on a GitHub runner with no runtime backend at all.
