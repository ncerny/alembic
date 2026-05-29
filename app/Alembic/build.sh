#!/bin/bash
# Build Alembic (macOS 26+ menu-bar app) and package it as a signed .app bundle.
#
# This is the CANONICAL packaging entry point for Alembic. It performs a clean
# release build with SwiftPM, assembles the .app bundle, ad-hoc codesigns it,
# and verifies the resulting signature so macOS TCC can grant Screen Recording /
# Microphone / Speech Recognition permissions against a stable identity.
#
# It mirrors the Milestone 0 spike (spike/realtime-transcribe/build.sh) but uses
# SwiftPM instead of a single-file `swiftc` invocation, and emits an .app bundle.
#
# Requires Xcode Command Line Tools (swift). Xcode.app is NOT required; this
# script never invokes `xcodebuild`.
#
# Usage:
#   bash build.sh            Clean build, package, ad-hoc sign, verify.
#   bash build.sh --run      Same as above, then `open` the built app.
#   bash build.sh --help     Print this help.

set -euo pipefail

usage() {
    sed -n '2,18p' "$0" | sed 's/^#\{1,\} \{0,1\}//'
}

OPEN_AFTER_BUILD=0
for arg in "$@"; do
    case "$arg" in
        --run|--open) OPEN_AFTER_BUILD=1 ;;
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

# Ad-hoc codesign so the bundle has a stable identity for TCC permission grants.
echo "==> Ad-hoc codesigning…"
codesign --force --sign - "$APP_BUNDLE"

# Verify the signature before declaring success.
echo "==> Verifying signature…"
codesign --verify --verbose "$APP_BUNDLE"

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
