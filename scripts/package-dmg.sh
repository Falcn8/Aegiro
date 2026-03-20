#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_PATH="dist/Aegiro.app"
OUTPUT_DMG="dist/Aegiro.dmg"
VOLUME_NAME="Aegiro"
BACKGROUND_IMAGE=""
OVERWRITE=0

WINDOW_LEFT=120
WINDOW_TOP=120
WINDOW_WIDTH=760
WINDOW_HEIGHT=460
APP_ICON_X=200
APP_ICON_Y=240
APPLICATIONS_ICON_X=560
APPLICATIONS_ICON_Y=240

to_abs_path() {
  case "$1" in
    /*) echo "$1" ;;
    *) echo "$ROOT_DIR/$1" ;;
  esac
}

usage() {
  cat <<'USAGE'
Usage: bash scripts/package-dmg.sh [options]

Options:
  --app <path>           App bundle to package (default: dist/Aegiro.app)
  --output <path>        Output dmg path (default: dist/Aegiro.dmg)
  --volume-name <name>   Mounted volume name (default: Aegiro)
  --background <path>    Background image for Finder window (png/jpg)
  --overwrite            Overwrite existing output dmg
  --help                 Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP_PATH="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT_DMG="${2:-}"
      shift 2
      ;;
    --volume-name)
      VOLUME_NAME="${2:-}"
      shift 2
      ;;
    --background)
      BACKGROUND_IMAGE="${2:-}"
      shift 2
      ;;
    --overwrite)
      OVERWRITE=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$APP_PATH" || -z "$OUTPUT_DMG" || -z "$VOLUME_NAME" ]]; then
  echo "Missing required option value." >&2
  usage >&2
  exit 1
fi

if ! command -v hdiutil >/dev/null 2>&1; then
  echo "hdiutil not found. This script requires macOS." >&2
  exit 1
fi

if ! command -v osascript >/dev/null 2>&1; then
  echo "osascript not found. This script requires macOS." >&2
  exit 1
fi

APP_PATH="$(to_abs_path "$APP_PATH")"
OUTPUT_DMG="$(to_abs_path "$OUTPUT_DMG")"

if [[ -z "$BACKGROUND_IMAGE" ]]; then
  if [[ -f "$ROOT_DIR/assets/dmg-background.png" ]]; then
    BACKGROUND_IMAGE="$ROOT_DIR/assets/dmg-background.png"
  elif [[ -f "$ROOT_DIR/assets/aegiro-banner.png" ]]; then
    BACKGROUND_IMAGE="$ROOT_DIR/assets/aegiro-banner.png"
  fi
fi

if [[ -n "$BACKGROUND_IMAGE" ]]; then
  if ! command -v sips >/dev/null 2>&1; then
    echo "sips not found. Background conversion requires macOS." >&2
    exit 1
  fi
  BACKGROUND_IMAGE="$(to_abs_path "$BACKGROUND_IMAGE")"
  if [[ ! -f "$BACKGROUND_IMAGE" ]]; then
    echo "Background image not found: $BACKGROUND_IMAGE" >&2
    exit 1
  fi
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  echo "Build it first with: bash scripts/build-app-universal.sh --configuration release --ad-hoc" >&2
  exit 1
fi

if [[ -e "$OUTPUT_DMG" && "$OVERWRITE" -ne 1 ]]; then
  echo "Output already exists: $OUTPUT_DMG" >&2
  echo "Use --overwrite to replace it." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_DMG")"

STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aegiro-dmg-stage.XXXXXX")"
TEMP_RW_DMG="$(mktemp -t aegiro-dmg-rw).dmg"
ATTACHED_DEVICE=""
MOUNT_POINT=""
APP_BUNDLE_NAME="$(basename "$APP_PATH")"

cleanup() {
  if [[ -n "$ATTACHED_DEVICE" ]]; then
    hdiutil detach "$ATTACHED_DEVICE" -quiet >/dev/null 2>&1 || \
      hdiutil detach "$ATTACHED_DEVICE" -force -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$STAGE_DIR"
  rm -f "$TEMP_RW_DMG"
}
trap cleanup EXIT

apply_finder_layout() {
  local mounted_volume_name="$1"
  local app_bundle_name="$2"
  local has_background="$3"
  local right bottom

  right=$((WINDOW_LEFT + WINDOW_WIDTH))
  bottom=$((WINDOW_TOP + WINDOW_HEIGHT))

  /usr/bin/osascript - "$mounted_volume_name" \
    "$app_bundle_name" \
    "$has_background" \
    "$WINDOW_LEFT" "$WINDOW_TOP" "$right" "$bottom" \
    "$APP_ICON_X" "$APP_ICON_Y" "$APPLICATIONS_ICON_X" "$APPLICATIONS_ICON_Y" <<'APPLESCRIPT'
on run argv
  set volumeName to item 1 of argv
  set appBundleName to item 2 of argv
  set hasBackground to item 3 of argv
  set leftBound to (item 4 of argv) as integer
  set topBound to (item 5 of argv) as integer
  set rightBound to (item 6 of argv) as integer
  set bottomBound to (item 7 of argv) as integer
  set appX to (item 8 of argv) as integer
  set appY to (item 9 of argv) as integer
  set appsX to (item 10 of argv) as integer
  set appsY to (item 11 of argv) as integer

  tell application "Finder"
    tell disk volumeName
      open
      delay 0.5
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set bounds of container window to {leftBound, topBound, rightBound, bottomBound}

      set viewOptions to the icon view options of container window
      set arrangement of viewOptions to not arranged
      set icon size of viewOptions to 128
      set text size of viewOptions to 14

      if hasBackground is "1" then
        set background picture of viewOptions to file ".background:background.png"
      end if

      set position of item appBundleName of container window to {appX, appY}
      set position of item "Applications" of container window to {appsX, appsY}

      update without registering applications
      delay 1
      close
      open
      delay 0.5
    end tell
  end tell
end run
APPLESCRIPT
}

cp -R "$APP_PATH" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

echo "Creating temporary writable image..."
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGE_DIR" \
  -format UDRW \
  -ov \
  "$TEMP_RW_DMG" >/dev/null

echo "Applying Finder layout..."
ATTACH_OUTPUT="$(hdiutil attach -readwrite -noverify -noautoopen "$TEMP_RW_DMG")"
ATTACHED_DEVICE="$(echo "$ATTACH_OUTPUT" | awk '/\/Volumes\// { print $1; exit }')"
MOUNT_POINT="$(echo "$ATTACH_OUTPUT" | awk 'match($0,/\/Volumes\/.*/) { print substr($0, RSTART); exit }')"

