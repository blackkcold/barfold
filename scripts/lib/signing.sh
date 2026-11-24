#!/bin/bash
# Code-signing helpers shared by build.sh and release.sh.
#
# The fixed identity lives in a throwaway keychain built from the exported .p12
# for the duration of one build. Nothing is installed into the login keychain,
# so a build never triggers a keychain password prompt and never leaves a
# private key behind.

BARFOLD_KEYCHAIN=""
BARFOLD_KEYCHAIN_PASSWORD=""
BARFOLD_ORIGINAL_KEYCHAINS=()

barfold_signing_material_available() {
    [ -f "${SIGNING_DIR}/BarFold.p12" ] && [ -f "${SIGNING_DIR}/BarFold.p12.password" ]
}

# `security list-keychains` prints one indented, quoted path per line.
barfold_capture_keychains() {
    BARFOLD_ORIGINAL_KEYCHAINS=()
    local line
    while IFS= read -r line; do
        line="$(printf '%s' "$line" | tr -d '"' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -n "$line" ] && BARFOLD_ORIGINAL_KEYCHAINS+=("$line")
    done < <(security list-keychains -d user)
}

barfold_open_signing_keychain() {
    if ! barfold_signing_material_available; then
        echo "❌ Signing material missing: ${SIGNING_DIR}/BarFold.p12" >&2
        echo "   Create it with scripts/setup-signing.sh, or use --adhoc." >&2
        return 1
    fi

    local workdir
    workdir="$(mktemp -d "${TMPDIR:-/tmp}/barfold-sign.XXXXXX")"
    BARFOLD_KEYCHAIN="${workdir}/barfold-sign.keychain-db"
    BARFOLD_KEYCHAIN_PASSWORD="$(openssl rand -hex 24)"

    security create-keychain -p "$BARFOLD_KEYCHAIN_PASSWORD" "$BARFOLD_KEYCHAIN" >/dev/null
    security set-keychain-settings -lut 600 "$BARFOLD_KEYCHAIN"
    security unlock-keychain -p "$BARFOLD_KEYCHAIN_PASSWORD" "$BARFOLD_KEYCHAIN" >/dev/null
    security import "${SIGNING_DIR}/BarFold.p12" \
        -k "$BARFOLD_KEYCHAIN" \
        -P "$(cat "${SIGNING_DIR}/BarFold.p12.password")" \
        -T /usr/bin/codesign -T /usr/bin/security >/dev/null
    # Without the partition list codesign cannot use the key non-interactively.
    security set-key-partition-list \
        -S apple-tool:,apple: \
        -s -k "$BARFOLD_KEYCHAIN_PASSWORD" "$BARFOLD_KEYCHAIN" >/dev/null

    barfold_capture_keychains
    security list-keychains -d user -s "$BARFOLD_KEYCHAIN" "${BARFOLD_ORIGINAL_KEYCHAINS[@]}"
}

barfold_close_signing_keychain() {
    if [ ${#BARFOLD_ORIGINAL_KEYCHAINS[@]} -gt 0 ]; then
        security list-keychains -d user -s "${BARFOLD_ORIGINAL_KEYCHAINS[@]}" || true
    fi
    if [ -n "$BARFOLD_KEYCHAIN" ] && [ -e "$BARFOLD_KEYCHAIN" ]; then
        security delete-keychain "$BARFOLD_KEYCHAIN" 2>/dev/null || true
    fi
    BARFOLD_KEYCHAIN=""
    BARFOLD_KEYCHAIN_PASSWORD=""
}

barfold_assert_signed() {
    local target="$1"
    local info authority bundle_id
    info="$(codesign -dv --verbose=4 "$target" 2>&1 || true)"

    if printf '%s' "$info" | grep -q "Signature=adhoc"; then
        echo "❌ ${target} is ad-hoc signed; the fixed identity was not applied." >&2
        return 1
    fi

    authority="$(printf '%s\n' "$info" | sed -n 's/^Authority=//p' | head -1)"
    if [ "$authority" != "$SIGN_IDENTITY" ]; then
        echo "❌ ${target} is signed by '${authority:-unknown}', expected '${SIGN_IDENTITY}'." >&2
        return 1
    fi

    bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${target}/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$bundle_id" != "$BUNDLE_ID" ]; then
        echo "❌ ${target} has bundle id '${bundle_id:-unknown}', expected '${BUNDLE_ID}'." >&2
        return 1
    fi

    codesign --verify --deep --strict "$target"
}

# Sparkle ships nested code: two XPC services, an installer app and a bare
# helper. Signing the framework before its nested code, or the app before the
# framework, leaves a seal that no longer matches the bytes on disk.
barfold_sign_nested_code() {
    local app="$1"
    local sign="$2"
    local framework="${app}/Contents/Frameworks/Sparkle.framework"
    local version_dir="${framework}/Versions/B"

    if [ -d "$version_dir" ]; then
        local nested
        for nested in \
            "${version_dir}/XPCServices/Downloader.xpc" \
            "${version_dir}/XPCServices/Installer.xpc" \
            "${version_dir}/Updater.app" \
            "${version_dir}/Autoupdate"; do
            [ -e "$nested" ] || continue
            codesign --force --sign "$sign" "$nested"
        done
        codesign --force --sign "$sign" "$framework"
    fi
}

barfold_sign_app() {
    local app="$1"
    barfold_sign_nested_code "$app" "$SIGN_IDENTITY"

    if [ -f "${app}/Contents/Helpers/barfold" ]; then
        codesign --force --sign "$SIGN_IDENTITY" "${app}/Contents/Helpers/barfold"
    fi

    codesign --force --sign "$SIGN_IDENTITY" "$app"
    barfold_assert_signed "$app"
}

barfold_sign_adhoc_app() {
    local app="$1"
    barfold_sign_nested_code "$app" "-"

    if [ -f "${app}/Contents/Helpers/barfold" ]; then
        codesign --force --sign - "${app}/Contents/Helpers/barfold"
    fi

    codesign --force --sign - "$app"
    codesign --verify --deep --strict "$app"
}

# Copies Sparkle into Contents/Frameworks with ditto so the framework's
# Versions/Current symlinks survive, then adds the rpath the bundle needs.
barfold_embed_sparkle() {
    local bin_dir="$1"
    local app="$2"
    local framework="${bin_dir}/Sparkle.framework"

    if [ ! -d "$framework" ]; then
        echo "⚠️  Sparkle.framework not found in ${bin_dir}; update checks will be disabled." >&2
        return 0
    fi

    mkdir -p "${app}/Contents/Frameworks"
    ditto "$framework" "${app}/Contents/Frameworks/Sparkle.framework"
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "${app}/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
    if [ -f "${app}/Contents/Helpers/barfold" ]; then
        install_name_tool -add_rpath "@executable_path/../Frameworks" \
            "${app}/Contents/Helpers/barfold" 2>/dev/null || true
    fi
}
