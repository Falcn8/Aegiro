#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

CONFIG="debug"
APP_NAME="AegiroApp"
APP_PATH="$ROOT_DIR/dist/${APP_NAME}.app"
BUNDLE_ID="com.example.aegiro"
IDENTITY=""
FORCE_AD_HOC=0

usage() {
  cat <<'EOF'
Usage: bash scripts/build-app-dev.sh [options]

Options:
  --configuration <debug|release>  Build configuration (default: debug)
  --identity "<name-or-sha1>"      Use this signing identity
  --bundle-id <id>                 Bundle identifier (default: com.example.aegiro)
  --ad-hoc                         Force ad-hoc signing
  --help                           Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration)
      CONFIG="${2:-}"
      shift 2
      ;;
    --identity)
      IDENTITY="${2:-}"
      shift 2
      ;;
    --bundle-id)
      BUNDLE_ID="${2:-}"
      shift 2
      ;;
    --ad-hoc)
      FORCE_AD_HOC=1
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

if [[ "$CONFIG" != "debug" && "$CONFIG" != "release" ]]; then
  echo "Invalid --configuration: $CONFIG (expected debug or release)" >&2
  exit 1
fi

detect_first_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/"[^"]+"/ { print $2; exit }'
}

echo "Building ${APP_NAME} (${CONFIG})..."
swift build --target "$APP_NAME" -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP_BIN="$BIN_DIR/$APP_NAME"
if [[ ! -x "$APP_BIN" ]]; then
  echo "Build did not produce executable: $APP_BIN" >&2
  exit 1
fi

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$APP_BIN" "$APP_PATH/Contents/MacOS/$APP_NAME"

cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSFaceIDUsageDescription</key><string>Use biometrics to unlock your vault.</string>
</dict>
</plist>
PLIST

SIGN_ID="-"
if [[ "$FORCE_AD_HOC" -eq 1 ]]; then
  SIGN_ID="-"
elif [[ -n "$IDENTITY" ]]; then
  SIGN_ID="$IDENTITY"
else
  AUTO_IDENTITY="$(detect_first_identity || true)"
  if [[ -n "${AUTO_IDENTITY:-}" ]]; then
    SIGN_ID="$AUTO_IDENTITY"
  fi
fi

if [[ "$SIGN_ID" == "-" ]]; then
  echo "No signing identity selected/found. Using ad-hoc signing."
  codesign --force --deep --timestamp=none --sign - "$APP_PATH"
else
  echo "Signing with identity: $SIGN_ID"
  codesign --force --deep --timestamp=none --options runtime --sign "$SIGN_ID" "$APP_PATH"
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
echo "Built app: $APP_PATH"

if [[ "$SIGN_ID" == "-" ]]; then
  cat <<'EOF'
Warning: ad-hoc signed build.
Touch ID secure keychain storage is expected to be unavailable in this mode.

To enable Touch ID storage:
1) Create a code-signing identity (Apple Development in Xcode, or a local self-signed Code Signing certificate).
2) Re-run: bash scripts/build-app-dev.sh --identity "<identity name>"
3) Verify identities: security find-identity -v -p codesigning
EOF
fi

echo "Run: open \"$APP_PATH\""
