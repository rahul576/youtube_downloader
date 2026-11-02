#!/bin/bash
# Builds "Video Saver.app" from source on your Mac.
#   bash build.sh            -> builds the app in this folder
#   bash build.sh --install  -> also copies it into /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Video Saver"
APP="$APP_NAME.app"
EXE="VideoSaver"

echo "==> Checking requirements"

# 1. Swift compiler (Xcode Command Line Tools)
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Xcode Command Line Tools are needed. A dialog will open — click Install, then re-run this script."
  xcode-select --install || true
  exit 1
fi

# 2. Homebrew + yt-dlp + ffmpeg (the app uses these to download and convert)
for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
  [ -x "$b" ] && eval "$("$b" shellenv)" && break
done
if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is needed. Install it from https://brew.sh (one command), then re-run this script."
  exit 1
fi
for tool in yt-dlp ffmpeg; do
  if command -v "$tool" >/dev/null 2>&1; then
    echo "    ${tool} ✓"
  else
    echo "    installing ${tool}..."
    brew install "$tool"
  fi
done

echo "==> Compiling"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

ARCH="$(uname -m)"   # arm64 on Apple Silicon, x86_64 on Intel
xcrun swiftc -O -parse-as-library -sdk "$(xcrun --show-sdk-path)" \
  -target "$ARCH-apple-macos13.0" \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/$EXE"

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> Signing (ad-hoc, for this Mac)"
codesign --force --deep --sign - "$APP" >/dev/null

if [ "${1:-}" = "--install" ]; then
  echo "==> Installing to /Applications"
  rm -rf "/Applications/$APP"
  cp -R "$APP" /Applications/
  open "/Applications/$APP"
  echo "Done — '$APP_NAME' is in your Applications folder."
else
  open -R "$APP"
  echo "Done — built '$APP'. Double-click to run, or drag it to Applications."
  echo "(Tip: 'bash build.sh --install' puts it in /Applications for you.)"
fi
