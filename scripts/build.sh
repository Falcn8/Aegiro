#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

BUILD_COMMIT="$(git rev-parse --short=7 HEAD 2>/dev/null || echo "unknown")"
if ! git diff --quiet --ignore-submodules -- || ! git diff --cached --quiet --ignore-submodules --; then
  BUILD_COMMIT="${BUILD_COMMIT}-dirty"
fi
BUILD_DATE="$(date -u +%F)"
BUILD_INFO_FILE="$ROOT_DIR/Sources/AegiroCLI/BuildInfo.generated.swift"
BUILD_INFO_BACKUP="$(mktemp)"
BUILD_INFO_HAD_FILE=0
if [[ -f "$BUILD_INFO_FILE" ]]; then
  cp "$BUILD_INFO_FILE" "$BUILD_INFO_BACKUP"
  BUILD_INFO_HAD_FILE=1
fi
restore_build_info() {
  if [[ "$BUILD_INFO_HAD_FILE" -eq 1 ]]; then
    cp "$BUILD_INFO_BACKUP" "$BUILD_INFO_FILE"
  else
    rm -f "$BUILD_INFO_FILE"
  fi
  rm -f "$BUILD_INFO_BACKUP"
}
trap restore_build_info EXIT
cat >"$BUILD_INFO_FILE" <<EOF
let AEGIRO_BUILD_COMMIT = "$BUILD_COMMIT"
let AEGIRO_BUILD_DATE = "$BUILD_DATE"
EOF
echo "Stamped build metadata: commit=$BUILD_COMMIT date=$BUILD_DATE"

echo "Checking dependencies (brew)..."
if ! pkg-config --exists liboqs 2>/dev/null; then
  if [[ ! -f /opt/homebrew/include/oqs/oqs.h ]]; then
    echo "Missing liboqs headers (brew install liboqs)" >&2
    exit 1
  fi
fi
if ! pkg-config --exists libargon2 2>/dev/null; then
  if [[ ! -f /opt/homebrew/include/argon2.h ]]; then
    echo "Missing argon2 headers (brew install argon2)" >&2
    exit 1
  fi
fi

PC_DIR="$ROOT_DIR/ThirdParty/pkgconfig"
mkdir -p "$PC_DIR"

# Write .pc shims (override brew to ensure link flags)
cat >"$PC_DIR/libargon2.pc" <<'PC'
prefix=/opt/homebrew
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include

Name: libargon2
Description: Argon2 password hashing
Version: 0
Libs: -L${libdir} -largon2
Cflags: -I${includedir}
PC
cat >"$PC_DIR/liboqs.pc" <<'PC'
prefix=/opt/homebrew
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include

Name: liboqs
Description: Open Quantum Safe
Version: 0
Libs: -L${libdir} -loqs -L/opt/homebrew/opt/openssl@3/lib -lcrypto
Cflags: -I${includedir}
PC

export PKG_CONFIG_PATH="$PC_DIR${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

echo "Building release..."
swift build -c release
BIN=".build/release/aegiro-cli"
if [[ ! -x "$BIN" ]]; then
  echo "Build did not produce $BIN" >&2
  exit 1
fi

mkdir -p dist
cp "$BIN" dist/aegiro-cli

ARCHIVE="dist/aegiro-cli-macos-arm64.tar.gz"
tar -C dist -czf "$ARCHIVE" aegiro-cli

echo "---"
echo "Built: $ARCHIVE"
shasum -a 256 "$ARCHIVE" || true
echo "Done."
