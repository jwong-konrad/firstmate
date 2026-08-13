# Worker launch environment

How much of the captain's environment a spawned worker inherits, why it is now deny-by-default, and what this control does *not* cover.

`bin/fm-env-clean.sh`'s header and `--help` own the exact mechanics and the built-in allowlist.
[`configuration.md`](configuration.md) owns the `config/spawn-env-allow` schema.
This file is the incident record, the verification evidence, and the honest statement of residual risk.

## The incident, 2026-07-31

`bin/fm-spawn.sh` does not exec the agent directly.
It types a command line into a pane whose shell is an ordinary login shell, so the agent inherited that shell's entire environment - including every secret the captain had exported.

On 2026-07-31 `LINEAR_API_KEY` was present in the captain's shell environment.
A spawned worker inherited it, the no-mistakes PR-body generation step serialized the value verbatim into the description of fork PR #3, and GitHub secret scanning raised an alert.
The key was removed from the environment afterwards.

The leaked variable was the symptom.
The defect was blanket inheritance: firstmate had no control over what reached a worker, so the next exported secret would have leaked the same way.

A note on a confusing piece of evidence: the 2026-08-04 parity audit found `LINEAR_API_KEY` unset in a worker, unset in a login shell, and absent from every shell profile ([`../data/qa-parity-audit-a6/report.md`](../data/qa-parity-audit-a6/report.md)).
That does not refute the incident.
Both readings are true at different times - the key was in the environment on 2026-07-31 and had been removed by 2026-08-04.
The absence of one variable on one date is not evidence that the mechanism is safe.

## What changed

Every launch is wrapped in `bin/fm-env-clean.sh`, which runs *inside the worker's pane* and `exec env -i`s the harness with only:

1. allowlisted names that are actually set in that pane, and
2. the explicit `NAME=VALUE` assignments firstmate passes it.

Everything else is dropped.
A new secret in the captain's shell is therefore denied because it was never allowed, not because someone predicted it.

`fm-spawn`'s raw launch-command escape hatch must now be argv-style.
A raw command carrying a shell operator (`;`, `&&`, `||`, `|`, `&`, `>`, `<`, or a newline) refuses the spawn before anything is created, because the pane shell would split the line and run its tail outside the wrapper with the pane's full environment.
That check is a deliberately blunt substring scan rather than a shell parse: it cannot tell a quoted `>` from a redirection, and it errs toward refusing, since a false positive costs the caller one rewrite into argv form while a false negative is a boundary escape.
Command substitution is allowed - the pane shell evaluates it and only its output becomes an argument, which is exactly how the generated templates' `"$(cat ...)"` already works.

Two design points worth keeping:

**It runs in the pane, not in firstmate.**
`TERM`, `PATH`, and the multiplexer's own ids are pane-authoritative.
Snapshotting firstmate's own values instead would hand the worker the wrong terminal type and a `PATH` that never had to resolve the harness binary.
Because `PATH` is copied from the pane verbatim, the harness, `git`, and `gh` resolve exactly as they did before.

**Unset stays unset.**
An allowed name that is not set in the pane is not passed as empty; set-but-empty is a different and occasionally load-bearing state.

The multiplexer's own ids (`TMUX`, `TMUX_PANE`, the `HERDR_*` pane/session ids, `ZELLIJ*`, `CMUX_WORKSPACE_ID`, `CMUX_SURFACE_ID`) are on the built-in allowlist, because running in the pane preserves nothing the allowlist does not name.
A worker that runs its own bootstrap, recovery, or spawns reads them: `fm_backend_detect` picks the backend adapter from `TMUX`/`HERDR_ENV`/`CMUX_WORKSPACE_ID`, and supervisor-target discovery finds the pane its wakes go to from `TMUX_PANE`/`HERDR_PANE_ID`.
They are ids, never credentials, which is why the two cmux names are spelled out instead of allowing `CMUX_*` - that namespace also holds `CMUX_SOCKET_PASSWORD`.

**The wider `FM_*` fleet-tuning surface stays out, deliberately.**
`FM_BUSY_REGEX`, `FM_GUARD_GRACE`, the `FM_SEND_*` knobs and their siblings are not allowed through, and no wildcard is added to admit them.
Nothing a worker does today needs them, and admitting a whole documented tuning namespace to a shared boundary on the chance that something might is exactly the precautionary widening `config/spawn-env-allow` refuses by design.
A future need should arrive as its own scoped change naming the consumer that requires it.
This omission is a decision, not an oversight.

## The named passthrough seam

A worker that legitimately needs a variable gets it explicitly, never by blanket inheritance.
There are two ways in, and they are deliberately different sizes:

| Need | Mechanism | Scope |
| --- | --- | --- |
| A non-secret name this whole home should keep | `config/spawn-env-allow` | every worker this home spawns |
| A value for one project | `config/project-env`, delivered through `SPAWN_ENV_INJECT` | that project's spawns only |
| A value for one task | `SPAWN_ENV_INJECT` in `bin/fm-spawn.sh` | that spawn only |

