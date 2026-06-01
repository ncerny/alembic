#!/bin/bash
# Build the Milestone 0 real-time transcription spike for macOS 26+.
# Requires Xcode Command Line Tools. Output is an .app bundle so macOS TCC grants
# Screen Recording / Microphone / Speech Recognition permissions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/build"

mkdir -p "$OUTPUT_DIR"

echo "Building realtime-transcribe spike…"
swiftc \
  -O \
  -o "$OUTPUT_DIR/realtime-transcribe-bin" \
  "$SCRIPT_DIR/RealtimeTranscribe.swift" \
  -framework ScreenCaptureKit \
  -framework AVFoundation \
  -framework CoreMedia \
  -framework Speech

APP_DIR="$OUTPUT_DIR/realtime-transcribe.app/Contents"
mkdir -p "$APP_DIR/MacOS"
mv "$OUTPUT_DIR/realtime-transcribe-bin" "$APP_DIR/MacOS/realtime-transcribe"
cp "$SCRIPT_DIR/Info.plist" "$APP_DIR/Info.plist"

# Ad-hoc codesign so the bundle has a stable identity for TCC permission grants.
codesign --force --sign - "$OUTPUT_DIR/realtime-transcribe.app" 2>/dev/null || true

echo "Built: $APP_DIR/MacOS/realtime-transcribe"
echo ""
echo "Run (Ctrl-C to stop):"
echo "  open -W \"$OUTPUT_DIR/realtime-transcribe.app\" --stdout /dev/stdout --stderr /dev/stderr \\"
echo "    --args --app 'Microsoft Teams' --output /tmp/realtime-transcript.jsonl"
echo ""
echo "Or run the binary directly (simpler logging; grant permissions when prompted):"
echo "  \"$APP_DIR/MacOS/realtime-transcribe\" --app 'Microsoft Teams' --output /tmp/realtime-transcript.jsonl"
