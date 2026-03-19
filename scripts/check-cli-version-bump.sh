#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

CLI_DIR="Sources/AegiroCLI"
VERSION_FILE="$CLI_DIR/main.swift"
VERSION_SYMBOL="AEGIRO_CLI_VERSION"

base_ref="${1:-}"

usage() {
  cat <<'USAGE'
Usage:
  bash scripts/check-cli-version-bump.sh [<base-ref>]

Behavior:
  - If files under Sources/AegiroCLI did not change, exits 0.
  - If files under Sources/AegiroCLI changed, requires the CLI version constant
    (AEGIRO_CLI_VERSION in Sources/AegiroCLI/main.swift) to be updated.

Examples:
  bash scripts/check-cli-version-bump.sh HEAD~1
  bash scripts/check-cli-version-bump.sh origin/main
USAGE
}

if [[ "${base_ref:-}" == "--help" || "${base_ref:-}" == "-h" ]]; then
  usage
  exit 0
fi

ref_exists() {
  local ref="$1"
  git cat-file -e "${ref}^{commit}" >/dev/null 2>&1
}

resolve_base_ref() {
  local requested="$1"
  if [[ -n "$requested" ]]; then
    if ref_exists "$requested"; then
      echo "$requested"
      return 0
    fi
    echo "Warning: base ref '$requested' not found. Falling back to HEAD~1." >&2
  fi

  if ref_exists "HEAD~1"; then
    echo "HEAD~1"
    return 0
  fi

  echo ""
  return 0
}

extract_version() {
  local source="$1"
  local line
  line=$(printf '%s\n' "$source" | sed -nE "s/^[[:space:]]*let[[:space:]]+${VERSION_SYMBOL}[[:space:]]*=[[:space:]]*\"([^\"]+)\".*/\1/p" | head -n1 || true)
  printf '%s' "$line"
}

resolved_base="$(resolve_base_ref "$base_ref")"
if [[ -z "$resolved_base" ]]; then
  echo "No comparable base commit found; skipping CLI version bump guard."
  exit 0
fi

range="${resolved_base}..HEAD"

if ! git diff --name-only "$range" -- "$CLI_DIR" | grep -q .; then
  echo "No changes detected under $CLI_DIR; CLI version bump check not required."
  exit 0
fi

if ! git diff -U0 "$range" -- "$VERSION_FILE" | grep -Eq "^[+-].*let[[:space:]]+${VERSION_SYMBOL}[[:space:]]*="; then
  echo "ERROR: CLI files changed under $CLI_DIR, but $VERSION_SYMBOL was not updated in $VERSION_FILE." >&2
  echo "Please bump $VERSION_SYMBOL when making CLI changes." >&2
  exit 1
fi

old_file=$(git show "${resolved_base}:${VERSION_FILE}" 2>/dev/null || true)
new_file=$(git show "HEAD:${VERSION_FILE}" 2>/dev/null || true)
old_version="$(extract_version "$old_file")"
new_version="$(extract_version "$new_file")"

if [[ -z "$new_version" ]]; then
  echo "ERROR: Could not parse $VERSION_SYMBOL from HEAD:$VERSION_FILE." >&2
  exit 1
fi

if [[ -n "$old_version" && "$old_version" == "$new_version" ]]; then
  echo "ERROR: $VERSION_SYMBOL line changed, but version value stayed '$new_version'." >&2
  echo "Please bump the version value for CLI changes." >&2
  exit 1
fi

echo "CLI version bump guard passed: ${old_version:-<none>} -> $new_version"
