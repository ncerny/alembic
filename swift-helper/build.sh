#!/bin/bash
# Build the audio capture helper for macOS
# Requires Xcode Command Line Tools

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/../build"

mkdir -p "$OUTPUT_DIR"

echo "Building audio-capture helper..."
swiftc \
  -O \
  -o "$OUTPUT_DIR/audio-capture-bin" \
  "$SCRIPT_DIR/AudioCapture.swift" \
  -framework ScreenCaptureKit \
  -framework AVFoundation \
  -framework CoreMedia \
  -framework Speech

# Package as .app bundle so macOS TCC grants Speech Recognition permission
APP_DIR="$OUTPUT_DIR/audio-capture.app/Contents"
mkdir -p "$APP_DIR/MacOS"
mv "$OUTPUT_DIR/audio-capture-bin" "$APP_DIR/MacOS/audio-capture"
cp "$SCRIPT_DIR/Info.plist" "$APP_DIR/Info.plist"

echo "Built: $APP_DIR/MacOS/audio-capture"
echo ""
echo "Usage:"
echo "  $APP_DIR/MacOS/audio-capture list"
echo "  $APP_DIR/MacOS/audio-capture capture --app 'Microsoft Teams' --output /tmp/meeting.wav"
