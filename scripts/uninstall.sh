#!/usr/bin/env bash

set -euo pipefail

APP_DIR="${AGENT_PENDING_APP_DIR:-$HOME/Applications}"
CLI_DIR="${AGENT_PENDING_CLI_DIR:-$HOME/.local/bin}"
SHARED_SKILLS_DIR="${AGENT_SKILLS_HOME:-$HOME/.agents/skills}"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/io.github.georgedu.agent-pending.plist"
LABEL="io.github.georgedu.agent-pending"
DOMAIN="gui/$(id -u)"
DATA_DIR="${AGENT_PENDING_DATA_DIR:-$HOME/Library/Application Support/Agent Pending}"

if [[ "${AGENT_PENDING_SKIP_LAUNCH:-0}" != "1" ]]; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
fi
rm -f "$LAUNCH_AGENT" "$CLI_DIR/agent-pending"
rm -f "$HOME/.codex/skills/agent-pending" "$HOME/.claude/skills/agent-pending"
rm -rf "$APP_DIR/Agent Pending.app" "$SHARED_SKILLS_DIR/agent-pending"

if [[ "${1:-}" == "--purge-data" ]]; then
  rm -rf "$DATA_DIR"
  echo "Removed app, CLI, skill, and data."
else
  echo "Removed app, CLI, and skill. Data preserved at: $DATA_DIR"
fi