`config/spawn-env-allow` takes exact names only.
Wildcards are refused, because a wildcard is a blanket passthrough wearing an allowlist's clothes.
Credential-shaped names are refused there too: a real credential is a per-project value, and belongs in the injection seam where it can be scoped, not in a home-wide name list.
Both refusals happen at spawn time, before a window, worktree, or task record exists, so a bad entry is a clean refusal instead of a pane that reports success and then dies on the launch line.

`config/spawn-env-allow` is deliberately **not** inherited into secondmate homes, unlike `config/crew-harness` and the rest of `FM_INHERITABLE_CONFIG`.
Widening an environment boundary should be a per-home act the captain performs deliberately, not something that propagates as a side effect of a sync.

### Per-project environment (`config/project-env`), landed 2026-08-13

`config/project-env` is read at spawn and delivered through `SPAWN_ENV_INJECT`, at the marked injection seam in `bin/fm-spawn.sh`.
[`configuration.md`](configuration.md) owns its schema, its refusal behavior, and why it is not inherited into secondmate homes.

The delivery mechanism is the load-bearing part, and it is worth recording why the obvious implementation is wrong.
A draft patch (`projects/claude-qa/scripts/firstmate-patches/0002-fm-spawn-project-env-injection.patch`, written before this boundary existed) delivered it by sending `export NAME=VALUE` into the pane, alongside the `GOTMPDIR` export that is still there.
A pane export does not cross `env -i`, so that would have set the variable in the pane and silently never reached the agent - exactly the mysterious-mid-task-failure shape this boundary exists to avoid, and indistinguishable from working code on inspection.
The `GOTMPDIR` pane export next to the seam is not a counterexample: the agent gets `GOTMPDIR` from `SPAWN_ENV_INJECT`, and the export exists only so a command the captain later types in that pane shares the task's temp root.

`tests/fm-spawn-env-allowlist.test.sh` pins the mechanism, not just the outcome: it asserts the variable is present in the launched agent's own dumped environment, and separately asserts the launch line does **not** carry it as a pane `export`.
Verified this way rather than by reading the code, because reading the code is what makes a pane export look correct.

## Verification, 2026-08-12

Everything below was run on macOS 25.6.0 (`darwin`), on this fleet, from a worker pane.

**The boundary holds.**
`tests/fm-spawn-env-allowlist.test.sh` takes the exact command line `fm-spawn` types into the pane, runs it in a shell carrying an unexpected variable, and asserts the launched agent's environment does not contain it.
Run against a `fm-spawn` with the wrapper disabled, that test fails with `not ok - LINEAR_API_KEY from the launching environment reached the worker`, which is the 2026-07-31 condition.

**The worker can still do its job.**
Under a clean environment with `SSH_AUTH_SOCK` unset:

```
$ env -i HOME=... PATH=... USER=... LOGNAME=... SHELL=... TERM=... LANG=... TMPDIR=... gh auth status
github.com
  ✓ Logged in to github.com account jwong-konrad (keyring)
  - Git operations protocol: https

$ ... gh-axi repo view
repo:
  name: firstmate

$ ... git ls-remote --heads origin main
7558ffbe768884dd079b9c6b1e446b11f60f3303	refs/heads/main

$ ... git credential fill  (protocol=https host=github.com)
username=jwong-konrad
password=<present>
```

macOS keychain access survives `env -i`: the Security framework resolves the login session from the process's inherited audit session, not from an environment variable.
That is what keeps `gh`'s keyring token and `git`'s `osxkeychain` helper working.

**Environment reduction observed on this fleet, re-measured 2026-08-12 after the multiplexer-id group was allowlisted:** 51 variables before, 24 after.

Measure it the same way when the allowlist changes again, from the pane in question:

```
$ printenv | wc -l                          # before: what the worker used to inherit
      51
$ bin/fm-env-clean.sh printenv | wc -l      # after: what the wrapper hands the agent
      24
```

That pair was measured in a worker pane with no multiplexer ids set, so the newly allowlisted `TMUX`/`HERDR_*`/`ZELLIJ*`/`CMUX_*` group adds nothing to this particular count; in a pane on the captain's herdr fleet the `after` figure is higher by however many of those ids are set there.
The `gh auth status`, `gh-axi repo view`, `git ls-remote` over the SSH remote, and `git credential fill` checks quoted above were re-run under the wrapper on the same date and still produce that output.

## Verification, 2026-08-13: per-project environment

Run on macOS 25.6.0 (`darwin`) against a fixture home whose `config/project-env` held one line, `polaris      PW_MCP_AUTH_APP=polaris`, with a fixture project clone named `polaris`.
The fixture directory is abbreviated below as `<d>` and this repo as `<repo>`; nothing else is edited.

The launch line `fm-spawn` composed carries the value as an explicit assignment to the wrapper, next to `GOTMPDIR`:

