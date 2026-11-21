#!/bin/sh
set -eu

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$PROJECT_DIR"
APP_NAME='DualVibe Coding.app'
APP_DIR="$PROJECT_DIR/$APP_NAME"
SIGNING_IDENTITY=${PS5VIBE_SIGNING_IDENTITY:-}
OPUS_DYLIB=${OPUS_PREFIX:+$OPUS_PREFIX/lib/libopus.0.dylib}

if [ -z "$OPUS_DYLIB" ]; then
    for prefix in /opt/homebrew/opt/opus /usr/local/opt/opus; do
        if [ -f "$prefix/lib/libopus.0.dylib" ]; then
            OPUS_DYLIB="$prefix/lib/libopus.0.dylib"
            break
        fi
    done
fi
if [ ! -f "$OPUS_DYLIB" ]; then
    printf '%s\n' 'A matching libopus.0.dylib is required. Install Opus or set OPUS_PREFIX.' >&2
    exit 1
fi

swift build -c release
PRODUCTS="$(swift build -c release --show-bin-path)"
for arch in $(lipo -archs "$PRODUCTS/PS5VibeCoding"); do
    lipo -verify_arch "$arch" "$OPUS_DYLIB"
done

"$PROJECT_DIR/scripts/build-agent-remote-mic-driver.sh"
STAGING="$(mktemp -d "$PROJECT_DIR/.build/ps5vibe-app.XXXXXX")"
trap ' /bin/rm -rf "$STAGING" ' EXIT
STAGED_APP="$STAGING/$APP_NAME"
CONTENTS="$STAGED_APP/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks" "$CONTENTS/PlugIns"
cp "$PRODUCTS/PS5VibeCoding" "$CONTENTS/MacOS/PS5VibeCoding"
cp "$PROJECT_DIR/AppBundle-template/Contents/Info.plist" "$CONTENTS/Info.plist"
cp "$PROJECT_DIR/AppBundle-template/Contents/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
RESOURCE_BUNDLE="$PRODUCTS/DualVibeCoding_PS5VibeCodingApp.bundle"
if [ ! -d "$RESOURCE_BUNDLE" ]; then
    RESOURCE_BUNDLE="$PRODUCTS/PS5VibeCoding_PS5VibeCodingApp.bundle"
fi
if [ -d "$RESOURCE_BUNDLE" ]; then
    ditto "$RESOURCE_BUNDLE" "$CONTENTS/Resources/$(basename "$RESOURCE_BUNDLE")"
fi

cp -L "$OPUS_DYLIB" "$CONTENTS/Frameworks/libopus.0.dylib"
ditto "$PROJECT_DIR/.build/agent-remote-driver/DualSenseBridgeMic.driver" "$CONTENTS/PlugIns/DualSenseBridgeMic.driver"
cp "$PROJECT_DIR/scripts/install-driver.sh" "$CONTENTS/Resources/install-driver.sh"
cp "$PROJECT_DIR/ThirdParty/AgentRemote/LICENSE" "$CONTENTS/Resources/AgentRemote-LICENSE.txt"
cp "$PROJECT_DIR/ThirdParty/AgentRemote/Driver/LICENSE-APPLE.txt" "$CONTENTS/Resources/AudioDriver-APPLE-LICENSE.txt"
cp "$PROJECT_DIR/ThirdParty/AgentRemote/Licenses/Opus.txt" "$CONTENTS/Resources/Opus-LICENSE.txt"
cp "$PROJECT_DIR/ThirdParty/AgentRemote/Licenses/Sonic.txt" "$CONTENTS/Resources/Sonic-APACHE-LICENSE.txt"
cp "$PROJECT_DIR/ThirdParty/AgentRemote/THIRD_PARTY_NOTICES.md" "$CONTENTS/Resources/THIRD-PARTY-NOTICES.md"
chmod 755 "$CONTENTS/Resources/install-driver.sh" "$CONTENTS/MacOS/PS5VibeCoding"

if [ "$SIGNING_IDENTITY" = - ]; then
    printf '%s\n' 'PS5VIBE_SIGNING_IDENTITY must name a persistent code-signing identity.' >&2
    exit 1
fi
if [ -n "$SIGNING_IDENTITY" ]; then
    /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
        "$CONTENTS/Frameworks/libopus.0.dylib" "$CONTENTS/PlugIns/DualSenseBridgeMic.driver"
    /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" "$STAGED_APP"
else
    SIGNING_IDENTITY="$(/bin/sh "$PROJECT_DIR/scripts/setup-local-signing.sh")"
    KEYCHAIN="$PROJECT_DIR/.local-signing/identity/PS5VibeCoding.keychain-db"
    BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$CONTENTS/Info.plist")"
    REQUIREMENT="identifier \"$BUNDLE_ID\" and certificate leaf = H\"$SIGNING_IDENTITY\""
    /usr/bin/codesign --force --timestamp=none --keychain "$KEYCHAIN" --sign "$SIGNING_IDENTITY" \
        "$CONTENTS/Frameworks/libopus.0.dylib" "$CONTENTS/PlugIns/DualSenseBridgeMic.driver"
    /usr/bin/codesign --force --timestamp=none --keychain "$KEYCHAIN" --sign "$SIGNING_IDENTITY" \
        --requirements "=designated => $REQUIREMENT" "$STAGED_APP"
    /usr/bin/codesign --verify --strict --test-requirement "=$REQUIREMENT" "$STAGED_APP"
fi
codesign --verify --deep --strict "$STAGED_APP"
plutil -lint "$CONTENTS/Info.plist"

if [ -e "$APP_DIR" ]; then
    mv "$APP_DIR" "$STAGING/Previous.app"
fi
if ! mv "$STAGED_APP" "$APP_DIR"; then
    if [ -e "$STAGING/Previous.app" ]; then
        mv "$STAGING/Previous.app" "$APP_DIR"
    fi
    exit 1
fi
printf 'Built %s\n' "$APP_DIR"
