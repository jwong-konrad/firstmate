# Worker write sandbox

The write boundary a claude scout runs inside, the evidence that it holds, and what it does not cover.

[`configuration.md`](configuration.md) "Worker permission posture and captain-present override" owns the posture and the override contract.
`bin/fm-sandbox-lib.sh`'s header owns the exact settings block, and `bin/fm-sandbox-guard.sh` and `bin/fm-sandbox-settings.sh` own their own mechanics.
This file is the verification evidence and the honest statement of residual risk.

## What a claude scout launches with

`bin/fm-spawn.sh` already writes `<worktree>/.claude/settings.local.json` for every claude worker to install the turn-end hook.
For a `kind=scout` task on a claude harness it writes two more things into the same file, and leaves `--dangerously-skip-permissions` exactly as it was:

1. Claude Code's built-in OS sandbox (macOS Seatbelt): `sandbox.enabled`, `allowUnsandboxedCommands: false`, `enableWeakerNetworkIsolation: true`, and `filesystem.allowWrite` set to the task's own `state/<id>.status` and `state/<id>.turn-ended`, `data/<id>/`, and `/tmp/fm-<id>/`.
   It confines every shell command and its child processes to the working directory plus that list.
2. A `PreToolUse` hook for `Edit|Write|MultiEdit|NotebookEdit` running `bin/fm-sandbox-guard.sh`, which refuses a file-tool write whose resolved target is outside the worktree, that same list, and the sandbox's own temp root.

Ship and tester tasks keep the turn-end-only settings, and a scout on any other harness launches exactly as before.
Testers are unsandboxed by design, because QA against the project's own stage and local apps needs a full browser; their brief binds the project's production-URL guard instead.
Each launch records `sandbox=on|off|off-tester|override|unsupported-harness` in `state/<id>.meta`.

A relaunch or resume restarts the harness in the existing worktree without `fm-spawn.sh`, so it would inherit whatever that settings file now says.
`bin/fm-sandbox-settings.sh <id>` regenerates the file from the task record immediately before a claude relaunch or resume, which returns the task to its standing posture and discards anything a worker wrote into the file.

## Why each setting is there

- `allowUnsandboxedCommands: false` - by default the Bash tool accepts a per-call `dangerouslyDisableSandbox`, and under `--dangerously-skip-permissions` that retry runs unsandboxed with no prompt.
  Without this setting the boundary is advisory.
- `enableWeakerNetworkIsolation: true` - `gh` verifies TLS through the macOS trust service, which the sandbox otherwise blocks, so every `gh` and `gh-axi` call fails.
  It opens that one service, which Claude Code's documentation notes is a potential exfiltration path; scouts read GitHub constantly, so the trade is deliberate.
- Pre-created state files - a single-file `allowWrite` entry is honoured only when the file already exists.
- The file-tool guard - the sandbox does not cover Claude Code's own file tools, which follow permission rules instead, and allow rules do nothing under `--dangerously-skip-permissions`.
  Hooks still fire under that flag and receive the exact target path, so a resolved-path check is reliable where a shell-string check is not.
  The guard fails closed: a missing `jq`, an unreadable payload, or a path it cannot resolve safely denies the write.

## Verification evidence

Verified 2026-10-14 against Claude Code 2.1.296 on macOS, in throwaway directories outside any repo, with the production flag: `claude --dangerously-skip-permissions --model haiku -p "<numbered commands>"` and the settings in `<work>/.claude/settings.local.json`.
`<home>` stands for a firstmate home whose `state/` and `data/` are outside any Claude temp directory.

