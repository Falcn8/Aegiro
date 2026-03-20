#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

SOURCE_IMAGE="assets/aegiro-banner.png"
OUTPUT_ICON="assets/AppIcon.icns"
OVERWRITE=0

to_abs_path() {
  case "$1" in
    /*) echo "$1" ;;
    *) echo "$ROOT_DIR/$1" ;;
  esac
}

usage() {
  cat <<'USAGE'
Usage: bash scripts/generate-app-icon.sh [options]

Options:
  --source <path>    Source image (default: assets/aegiro-banner.png)
  --output <path>    Output icns path (default: assets/AppIcon.icns)
  --overwrite        Overwrite existing output file
  --help             Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      SOURCE_IMAGE="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT_ICON="${2:-}"
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

if ! command -v sips >/dev/null 2>&1; then
  echo "sips not found. This script requires macOS." >&2
  exit 1
fi

if ! command -v iconutil >/dev/null 2>&1; then
  echo "iconutil not found. This script requires macOS." >&2
  exit 1
fi

SOURCE_IMAGE="$(to_abs_path "$SOURCE_IMAGE")"
OUTPUT_ICON="$(to_abs_path "$OUTPUT_ICON")"

if [[ ! -f "$SOURCE_IMAGE" ]]; then
  echo "Source image not found: $SOURCE_IMAGE" >&2
  exit 1
fi

if [[ -e "$OUTPUT_ICON" && "$OVERWRITE" -ne 1 ]]; then
  echo "Output already exists: $OUTPUT_ICON" >&2
  echo "Use --overwrite to replace it." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_ICON")"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aegiro-icon.XXXXXX")"
ICONSET_DIR="$WORK_DIR/AppIcon.iconset"
SOURCE_PNG="$WORK_DIR/source.png"
SQUARE_PNG="$WORK_DIR/square.png"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$ICONSET_DIR"

sips -s format png "$SOURCE_IMAGE" --out "$SOURCE_PNG" >/dev/null

WIDTH="$(sips -g pixelWidth "$SOURCE_PNG" | awk '/pixelWidth:/ { print $2 }')"
HEIGHT="$(sips -g pixelHeight "$SOURCE_PNG" | awk '/pixelHeight:/ { print $2 }')"

if [[ -z "$WIDTH" || -z "$HEIGHT" ]]; then
  echo "Unable to read image dimensions for: $SOURCE_IMAGE" >&2
  exit 1
fi

MIN_DIM="$WIDTH"
if (( HEIGHT < MIN_DIM )); then
  MIN_DIM="$HEIGHT"
fi

if [[ "$WIDTH" != "$HEIGHT" ]]; then
  echo "Cropping source to centered square (${MIN_DIM}x${MIN_DIM})..."
  sips -c "$MIN_DIM" "$MIN_DIM" "$SOURCE_PNG" --out "$SQUARE_PNG" >/dev/null
else
  cp "$SOURCE_PNG" "$SQUARE_PNG"
fi

render_icon() {
  local size="$1"
  local filename="$2"
  sips -z "$size" "$size" "$SQUARE_PNG" --out "$ICONSET_DIR/$filename" >/dev/null
}

render_icon 16 icon_16x16.png
render_icon 32 icon_16x16@2x.png
render_icon 32 icon_32x32.png
render_icon 64 icon_32x32@2x.png
render_icon 128 icon_128x128.png
render_icon 256 icon_128x128@2x.png
render_icon 256 icon_256x256.png
render_icon 512 icon_256x256@2x.png
render_icon 512 icon_512x512.png
render_icon 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET_DIR" -o "$OUTPUT_ICON"

echo "Built app icon: $OUTPUT_ICON"
