#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

CONFIG="debug"
TARGET_NAME="AegiroApp"
APP_EXECUTABLE="$TARGET_NAME"
APP_BUNDLE_NAME="Aegiro"
APP_PATH="$ROOT_DIR/dist/${APP_BUNDLE_NAME}.app"
APP_ICON_SOURCE="$ROOT_DIR/assets/AppIcon.icns"
BUNDLE_ID="com.example.aegiro"
IDENTITY=""
FORCE_AD_HOC=0
LAUNCH_AFTER_BUILD=0
KILL_RUNNING=0
BUILD_VERSION="$(date +%Y%m%d%H%M%S)"

usage() {
  cat <<'EOF'
Usage: bash scripts/build-app-dev.sh [options]

Options:
  --configuration <debug|release>  Build configuration (default: debug)
  --identity "<name-or-sha1>"      Use this signing identity
  --bundle-id <id>                 Bundle identifier (default: com.example.aegiro)
  --launch                         Launch the built app as a new instance
  --kill-running                   Kill existing Aegiro app processes before launch
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
    --launch)
      LAUNCH_AFTER_BUILD=1
      KILL_RUNNING=1
      shift
      ;;
    --kill-running)
      KILL_RUNNING=1
      shift
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

list_running_instances() {
  ps -axo pid=,command= \
    | awk '$2 ~ /\/AegiroApp$/ { print }'
}

list_debugserver_instances() {
  ps -axo pid=,command= \
    | awk '$2 ~ /\/debugserver$/ && $0 ~ /DerivedData\/Aegiro/ && $0 ~ /AegiroApp/ { print }'
}

kill_running_instances() {
  local lines pids remaining dbg_lines dbg_pids
  lines="$(list_running_instances || true)"
  dbg_lines="$(list_debugserver_instances || true)"
  if [[ -n "$lines" ]]; then
    echo "Stopping running AegiroApp processes:"
    echo "$lines"
    pids="$(echo "$lines" | awk '{ print $1 }' | xargs)"
    if [[ -n "$pids" ]]; then
      kill $pids || true
      sleep 0.5
      remaining="$(list_running_instances || true)"
      if [[ -n "$remaining" ]]; then
        echo "Force-stopping stubborn AegiroApp processes:"
        echo "$remaining"
        echo "$remaining" | awk '{ print $1 }' | xargs kill -9 || true
        sleep 0.2
      fi
    fi
  fi

  if [[ -n "$dbg_lines" ]]; then
    echo "Stopping Xcode debugserver sessions for Aegiro:"
    echo "$dbg_lines"
    dbg_pids="$(echo "$dbg_lines" | awk '{ print $1 }' | xargs)"
    if [[ -n "$dbg_pids" ]]; then
      kill $dbg_pids || true
      sleep 0.2
    fi
  fi
}

echo "Building ${APP_BUNDLE_NAME}.app (${CONFIG}) from target ${TARGET_NAME}..."
swift build --target "$TARGET_NAME" -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP_BIN="$BIN_DIR/$APP_EXECUTABLE"
if [[ ! -x "$APP_BIN" ]]; then
  echo "Build did not produce executable: $APP_BIN" >&2
  exit 1
fi

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$APP_BIN" "$APP_PATH/Contents/MacOS/$APP_EXECUTABLE"

# SwiftPM resource bundles are emitted next to the executable.
# Copy bundles into app resources so packaged builds include images/fonts/json assets.
while IFS= read -r bundle; do
  [[ -z "$bundle" ]] && continue
  cp -R "$bundle" "$APP_PATH/Contents/Resources/$(basename "$bundle")"
done < <(find "$BIN_DIR" -maxdepth 1 -type d -name '*.bundle' | sort)

ICON_PLIST_BLOCK=""
if [[ -f "$APP_ICON_SOURCE" ]]; then
  cp "$APP_ICON_SOURCE" "$APP_PATH/Contents/Resources/AppIcon.icns"
  ICON_PLIST_BLOCK=$'  <key>CFBundleIconFile</key><string>AppIcon</string>\n'
fi

cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_BUNDLE_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_BUNDLE_NAME}</string>
  <key>CFBundleExecutable</key><string>${APP_EXECUTABLE}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleVersion</key><string>${BUILD_VERSION}</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
${ICON_PLIST_BLOCK}  <key>NSFaceIDUsageDescription</key><string>Use biometrics to unlock your vault.</string>
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
echo "Build version: $BUILD_VERSION"

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

if [[ "$LAUNCH_AFTER_BUILD" -eq 1 ]]; then
  if [[ "$KILL_RUNNING" -eq 1 ]]; then
    kill_running_instances
  fi
  open -n "$APP_PATH"
fi

echo "Run: open -n \"$APP_PATH\""
