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
  -o "$OUTPUT_DIR/audio-capture" \
  "$SCRIPT_DIR/AudioCapture.swift" \
  -framework ScreenCaptureKit \
  -framework AVFoundation \
  -framework CoreMedia

echo "Built: $OUTPUT_DIR/audio-capture"
echo ""
echo "Usage:"
echo "  $OUTPUT_DIR/audio-capture list"
echo "  $OUTPUT_DIR/audio-capture capture --app 'Microsoft Teams' --output /tmp/meeting.wav"
