#!/bin/sh
set -eu

output_directory=${1:-dist}
scratch_directory=${SWIFT_BUILD_PATH:-.build-release}
umask 022

if [ -e "$output_directory" ]; then
  echo "Release output directory already exists: $output_directory" >&2
  exit 1
fi

if [ -z "${CODESIGN_IDENTITY:-}" ]; then
  echo "CODESIGN_IDENTITY is required for release builds" >&2
  exit 1
fi
case "$CODESIGN_IDENTITY" in
  "Developer ID Application:"*) ;;
  *) echo "CODESIGN_IDENTITY must be a Developer ID Application identity" >&2; exit 1 ;;
esac
if [ -z "${APPLE_TEAM_ID:-}" ]; then
  echo "APPLE_TEAM_ID is required to verify the signing certificate" >&2
  exit 1
fi

build_architecture() {
  architecture=$1
  architecture_scratch="$scratch_directory/$architecture"
  swift build \
    --configuration release \
    --arch "$architecture" \
    --scratch-path "$architecture_scratch" 1>&2
  swift build \
    --configuration release \
    --arch "$architecture" \
    --scratch-path "$architecture_scratch" \
    --show-bin-path
}

arm64_directory=$(build_architecture arm64)

mkdir -p "$output_directory/package"
cp "$arm64_directory/github-agent-auth" "$output_directory/package/github-agent-auth"
chmod 755 "$output_directory/package/github-agent-auth"

codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" \
  "$output_directory/package/github-agent-auth"
codesign --verify --deep --strict --verbose=2 "$output_directory/package/github-agent-auth"
signature=$(codesign --display --verbose=4 "$output_directory/package/github-agent-auth" 2>&1)
printf '%s\n' "$signature" | grep -F "Authority=Developer ID Application:" >/dev/null
printf '%s\n' "$signature" | grep -F "TeamIdentifier=$APPLE_TEAM_ID" >/dev/null
test "$(lipo -archs "$output_directory/package/github-agent-auth")" = "arm64"

COPYFILE_DISABLE=1 tar -C "$output_directory/package" -czf "$output_directory/github-agent-auth-macos-arm64.tar.gz" github-agent-auth
shasum -a 256 "$output_directory/github-agent-auth-macos-arm64.tar.gz" \
  > "$output_directory/github-agent-auth-macos-arm64.tar.gz.sha256"
