#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

VERSION="$(tr -d '[:space:]' < version.txt)"
APP="${PROJECT_DIR}/release/${VERSION}/BarFold.app"
CLI="${APP}/Contents/Helpers/barfold"
STATUS_JSON="$(mktemp -t barfold-e2e-status.XXXXXX.json)"
COLLAPSED_JSON="$(mktemp -t barfold-e2e-collapsed.XXXXXX.json)"
EXPANDED_JSON="$(mktemp -t barfold-e2e-expanded.XXXXXX.json)"
SELFTEST_JSON="$(mktemp -t barfold-e2e-selftest.XXXXXX.json)"
DOCTOR_JSON="$(mktemp -t barfold-e2e-doctor.XXXXXX.json)"

cleanup() {
    "${CLI}" quit >/dev/null 2>&1 || true
    rm -f "${STATUS_JSON}" "${COLLAPSED_JSON}" "${EXPANDED_JSON}" "${SELFTEST_JSON}" "${DOCTOR_JSON}"
}
trap cleanup EXIT

echo "🔨 Building test app..."
scripts/build.sh --debug --adhoc >/dev/null

echo "🧹 Stopping any existing instance..."
"${CLI}" quit >/dev/null 2>&1 || true
sleep 0.5

echo "🚀 Launching in test mode..."
open -n "${APP}" --args --test-mode

for _ in {1..60}; do
    if "${CLI}" status --json >"${STATUS_JSON}" 2>/dev/null; then
        if python3 - "${STATUS_JSON}" <<'PY' >/dev/null 2>&1
import json, sys
data = json.load(open(sys.argv[1]))
raise SystemExit(0 if data.get("layoutSettled") and data.get("toggleOnScreen") else 1)
PY
        then
            break
        fi
    fi
    sleep 0.1
done

if [ ! -s "${STATUS_JSON}" ]; then
    echo "❌ BarFold did not start or did not answer on its control socket." >&2
    exit 1
fi

python3 - "${STATUS_JSON}" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data.get("ok", True) is not False, data
assert data["collapsed"] is False, data
assert data["toggleOnScreen"] is True, data
assert data["layoutSettled"] is True, data
assert data["separatorWindowWidth"] <= 20, data
print("✓ initial: expanded, arrow on screen, layout settled")
PY

INITIAL_VISIBLE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["visibleStatusWindowCount"])' "${STATUS_JSON}")

echo "→ collapse"
"${CLI}" collapse >/dev/null
"${CLI}" wait collapsed --timeout 3000
"${CLI}" probe --json >"${COLLAPSED_JSON}"
python3 - "${COLLAPSED_JSON}" "${INITIAL_VISIBLE}" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
initial = int(sys.argv[2])
assert data["collapsed"] is True, data
assert data["layoutSettled"] is True, data
assert data["separatorWindowWidth"] > 1000, data
assert data["toggleOnScreen"] is True, data
assert data["canaryOnScreen"] is False, data
assert data["visibleStatusWindowCount"] < initial, (data["visibleStatusWindowCount"], initial)
print(f"✓ collapsed: separator {int(data['separatorWindowWidth'])}pt, canary hidden, visible items {initial}→{data['visibleStatusWindowCount']}, arrow still on screen")
PY

echo "→ expand"
"${CLI}" expand >/dev/null
"${CLI}" wait expanded --timeout 3000
"${CLI}" probe --json >"${EXPANDED_JSON}"
python3 - "${EXPANDED_JSON}" "${INITIAL_VISIBLE}" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
initial = int(sys.argv[2])
assert data["collapsed"] is False, data
assert data["layoutSettled"] is True, data
assert data["separatorWindowWidth"] <= 20, data
assert data["canaryOnScreen"] is True, data
assert data["visibleStatusWindowCount"] == initial, (data["visibleStatusWindowCount"], initial)
print(f"✓ expanded: canary visible, visible items back to {initial}")
PY

echo "→ selftest"
"${CLI}" selftest --json >"${SELFTEST_JSON}"
python3 - "${SELFTEST_JSON}" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data.get("ok") is True, data
print("✓ selftest: all engine checks pass")
PY

echo "→ doctor"
"${CLI}" doctor --json >"${DOCTOR_JSON}"
python3 - "${DOCTOR_JSON}" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data.get("ok") is True, data
failed = [c for c in data.get("checks", []) if c.get("status") == "fail"]
assert not failed, failed
print("✓ doctor: no failures")
PY

echo "✅ E2E PASS"
