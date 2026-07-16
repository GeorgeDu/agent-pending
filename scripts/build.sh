#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${AGENT_PENDING_BUILD_DIR:-$ROOT/build}"
DIST_DIR="${AGENT_PENDING_DIST_DIR:-$ROOT/build/.artifacts}"
APP="$DIST_DIR/Agent Pending.app"
CONTENTS="$APP/Contents"

rm -rf "$APP"
mkdir -p "$BUILD_DIR" "$CONTENTS/MacOS" "$CONTENTS/Resources"

clang -fobjc-arc -Wall -Wextra \
  -framework Cocoa \
  -framework UserNotifications \
  "$ROOT/src/AgentPendingApp.m" \
  -o "$BUILD_DIR/AgentPendingApp"

cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
cp "$BUILD_DIR/AgentPendingApp" "$CONTENTS/MacOS/AgentPendingApp"
chmod +x "$CONTENTS/MacOS/AgentPendingApp"
/usr/bin/codesign --force --deep --sign - "$APP"

echo "$APP"
