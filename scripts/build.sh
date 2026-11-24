#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

# shellcheck source=lib/app-config.sh
source "${PROJECT_DIR}/scripts/lib/app-config.sh"
# shellcheck source=lib/signing.sh
source "${PROJECT_DIR}/scripts/lib/signing.sh"

CONFIG="release"
SIGN_MODE="adhoc"

for arg in "$@"; do
    case "$arg" in
        --debug)
            CONFIG="debug"
            ;;
        --adhoc)
            SIGN_MODE="adhoc"
            ;;
        --local-signed)
            SIGN_MODE="local"
            ;;
        -h|--help)
            echo "Usage: scripts/build.sh [--debug] [--adhoc | --local-signed]"
            echo "  --debug         Build the debug configuration (faster iteration)."
            echo "  --adhoc         Ad-hoc signature; local-only, never publishable."
            echo "  --local-signed  Sign with the fixed BarFold identity."
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 2
            ;;
    esac
done

VERSION="$(tr -d '[:space:]' < version.txt)"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "❌ version.txt must contain a semantic version (got '${VERSION}')" >&2
    exit 1
fi

RELEASE_DIR="release/${VERSION}"
BUNDLE_DIR="${RELEASE_DIR}/${APP_NAME}.app"

if [ "$SIGN_MODE" = "local" ] && ! barfold_signing_material_available; then
    echo "❌ Signing material missing: ${SIGNING_DIR}/BarFold.p12" >&2
    echo "   Run scripts/setup-signing.sh check, or use --adhoc." >&2
    exit 1
fi

echo "🔨 Building ${APP_NAME} v${VERSION} (${CONFIG})..."
BUILD_TIMESTAMP_UTC="$(barfold_build_timestamp_utc)"
swift build -c "$CONFIG" --arch arm64
BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"

echo "📦 Assembling ${BUNDLE_DIR}..."
mkdir -p "${BUNDLE_DIR}/Contents"
rm -rf "${BUNDLE_DIR}/Contents/MacOS" "${BUNDLE_DIR}/Contents/Helpers" "${BUNDLE_DIR}/Contents/Frameworks"
mkdir -p "${BUNDLE_DIR}/Contents/MacOS" "${BUNDLE_DIR}/Contents/Helpers" "${BUNDLE_DIR}/Contents/Resources"

cp "${BIN_DIR}/BarFold" "${BUNDLE_DIR}/Contents/MacOS/BarFold"
cp "${BIN_DIR}/barfoldctl" "${BUNDLE_DIR}/Contents/Helpers/barfold"
cp version.txt "${BUNDLE_DIR}/Contents/Resources/version.txt"

if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "${BUNDLE_DIR}/Contents/Resources/AppIcon.icns"
else
    echo "⚠️  Resources/AppIcon.icns is missing; the app will use the generic icon."
fi

barfold_embed_sparkle "$BIN_DIR" "$BUNDLE_DIR"

cat > "${BUNDLE_DIR}/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>BarFold</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>BarFoldBuildTimestampUTC</key>
    <string>${BUILD_TIMESTAMP_UTC}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh_CN</string>
        <string>en</string>
    </array>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>SUFeedURL</key>
    <string>${SU_FEED_URL}</string>
    <key>SUPublicEDKey</key>
    <string>${SU_PUBLIC_ED_KEY}</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUAutomaticallyUpdate</key>
    <false/>
    <key>SUScheduledCheckInterval</key>
    <integer>86400</integer>
    <key>SUVerifyUpdateBeforeExtraction</key>
    <true/>
    <key>SURequireSignedFeed</key>
    <true/>
</dict>
</plist>
PLIST

plutil -lint "${BUNDLE_DIR}/Contents/Info.plist" >/dev/null
PLIST_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${BUNDLE_DIR}/Contents/Info.plist")
if [ "$PLIST_VERSION" != "$VERSION" ]; then
    echo "❌ Info.plist version ${PLIST_VERSION} does not match version.txt ${VERSION}" >&2
    exit 1
fi
PLIST_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${BUNDLE_DIR}/Contents/Info.plist")
if [ "$PLIST_BUNDLE_ID" != "$BUNDLE_ID" ]; then
    echo "❌ Info.plist bundle id ${PLIST_BUNDLE_ID} does not match ${BUNDLE_ID}" >&2
    exit 1
fi

echo "🔏 Signing (${SIGN_MODE})..."
if [ "$SIGN_MODE" = "adhoc" ]; then
    barfold_sign_adhoc_app "$BUNDLE_DIR"
else
    echo "   Identity: ${SIGN_IDENTITY}"
    trap barfold_close_signing_keychain EXIT
    barfold_open_signing_keychain
    barfold_sign_app "$BUNDLE_DIR"
fi

ln -sfn "${APP_NAME}.app/Contents/Helpers/barfold" "${RELEASE_DIR}/barfold"
echo "✅ Built ${BUNDLE_DIR}"
echo "   Run: open \"${BUNDLE_DIR}\""
echo "   CLI: \"${RELEASE_DIR}/barfold\""
