# AgentAuth for GitHub

AgentAuth gives local coding agents restricted Git and GitHub CLI access without exposing
a reusable credential. It is native Swift for Apple Silicon macOS.

This project is not affiliated with GitHub.

## Requirements

- macOS 13 or later on Apple Silicon
- Xcode Command Line Tools
- GitHub CLI from a trusted source
- A GitHub repository
- Administrator access during setup and maintenance

## Install

Download and inspect the installer before running it:

```sh
curl -fsSLo /tmp/github-agent-auth-install.sh \
  https://raw.githubusercontent.com/eshlox/github-agent-auth/main/install.sh
less /tmp/github-agent-auth-install.sh
sh /tmp/github-agent-auth-install.sh

export PATH="$HOME/.local/bin:$PATH"
cd ~/projects/my-repository
github-agent-auth setup
```

The installer downloads the source, builds it with local Xcode, runs its security
self-test, and installs the binary in `~/.local/bin`. It does not use `sudo`. Setup asks
for administrator approval when it installs the privileged service.

For a quick install:

```sh
curl -fsSL \
  https://raw.githubusercontent.com/eshlox/github-agent-auth/main/install.sh | sh
```

For a reproducible install, replace `COMMIT_SHA` with a reviewed commit:

```sh
commit=COMMIT_SHA
curl -fsSLo /tmp/github-agent-auth-install.sh \
  "https://raw.githubusercontent.com/eshlox/github-agent-auth/$commit/install.sh"
GITHUB_AGENT_AUTH_REF="$commit" sh /tmp/github-agent-auth-install.sh
```

Setup opens GitHub to create a private GitHub App and install it on the current
repository. It then asks for administrator approval.

Setup installs:

- A root-owned LaunchDaemon
- A hidden, disabled-login `_github-agent-auth` worker account
- A root-owned App key, configuration, and protected GitHub CLI copy
- `gh` and Git remote-helper shims in `~/.local/bin`

Put `~/.local/bin` first in `PATH`. Setup can update `.zprofile` or `.bash_profile`.

## Use

Existing commands work through the broker:

```sh
git fetch
git pull
git push origin agent/my-change

gh pr list
gh pr create \
  --head agent/my-change \
  --title "My change" \
  --body "Description"
```

Supported GitHub CLI commands:

```text
gh repo view
gh issue list|view
gh issue create --title "Title" --body "Description"
gh issue comment NUMBER --body "Comment"
gh issue close|reopen NUMBER
gh pr list|status|view|checks|diff
gh pr create|comment|review|close|reopen|ready
```

`gh pr create` requires `--head`, `--title`, and `--body`. Merge, `gh api`, aliases,
extensions, repository overrides, editors, web flows, and arbitrary file inputs are
blocked. Issue creation and comments require inline text. Issue metadata edits and bulk
operations are blocked.

## Repository and permission policy

The default `core` profile requests:

- Metadata read
- Contents read/write
- Issues read/write
- Pull requests read/write

Use `developer` when the agent must inspect CI, security findings, deployments,
discussions, or merge queues:

```sh
github-agent-auth setup --permissions developer
github-agent-auth permissions set developer
```

The App must already have the selected permissions. Choose `developer` during setup if
you need this profile.

The `developer` profile adds read-only access to Actions, Checks, Commit statuses, Code
Quality, Code scanning alerts, Dependabot alerts, Deployments, Discussions, and Merge
queues. It does not grant access to secrets, secret-scanning alerts, private security
advisories, environments, administration, or workflow modification.

Read developer context as JSON:

```sh
github-agent-auth context code-quality
github-agent-auth context code-scanning
github-agent-auth context dependabot
github-agent-auth context deployments
github-agent-auth context discussions
github-agent-auth context merge-queue
```

Context commands use fixed read-only API requests. General `gh api` remains blocked.

The broker requests its local permission cap for every token. Expanding the GitHub App
does not expand broker tokens automatically.

Manage allowed repositories:

```sh
cd ~/projects/another-repository
github-agent-auth repo add
github-agent-auth repo remove
github-agent-auth list
```

Policy changes require administrator approval.

## Maintenance

After upgrading AgentAuth:

```sh
sh /tmp/github-agent-auth-install.sh
github-agent-auth install-service
github-agent-auth doctor
```

Download the current installer again if `/tmp/github-agent-auth-install.sh` no longer
exists. Pin `GITHUB_AGENT_AUTH_REF` to update to a specific commit.

After upgrading your trusted GitHub CLI installation:

```sh
brew upgrade gh
github-agent-auth update-gh
github-agent-auth doctor
```

`update-gh` prints the source path, asks for administrator approval, verifies internal
code-signature consistency, and atomically replaces the root-owned copy. Homebrew `gh`
may be ad-hoc signed, so this does not prove publisher identity. Review the path before
approval. Never configure passwordless sudo for this command.

Useful commands:

```sh
github-agent-auth status
github-agent-auth doctor
github-agent-auth self-test
github-agent-auth permissions
```

## Uninstall

```sh
github-agent-auth uninstall
rm "$HOME/.local/bin/github-agent-auth"
```

The first command removes all local broker state, privileged files, logs, shims, Git
configuration, shell PATH changes, and the worker account. The second removes the local
binary. Remove the GitHub App separately in GitHub settings.

## How it is secured

- The socket accepts only the macOS UID recorded during setup.
- The user-facing socket never returns a key or token.
- Tokens are short-lived and limited to one configured repository and permission cap.
- Git supports only stateless fetch and push through root-owned Xcode transport.
- GitHub CLI uses a root-owned copy, an isolated worker account, a clean environment,
  fixed repository selection, and a strict command allowlist.
- Configuration changes require root and the configured sudo caller.
- Decisions are logged without command arguments or credentials.

AgentAuth protects GitHub credentials and broker operations. It does not protect local
source files from software running as your user. Use reviewed pull requests and GitHub
rulesets, and never give the App bypass permission.

Read [SECURITY.md](SECURITY.md) for the complete threat model and security decisions.

## Build manually

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build -c release
cd ~/projects/my-repository
.build/release/github-agent-auth setup
```

No prebuilt binaries are published. See [SECURITY.md](SECURITY.md) for the source-install
trust model. Future release maintainers should follow
[docs/local-release.md](docs/local-release.md).

## License

[Apache License 2.0](LICENSE)
