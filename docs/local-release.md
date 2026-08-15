# Local signed release

Release from a dedicated, FileVault-protected Apple Silicon Mac. Keep the Developer ID
private key in that Mac's login Keychain. Do not upload Apple credentials to GitHub.

The release script expects one Developer ID Application identity and a notarytool profile
named `agentauth-notary`.

## One-time setup

### Developer ID

1. Join the [Apple Developer Program](https://developer.apple.com/programs/).
2. Create a Certificate Signing Request in Keychain Access on the release Mac.
3. Create a Developer ID Application certificate from that CSR in
   [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/list).
4. Install the certificate on the same Mac.
5. Keep certificate trust set to **Use System Defaults**.
6. Verify the identity:

```sh
security find-identity -v -p codesigning
```

The certificate must appear under **My Certificates** with its private key. If the chain
is incomplete, install Apple's current Developer ID G2 intermediate from the
[Apple Certificate Authority](https://www.apple.com/certificateauthority/) page.

### Notarization

Prefer a revocable Team Key from **App Store Connect > Users and Access > Integrations >
App Store Connect API**. Use the Developer role. Team Keys cannot be limited to one app.

```sh
xcrun notarytool store-credentials agentauth-notary \
  --key /secure/path/AuthKey_KEYID.p8 \
  --key-id KEYID \
  --issuer ISSUER_ID

xcrun notarytool history --keychain-profile agentauth-notary
```

Move the only `.p8` backup to encrypted offline storage or delete it from the Mac.

If Team Keys are unavailable, create a dedicated Apple app-specific password and store it
without putting it in shell history:

```sh
xcrun notarytool store-credentials agentauth-notary \
  --apple-id "APPLE_ACCOUNT_EMAIL" \
  --team-id TEAMID

xcrun notarytool history --keychain-profile agentauth-notary
```

Revoke notarization credentials and the Developer ID certificate if the key or release
Mac may be compromised.

### GitHub

Protect `main`, release tags, and the default branch of `eshlox/homebrew-tap`. Require
reviewed pull requests and required checks. Do not let the GitHub App bypass rulesets.

Authenticate the release operator:

```sh
/opt/homebrew/bin/gh auth login -h github.com
/opt/homebrew/bin/gh auth status
```

Release scripts use `/opt/homebrew/bin/gh`, not the restricted AgentAuth `gh` shim. Set
`RELEASE_GH` to another absolute trusted path when needed:

```sh
export RELEASE_GH=/absolute/path/to/gh
"$RELEASE_GH" auth status -h github.com
```

Configure signed release tags. Example with an SSH signing key registered on GitHub:

```sh
git config user.signingkey /absolute/path/to/id_ed25519.pub
git config gpg.format ssh
git config commit.gpgsign true
git config tag.gpgsign true
```

Do not leave `_PUBLIC_KEY_PATH_PLACEHOLDER_` in Git configuration.

## Publish `vX.Y.Z`

Start from a clean `main` that exactly matches `origin/main`:

```sh
git switch main
git pull --ff-only origin main
scripts/release-local.sh vX.Y.Z
```

The script:

1. Verifies the branch, worktree, remote commit, signing identity, notary profile, and
   unused version.
2. Builds an Apple Silicon release.
3. Signs, notarizes, and Gatekeeper-checks it.
4. Runs the security self-test.
5. Creates and pushes a signed tag.
6. Publishes the archive and checksum.
7. Opens a Homebrew tap pull request without merging it.

If it fails before pushing the tag, fix the error, remove or archive `dist`, and rerun.
If it fails after pushing the tag, inspect remote state first. Never replace a release
tag.

## Verify the public release

Use a clean macOS account:

```sh
brew install eshlox/tap/github-agent-auth
binary="$(brew --prefix)/bin/github-agent-auth"
codesign --verify --deep --strict --verbose=2 "$binary"
spctl --assess --type execute --verbose=2 "$binary"
github-agent-auth self-test
```

Use a disposable private repository and GitHub App:

```sh
cd /path/to/disposable-repository
github-agent-auth setup
github-agent-auth doctor
github-agent-auth update-gh
git fetch
git push --dry-run origin HEAD:refs/heads/agent/release-verification
gh pr list

sudo stat -f '%Su %Sp %N' \
  "/Library/Application Support/AgentAuth for GitHub/config.json" \
  "/Library/Application Support/AgentAuth for GitHub/github-app-private-key.pem" \
  /Library/PrivilegedHelperTools/github-agent-auth \
  /Library/PrivilegedHelperTools/agentauth-gh

github-agent-auth uninstall
brew uninstall github-agent-auth
```

Confirm:

- The configuration and privileged executables are root-owned and not writable by group
  or others.
- The App key is root-owned with mode `0600`.
- `update-gh` requires administrator approval.
- Git and supported `gh` commands work.
- Uninstall removes the daemon, worker account, privileged files, key, logs, socket,
  wrappers, Git rewrite, and setup's shell PATH block.

Delete the disposable GitHub App. Do not announce the release if any check fails.
