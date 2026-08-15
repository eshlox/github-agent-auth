#!/bin/sh
set -eu

formula=$1
tap_repository=$2
version=$3
formula_path="Formula/github-agent-auth.rb"
branch="release/github-agent-auth-v$version"
release_gh=${RELEASE_GH:-/opt/homebrew/bin/gh}

printf '%s\n' "$tap_repository" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || {
  echo "tap repository must use OWNER/REPOSITORY" >&2
  exit 1
}
printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || {
  echo "version must use MAJOR.MINOR.PATCH" >&2
  exit 1
}
test -x "$release_gh" || {
  echo "Trusted GitHub CLI is unavailable: $release_gh" >&2
  exit 1
}
case "$release_gh" in
  /*) ;;
  *) echo "RELEASE_GH must be an absolute path" >&2; exit 1 ;;
esac

default_branch=$("$release_gh" api "repos/$tap_repository" --jq '.default_branch')
base_sha=$("$release_gh" api "repos/$tap_repository/commits/$default_branch" --jq '.sha')

if "$release_gh" api "repos/$tap_repository/git/ref/heads/$branch" >/dev/null 2>&1; then
  echo "Refusing to replace existing tap branch $branch" >&2
  exit 1
fi

"$release_gh" api "repos/$tap_repository/git/refs" --method POST \
  -f ref="refs/heads/$branch" \
  -f sha="$base_sha" >/dev/null

existing_sha=$("$release_gh" api "repos/$tap_repository/contents/$formula_path" -f ref="$branch" --jq '.sha' 2>/dev/null || true)
content=$(base64 < "$formula" | tr -d '\n')

if [ -n "$existing_sha" ]; then
  "$release_gh" api "repos/$tap_repository/contents/$formula_path" --method PUT \
    -f message="Update github-agent-auth to $version" \
    -f content="$content" \
    -f sha="$existing_sha" \
    -f branch="$branch" >/dev/null
else
  "$release_gh" api "repos/$tap_repository/contents/$formula_path" --method PUT \
    -f message="Add github-agent-auth $version" \
    -f content="$content" \
    -f branch="$branch" >/dev/null
fi

"$release_gh" pr create \
  --repo "$tap_repository" \
  --base "$default_branch" \
  --head "$branch" \
  --title "Update github-agent-auth to $version" \
  --body "Updates AgentAuth for GitHub to the signed and notarized $version release."
