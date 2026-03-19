#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

CONFIG="debug"
TARGET_NAME="AegiroApp"
APP_EXECUTABLE="$TARGET_NAME"
APP_BUNDLE_NAME="Aegiro"
CANONICAL_APP_PATH="$ROOT_DIR/dist/${APP_BUNDLE_NAME}.app"
BUNDLE_ID="com.example.aegiro"
IDENTITY=""
FORCE_AD_HOC=0
LAUNCH_AFTER_BUILD=0
KILL_RUNNING=0
BUILD_VERSION="$(date +%Y%m%d%H%M%S)"
ARCH_INPUT="arm64,x86_64"

ARCHES=()
BUILT_ARCHES=()
BUILT_APPS=()
SIGN_ID="-"

usage() {
  cat <<'EOF'
Usage: bash scripts/build-app-universal.sh [options]

Options:
  --configuration <debug|release>  Build configuration (default: debug)
  --architectures <list>           Comma-separated arch list (default: arm64,x86_64)
                                   Supported: arm64, x86_64
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
    --architectures)
      ARCH_INPUT="${2:-}"
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

normalize_arch() {
  case "$1" in
    arm64|aarch64)
      echo "arm64"
      ;;
    x86_64|amd64)
      echo "x86_64"
      ;;
    *)
      return 1
      ;;
  esac
}

contains_arch() {
  local needle="$1"
  shift
  local candidate
  for candidate in "$@"; do
    if [[ "$candidate" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

resolve_arches() {
  local raw=()
  local token normalized

  if [[ -z "$ARCH_INPUT" ]]; then
    echo "Missing --architectures value" >&2
    exit 1
  fi

  for token in $(echo "$ARCH_INPUT" | tr ',' ' '); do
    if [[ "$token" == "all" ]]; then
      raw+=("arm64" "x86_64")
      continue
    fi
    if ! normalized="$(normalize_arch "$token")"; then
      echo "Unsupported architecture: $token" >&2
      exit 1
    fi
    raw+=("$normalized")
  done

  if [[ "${#raw[@]}" -eq 0 ]]; then
    echo "No architectures resolved from: $ARCH_INPUT" >&2
    exit 1
  fi

  for token in "${raw[@]}"; do
    if [[ ${#ARCHES[@]} -eq 0 ]] || ! contains_arch "$token" "${ARCHES[@]}"; then
      ARCHES+=("$token")
    fi
  done
}

brew_prefix_for_arch() {
  local arch="$1"
  case "$arch" in
    arm64)
      echo "/opt/homebrew"
      ;;
    x86_64)
      echo "/usr/local"
      ;;
    *)
      return 1
      ;;
  esac
}

brew_binary_for_arch() {
  local arch="$1"
  case "$arch" in
    arm64)
      echo "/opt/homebrew/bin/brew"
      ;;
    x86_64)
      echo "/usr/local/bin/brew"
      ;;
    *)
      return 1
      ;;
  esac
}

ensure_brew_for_arch() {
  local arch="$1"
  local brew_bin
  brew_bin="$(brew_binary_for_arch "$arch")"
  if [[ -x "$brew_bin" ]]; then
    return
  fi

  if [[ "$arch" == "x86_64" ]]; then
    cat >&2 <<'EOF'
Missing Intel Homebrew at /usr/local/bin/brew.
Install it first:
  softwareupdate --install-rosetta --agree-to-license
  arch -x86_64 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
Then install x86_64 deps:
  arch -x86_64 /usr/local/bin/brew install liboqs argon2 openssl@3
EOF
  else
    echo "Missing Homebrew at /opt/homebrew/bin/brew." >&2
    echo "Install deps with: brew install liboqs argon2 openssl@3" >&2
  fi
  exit 1
}

