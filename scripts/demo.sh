#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agent-pending-demo.XXXXXX")"
DEMO_DATA="$DEMO_ROOT/data"

cleanup() {
  if [[ -n "${DEMO_PID:-}" ]]; then
    kill "$DEMO_PID" 2>/dev/null || true
    wait "$DEMO_PID" 2>/dev/null || true
  fi
  rm -rf "$DEMO_ROOT"
}
trap cleanup EXIT INT TERM

AGENT_PENDING_BUILD_DIR="$DEMO_ROOT/build" \
AGENT_PENDING_DIST_DIR="$DEMO_ROOT/dist" \
  "$ROOT/scripts/build.sh" >/dev/null

add_demo_item() {
  AGENT_PENDING_DATA_DIR="$DEMO_DATA" /usr/bin/python3 "$ROOT/src/agent_pending_cli.py" add \
    --title "$1" \
    --note "$2" \
    --workspace "$3" >/dev/null
}

add_demo_item "产品发布" "确认发布说明与最终截图" "/Users/demo/product-release"
add_demo_item "网站改版" "审核首页文案和视觉稿" "/Users/demo/website"
add_demo_item "研究报告" "确认结论摘要后生成终稿" "/Users/demo/research-report"
add_demo_item "API 迁移" "决定是否保留旧版兼容层" "/Users/demo/api-migration"

echo "Demo data: $DEMO_DATA"
echo "The popover opens automatically. Press Control-C to stop and delete all demo data."

AGENT_PENDING_DATA_DIR="$DEMO_DATA" \
AGENT_PENDING_LANGUAGE="${AGENT_PENDING_LANGUAGE:-zh}" \
AGENT_PENDING_OPEN_ON_LAUNCH=1 \
  "$DEMO_ROOT/dist/Agent Pending.app/Contents/MacOS/AgentPendingApp" &
DEMO_PID=$!
wait "$DEMO_PID"
