#!/bin/bash
# Build Alembic (macOS 26+ menu-bar app) and package it as a signed .app bundle.
#
# This is the CANONICAL packaging entry point for Alembic. It performs a clean
# release build with SwiftPM, assembles the .app bundle, codesigns it, and
# verifies the resulting signature so macOS TCC can grant Screen Recording /
# Microphone / Speech Recognition permissions.
#
# ## TCC identity stability (important)
# macOS keys permission grants (especially Screen Recording) to the app's code
# signature. An *ad-hoc* signature (`codesign --sign -`) has NO stable identity:
# its CDHash changes on every rebuild, so each rebuilt binary looks like a brand
# new app and previously-granted permissions stop applying (System Settings may
# still show a stale "Alembic" toggle). To make grants survive rebuilds, sign
# with a STABLE identity:
#
#   1. Create a persistent self-signed code-signing certificate (one time):
#        bash build.sh --make-cert
#   2. Rebuild — the script auto-detects the cert and signs with it:
#        bash build.sh --run
#   3. If you previously granted permissions to ad-hoc builds, clear the stale
#      grants once, then re-grant when prompted:
#        bash build.sh --reset-tcc
#
# You can also point at any identity you already have via the environment:
#   ALEMBIC_CODESIGN_IDENTITY="Apple Development: you@example.com" bash build.sh
#
# Without a stable identity the script still works (ad-hoc) but prints a warning
# that permissions will reset on every rebuild.
#
# It mirrors the Milestone 0 spike (spike/realtime-transcribe/build.sh) but uses
# SwiftPM instead of a single-file `swiftc` invocation, and emits an .app bundle.
#
# Requires Xcode Command Line Tools (swift). Xcode.app is NOT required; this
# script never invokes `xcodebuild`.
#
# Usage:
#   bash build.sh             Clean build, package, sign, verify.
#   bash build.sh --run       Same as above, then `open` the built app.
#   bash build.sh --make-cert Create the persistent self-signed signing cert.
#   bash build.sh --reset-tcc Reset Alembic's TCC grants (then re-grant on launch).
#   bash build.sh --help      Print this help.

set -euo pipefail

usage() {
    sed -n '2,46p' "$0" | sed 's/^#\{1,\} \{0,1\}//'
}

# Stable identity used for TCC-persistent local signing. Override with
# ALEMBIC_CODESIGN_IDENTITY to use a real (e.g. Apple Development) identity.
CERT_CN="Alembic Self-Signed"
BUNDLE_ID="com.alembic.app"

# Create a persistent self-signed code-signing certificate in the login keychain.
# A self-signed cert is not Gatekeeper-trusted (irrelevant for a locally-run dev
# app), but it gives codesign a STABLE identity, so the app's Designated
# Requirement — and therefore its TCC permission grants — survive rebuilds.
make_cert() {
    if security find-identity -p codesigning 2>/dev/null | grep -q "$CERT_CN"; then
        echo "==> Signing certificate \"$CERT_CN\" already exists; nothing to do."
        return 0
    fi
    command -v openssl >/dev/null 2>&1 || { echo "error: 'openssl' is required for --make-cert." >&2; exit 1; }

    echo "==> Creating self-signed code-signing certificate \"$CERT_CN\"…"
    local TMP; TMP="$(mktemp -d)"
    local P12_PASS="alembic-transient"
    cat > "$TMP/cert.conf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[ dn ]
CN = $CERT_CN
[ v3 ]
basicConstraints   = critical,CA:FALSE
keyUsage           = critical,digitalSignature
extendedKeyUsage   = critical,codeSigning
EOF
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.conf" >/dev/null 2>&1
    # `-legacy` is required: OpenSSL 3.x's default PKCS#12 MAC isn't accepted by
    # Apple's `security import`. A non-empty transient password is also required
    # (empty-password p12s fail MAC verification on import).
    openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -name "$CERT_CN" -passout "pass:${P12_PASS}" -out "$TMP/identity.p12" >/dev/null 2>&1
    # -A lets any app (incl. codesign) use the private key without a per-build
    # keychain prompt. Fine for a throwaway local dev signing key. The cert is
    # self-signed (untrusted), which is harmless: codesign signs with it anyway,
    # and the resulting Designated Requirement is stable across rebuilds.
    security import "$TMP/identity.p12" \
        -k "$HOME/Library/Keychains/login.keychain-db" -P "$P12_PASS" -A >/dev/null 2>&1
    rm -rf "$TMP"
    echo "    Done. Future builds will sign with \"$CERT_CN\"."
    echo "    If you granted permissions to earlier ad-hoc builds, run:"
    echo "        bash build.sh --reset-tcc"
}

