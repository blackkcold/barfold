#!/bin/bash
# Shared build and release constants. Sourced by build.sh and release.sh.
# Never executed on its own.

APP_NAME="BarFold"
BUNDLE_ID="com.haoran.BarFold"

# Update this to the real repository before publishing an appcast.
REPO_SLUG="${BARFOLD_REPO_SLUG:-blackkcold/barfold}"

# The fixed signing identity. Its certificate leaf is the app's designated
# requirement, so it must never be regenerated: a new certificate resets every
# TCC grant, notification permission and login-item approval.
SIGN_IDENTITY="${BARFOLD_SIGN_IDENTITY:-BarFold Code Signing}"
SIGNING_DIR="${BARFOLD_SIGNING_DIR:-$HOME/.config/barfold/signing}"

SU_FEED_URL="${BARFOLD_SU_FEED_URL:-https://github.com/${REPO_SLUG}/releases/latest/download/appcast.xml}"
if [ -n "${BARFOLD_SU_PUBLIC_ED_KEY:-}" ]; then
    SU_PUBLIC_ED_KEY="${BARFOLD_SU_PUBLIC_ED_KEY}"
elif [ -f "${SIGNING_DIR}/Sparkle.public-key" ]; then
    SU_PUBLIC_ED_KEY="$(tr -d '[:space:]' < "${SIGNING_DIR}/Sparkle.public-key")"
else
    SU_PUBLIC_ED_KEY=""
fi

barfold_build_timestamp_utc() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}
