#!/bin/bash
# Captures a single frame from the webcam
# Supports Linux (v4l2) and macOS (avfoundation)

OUTPUT="${1:-/tmp/claude-vibe-check-$(date +%s).jpg}"

capture_linux() {
  if command -v fswebcam &>/dev/null; then
    fswebcam -r 1280x720 --no-banner --quiet "$OUTPUT" 2>/dev/null
    return $?
  fi

  if command -v ffmpeg &>/dev/null; then
    for dev in /dev/video*; do
      [ -e "$dev" ] || continue
      ffmpeg -f v4l2 -i "$dev" -frames:v 1 -y -loglevel quiet "$OUTPUT" 2>/dev/null && return 0
    done
  fi

  if command -v gst-launch-1.0 &>/dev/null; then
    for dev in /dev/video*; do
      [ -e "$dev" ] || continue
      gst-launch-1.0 v4l2src device="$dev" num-buffers=1 ! jpegenc ! filesink location="$OUTPUT" 2>/dev/null && return 0
    done
  fi

  return 1
}

capture_macos() {
  if command -v imagesnap &>/dev/null; then
    imagesnap -q "$OUTPUT" 2>/dev/null
    return $?
  fi

  if command -v ffmpeg &>/dev/null; then
    for idx in 0 1 2 3 4; do
      ffmpeg -f avfoundation -framerate 30 -i "$idx" -frames:v 1 -y -loglevel quiet "$OUTPUT" 2>/dev/null && return 0
    done
  fi

  return 1
}

OS="$(uname -s)"

case "$OS" in
  Linux)  capture_linux  ;;
  Darwin) capture_macos  ;;
  MINGW*|MSYS*|CYGWIN*)
    echo "Windows is not yet supported. Webcam capture requires v4l2 (Linux) or avfoundation (macOS)." >&2
    exit 1
    ;;
  *)
    echo "Unsupported OS: $OS" >&2
    exit 1
    ;;
esac

if [ $? -eq 0 ] && [ -f "$OUTPUT" ]; then
  echo "$OUTPUT"
  exit 0
else
  echo "Failed to capture webcam photo. Make sure a webcam is connected and capture tools are installed (fswebcam, ffmpeg, or imagesnap)." >&2
  exit 1
fi
