# AgentAuth for GitHub

A dependency-free, macOS-native GitHub App credential broker for semi-trusted
development machines. Normal `git pull`, `git push`, and `gh pr create` workflows
remain unchanged while credentials are limited to explicitly allowed repositories.

AgentAuth for GitHub is an independent project and is not affiliated with or endorsed
by GitHub. The command and Homebrew formula remain `github-agent-auth`. Published
releases support Apple Silicon Macs only.

## Fast installation

After the first signed release and Homebrew tap are published:

```sh
brew install eshlox/tap/github-agent-auth
cd ~/projects/my-repository
github-agent-auth setup
```

`setup` detects the current HTTPS GitHub remote and opens GitHub for two confirmations:

1. Create a private GitHub App with a predefined minimal permission profile.
2. Select repositories and install the App.

The GitHub App Manifest flow returns the App ID and private key directly to the CLI.
The key is validated in memory and stored in macOS Keychain; it is never written as a
PEM file. The installation ID and selected repository are verified through the GitHub
API before local configuration is saved.

For read-only CI inspection, opt in explicitly:

```sh
github-agent-auth setup --permissions ci-read
```

For an App owned by an organization instead of your personal account:

```sh
github-agent-auth setup --organization my-organization
```

## Build from source

Until the Homebrew tap has a published release:

```sh
swift build -c release
mkdir -p "$HOME/.local/bin"
install -m 755 .build/release/github-agent-auth "$HOME/.local/bin/github-agent-auth"
cd ~/projects/my-repository
github-agent-auth setup
```

The transparent `gh` wrapper is installed at `~/.local/bin/gh`. Ensure that directory
appears before the real GitHub CLI in `PATH`:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

## Commands

```sh
github-agent-auth setup
github-agent-auth repo add
github-agent-auth repo remove
github-agent-auth permissions
github-agent-auth permissions set ci-read
github-agent-auth list
github-agent-auth status
github-agent-auth doctor
github-agent-auth self-test
github-agent-auth uninstall --delete-key
```

Run `repo add` or `repo remove` inside the affected repository. An explicit repository
can be supplied with `--repository OWNER/REPOSITORY`.

The previous manual setup remains available for existing Apps:

```sh
github-agent-auth setup \
  --app-id 123456 \
  --private-key ~/Downloads/app.private-key.pem \
  --gh-binary /opt/homebrew/bin/gh

github-agent-auth add-installation \
  --owner org-a --installation-id 111111 \
  --repositories frontend,backend
```

Manual setup defaults to the `core` local token permission cap. Select the read-only CI
profile explicitly when needed:

```sh
github-agent-auth setup \
  --app-id 123456 \
  --private-key ~/Downloads/app.private-key.pem \
  --permissions ci-read
```

Configurations created by an earlier version may still have no local cap. Run
`github-agent-auth permissions set core` once to secure those existing configurations.

## Uninstall

Run the broker's uninstall command before removing the Homebrew package so the command
is still available to stop the LaunchAgent and clean up its configuration:

```sh
github-agent-auth uninstall --delete-key
brew uninstall github-agent-auth
```

`--delete-key` removes the GitHub App private key from macOS Keychain. Omit the flag if
you intentionally want to preserve the key for a later reinstall:

```sh
github-agent-auth uninstall
```

The command stops and removes the LaunchAgent, socket, local configuration, transparent
`~/.local/bin/gh` wrapper, and the Git credential helper entry created by this tool. It
does not remove Git's `credential.https://github.com.useHttpPath` setting because that
setting is not secret and may be used by another credential helper.

For a source installation, remove the installed executable after running the broker
cleanup:

```sh
rm "$HOME/.local/bin/github-agent-auth"
```

Local uninstall does not delete the GitHub App or its repository installation. For full
removal, open **GitHub Settings → Developer settings → GitHub Apps**, select the App,
uninstall it from its accounts, and delete the App registration. If setup added
`~/.local/bin` to your shell profile, remove the `# Added by github-agent-auth` block
only when no other tools rely on that directory.

If the executable has already been removed, clean up the local installation manually:

```sh
for label in net.eshlox.github-agent-auth com.example.github-auth-broker; do
  plist="$HOME/Library/LaunchAgents/$label.plist"
  launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
  rm -f "$plist"
done
wrapper_target=$(readlink "$HOME/.local/bin/gh" 2>/dev/null || true)
case "$wrapper_target" in *github-agent-auth) rm "$HOME/.local/bin/gh" ;; esac
helper=$(git config --global --get credential.https://github.com.helper 2>/dev/null || true)
case "$helper" in *github-agent-auth*) git config --global --unset credential.https://github.com.helper ;; esac
rm -rf "$HOME/Library/Application Support/github-auth-broker"
```

Manual cleanup intentionally leaves the Keychain private key in place because deleting
the wrong credential is irreversible. Delete the `net.eshlox.github-agent-auth` generic
password in Keychain Access only after confirming its account is the expected
`github-app-private-key:APP_ID`. Older installations used the
`com.example.github-auth-broker` service name.

## Security boundary

- The only Git host is exactly `github.com`; authenticated API calls use only the
  compiled-in `https://api.github.com` origin and refuse redirects.
- Every repository must appear explicitly in the local configuration, and installation
  tokens request exactly one repository.
- The App private key uses Keychain Services with no filesystem fallback. Installation
  tokens are cached only in broker memory.
- Manifest and installation callbacks bind only to `127.0.0.1`, use an unpredictable
  state value, expire after ten minutes, and verify the installation with GitHub.
- The `gh` child environment removes existing GitHub token variables before injecting
  its temporary token.

The default `core` profile grants Contents read/write, Pull requests read/write, and
Metadata read. The optional `ci-read` profile additionally grants Actions, Checks, and
Commit statuses read-only. Every token request includes the configured local profile, so
later GitHub-side permission expansion does not automatically broaden broker tokens.
GitHub App permissions remain the outer limit. Do not add Actions write, Workflows,
Deployments, Environments, Administration, or Secrets access.

Same-user malware can invoke the broker for allowed repositories. Protect default
branches with GitHub rulesets and never put the App on a bypass list.

Configuration lives at
`~/Library/Application Support/github-auth-broker/config.json` with mode `0600`.
The LaunchAgent and socket are user-owned; no `sudo`, PAT, SSH key, or GitHub OAuth
login is required.

## Releasing

Releases are built, Developer ID-signed, notarized, verified, and published manually
from a dedicated Apple Silicon Mac. Apple credentials and the Developer ID private key
are never stored in GitHub. Follow the [local signed release](docs/local-release.md)
procedure.