| Check | Command | Result |
|---|---|---|
| Shell write outside the boundary | `echo x > /tmp/<outside>/a.txt` | `(eval):1: operation not permitted`, rc=1, file absent |
| Interpreter write outside | `python3 -c "open('/tmp/<outside>/py.txt','w').write('y')"` | `PermissionError: [Errno 1] Operation not permitted` |
| Write into the user's Claude config | `echo x > $HOME/.claude/<probe>` | `operation not permitted` |
| In-copy write and commit in a linked git worktree | `echo x > in.txt && git add in.txt && git -c commit.gpgsign=false commit -qm t` | commit created |
| Shared git dir of that worktree | writes to `<main>/.git/hooks/`, `<main>/.git/config`, `<main>/<file>` | all `operation not permitted`; `<main>/.git/refs/heads/<ref>` writable, as git needs |
| Declared directories | `echo x > <home>/data/<id>/report.md; echo y > /tmp/fm-<id>/f` | both written |
| Single-file entry, file absent at launch | `echo s >> <home>/state/<id>.status` | `operation not permitted`, file never created |
| Single-file entry, file pre-created | same | rc=0 |
| Sibling state file | `echo x > <home>/state/other.status` | `operation not permitted` |
| Turn-end hook | Stop hook `touch '<home>/state/<id>.turn-ended'` while the same Bash `touch` is denied | file written: hooks run outside the sandbox |
| Escape hatch, default | Bash call with `dangerouslyDisableSandbox: true` writing outside | rc=0, file written |
| Escape hatch, `allowUnsandboxedCommands: false` | same | `operation not permitted`, rc=1 |
| `gh`, default | `gh api repos/<owner>/<repo> --jq .name` | `tls: failed to verify certificate: x509: OSStatus -26276` |
| `gh` with `enableWeakerNetworkIsolation` | same, and `gh-axi pr list --repo <owner>/<repo>` | repo name printed; PR list returned |
| Write tool, sandbox only | Write tool to `/tmp/<outside>/write-tool.txt` | `File created successfully`: file tools are not sandboxed |
| Write tool, with the guard | the settings `fm-sandbox-settings.sh` generates; Write to `/tmp/<outside>/w.txt` | `fm-sandbox-guard: refusing to write ...`, file absent |
| Write tool inside the boundary, with the guard | Write to `<worktree>/notes.txt` and `<home>/data/<id>/report.md` | both created |
| MCP server the worker launches | a project `.mcp.json` stdio server writing `/tmp/<outside>/` at startup and on a tool call | both files written: MCP servers run outside the sandbox |
| Browser | `chrome-devtools-axi open https://example.org` | `error: Bridge failed to start within 30s`, `code: BRIDGE_NOT_READY` |

The browser fails for two independent reasons, shown by running its parts directly inside the sandbox.
Its default launcher runs `npx`, which needs to write the shared npm cache: `npm error errno EPERM`, and `touch ~/.npm/_npx/<probe>` gives `Operation not permitted`.
Chrome itself then aborts: `sandbox_extension_issue_file_to_process failed ... Operation not permitted`, `bootstrap_check_in org.chromium.crashpad... Permission denied (1100)`, and `Failed to create a ProcessSingleton for your profile directory ... Aborting now`.
Adding `~/.chrome-devtools-axi` to `allowWrite`, `network.allowLocalBinding`, and a task-temp `CHROME_DEVTOOLS_AXI_USER_DATA_DIR` did not change the result.

## What this does not cover

- **No browser for sandboxed scouts.** No narrow setting makes Chrome run inside Seatbelt.
  Exempting the browser tool with `sandbox.excludedCommands` was rejected: its `screenshot <path>` and `heap <path>` write any path and `setup hooks` writes Claude hook configuration, which would reopen the boundary.
  A scout that needs the browser escalates for the captain-present override.
- **MCP servers run outside the sandbox.** A server the worker starts can write anywhere, and the file-tool guard does not judge MCP tools.
  A worker can add one through a `.mcp.json` in its own copy; it loads at the next start, which is one reason every relaunch regenerates the settings file first.
- **The settings file is inside the worker's writable copy.** A worker can edit it, including to add a hook, and hooks run outside the sandbox.
  Claude Code reads it at start, and `bin/fm-sandbox-settings.sh` regenerates it before every relaunch or resume.
- **Writes only.** Reads are unrestricted, and outbound network is not limited; egress control is out of scope.
- **The sandbox's own temp root** (`/tmp/claude-<uid>`, set as `TMPDIR` inside the sandbox) is writable and shared by every Claude session of the same user.
  The guard mirrors it so the file tools may write where shell commands already can.
- **claude scouts on macOS only.** Ship tasks stay unsandboxed until the ship-task spike decides their route, testers are unsandboxed by design, no other harness has a verified mechanism, and the Linux sandbox has not been exercised.
- **The launch environment is a separate boundary**, owned by [`worker-environment.md`](worker-environment.md).
