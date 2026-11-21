#!/bin/sh
set -eu

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$PROJECT_DIR"
APP_NAME='DualVibe Coding.app'

"$PROJECT_DIR/scripts/build-app.sh"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_NAME/Contents/Info.plist")"
DIST="$PROJECT_DIR/dist"
STAGING="$(mktemp -d "$PROJECT_DIR/.build/dmg.XXXXXX")"
trap ' /bin/rm -rf "$STAGING" ' EXIT
mkdir -p "$DIST" "$STAGING/DualVibe Coding"
ditto "$PROJECT_DIR/$APP_NAME" "$STAGING/DualVibe Coding/$APP_NAME"
ln -s /Applications "$STAGING/DualVibe Coding/Applications"
DMG="$DIST/DualVibe-Coding-$VERSION.dmg"
hdiutil create -volname "DualVibe Coding" -srcfolder "$STAGING/DualVibe Coding" -ov -format UDZO "$DMG"
printf 'Created %s\n' "$DMG"
