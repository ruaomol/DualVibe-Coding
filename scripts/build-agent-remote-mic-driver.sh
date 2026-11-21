#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="${0:A:h:h}"
BUILD_ROOT="$PROJECT_ROOT/.build/agent-remote-driver"
DRIVER_PATH="$BUILD_ROOT/DualSenseBridgeMic.driver"
CONTENTS_PATH="$DRIVER_PATH/Contents"
MACOS_PATH="$CONTENTS_PATH/MacOS"
mkdir -p "$MACOS_PATH"
cp "$PROJECT_ROOT/ThirdParty/AgentRemote/Driver/Info.plist" "$CONTENTS_PATH/Info.plist"
xcrun clang \
  -bundle \
  -arch arm64 \
  -arch x86_64 \
  -mmacosx-version-min=13.0 \
  -O2 -Wall -Wextra \
  -framework CoreAudio -framework CoreFoundation \
  "$PROJECT_ROOT/ThirdParty/AgentRemote/Driver/DualSenseBridgeMic.c" \
  -o "$MACOS_PATH/DualSenseBridgeMic"
chmod 755 "$MACOS_PATH/DualSenseBridgeMic"
plutil -lint "$CONTENTS_PATH/Info.plist"
printf '%s\n' "$DRIVER_PATH"
