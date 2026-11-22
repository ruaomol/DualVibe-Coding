#!/bin/sh
set -eu
set +x
umask 077

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SIGNING_DIR="$PROJECT_DIR/.local-signing"
IDENTITY_DIR="$SIGNING_DIR/identity"
KEYCHAIN_NAME=DualVibeCoding.keychain-db
KEYCHAIN="$IDENTITY_DIR/$KEYCHAIN_NAME"
IDENTITY_NAME='DualVibe Coding Local Code Signing'
if [ ! -f "$KEYCHAIN" ] && [ -f "$IDENTITY_DIR/PS5VibeCoding.keychain-db" ]; then
    KEYCHAIN_NAME=PS5VibeCoding.keychain-db
    KEYCHAIN="$IDENTITY_DIR/$KEYCHAIN_NAME"
    IDENTITY_NAME='PS5 Vibe Coding Local Code Signing'
fi
SETUP_LOCK="$SIGNING_DIR/setup.lock"
SETUP_STAGE=''

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

if [ -L "$SIGNING_DIR" ]; then
    fail "Use a project-local signing directory at $SIGNING_DIR."
fi
mkdir -p "$SIGNING_DIR"
chmod 700 "$SIGNING_DIR"

cleanup_setup() {
    if [ -n "$SETUP_STAGE" ] && [ -d "$SETUP_STAGE" ]; then
        if [ -f "$SETUP_STAGE/$KEYCHAIN_NAME" ]; then
            /usr/bin/security delete-keychain "$SETUP_STAGE/$KEYCHAIN_NAME" >/dev/null 2>&1 || true
        fi
        for credential in private-key.pem certificate.pem identity.p12 password; do
            if [ -f "$SETUP_STAGE/$credential" ]; then
                /bin/rm "$SETUP_STAGE/$credential"
            fi
        done
        rmdir "$SETUP_STAGE" 2>/dev/null || true
    fi
    rmdir "$SETUP_LOCK"
}

if [ ! -d "$IDENTITY_DIR" ]; then
    mkdir "$SETUP_LOCK" 2>/dev/null || fail "Local signing setup is already in progress at $SETUP_LOCK."
    trap cleanup_setup EXIT
    trap 'exit 1' HUP INT TERM
    if [ ! -d "$IDENTITY_DIR" ]; then
        SETUP_STAGE="$(mktemp -d "$SIGNING_DIR/setup.XXXXXX")"
        /usr/bin/openssl rand -hex 32 > "$SETUP_STAGE/password"
        PASSPHRASE="$(cat "$SETUP_STAGE/password")"
        /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 \
            -subj "/CN=$IDENTITY_NAME" -keyout "$SETUP_STAGE/private-key.pem" \
            -out "$SETUP_STAGE/certificate.pem" \
            -addext 'basicConstraints=critical,CA:FALSE' \
            -addext 'keyUsage=critical,digitalSignature' \
            -addext 'extendedKeyUsage=codeSigning'
        /usr/bin/openssl pkcs12 -export -inkey "$SETUP_STAGE/private-key.pem" \
            -in "$SETUP_STAGE/certificate.pem" -out "$SETUP_STAGE/identity.p12" \
            -passout "file:$SETUP_STAGE/password"

        STAGED_KEYCHAIN="$SETUP_STAGE/$KEYCHAIN_NAME"
        /usr/bin/security create-keychain -p "$PASSPHRASE" "$STAGED_KEYCHAIN"
        /usr/bin/security unlock-keychain -p "$PASSPHRASE" "$STAGED_KEYCHAIN"
        /usr/bin/security import "$SETUP_STAGE/identity.p12" -k "$STAGED_KEYCHAIN" \
            -P "$PASSPHRASE" -x -T /usr/bin/codesign >/dev/null
        /usr/bin/security set-key-partition-list -S apple-tool:,apple: -s \
            -k "$PASSPHRASE" "$STAGED_KEYCHAIN" >/dev/null
        /usr/bin/security set-keychain-settings -l -u -t 900 "$STAGED_KEYCHAIN"
        /usr/bin/security lock-keychain "$STAGED_KEYCHAIN"
        /bin/rm "$SETUP_STAGE/private-key.pem" "$SETUP_STAGE/certificate.pem" "$SETUP_STAGE/identity.p12"
        chmod 600 "$STAGED_KEYCHAIN" "$SETUP_STAGE/password"
        mv "$SETUP_STAGE" "$IDENTITY_DIR"
    fi
fi

if [ ! -f "$KEYCHAIN" ] || [ ! -s "$IDENTITY_DIR/password" ]; then
    fail "Local signing credentials are incomplete. Restore $IDENTITY_DIR to keep the existing app identity."
fi

PASSPHRASE="$(cat "$IDENTITY_DIR/password")"
/usr/bin/security unlock-keychain -p "$PASSPHRASE" "$KEYCHAIN"
CERTIFICATE="$(/usr/bin/security find-certificate -c "$IDENTITY_NAME" -p "$KEYCHAIN")"
FINGERPRINT="$(printf '%s\n' "$CERTIFICATE" | /usr/bin/openssl x509 -noout -sha1 -fingerprint)"
FINGERPRINT="$(printf '%s' "${FINGERPRINT#*=}" | tr -d ':' | tr '[:lower:]' '[:upper:]')"
if [ "${#FINGERPRINT}" -ne 40 ]; then
    fail "Could not read the local signing certificate SHA-1 fingerprint."
fi
IDENTITIES="$(/usr/bin/security find-identity -p codesigning "$KEYCHAIN")"
case "$IDENTITIES" in
    *"$FINGERPRINT"*) printf '%s\n' "$FINGERPRINT" ;;
    *) fail "The local signing certificate has no corresponding private key in $KEYCHAIN." ;;
esac
