# Agent Pending

<p align="center">
  <img src="Resources/AppIcon.png" width="144" alt="Agent Pending icon">
</p>

<p align="center">
  A minimal “still needs me” list for AI-agent workflows on macOS.<br>
  <a href="README.md">简体中文</a>
</p>

<p align="center">
  <img src="docs/images/agent-pending-zh.png" width="420" alt="Agent Pending running in Chinese">
</p>

Agent Pending collects human next actions scattered across terminals, repositories, and conversations into one local menu-bar list. An item may be an approval, an unfinished task, a follow-up, or a wish. The common property is that it still belongs to you and the agent cannot complete it autonomously.

It is not a project manager, and it never discovers tasks automatically. An agent adds an item only when you explicitly invoke `$agent-pending` or directly ask it to use Agent Pending.

## Features

- A persistent menu-bar count; left-click to open or close the compact list.
- Each row shows a title, one next action, importance, the workspace name, and capture time. Copy the full workspace path with one click.
- Drag cards to change processing order. High, Medium, and Low indicate importance only and never reorder items automatically.
- Edit the title, pending action, importance, and workspace in the app, or complete the item and move it to the archive.
- Native macOS materials, system typography, and dynamic system colors adapt to light and dark appearances.
- Add, list, reorder, change importance, archive, and restore through the CLI. Identical additions are idempotent by default.
- One macOS notification when the app detects a new item.
- Chinese and English UI. Chinese is the default; switch language from the right-click menu.
- Local-only data, login startup, and an explicit Quit action.

“Reminder” here means the always-visible menu-bar count and a notification for a newly captured item. It does not mean due dates or recurring alerts. The scrollable list has no 10- or 20-item hard cap, but it is intentionally designed as a short, actionable human queue.

## Install

Requires macOS 13 or later and Xcode Command Line Tools.

```bash
git clone https://github.com/GeorgeDu/agent-pending.git
cd agent-pending
./scripts/install.sh
```

The installer does not require `sudo`. Default locations:

- App: `~/Applications/Agent Pending.app`
- CLI: `~/.local/bin/agent-pending`
- Shared skill source: an existing `~/agent-skills/09-agent-ops` catalog, otherwise `~/.agents/skills/agent-pending`
- Data: `~/Library/Application Support/Agent Pending/store.json`

Set `AGENT_SKILLS_HOME` to choose another skill root. The installer creates skill links for Codex and Claude Code and registers the app to start at login. If you quit the app, it stays closed for the current login session; reopen it from `~/Applications/Agent Pending.app`.

## Use

### Ask an agent to capture an item

Invocation must be explicit:

```text
$agent-pending Record that I need to approve the final release copy.
```

Each invocation writes exactly one item. The skill summarizes a title and one next action from context and records the current project root. It does not scan project files or search for other incomplete work.

### Work from the menu bar

- Left-click the icon: open or close the list.
- Drag a card to change processing order, or right-click it to move it to the top, up, or down.
- Pencil: edit the title and next action.
- Checkmark: complete and archive.
- Right-click the icon: show the list, switch language, restart, or quit.

The archive is currently available through the CLI, not in the GUI.

### Use the CLI directly

```bash
agent-pending add \
  --title "Release review" \
  --note "Approve the final copy before publishing" \
  --workspace "$PWD"

agent-pending list --json
agent-pending priority <item-id> high
agent-pending move <item-id> --top
agent-pending complete <item-id>
agent-pending archive --json
agent-pending restore <item-id>
```

## How it works

```text
You explicitly invoke the skill
            ↓
The agent sends one item to the local CLI
            ↓
The CLI atomically updates local JSON
            ↓
The menu-bar app refreshes its count, list, and one-time notification
```

An item stores a title, next action, workspace path, time, processing position, and importance. Position answers what to do first; importance is a separate decision cue. The path is location metadata only; neither the app nor the skill reads workspace contents because of it.

## Deliberate non-features

Agent Pending v0.2 intentionally excludes:

- Automatic discovery, capture, or background task scanning
- Multi-level tags, project hierarchies, due dates, and recurring reminders
- Cloud sync, accounts, team permissions, and collaborative boards
- GUI archive history

If this becomes another complex project-management system, it has missed its purpose.

## Privacy

The app reads and writes only its local data directory. Titles and next actions may appear in macOS notifications; notification previews can be disabled in System Settings. The repository never stores user data, and runtime JSON, lock files, and build output are ignored by Git.

## Simulate a running app and take a screenshot

The repository includes a fully isolated demo. It builds into a temporary directory, writes four fictional items, and opens the popover without reading or changing production data:

```bash
./scripts/demo.sh
```

Press `Control-C` to stop the app and delete all demo data. To preview English:

```bash
AGENT_PENDING_LANGUAGE=en ./scripts/demo.sh
```

On macOS, press `Shift-Command-4`, then Space, and select the popover. Confirm that the image contains demo items only before committing it.

To center the popover on the Retina main display for a high-resolution documentation screenshot:

```bash
AGENT_PENDING_SCREENSHOT_MODE=1 ./scripts/demo.sh
```

## Build and test

```bash
/usr/bin/python3 tests/test_agent_pending.py
/usr/bin/python3 tests/test_public_repo.py
./scripts/build.sh
```

The v0.2 source release is compiled and ad-hoc signed locally. The repository does not yet ship an Apple-notarized binary.

## Uninstall

```bash
./scripts/uninstall.sh
```

Data is preserved by default. To remove it too:

```bash
./scripts/uninstall.sh --purge-data
```

## License

[MIT](LICENSE)