configure_arch_environment() {
  local arch="$1"
  local prefix brew_bin oqs_header argon_header oqs_static openssl_lib
  ensure_brew_for_arch "$arch"
  prefix="$(brew_prefix_for_arch "$arch")"
  brew_bin="$(brew_binary_for_arch "$arch")"
  oqs_header="$prefix/include/oqs/oqs.h"
  argon_header="$prefix/include/argon2.h"
  oqs_static="$prefix/lib/liboqs.a"
  openssl_lib="$prefix/opt/openssl@3/lib/libcrypto.dylib"

  if [[ ! -f "$oqs_header" ]]; then
    echo "Missing liboqs header for $arch at $oqs_header" >&2
    echo "Install deps with: arch -$arch $brew_bin install liboqs argon2 openssl@3" >&2
    exit 1
  fi
  if [[ ! -f "$argon_header" ]]; then
    echo "Missing argon2 header for $arch at $argon_header" >&2
    echo "Install deps with: arch -$arch $brew_bin install liboqs argon2 openssl@3" >&2
    exit 1
  fi
  if [[ ! -f "$oqs_static" ]]; then
    echo "Missing liboqs static library for $arch at $oqs_static" >&2
    exit 1
  fi
  if [[ ! -f "$openssl_lib" ]]; then
    echo "Missing OpenSSL libcrypto for $arch at $openssl_lib" >&2
    exit 1
  fi

  local pc_dir="$ROOT_DIR/.build-app-pkgconfig/$arch"
  mkdir -p "$pc_dir"

  cat >"$pc_dir/libargon2.pc" <<PC
prefix=$prefix
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: libargon2
Description: Argon2 password hashing
Version: 0
Libs: -L\${libdir} -largon2
Cflags: -I\${includedir}
PC

  cat >"$pc_dir/liboqs.pc" <<PC
prefix=$prefix
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include
openssl_libdir=$prefix/opt/openssl@3/lib

Name: liboqs
Description: Open Quantum Safe
Version: 0
Libs: -L\${libdir} -loqs -L\${openssl_libdir} -lcrypto
Cflags: -I\${includedir}
PC

  export PKG_CONFIG_PATH="$pc_dir${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  export AEGIRO_OQS_LIB_DIR="$prefix/lib"
  export AEGIRO_OPENSSL_LIB_DIR="$prefix/opt/openssl@3/lib"
}

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

select_sign_identity() {
  if [[ "$FORCE_AD_HOC" -eq 1 ]]; then
    SIGN_ID="-"
    return
  fi
  if [[ -n "$IDENTITY" ]]; then
    SIGN_ID="$IDENTITY"
    return
  fi
  local detected
  detected="$(detect_first_identity || true)"
  if [[ -n "$detected" ]]; then
    SIGN_ID="$detected"
  else
    SIGN_ID="-"
  fi
}

sign_app_bundle() {
  local app_path="$1"
  if [[ "$SIGN_ID" == "-" ]]; then
    codesign --force --deep --timestamp=none --sign - "$app_path"
  else
    codesign --force --deep --timestamp=none --options runtime --sign "$SIGN_ID" "$app_path"
  fi
  codesign --verify --deep --strict --verbose=2 "$app_path"
}

package_app_bundle() {
  local app_path="$1"
  local app_bin="$2"
  local bin_dir="$3"

  rm -rf "$app_path"
  mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
  cp "$app_bin" "$app_path/Contents/MacOS/$APP_EXECUTABLE"

  while IFS= read -r bundle; do
    [[ -z "$bundle" ]] && continue
    cp -R "$bundle" "$app_path/Contents/Resources/$(basename "$bundle")"
  done < <(find "$bin_dir" -maxdepth 1 -type d -name '*.bundle' | sort)

  cat > "$app_path/Contents/Info.plist" <<PLIST
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
  <key>NSFaceIDUsageDescription</key><string>Use biometrics to unlock your vault.</string>
</dict>
</plist>
PLIST

  sign_app_bundle "$app_path"
}

