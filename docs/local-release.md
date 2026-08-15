# Local signed release

Use a dedicated, FileVault-protected Apple Silicon Mac. The Developer ID private key
never leaves its login Keychain; GitHub stores no Apple credentials.

This is intentional. GitHub environment secrets are encrypted and commonly used for
CI signing, but a workflow receiving a `.p12` can decrypt or misuse its private key.
The practical indie gold standard is a reviewed CI build plus human-authorized signing
on a dedicated Mac. A hardware-backed signing service is stronger but adds substantial
cost and operational complexity.

## One-time setup

### 1. Install the signing identity

1. Join the [Apple Developer Program](https://developer.apple.com/programs/) and note
   the 10-character **Team ID** under Membership.
2. In Keychain Access, choose **Certificate Assistant > Request a Certificate From a
   Certificate Authority**, enter the account email and a descriptive common name,
   choose **Saved to disk**, and create the CSR on the release Mac.
3. In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/list),
   create a **Developer ID Application** certificate from that CSR. Download and open
   the `.cer` on the same Mac.
4. In Keychain Access > **My Certificates**, confirm the certificate expands to show
   its private key and says it is valid. Leave trust set to **Use System Defaults**.
   Do not export or sync the private key.
5. Confirm the identity:

   ```sh
   security find-identity -v -p codesigning
   ```

   Save the full `Developer ID Application: Name (TEAMID)` text as the signing
   identity.

If Keychain says **Not Trusted** or the command finds zero identities:

1. Under **My Certificates**, expand the Developer ID certificate. Its private key
   must appear underneath. A `.cer` contains no private key; recover the `.p12` from
   the Mac that created the CSR or create a new CSR and certificate on this Mac.
2. Leave the certificate's trust setting at **Use System Defaults**. Never use **Always
   Trust** to hide a broken chain.
3. Install Apple's current Developer ID G2 intermediate from the official
   [Apple Certificate Authority](https://www.apple.com/certificateauthority/) page,
   then run `security find-identity -v -p codesigning` again.

### 2. Install notarization credentials

Prefer a revocable Team Key. Individual Apple Developer enrollment is supported: the
person who enrolled is the Account Holder. Open [App Store Connect](https://appstoreconnect.apple.com/),
not the Apple Developer portal, then go to **Users and Access > Integrations > App
Store Connect API**. If Team Keys are absent, click **Request Access** and wait for
Apple's case-by-case approval.

Create the key with the least practical access:

```text
Name: AgentAuth Notarization
Access: Developer
```

Do not grant Admin or Account Holder access. Team Keys apply to every app and cannot be
restricted to AgentAuth, so the role is the important boundary. An Individual API Key
cannot use `notarytool`.

Download the `.p8` once, record its **Key ID** and **Issuer ID**, and store it in the
release Mac's Keychain:

```sh
xcrun notarytool store-credentials agentauth-notary \
  --key /secure/path/AuthKey_KEYID.p8 \
  --key-id KEYID \
  --issuer ISSUER_ID
```

Verify it, then move the only backup of the `.p8` to encrypted offline storage or
delete it from the Mac:

```sh
xcrun notarytool history --keychain-profile agentauth-notary
```

If Apple has not approved API access, use a dedicated app-specific password instead.
Create `agentauth-notary` under [Apple Account > Sign-In and Security > App-Specific
Passwords](https://account.apple.com/), then store it without putting it in shell
history:

```sh
xcrun notarytool store-credentials agentauth-notary \
  --apple-id "APPLE_ACCOUNT_EMAIL" \
  --team-id "TEAMID"
```

Enter the app-specific password when prompted and run the same `notarytool history`
check. Never use or store the regular Apple Account password. Both credential methods
produce the same `agentauth-notary` profile expected by the release script.

Revoke and replace the API key or app-specific password if it or the signing Mac may be
compromised. Revoke the Developer ID certificate if its private key may be compromised.

### 3. Configure GitHub

1. Protect `main` with reviewed pull requests and required checks. Restrict creation,
   update, and deletion of `v*` tags.
2. Protect the `eshlox/homebrew-tap` default branch; formula updates must use reviewed
   pull requests.
3. Authenticate `gh` on the release Mac with only the repository and tap permissions
   needed to create releases, branches, contents, and pull requests:

   ```sh
   gh auth login -h github.com
   gh auth status
   ```

4. Configure a Git signing key for the release tag. This is separate from the Apple
   Developer ID identity. For an SSH signing key registered with GitHub:

   ```sh
   git config user.signingkey /absolute/path/to/id_ed25519.pub
   git config gpg.format ssh
   git config commit.gpgsign true
   git config tag.gpgsign true
   ```

   Replace any `_PUBLIC_KEY_PATH_PLACEHOLDER_` value. The release script stops before
   building if the configured SSH public key is unavailable.

## Release `vX.Y.Z`

Merge the release commit to `main`, wait for its required checks, update a clean local
`main`, and run one command:

```sh
git switch main
git pull --ff-only origin main
scripts/release-local.sh vX.Y.Z
```

The script requires exactly one valid Developer ID Application identity and the
`agentauth-notary` Keychain profile. It then fails closed unless the worktree is clean,
local `main` exactly matches `origin/main`, and the version is unused. It builds and
signs arm64 output, notarizes it, verifies the signature and Gatekeeper, runs the
self-test, creates and pushes a signed tag, publishes the archive and checksum, and
opens the Homebrew tap pull request. It never merges that pull request.

If it stops before pushing the tag, fix the reported problem, archive or remove `dist`,
and rerun it. If it stops after pushing the tag, inspect the published state before
continuing; never replace a release tag.

## Verify the public release

From a clean Apple Silicon macOS account:

```sh
brew install eshlox/tap/github-agent-auth
binary="$(brew --prefix)/bin/github-agent-auth"
codesign --verify --deep --strict --verbose=2 "$binary"
spctl --assess --type execute --verbose=2 "$binary"
github-agent-auth self-test
```

Then use a disposable private repository and test GitHub App:

```sh
cd /path/to/disposable-repository
github-agent-auth setup
github-agent-auth doctor
git fetch
git push --dry-run origin HEAD:refs/heads/agent/release-verification
gh pr list
sudo stat -f '%Su %Sp %N' \
  "/Library/Application Support/AgentAuth for GitHub/config.json" \
  "/Library/Application Support/AgentAuth for GitHub/github-app-private-key.pem"
github-agent-auth uninstall
```

Confirm that the configuration is root-owned and not group/other-writable, the private
key is root-owned `0600`, the LaunchDaemon stops after uninstall, and the privileged
files, wrappers, socket, Git rewrite, and key are removed. Delete the disposable GitHub
App afterward. Do not announce the release if installation, signature, Gatekeeper,
self-test, brokered Git/`gh`, ownership, or uninstall verification fails.
