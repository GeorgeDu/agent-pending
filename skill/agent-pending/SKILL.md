---
name: agent-pending
description: Only when the user explicitly invokes `$agent-pending` or directly asks to use Agent Pending, record exactly one user-owned pending item in the local macOS Agent Pending list. The item may be a task, approval, unfinished action, follow-up, or wish. Never trigger from ordinary discussion of blockers, reviews, reminders, or incomplete work, and never collect items automatically.
---

# Agent Pending

Record one item only after an explicit invocation. The list is external memory for actions that still belong to the human, not a background task collector.

## Record an item

1. Summarize a distinctive title from the current context; do not copy only the directory name.
2. Compress the user's next action into one sentence. Omit background, agent progress, and completed work.
3. Use the actual project root as the absolute workspace path. Fall back to the current working directory only when the project root cannot be determined.
4. Resolve the CLI from `AGENT_PENDING_CLI`, `PATH`, or `~/.local/bin/agent-pending`, in that order.
5. Run one command:

```bash
"${AGENT_PENDING_CLI:-$(command -v agent-pending || printf '%s' "$HOME/.local/bin/agent-pending")}" add \
  --title "<project or item title>" \
  --note "<one action the user still needs to take>" \
  --workspace "<absolute project path>"
```

6. Treat exit code 0 plus a JSON object containing a non-empty `id` as success. If `created` is false, report that the identical item already existed.

Return only one line, matching the user's language (Chinese by default). Use one of these forms:

```text
Chinese: 已记录：<title> — <one next action>
English: Recorded: <title> — <one next action>
```

Do not scan workspace files, scan for other items, infer tasks from the conversation, or add more than the item named in this invocation. The workspace path is location metadata only. This skill adds items; use the CLI directly for archive and restore operations.