```
$ cat launch.log
'<repo>/bin/fm-env-clean.sh' --allow-file '<d>/home/config/spawn-env-allow' 'GOTMPDIR=/tmp/fm-demo-x1/gotmp' 'PW_MCP_AUTH_APP=polaris' FM_MANAGED=1 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions "$(cat '<d>/home/data/demo-x1/brief.md')"
```

Running that exact line the way the pane's login shell would, in a shell also carrying `LINEAR_API_KEY`, and dumping the launched process's own environment:

```
$ env LINEAR_API_KEY=leaked PATH=<fixture-bin>:$PATH bash -c "$(cat launch.log)"
$ grep -E 'PW_MCP_AUTH_APP|LINEAR_API_KEY' agent-env.txt
PW_MCP_AUTH_APP=polaris
```

The per-project value reached the agent process and the launching shell's secret did not, so widening the seam did not widen the boundary.
And the value is not delivered as a pane export, which is the failure mode this replaced:

```
$ grep -c 'export PW_MCP_AUTH_APP' launch.log
0
```

`PW_MCP_AUTH_APP` is also a useful case rather than an arbitrary one: it contains `AUTH`, so `config/spawn-env-allow` refuses it by name.
The injection seam is the only path by which it can legitimately reach a worker, which is exactly the split the table above describes.

## Residual risks this does not close

State these plainly rather than letting the allowlist read as a complete identity boundary.

**The captain's SSH identity is still reachable through the filesystem.**
`SSH_AUTH_SOCK` is dropped, so a worker cannot use the captain's ssh-agent, and agent-only or forwarded identities become unreachable.
But `git push` over SSH still succeeds from a worker without the agent, verified on 2026-08-12:

```
$ env -u SSH_AUTH_SOCK ssh -o BatchMode=yes -T git@github.com
Hi jwong-konrad! You've successfully authenticated, but GitHub does not provide shell access.
```

Two independent reasons, both filesystem-level:
`~/.ssh/config` sets `UseKeychain yes` for `github.com`, so `ssh` retrieves the passphrase for the encrypted `~/.ssh/id_ed25519` from the login keychain with no agent involved; and `~/.ssh/id_rsa` (used for the `kg-bastion*` hosts) has no passphrase at all.
Any process running as the captain with `HOME` set can read those files.

This is good news for the acceptance criterion that `git` keeps working, and it is the honest limit of an environment allowlist: dropping the agent socket removes an inherited *capability*, but it cannot remove access to a key sitting on disk.
Closing that requires a filesystem boundary, which is the sandbox work (`sandbox-trust-services-spike-t1`, `sandbox-scout-dispatch-s0`), not this control.

**The multiplexer ids hand the worker reach over the captain's session.**
`TMUX` and `HERDR_SOCKET_PATH` do not just identify a pane - they name the captain's live multiplexer server.
A worker holding them can drive that server with no further discovery: send keys into the captain's own pane, read what other panes hold.
That is the same shape of ambient capability as the `SSH_AUTH_SOCK` this control deliberately drops.
They are allowlisted anyway, for the same reason the SSH key stays readable: a worker needs its own backend detection and supervisor-pane discovery to work at all, and it could reach the default socket path regardless of whether the variable was handed to it.
Closing this belongs to the same filesystem/process sandbox work as the SSH residual (`sandbox-trust-services-spike-t1`, `sandbox-scout-dispatch-s0`), not to an environment allowlist.

**A profile can re-export a secret.**
Some harnesses initialize their shell tool from the user's profile, so a secret exported from `~/.zshrc` would return in a worker's subshells even though the agent process itself started clean.
No shell profile on this fleet exports a secret today (verified in the 2026-08-04 audit and again on 2026-08-12: the profiles export only `PATH`, `SDKMAN_DIR`, and `NVM_DIR`).
`fm-spawn` cannot enforce this; keeping secrets out of shell profiles remains a captain-side habit.

**A few allowed names could carry a credential in some home.**
The proxy variables (`HTTPS_PROXY` and friends) are allowed because a worker behind a corporate proxy cannot reach the network without them, and a proxy URL can embed `user:pass`.
None are set on this fleet.

**A pipeline can still serialize whatever the worker does hold.**
The 2026-07-31 leak needed two things: a secret in the worker's environment, and a step that wrote the environment into outward-facing text.
This control removes the first for firstmate-launched workers, and it is the load-bearing one because it closes the class rather than one symptom.
The second lives in `no-mistakes`, which firstmate does not own and cannot enforce.
Treat any pipeline or agent step that serializes environment into a PR body, issue comment, or log as a second necessary condition worth keeping absent - but not as a substitute for the allowlist.

## Maintaining this file

Keep this as evidence: dates, exact commands, exact output.
When the allowlist changes, re-verify the `gh`/`git`/keychain path rather than assuming it still holds, and update the reduction count and the residual-risk list to match what is actually true.