# Reset Alembic's TCC grants so stale ad-hoc-identity entries don't shadow the
# newly-signed build. You'll be re-prompted (or re-toggle in System Settings) on
# the next launch; with a stable cert the new grant then persists across rebuilds.
reset_tcc() {
    echo "==> Resetting TCC grants for ${BUNDLE_ID} (ScreenCapture, Microphone, SpeechRecognition)…"
    tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null || true
    tccutil reset Microphone "$BUNDLE_ID" 2>/dev/null || true
    tccutil reset SpeechRecognition "$BUNDLE_ID" 2>/dev/null || true
    echo "    Done. Relaunch Alembic and grant the three permissions again."
}

OPEN_AFTER_BUILD=0
for arg in "$@"; do
    case "$arg" in
        --run|--open) OPEN_AFTER_BUILD=1 ;;
        --make-cert) make_cert; exit 0 ;;
        --reset-tcc) reset_tcc; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $arg" >&2; usage >&2; exit 2 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/build"
EXECUTABLE="Alembic"
APP_NAME="Alembic.app"
APP_BUNDLE="${OUTPUT_DIR}/${APP_NAME}"
TRANSCRIPT_DIR="${HOME}/Documents/Alembic"

# Fail early with an actionable message if the Swift toolchain is missing.
if ! command -v swift >/dev/null 2>&1; then
    echo "error: 'swift' not found. Install the Xcode Command Line Tools: xcode-select --install" >&2
    exit 1
fi

echo "==> Building ${EXECUTABLE} (release, Swift 6 strict concurrency)…"
swift build -c release --package-path "$SCRIPT_DIR"

BIN_PATH="$(swift build -c release --package-path "$SCRIPT_DIR" --show-bin-path)"

# Assemble the .app bundle from scratch so stale binaries never linger.
echo "==> Assembling ${APP_NAME}…"
APP_DIR="${APP_BUNDLE}/Contents"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_DIR/MacOS"
cp "$BIN_PATH/$EXECUTABLE" "$APP_DIR/MacOS/$EXECUTABLE"
cp "$SCRIPT_DIR/Info.plist" "$APP_DIR/Info.plist"

# Codesign so the bundle has an identity for TCC permission grants. Prefer a
# STABLE identity (so grants survive rebuilds); fall back to ad-hoc with a loud
# warning that permissions will reset every rebuild.
SIGN_IDENTITY="${ALEMBIC_CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]] && security find-identity -p codesigning 2>/dev/null | grep -q "$CERT_CN"; then
    SIGN_IDENTITY="$CERT_CN"
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "==> Codesigning with stable identity: ${SIGN_IDENTITY}…"
    codesign --force --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
else
    echo "==> Ad-hoc codesigning…"
    codesign --force --sign - "$APP_BUNDLE"
fi

# Verify the signature before declaring success.
echo "==> Verifying signature…"
codesign --verify --verbose "$APP_BUNDLE"

if [[ -z "$SIGN_IDENTITY" ]]; then
    echo ""
    echo "WARNING: ad-hoc signed. macOS TCC keys permissions to the binary hash,"
    echo "         which changes every rebuild — so previously-granted permissions"
    echo "         (Screen Recording in particular) will STOP applying after each"
    echo "         rebuild. For grants that persist, create a stable signing cert:"
    echo "             bash build.sh --make-cert"
    echo "         then rebuild and (once) clear stale grants: bash build.sh --reset-tcc"
fi

echo ""
echo "Built and verified: ${APP_BUNDLE}"
echo "Run:                open \"${APP_BUNDLE}\""
echo "Transcripts saved:  ${TRANSCRIPT_DIR}/<yyyy-MM-dd_HHmm>-<meeting>.{jsonl,md}"
echo ""
echo "Note: Alembic is a menu-bar-only app (LSUIElement). After launch, look for"
echo "      its icon in the macOS menu bar (no Dock icon, no window on launch)."

if [[ "$OPEN_AFTER_BUILD" -eq 1 ]]; then
    echo ""
    echo "==> Opening ${APP_NAME}…"
    open "$APP_BUNDLE"
fi
