#!/bin/sh
set -eu

version=$1
checksum=$2
repository=${3:-eshlox/gh-agent}

printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || {
  echo "version must use MAJOR.MINOR.PATCH" >&2
  exit 1
}
printf '%s\n' "$checksum" | grep -Eq '^[0-9a-f]{64}$' || {
  echo "checksum must be 64 lowercase hexadecimal characters" >&2
  exit 1
}
printf '%s\n' "$repository" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || {
  echo "repository must use OWNER/REPOSITORY" >&2
  exit 1
}

cat <<EOF
class GithubAgentAuth < Formula
  desc "Repository-scoped GitHub App credential broker for macOS"
  homepage "https://github.com/$repository"
  url "https://github.com/$repository/releases/download/v$version/github-agent-auth-macos-arm64.tar.gz"
  sha256 "$checksum"
  version "$version"

  depends_on :macos
  depends_on arch: :arm64

  def install
    bin.install "github-agent-auth"
  end

  test do
    system "/usr/bin/codesign", "--verify", "--deep", "--strict", bin/"github-agent-auth"
    assert_match "Self-test passed", shell_output("#{bin}/github-agent-auth self-test")
  end
end
EOF
