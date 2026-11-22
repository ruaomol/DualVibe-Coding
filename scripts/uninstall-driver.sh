#!/bin/zsh
set -euo pipefail

TARGET_DRIVER="/Library/Audio/Plug-Ins/HAL/DualSenseBridgeMic.driver"

if [[ -e "$TARGET_DRIVER" ]]; then
  /bin/rm -rf -- "$TARGET_DRIVER"
  /usr/bin/killall coreaudiod 2>/dev/null || true
  print -r -- "DualSense Bridge Mic removed"
else
  print -r -- "DualSense Bridge Mic is not installed"
fi
