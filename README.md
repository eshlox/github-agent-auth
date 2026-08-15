# AgentAuth for GitHub

A macOS-native GitHub App broker that lets semi-trusted coding agents use selected
GitHub repositories without receiving a GitHub credential.

AgentAuth is independent and is not affiliated with or endorsed by GitHub. The CLI and
Homebrew formula are named `github-agent-auth`. Published releases support Apple
Silicon Macs only.

## Install

After the first signed release is available:

```sh
brew install eshlox/tap/github-agent-auth
cd ~/projects/my-repository
github-agent-auth setup
```

Setup opens GitHub for two confirmations:

1. Create a private GitHub App with the selected minimal permission profile.
2. Install it on the repository selected during setup.

The final installation step asks for macOS administrator approval. It installs a
root-owned LaunchDaemon, hidden non-login `_github-agent-auth` worker account,
configuration, GitHub App private key, and root-owned protected copy of the GitHub CLI.
No GitHub credential is stored in the user's account or returned through the broker
socket.

After setup, existing commands remain unchanged:

```sh
git fetch
git pull
git push origin agent/my-change
gh pr create --head agent/my-change --title "My change" --body "Description"
gh pr list
```

`~/.local/bin` must be at the front of `PATH`. Setup offers to configure this.

## How it works

For GitHub HTTPS remotes, Git invokes the `git-remote-agentauth` shim through an
`insteadOf` URL rule. The shim and broker expose only Git's `stateless-connect`
transport. The root-owned broker runs Git's HTTPS transport as a hidden, dedicated
`_github-agent-auth` account with a short-lived, single-repository installation token and streams
the Git protocol back to the ordinary user-owned Git process. The privileged transport
uses `GIT_DIR=/dev/null`, so it does
not read or modify the working tree or object database.

The `gh` shim sends an allowlisted command and repository identity to the broker. The
broker runs a root-owned copy of GitHub CLI as `_github-agent-auth`, with an empty environment,
isolated config, disabled prompts, a fixed repository, and a short-lived installation
token. Arbitrary API calls, aliases, extensions, merge commands, web/editor flows, repository overrides,
and file-input flags are rejected.

The broker accepts only the UID recorded during setup, verified from the Unix socket by
the kernel. Its configuration cannot be changed without `sudo`. Allow and deny decisions
are written without arguments or credentials to `/var/log/github-agent-auth.log`.

## Supported `gh` commands

```text
gh repo view
gh pr list|status|view|checks|diff
gh pr create|comment|review|close|reopen|ready
```

`gh pr create` requires explicit `--head`, `--title`, and `--body`. This prevents the
privileged process from reading commit messages, editor state, or arbitrary files to
construct the pull request. Pull-request merging is intentionally excluded; merge with
a reviewed GitHub UI workflow or another separately authorized identity.
`gh pr checks` additionally requires the `ci-read` permission profile.

## Permissions and repositories

The default `core` token cap requests:

- Contents read/write
- Pull requests read/write
- Metadata read

Read-only CI inspection is opt-in:

```sh
github-agent-auth setup --permissions ci-read
# or later
github-agent-auth permissions set ci-read
```

That profile additionally requests Actions, Checks, and Commit statuses read-only. The
local profile is sent on every token request, so expanding the GitHub App later does not
automatically expand broker tokens.

Add or remove repositories explicitly:

```sh
cd ~/projects/another-repository
github-agent-auth repo add
github-agent-auth repo remove
github-agent-auth list
```

Repository changes and permission changes require administrator approval because the
configuration is root-owned.

## Commands

```sh
github-agent-auth setup
github-agent-auth install-service
github-agent-auth update-gh
github-agent-auth repo add|remove
github-agent-auth permissions
github-agent-auth permissions set core|ci-read
github-agent-auth list
github-agent-auth status
github-agent-auth doctor
github-agent-auth self-test
github-agent-auth uninstall
```

Run `install-service` after upgrading `github-agent-auth`. It replaces the privileged
broker and protected GitHub CLI, then restarts the daemon. After upgrading the separate
user-installed GitHub CLI, refresh only the protected runtime:

```sh
brew upgrade gh
github-agent-auth update-gh
```

`update-gh` finds the real `gh` behind the AgentAuth wrapper, copies it atomically into
`/Library/PrivilegedHelperTools/agentauth-gh`, verifies that its macOS code signature is
structurally valid, and requires administrator approval. The broker never executes the
user-owned source with a token. Because Homebrew binaries are user-owned and commonly
ad-hoc signed, this is an explicit administrator trust decision rather than proof of the
binary's publisher. Install `gh` only from a source you trust and update it before running
`update-gh`.

## Security boundary

- GitHub is the only supported host. Authenticated API requests use the compiled-in
  `https://api.github.com` origin and refuse redirects.
- Each token request names exactly one explicitly configured repository and includes
  the local permission cap.
- The App private key is a root-owned `0600` file. Installation tokens exist only in
  root-process memory and isolated service-account child environments, never under the agent UID.
- The user-facing socket never returns keys, tokens, authorization headers, or child
  environment variables.
- Broker tool paths are absolute. Git's transport is supplied by root-owned Xcode
  Command Line Tools; GitHub CLI is copied into a root-owned location during install.
- `gh` uses a strict built-in command allowlist rather than passthrough classification.
- Configuration mutations require both root and a matching `SUDO_UID`.
- Manifest callbacks bind only to `127.0.0.1`, use 256-bit random state, expire after
  ten minutes, and verify the installation and repository with GitHub.

AgentAuth limits GitHub credentials; it is not a general agent sandbox. An agent can
still modify local files, create commits, and request any operation deliberately
allowed above. Protect default branches with GitHub rulesets, require reviewed pull
requests, and never put the App on a bypass list. Root compromise, kernel compromise,
and vulnerabilities in the small root broker are outside the boundary. Git and GitHub
CLI process untrusted network data without root or agent-user privileges.

See [SECURITY.md](SECURITY.md) for the complete threat model, credential flows, security
decisions, update trust model, and residual risks.

## Build from source

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release
cd ~/projects/my-repository
.build/release/github-agent-auth setup
```

Setup copies the current executable into `/Library/PrivilegedHelperTools`; do not delete
or replace the source binary while the administrator prompt is active. Public releases
are Developer ID signed and notarized. Prefer them over source builds for routine use.

## Uninstall

Run uninstall before removing the package:

```sh
github-agent-auth uninstall
brew uninstall github-agent-auth
```

Uninstall removes the LaunchDaemon, privileged broker and protected GitHub CLI, socket,
root-owned configuration, App private key, logs, isolated worker directories, hidden
`_github-agent-auth` account and group, wrappers, Git URL rewrite, and the shell PATH block
created by setup. `brew uninstall github-agent-auth` then removes the package-manager
receipt and user-facing executable. The command deliberately does not delete the GitHub
App or its installation because those are external, potentially shared resources; remove
them in GitHub settings when they are no longer needed.

## Release

Releases are built, Developer ID signed, notarized, Gatekeeper-checked, and published
from a dedicated Apple Silicon Mac. See [docs/local-release.md](docs/local-release.md).
