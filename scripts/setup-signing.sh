#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

# shellcheck source=lib/app-config.sh
source "${PROJECT_DIR}/scripts/lib/app-config.sh"

MODE="${1:-check}"

usage() {
    echo "Usage: scripts/setup-signing.sh check"
    echo "       BARFOLD_CONFIRM_SIGNING=1 scripts/setup-signing.sh apply"
    echo
    echo "check  Inspect prerequisites and existing material; never writes secrets."
    echo "apply  Create the fixed identity, p12 password, and Sparkle EdDSA seed."
    echo "       apply refuses to run without BARFOLD_CONFIRM_SIGNING=1."
}

if [ "$MODE" = "-h" ] || [ "$MODE" = "--help" ]; then
    usage
    exit 0
fi

if [ "$MODE" = "check" ]; then
    echo "Signing directory: ${SIGNING_DIR}"
    echo "Identity:          ${SIGN_IDENTITY}"
    echo "Bundle ID:         ${BUNDLE_ID}"
    echo
    for tool in openssl security swift; do
        if command -v "$tool" >/dev/null 2>&1; then
            echo "✓ $tool: $(command -v "$tool")"
        else
            echo "✗ $tool: missing"
        fi
    done
    if command -v op >/dev/null 2>&1; then
        echo -n "1Password CLI: "
        if op whoami >/dev/null 2>&1; then
            echo "signed in"
        else
            echo "installed but not signed in (op signin)"
        fi
    else
        echo "1Password CLI: not installed"
    fi
    echo

    if [ -f "${SIGNING_DIR}/BarFold.p12" ]; then
        echo "✓ p12: ${SIGNING_DIR}/BarFold.p12"
        if command -v openssl >/dev/null 2>&1 && [ -f "${SIGNING_DIR}/BarFold.crt" ]; then
            openssl x509 -in "${SIGNING_DIR}/BarFold.crt" -noout -fingerprint -sha256 | sed 's/^/  /'
        fi
    else
        echo "✗ p12: not created"
    fi
    if [ -f "${SIGNING_DIR}/BarFold.p12.password" ]; then
        echo "✓ p12 password file: present (0600 expected)"
    else
        echo "✗ p12 password file: missing"
    fi
    if [ -f "${SIGNING_DIR}/Sparkle.public-key" ]; then
        echo "✓ Sparkle public key: $(cat "${SIGNING_DIR}/Sparkle.public-key")"
    else
        echo "✗ Sparkle public key: missing"
    fi
    if [ -f "${SIGNING_DIR}/Sparkle.edseed" ]; then
        echo "✓ Sparkle EdDSA seed: present (must live in 1Password)"
    else
        echo "✗ Sparkle EdDSA seed: missing"
    fi
    exit 0
fi

if [ "$MODE" != "apply" ]; then
    usage
    exit 2
fi

if [ "${BARFOLD_CONFIRM_SIGNING:-}" != "1" ]; then
    echo "❌ Refusing to create signing material without explicit confirmation." >&2
    echo "   Set BARFOLD_CONFIRM_SIGNING=1 only after you have read docs/signing.md and" >&2
    echo "   are ready to back up the p12 and EdDSA seed in 1Password." >&2
    exit 2
fi

if [ -f "${SIGNING_DIR}/BarFold.p12" ]; then
    echo "❌ ${SIGNING_DIR}/BarFold.p12 already exists." >&2
    echo "   Never regenerate a fixed identity: it resets TCC, notifications and login-item approvals." >&2
    exit 1
fi

mkdir -p "${SIGNING_DIR}"
chmod 700 "${SIGNING_DIR}"

CONFIG_FILE="$(mktemp "${TMPDIR:-/tmp}/barfold-cert.XXXXXX.cnf")"
trap 'rm -f "$CONFIG_FILE"' EXIT

cat > "$CONFIG_FILE" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3_codesign
prompt = no

[dn]
CN = BarFold Code Signing

[v3_codesign]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

echo "🔑 Generating RSA 3072 key and 10-year code-signing certificate..."
openssl genrsa -out "${SIGNING_DIR}/BarFold.key" 3072 >/dev/null 2>&1
openssl req -new -x509 \
    -key "${SIGNING_DIR}/BarFold.key" \
    -out "${SIGNING_DIR}/BarFold.crt" \
    -days 3650 \
    -config "$CONFIG_FILE" \
    -extensions v3_codesign >/dev/null 2>&1

P12_PASSWORD="$(openssl rand -hex 24)"
printf '%s' "$P12_PASSWORD" > "${SIGNING_DIR}/BarFold.p12.password"
chmod 600 "${SIGNING_DIR}/BarFold.p12.password"

openssl pkcs12 -export \
    -out "${SIGNING_DIR}/BarFold.p12" \
    -inkey "${SIGNING_DIR}/BarFold.key" \
    -in "${SIGNING_DIR}/BarFold.crt" \
    -name "${SIGN_IDENTITY}" \
    -passout "pass:${P12_PASSWORD}" >/dev/null 2>&1
chmod 600 "${SIGNING_DIR}/BarFold.p12"

# The p12 contains the private key; the raw key is no longer needed.
rm -f "${SIGNING_DIR}/BarFold.key"

echo "🔐 Generating Sparkle EdDSA seed and deriving its public key..."
SEED="$(openssl rand -base64 32)"
printf '%s' "$SEED" > "${SIGNING_DIR}/Sparkle.edseed"
chmod 600 "${SIGNING_DIR}/Sparkle.edseed"
PUBLIC_KEY="$(swift "${PROJECT_DIR}/scripts/eddsa-public-key.swift" "$SEED")"
printf '%s' "$PUBLIC_KEY" > "${SIGNING_DIR}/Sparkle.public-key"
chmod 600 "${SIGNING_DIR}/Sparkle.public-key"

FINGERPRINT="$(openssl x509 -in "${SIGNING_DIR}/BarFold.crt" -noout -fingerprint -sha256)"

cat <<TEXT

✅ Created signing material in ${SIGNING_DIR}
   ${FINGERPRINT}
   Sparkle public key: ${PUBLIC_KEY}

Next — protect the material in 1Password (required):
  1. Create a Secure Note "BarFold Code Signing" and attach:
       ${SIGNING_DIR}/BarFold.p12
       ${SIGNING_DIR}/BarFold.p12.password
     Put the SHA-256 fingerprint in the note.
  2. Create a Secure Note "BarFold Sparkle EdDSA" and attach:
       ${SIGNING_DIR}/Sparkle.edseed
     Put the public key in the note.
  3. Back up both items to a second vault / offline location.
  4. After the backup, delete the local secret files and materialize them with
     `op read` before each signed build. Never commit them.

Build a signed app:
  scripts/build.sh --local-signed
  scripts/signing-check.sh

TEXT