if [[ -z "$ATTACHED_DEVICE" || -z "$MOUNT_POINT" ]]; then
  echo "Failed to attach temporary image." >&2
  exit 1
fi

HAS_BACKGROUND=0
if [[ -n "$BACKGROUND_IMAGE" ]]; then
  mkdir -p "$MOUNT_POINT/.background"
  sips -s format png "$BACKGROUND_IMAGE" --out "$MOUNT_POINT/.background/background.png" >/dev/null
  HAS_BACKGROUND=1
fi

MOUNTED_VOLUME_NAME="$(basename "$MOUNT_POINT")"
if ! apply_finder_layout "$MOUNTED_VOLUME_NAME" "$APP_BUNDLE_NAME" "$HAS_BACKGROUND"; then
  echo "Warning: Finder layout automation failed; continuing with default layout." >&2
fi

sync
hdiutil detach "$ATTACHED_DEVICE" -quiet >/dev/null || hdiutil detach "$ATTACHED_DEVICE" -force -quiet >/dev/null
ATTACHED_DEVICE=""

echo "Compressing final dmg..."
hdiutil convert \
  "$TEMP_RW_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  -o "$OUTPUT_DMG" >/dev/null

echo "Verifying dmg..."
hdiutil verify "$OUTPUT_DMG" >/dev/null

SHA256="$(shasum -a 256 "$OUTPUT_DMG" | awk '{print $1}')"

echo "---"
echo "Built dmg: $OUTPUT_DMG"
echo "SHA256: $SHA256"
if [[ "$HAS_BACKGROUND" -eq 1 ]]; then
  echo "Background image: $BACKGROUND_IMAGE"
fi
