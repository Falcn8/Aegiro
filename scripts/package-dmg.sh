#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_PATH="dist/Aegiro.app"
OUTPUT_DMG="dist/Aegiro.dmg"
VOLUME_NAME="Aegiro"
OVERWRITE=0

to_abs_path() {
  case "$1" in
    /*) echo "$1" ;;
    *) echo "$ROOT_DIR/$1" ;;
  esac
}

usage() {
  cat <<'EOF'
Usage: bash scripts/package-dmg.sh [options]

Options:
  --app <path>           App bundle to package (default: dist/Aegiro.app)
  --output <path>        Output dmg path (default: dist/Aegiro.dmg)
  --volume-name <name>   Mounted volume name (default: Aegiro)
  --overwrite            Overwrite existing output dmg
  --help                 Show this help
EOF
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

APP_PATH="$(to_abs_path "$APP_PATH")"
OUTPUT_DMG="$(to_abs_path "$OUTPUT_DMG")"

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

cleanup() {
  rm -rf "$STAGE_DIR"
  rm -f "$TEMP_RW_DMG"
}
trap cleanup EXIT

cp -R "$APP_PATH" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

echo "Creating temporary writable image..."
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGE_DIR" \
  -format UDRW \
  -ov \
  "$TEMP_RW_DMG" >/dev/null

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