build_for_arch() {
  local arch="$1"
  local scratch_path bin_dir app_bin app_path

  echo "Building ${APP_BUNDLE_NAME}.app (${CONFIG}, ${arch}) from target ${TARGET_NAME}..."
  configure_arch_environment "$arch"

  scratch_path="$ROOT_DIR/.build-app-${arch}-${CONFIG}"
  swift build --product "$TARGET_NAME" -c "$CONFIG" --arch "$arch" --scratch-path "$scratch_path"
  bin_dir="$(swift build --product "$TARGET_NAME" -c "$CONFIG" --arch "$arch" --scratch-path "$scratch_path" --show-bin-path)"
  app_bin="$bin_dir/$APP_EXECUTABLE"
  if [[ ! -x "$app_bin" ]]; then
    echo "Build did not produce executable: $app_bin" >&2
    exit 1
  fi

  mkdir -p "$ROOT_DIR/dist"
  app_path="$ROOT_DIR/dist/${APP_BUNDLE_NAME}-${arch}.app"
  package_app_bundle "$app_path" "$app_bin" "$bin_dir"

  BUILT_ARCHES+=("$arch")
  BUILT_APPS+=("$app_path")
  echo "Built app: $app_path"
}

app_path_for_arch() {
  local target="$1"
  local i
  for ((i=0; i<${#BUILT_ARCHES[@]}; i++)); do
    if [[ "${BUILT_ARCHES[$i]}" == "$target" ]]; then
      echo "${BUILT_APPS[$i]}"
      return 0
    fi
  done
  return 1
}

build_universal_app() {
  local arm_app x86_app source_app
  local arm_exec x86_exec uni_exec

  arm_app="$(app_path_for_arch arm64 || true)"
  x86_app="$(app_path_for_arch x86_64 || true)"
  if [[ -z "$arm_app" || -z "$x86_app" ]]; then
    echo "Skipping universal app: both arm64 and x86_64 builds are required." >&2
    return
  fi

  source_app="$arm_app"
  rm -rf "$CANONICAL_APP_PATH"
  cp -R "$source_app" "$CANONICAL_APP_PATH"

  arm_exec="$arm_app/Contents/MacOS/$APP_EXECUTABLE"
  x86_exec="$x86_app/Contents/MacOS/$APP_EXECUTABLE"
  uni_exec="$CANONICAL_APP_PATH/Contents/MacOS/$APP_EXECUTABLE"

  lipo -create "$arm_exec" "$x86_exec" -output "$uni_exec"
  sign_app_bundle "$CANONICAL_APP_PATH"
  echo "Built universal app: $CANONICAL_APP_PATH"
}

resolve_arches
select_sign_identity

if [[ "$SIGN_ID" == "-" ]]; then
  echo "No signing identity selected/found. Using ad-hoc signing."
else
  echo "Signing with identity: $SIGN_ID"
fi

for arch in "${ARCHES[@]}"; do
  build_for_arch "$arch"
done

if contains_arch "arm64" "${ARCHES[@]}" && contains_arch "x86_64" "${ARCHES[@]}"; then
  build_universal_app
else
  rm -rf "$CANONICAL_APP_PATH"
  cp -R "${BUILT_APPS[0]}" "$CANONICAL_APP_PATH"
  echo "Built app: $CANONICAL_APP_PATH"
fi

echo "---"
echo "Build version: $BUILD_VERSION"
echo "Built architecture bundles:"
for app_path in "${BUILT_APPS[@]}"; do
  echo "  - $app_path"
done
if [[ -d "$CANONICAL_APP_PATH" ]]; then
  echo "  - $CANONICAL_APP_PATH"
fi

if [[ "$SIGN_ID" == "-" ]]; then
  cat <<'EOF'
Warning: ad-hoc signed build.
Touch ID secure keychain storage is expected to be unavailable in this mode.

To enable Touch ID storage:
1) Create a code-signing identity (Apple Development in Xcode, or a local self-signed Code Signing certificate).
2) Re-run with --identity "<identity name>".
3) Verify identities: security find-identity -v -p codesigning
EOF
fi

if [[ "$LAUNCH_AFTER_BUILD" -eq 1 ]]; then
  if [[ "$KILL_RUNNING" -eq 1 ]]; then
    kill_running_instances
  fi
  open -n "$CANONICAL_APP_PATH"
fi

echo "Run: open -n \"$CANONICAL_APP_PATH\""
