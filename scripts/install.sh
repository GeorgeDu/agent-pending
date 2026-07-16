#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${AGENT_PENDING_APP_DIR:-$HOME/Applications}"
APP_PATH="$APP_DIR/Agent Pending.app"
CLI_DIR="${AGENT_PENDING_CLI_DIR:-$HOME/.local/bin}"
CLI_PATH="$CLI_DIR/agent-pending"
if [[ -n "${AGENT_SKILLS_HOME:-}" ]]; then
  SHARED_SKILLS_DIR="$AGENT_SKILLS_HOME"
elif [[ -d "$HOME/agent-skills/09-agent-ops" ]]; then
  SHARED_SKILLS_DIR="$HOME/agent-skills/09-agent-ops"
else
  SHARED_SKILLS_DIR="$HOME/.agents/skills"
fi
SHARED_SKILL="$SHARED_SKILLS_DIR/agent-pending"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENT="$LAUNCH_AGENTS_DIR/io.github.georgedu.agent-pending.plist"
LABEL="io.github.georgedu.agent-pending"
DOMAIN="gui/$(id -u)"

/usr/bin/python3 "$ROOT/tests/test_agent_pending.py"
BUILT_APP="$("$ROOT/scripts/build.sh")"

mkdir -p "$APP_DIR" "$CLI_DIR" "$SHARED_SKILLS_DIR" "$LAUNCH_AGENTS_DIR"
/usr/bin/ditto "$BUILT_APP" "$APP_PATH"
/usr/bin/install -m 755 "$ROOT/src/agent_pending_cli.py" "$CLI_PATH"
/usr/bin/ditto "$ROOT/skill/agent-pending" "$SHARED_SKILL"

for client_dir in "$HOME/.codex/skills" "$HOME/.claude/skills"; do
  mkdir -p "$client_dir"
  client_skill="$client_dir/agent-pending"
  if [[ "$client_skill" == "$SHARED_SKILL" ]]; then
    continue
  fi
  if [[ -e "$client_skill" && ! -L "$client_skill" ]]; then
    rm -rf "$client_skill"
  fi
  ln -sfn "$SHARED_SKILL" "$client_skill"
done

escaped_app_path="$(printf '%s' "$APP_PATH" | sed 's/[&|]/\\&/g')"
sed "s|__APP_PATH__|$escaped_app_path|g" \
  "$ROOT/Resources/io.github.georgedu.agent-pending.plist.in" > "$LAUNCH_AGENT"

"$CLI_PATH" list >/dev/null
if [[ "${AGENT_PENDING_SKIP_LAUNCH:-0}" != "1" ]]; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  launchctl bootstrap "$DOMAIN" "$LAUNCH_AGENT"
  /usr/bin/open -g "$APP_PATH"
fi

echo "App: $APP_PATH"
echo "CLI: $CLI_PATH"
echo "Skill: $SHARED_SKILL"
