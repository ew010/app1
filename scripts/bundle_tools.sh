#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-}"
BUNDLE_ROOT="${2:-}"

if [[ -z "$TARGET" || -z "$BUNDLE_ROOT" ]]; then
  echo "Usage: $0 <linux|windows|macos> <bundle_root_dir>"
  exit 1
fi

if [[ "$TARGET" != "linux" && "$TARGET" != "windows" && "$TARGET" != "macos" ]]; then
  echo "Unsupported target: $TARGET"
  exit 1
fi

WORK_DIR="$(mktemp -d)"
TOOLS_DIR="$BUNDLE_ROOT/tools"
mkdir -p "$TOOLS_DIR"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

download() {
  local url="$1"
  local output="$2"
  curl -fL --retry 5 --retry-delay 2 "$url" -o "$output"
}

echo "Bundling adb and scrcpy for target=$TARGET into $TOOLS_DIR"

case "$TARGET" in
  linux)
    ADB_ZIP_URL="https://dl.google.com/android/repository/platform-tools-latest-linux.zip"
    SCRCPY_ARCHIVE_NAME="scrcpy-linux-x86_64"
    SCRCPY_EXTENSION="tar.gz"
    SCRCPY_BIN_NAME="scrcpy"
    ;;
  windows)
    ADB_ZIP_URL="https://dl.google.com/android/repository/platform-tools-latest-windows.zip"
    SCRCPY_ARCHIVE_NAME="scrcpy-win64"
    SCRCPY_EXTENSION="zip"
    SCRCPY_BIN_NAME="scrcpy.exe"
    ;;
  macos)
    ADB_ZIP_URL="https://dl.google.com/android/repository/platform-tools-latest-darwin.zip"
    if [[ "$(uname -m)" == "arm64" ]]; then
      SCRCPY_ARCHIVE_NAME="scrcpy-macos-aarch64"
    else
      SCRCPY_ARCHIVE_NAME="scrcpy-macos-x86_64"
    fi
    SCRCPY_EXTENSION="tar.gz"
    SCRCPY_BIN_NAME="scrcpy"
    ;;
esac

SCRCPY_LATEST_URL="$(curl -Ls -o /dev/null -w '%{url_effective}' https://github.com/Genymobile/scrcpy/releases/latest)"
SCRCPY_TAG="${SCRCPY_LATEST_URL##*/}"
if [[ -z "$SCRCPY_TAG" || "$SCRCPY_TAG" != v* ]]; then
  echo "Failed to resolve scrcpy latest tag from: $SCRCPY_LATEST_URL"
  exit 1
fi

SCRCPY_ASSET="${SCRCPY_ARCHIVE_NAME}-${SCRCPY_TAG}.${SCRCPY_EXTENSION}"
SCRCPY_URL="https://github.com/Genymobile/scrcpy/releases/download/${SCRCPY_TAG}/${SCRCPY_ASSET}"

ADB_ZIP="$WORK_DIR/platform-tools.zip"
SCRCPY_ARCHIVE="$WORK_DIR/scrcpy-archive"

# Download and unpack adb platform-tools.
download "$ADB_ZIP_URL" "$ADB_ZIP"
unzip -q "$ADB_ZIP" -d "$WORK_DIR"
rm -rf "$TOOLS_DIR/platform-tools"
mkdir -p "$TOOLS_DIR/platform-tools"
cp -R "$WORK_DIR/platform-tools/." "$TOOLS_DIR/platform-tools/"

# Download and unpack scrcpy bundle.
download "$SCRCPY_URL" "$SCRCPY_ARCHIVE"
SCRCPY_EXTRACT_DIR="$WORK_DIR/scrcpy-extract"
mkdir -p "$SCRCPY_EXTRACT_DIR"
if [[ "$SCRCPY_EXTENSION" == "zip" ]]; then
  unzip -q "$SCRCPY_ARCHIVE" -d "$SCRCPY_EXTRACT_DIR"
else
  tar -xzf "$SCRCPY_ARCHIVE" -C "$SCRCPY_EXTRACT_DIR"
fi

SCRCPY_SOURCE="$SCRCPY_EXTRACT_DIR"
TOP_LEVEL_DIR="$(find "$SCRCPY_EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1 || true)"
if [[ -n "$TOP_LEVEL_DIR" ]]; then
  SCRCPY_SOURCE="$TOP_LEVEL_DIR"
fi

rm -rf "$TOOLS_DIR/scrcpy"
mkdir -p "$TOOLS_DIR/scrcpy"
cp -R "$SCRCPY_SOURCE/." "$TOOLS_DIR/scrcpy/"

if [[ "$TARGET" != "windows" ]]; then
  chmod +x "$TOOLS_DIR/platform-tools/adb" || true
  chmod +x "$TOOLS_DIR/scrcpy/$SCRCPY_BIN_NAME" || true
fi

if [[ "$TARGET" == "windows" ]]; then
  if [[ ! -f "$TOOLS_DIR/platform-tools/adb.exe" || ! -f "$TOOLS_DIR/scrcpy/$SCRCPY_BIN_NAME" ]]; then
    echo "Bundled tool validation failed for Windows"
    exit 1
  fi
else
  if [[ ! -f "$TOOLS_DIR/platform-tools/adb" || ! -f "$TOOLS_DIR/scrcpy/$SCRCPY_BIN_NAME" ]]; then
    echo "Bundled tool validation failed for $TARGET"
    exit 1
  fi
fi

echo "Bundled tools ready."
