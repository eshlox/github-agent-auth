#!/bin/sh

set -eu

repository=${GITHUB_AGENT_AUTH_REPOSITORY:-https://github.com/eshlox/github-agent-auth.git}
ref=${GITHUB_AGENT_AUTH_REF:-main}
install_directory=${GITHUB_AGENT_AUTH_INSTALL_DIR:-"$HOME/.local/bin"}
developer_directory=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
temporary_directory=
pending_binary="$install_directory/github-agent-auth.new"

cleanup() {
  if [ -n "$temporary_directory" ] && [ -d "$temporary_directory" ]; then
    rm -rf "$temporary_directory"
  fi
  rm -f "$pending_binary"
}

trap cleanup EXIT HUP INT TERM

[ "$(uname -s)" = Darwin ] || { echo "AgentAuth requires macOS." >&2; exit 1; }
[ "$(uname -m)" = arm64 ] || { echo "AgentAuth requires Apple Silicon." >&2; exit 1; }

for command in git swift xcode-select; do
  command -v "$command" >/dev/null 2>&1 || { echo "Missing required command: $command" >&2; exit 1; }
done

xcode-select -p >/dev/null 2>&1 || {
  echo "Install Xcode Command Line Tools with: xcode-select --install" >&2
  exit 1
}

[ -d "$developer_directory" ] || {
  echo "Xcode was not found at $developer_directory. Set DEVELOPER_DIR to its developer directory." >&2
  exit 1
}

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/github-agent-auth.XXXXXX")
source_directory="$temporary_directory/source"
build_directory="$temporary_directory/build"

git init -q "$source_directory"
git -C "$source_directory" remote add origin "$repository"
git -C "$source_directory" fetch --depth 1 origin "$ref"
git -C "$source_directory" checkout -q --detach FETCH_HEAD
commit=$(git -C "$source_directory" rev-parse HEAD)

echo "Building AgentAuth from commit $commit"
DEVELOPER_DIR="$developer_directory" swift build -c release \
  --package-path "$source_directory" \
  --scratch-path "$build_directory"
binary_directory=$(DEVELOPER_DIR="$developer_directory" swift build -c release \
  --package-path "$source_directory" \
  --scratch-path "$build_directory" \
  --show-bin-path)
binary="$binary_directory/github-agent-auth"

/usr/bin/codesign --verify --strict "$binary"
"$binary" self-test

mkdir -p "$install_directory"
/usr/bin/install -m 0755 "$binary" "$pending_binary"
mv -f "$pending_binary" "$install_directory/github-agent-auth"

echo "Installed $install_directory/github-agent-auth"
echo "Next:"
echo "  export PATH=\"$install_directory:\$PATH\""
echo "  cd /path/to/repository"
echo "  github-agent-auth setup"
