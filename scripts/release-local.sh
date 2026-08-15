#!/bin/sh
set -eu

repository=eshlox/github-agent-auth
tap_repository=eshlox/homebrew-tap
notary_profile=agentauth-notary
script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_directory=$(dirname "$script_directory")
output_directory="$repository_directory/dist"

usage() {
  echo "Usage: scripts/release-local.sh vMAJOR.MINOR.PATCH" >&2
  exit 1
}

test "$#" -eq 1 || usage
version=$1
printf '%s\n' "$version" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || usage
release_version=${version#v}

for command in git gh security codesign xcrun spctl ditto shasum; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Required command is unavailable: $command" >&2
    exit 1
  }
done

test "$(uname -s)" = Darwin || {
  echo "Releases require macOS" >&2
  exit 1
}
test "$(uname -m)" = arm64 || {
  echo "Releases require an Apple Silicon Mac" >&2
  exit 1
}

cd "$repository_directory"
test ! -e "$output_directory" || {
  echo "Remove or archive the existing release output first: $output_directory" >&2
  exit 1
}
test -z "$(git status --porcelain)" || {
  echo "Release worktree must be clean" >&2
  exit 1
}

gh auth status -h github.com >/dev/null
git fetch origin main --tags
test "$(git branch --show-current)" = main || {
  echo "Release from the main branch" >&2
  exit 1
}
test "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" || {
  echo "Local main must exactly match origin/main" >&2
  exit 1
}
signing_key=$(git config --get user.signingkey || true)
test -n "$signing_key" || {
  echo "Git user.signingkey is required for the signed release tag" >&2
  exit 1
}
if test "$(git config --get gpg.format || true)" = ssh; then
  case "$signing_key" in
    key::*) ;;
    *)
      test -r "$signing_key" || {
        echo "Git SSH signing key is unavailable: $signing_key" >&2
        exit 1
      }
      ;;
  esac
fi
git rev-parse -q --verify "refs/tags/$version" >/dev/null 2>&1 && {
  echo "Tag already exists: $version" >&2
  exit 1
}
gh release view "$version" --repo "$repository" >/dev/null 2>&1 && {
  echo "GitHub release already exists: $version" >&2
  exit 1
}
gh api "repos/$tap_repository/git/ref/heads/release/github-agent-auth-$version" \
  >/dev/null 2>&1 && {
  echo "Homebrew release branch already exists: release/github-agent-auth-$version" >&2
  exit 1
}

identities=$(security find-identity -v -p codesigning | \
  sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p')
identity_count=$(printf '%s\n' "$identities" | grep -c . || true)
test "$identity_count" -eq 1 || {
  echo "Expected exactly one valid Developer ID Application identity; found $identity_count" >&2
  security find-identity -v -p codesigning >&2
  exit 1
}
CODESIGN_IDENTITY=$identities
APPLE_TEAM_ID=$(printf '%s\n' "$CODESIGN_IDENTITY" | \
  sed -n 's/.*(\([A-Z0-9][A-Z0-9]*\))$/\1/p')
test "${#APPLE_TEAM_ID}" -eq 10 || {
  echo "Could not read the 10-character Team ID from the signing identity" >&2
  exit 1
}
export CODESIGN_IDENTITY APPLE_TEAM_ID

xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null

echo "Building and signing $version with $CODESIGN_IDENTITY"
"$script_directory/build-release.sh" "$output_directory"

ditto -c -k --keepParent \
  "$output_directory/package/github-agent-auth" \
  "$output_directory/github-agent-auth-notarization.zip"
xcrun notarytool submit "$output_directory/github-agent-auth-notarization.zip" \
  --keychain-profile "$notary_profile" \
  --wait
codesign --verify --deep --strict --verbose=2 \
  "$output_directory/package/github-agent-auth"
spctl --assess --type execute --verbose=2 \
  "$output_directory/package/github-agent-auth"
"$output_directory/package/github-agent-auth" self-test

git tag -s "$version" -m "Release $version"
git push origin "$version"
gh release create "$version" \
  "$output_directory/github-agent-auth-macos-arm64.tar.gz" \
  "$output_directory/github-agent-auth-macos-arm64.tar.gz.sha256" \
  --repo "$repository" \
  --generate-notes \
  --verify-tag

checksum=$(cut -d ' ' -f 1 \
  "$output_directory/github-agent-auth-macos-arm64.tar.gz.sha256")
formula="$output_directory/github-agent-auth.rb"
"$script_directory/render-homebrew-formula.sh" \
  "$release_version" "$checksum" "$repository" > "$formula"
"$script_directory/publish-homebrew-formula.sh" \
  "$formula" "$tap_repository" "$release_version"

echo "Release $version published; review and merge the Homebrew tap pull request"
