# Agent Pending

<p align="center">
  <img src="Resources/AppIcon.png" width="160" alt="Agent Pending icon">
</p>

A minimal, local-first macOS list for the things a human still needs to do while working with AI agents.

Agent Pending is not another project manager. It is a small human-attention queue shared across agent workspaces. An item can be an approval, an unfinished task, a follow-up, or a wish. The common property is simple: the agent cannot finish it for you, and you do not want it to disappear inside an old conversation.

中文定位：它不是复杂任务管理器，而是你面对多个 Agent 时统一查看“接下来仍需我处理什么”的极简清单。

## Why it exists

1. Agent work is distributed across terminals, repositories, and conversations; human obligations need one visible place.
2. The meaningful unit is not an agent run but the human's next action: what to do, why, and in which workspace.
3. External memory prevents completed agent work from hiding an unresolved human step.
4. Explicit capture avoids the opposite failure: an automatically generated backlog that becomes another burden.
5. Local storage keeps project names and review notes on the Mac instead of introducing another hosted service.

## Principles

- **Explicit only:** an agent records an item only when the user invokes `$agent-pending` or directly asks to use Agent Pending.
- **One invocation, one item:** no scanning or background collection.
- **Small record:** title, one next action, workspace, and timestamp.
- **Local first:** data stays in `~/Library/Application Support/Agent Pending/`.
- **Reversible completion:** completed items are archived and can be restored.

## Requirements

- macOS 13 or later
- Xcode Command Line Tools (`xcode-select --install`)
- Python 3 included with macOS

## Install

```bash
git clone https://github.com/GeorgeDu/agent-pending.git
cd agent-pending
./scripts/install.sh
```

The installer uses user-owned locations and does not require `sudo`:

- App: `~/Applications/Agent Pending.app`
- CLI: `~/.local/bin/agent-pending`
- Shared skill source: `~/.agents/skills/agent-pending`
- Data: `~/Library/Application Support/Agent Pending/store.json`

It also creates skill links for Codex and Claude Code when their skill directories are available.

## Use

Invoke the skill explicitly:

```text
$agent-pending Record that I need to approve the release copy for this workspace.
```

Or use the CLI directly:

```bash
agent-pending add \
  --title "Release copy review" \
  --note "Approve the final copy before publishing" \
  --workspace "$PWD"

agent-pending list --json
agent-pending complete <item-id>
agent-pending archive --json
agent-pending restore <item-id>
```

Repeated identical `add` calls are idempotent by default. Pass `--allow-duplicate` only when two identical-looking items are intentional.

## Privacy

The app reads and writes only its local data directory. Titles and notes may appear in macOS notifications; notification previews can be disabled in System Settings. The repository never stores user data, and `data/`, `store.json`, and build output are ignored by Git.

## Build and test

```bash
/usr/bin/python3 tests/test_agent_pending.py
./scripts/build.sh
```

This v0.1 source release builds and ad-hoc signs the app locally. It is not distributed as a notarized binary.

## Uninstall

```bash
./scripts/uninstall.sh
```

Data is preserved by default. To remove it as well:

```bash
./scripts/uninstall.sh --purge-data
```

## Scope

Agent Pending intentionally does not include projects, tags, priorities, due dates, cloud sync, team permissions, or automatic task discovery. If the list becomes a project-management system, it has missed its purpose.

## License

[MIT](LICENSE)
