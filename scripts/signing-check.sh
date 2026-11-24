#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

# shellcheck source=lib/app-config.sh
source "${PROJECT_DIR}/scripts/lib/app-config.sh"

VERSION="$(tr -d '[:space:]' < version.txt)"
APP="${PROJECT_DIR}/release/${VERSION}/${APP_NAME}.app"
EXPECT_ADHOC=0
for arg in "$@"; do
    case "$arg" in
        --adhoc) EXPECT_ADHOC=1 ;;
        -h|--help)
            echo "Usage: scripts/signing-check.sh [--adhoc] [path/to/BarFold.app]"
            exit 0
            ;;
        *)
            APP="$arg"
            ;;
    esac
done

if [ ! -d "$APP" ]; then
    echo "❌ App bundle not found: $APP" >&2
    exit 1
fi

echo "🔎 Checking $APP"
INFO="$(codesign -dv --verbose=4 "$APP" 2>&1 || true)"

if [ "$EXPECT_ADHOC" -eq 1 ]; then
    if ! printf '%s' "$INFO" | grep -q "Signature=adhoc"; then
        echo "❌ Expected an ad-hoc signature." >&2
        exit 1
    fi
    echo "   signature: ad-hoc (development build)"
else
    if printf '%s' "$INFO" | grep -q "Signature=adhoc"; then
        echo "❌ App is ad-hoc signed; a release build must use '${SIGN_IDENTITY}'." >&2
        exit 1
    fi
    AUTHORITY="$(printf '%s\n' "$INFO" | sed -n 's/^Authority=//p' | head -1)"
    if [ "$AUTHORITY" != "$SIGN_IDENTITY" ]; then
        echo "❌ Authority is '${AUTHORITY:-unknown}', expected '${SIGN_IDENTITY}'." >&2
        exit 1
    fi
    echo "   identity: $AUTHORITY"
fi

BUNDLE_ID_VALUE="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${APP}/Contents/Info.plist" 2>/dev/null || true)"
if [ "$BUNDLE_ID_VALUE" != "$BUNDLE_ID" ]; then
    echo "❌ Bundle id is '${BUNDLE_ID_VALUE:-unknown}', expected '${BUNDLE_ID}'." >&2
    exit 1
fi
echo "   bundle id: $BUNDLE_ID_VALUE"

if [ ! -x "${APP}/Contents/Helpers/barfold" ]; then
    echo "❌ CLI helper missing: ${APP}/Contents/Helpers/barfold" >&2
    exit 1
fi
echo "   CLI: Contents/Helpers/barfold"

if [ -d "${APP}/Contents/Frameworks/Sparkle.framework" ]; then
    echo "   Sparkle: embedded"
else
    echo "   Sparkle: not embedded"
fi

PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "${APP}/Contents/Info.plist" 2>/dev/null || true)"
if [ -z "$PUBLIC_KEY" ]; then
    if [ "$EXPECT_ADHOC" -eq 1 ]; then
        echo "⚠️  SUPublicEDKey is empty; update checks are disabled in this development build."
    else
        echo "❌ SUPublicEDKey is empty; a release build cannot verify updates." >&2
        exit 1
    fi
else
    echo "   Sparkle EdDSA public key: present"
fi

codesign --verify --deep --strict "$APP"
echo "✅ Signature checks passed."
