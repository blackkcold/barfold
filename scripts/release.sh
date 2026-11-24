#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

# shellcheck source=lib/app-config.sh
source "${PROJECT_DIR}/scripts/lib/app-config.sh"
# shellcheck source=lib/signing.sh
source "${PROJECT_DIR}/scripts/lib/signing.sh"

MODE="signed"
for arg in "$@"; do
    case "$arg" in
        --adhoc) MODE="adhoc" ;;
        --signed) MODE="signed" ;;
        -h|--help)
            echo "Usage: scripts/release.sh [--adhoc | --signed]"
            echo "  --adhoc   Build a development zip only (no appcast)."
            echo "  --signed  Fixed-identity build + zip + EdDSA appcast."
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 2
            ;;
    esac
done

VERSION="$(tr -d '[:space:]' < version.txt)"
RELEASE_DIR="release/${VERSION}"
APP="${RELEASE_DIR}/${APP_NAME}.app"
ZIP="${RELEASE_DIR}/${APP_NAME}-${VERSION}.zip"
NOTES="${RELEASE_DIR}/${APP_NAME}-${VERSION}.md"

if [ "$MODE" = "signed" ]; then
    if ! barfold_signing_material_available 2>/dev/null; then
        # signing.sh is sourced by build.sh; check the files directly here too.
        if [ ! -f "${SIGNING_DIR}/BarFold.p12" ] || [ ! -f "${SIGNING_DIR}/BarFold.p12.password" ]; then
            echo "❌ Signed release needs ${SIGNING_DIR}/BarFold.p12 and its password." >&2
            echo "   Run scripts/setup-signing.sh check; use --adhoc for a dev zip." >&2
            exit 1
        fi
    fi
    if [ ! -f "${SIGNING_DIR}/Sparkle.edseed" ]; then
        echo "❌ Sparkle EdDSA seed missing: ${SIGNING_DIR}/Sparkle.edseed" >&2
        exit 1
    fi
    scripts/build.sh --local-signed
else
    scripts/build.sh --adhoc
fi

mkdir -p "$RELEASE_DIR"
rm -f "$ZIP" "$ZIP.sha256" "${RELEASE_DIR}/appcast.xml"

echo "🗜  Creating ${ZIP}..."
ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"

if [ "$MODE" = "adhoc" ]; then
    echo "✅ Development zip: ${ZIP}"
    echo "   No appcast was generated because this build is not fixed-identity signed."
    exit 0
fi

GENERATE_APPCAST="$(find .build -type f -name generate_appcast -perm +111 2>/dev/null | head -1)"
if [ -z "$GENERATE_APPCAST" ]; then
    echo "❌ generate_appcast not found under .build." >&2
    echo "   Resolve Sparkle first: swift package resolve" >&2
    exit 1
fi

if [ ! -f "$NOTES" ]; then
    {
        echo "# BarFold ${VERSION}"
        echo
        sed -n '1,80p' CHANGELOG.md 2>/dev/null || echo "Release ${VERSION}"
    } > "$NOTES"
fi

echo "📝 Generating EdDSA appcast..."
"$GENERATE_APPCAST" \
    --ed-key-file "${SIGNING_DIR}/Sparkle.edseed" \
    --download-url-prefix "https://github.com/${REPO_SLUG}/releases/download/v${VERSION}/" \
    --maximum-versions 1 \
    --maximum-deltas 2 \
    --embed-release-notes \
    "$RELEASE_DIR"

if [ ! -f "${RELEASE_DIR}/appcast.xml" ]; then
    echo "❌ appcast.xml was not produced." >&2
    exit 1
fi

echo "✅ Release artifacts:"
ls -lh "$ZIP" "${RELEASE_DIR}/appcast.xml" "$NOTES"
echo
echo "Publish (after reviewing the files):"
echo "  gh release create v${VERSION} \"$ZIP\" \"${RELEASE_DIR}/appcast.xml\" \\"
echo "    --title \"BarFold ${VERSION}\" --notes-file \"$NOTES\""
echo
echo "Feed: ${SU_FEED_URL}"
