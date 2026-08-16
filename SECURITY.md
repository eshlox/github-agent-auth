# Security

## Report a vulnerability

Use GitHub private vulnerability reporting. Do not open a public issue.

Include the AgentAuth version, macOS version, reproduction steps, and relevant signature,
checksum, or Gatekeeper output. Never include keys, tokens, or authorization headers.

Security fixes are made on `main`. No prebuilt binaries are currently published.

## Goal

AgentAuth lets an untrusted process running as one macOS user perform a small set of GitHub
operations without receiving a reusable GitHub credential.

It protects:

- The GitHub App private key and installation tokens
- The repository and permission policy
- Privileged executables and configuration
- Broker audit records from the configured user

It does not protect the configured user's local files, source tree, Git history, terminal
output, or other accounts. Software running as that user can request every operation the
policy allows.

## Trust assumptions

AgentAuth trusts macOS, the kernel, root, launchd, sudo, Directory Services, Xcode Command
Line Tools, the installed protected GitHub CLI, and GitHub.

The model does not cover root or kernel compromise, an unlocked Mac under physical
attack, malicious GitHub responses, or vulnerabilities in GitHub, Xcode Git transport,
the protected GitHub CLI, or AgentAuth itself.

## Credential flow

1. A user shim sends a structured request through a Unix socket.
2. The root daemon verifies the peer UID with `getpeereid`.
3. The daemon validates the repository, operation, and local permission cap.
4. The daemon mints or reuses a short-lived token for one repository.
5. A hidden `_github-agent-auth` worker runs the approved Git or `gh` operation.
6. The socket returns command or Git protocol output, never the credential.

The root daemon handles the fixed GitHub App token exchange. General Git and GitHub CLI
network parsing runs under the worker account.

## Security decisions

### Root-owned LaunchDaemon

Root ownership prevents the configured user from replacing the daemon, App key, policy,
or LaunchDaemon definition. The daemon delegates credential-bearing tools to a non-root
worker.

### Dedicated worker account

`_github-agent-auth` is a hidden local account with a system UID and GID, disabled
password, `/usr/bin/false` shell, and no login access. It keeps tokens away from root, the
configured user, and shared accounts such as `nobody`. Its private directories use mode
`0700`.

### Root-owned key and policy

The App key is root-owned with mode `0600`. Configuration is root-owned and not writable
by group or others. Policy updates require root and a `SUDO_UID` equal to the configured
client UID.

### Kernel-authenticated socket

The broker trusts the peer UID reported by macOS, not a username, path, environment
variable, or client claim. The socket performs operations and never acts as a token API.

### Scoped installation tokens

Each token request names one configured repository and includes the local permission cap.
The default `core` cap requests metadata read, contents read/write, and pull-request
read/write. `ci-read` also requests Actions, Checks, and Commit statuses read-only.

Changing GitHub App permissions does not change the local cap. Protect default branches
with reviewed pull requests and rulesets that the App cannot bypass.

### Fixed GitHub destination

Only exactly `github.com` and the compiled-in `https://api.github.com` origin are allowed.
The broker rejects alternate hosts, schemes, ports, credentials in URLs, redirects,
repository overrides, and unlisted repositories.

### Restricted Git

Git supports only `capabilities` and `stateless-connect` for `git-upload-pack` and
`git-receive-pack`. The broker runs the absolute, root-owned Xcode `git-remote-http` with
credential helpers, redirects, prompts, and the working repository disabled. The user's
Git process remains untrusted and never receives a token.

### Restricted GitHub CLI

The public `gh` shim and broker both enforce the same built-in allowlist. The broker fixes
the repository and runs `gh` with closed input, isolated directories, disabled prompts,
and a clean environment.

The broker rejects `gh api`, aliases, extensions, merge, repository overrides, editors,
web flows, templates, debug output, and arbitrary file input. `pr create` requires an
explicit head, title, and body.

### Protected GitHub CLI copy

Homebrew files are normally writable by the installing user. Giving a Homebrew `gh`
process a token would let compromised user software replace it and steal that token.

Setup atomically copies `gh` to root-owned
`/Library/PrivilegedHelperTools/agentauth-gh`. The broker never executes the user-owned
source with a token.

After updating the trusted user installation, run:

```sh
github-agent-auth update-gh
```

The command prints the source path and requires administrator approval. It copies to a
temporary root-owned file, sets mode `0755`, runs `codesign --verify --strict`, and
atomically replaces the protected copy.

This verifies code-signature consistency, not publisher identity. Homebrew `gh` may be
ad-hoc signed. Approval therefore means trusting the displayed source and its installation
channel. Independent Homebrew bottle provenance verification is not implemented. Do not
allow passwordless sudo for AgentAuth commands.

### Clean subprocess state

Credential-bearing tools receive an explicit environment. User configuration, credential
helpers, aliases, extensions, prompts, pagers, editors, and temporary directories are
disabled or isolated where applicable.

### Minimal audit data

Valid allow and deny policy decisions record timestamp, peer UID, repository, normalized
operation, and decision in `/var/log/github-agent-auth.log`. Arguments and credentials are
not logged. Malformed requests rejected before policy evaluation are not logged.

The log is root-owned with mode `0600`. It is not tamper-proof against root and is removed
by uninstall.

### Source distribution

The supported installer fetches source over HTTPS, optionally at an exact commit, and
builds it with the local Xcode toolchain. It runs `codesign --verify --strict` and the
security self-test before installing the binary in the user's `~/.local/bin`.

This provides source transparency and avoids trusting an unsigned prebuilt binary. It
does not prove Apple publisher identity. The local ad-hoc code signature checks binary
integrity, not who published it. Review the installer and pin a reviewed commit when that
distinction matters.

Never run the installer with `sudo`. Only the locally built `github-agent-auth setup`
command should request administrator approval. Do not redistribute prebuilt binaries
until they are Developer ID signed, notarized, checksummed, and verified on a clean Mac.

### Explicit uninstall

```sh
github-agent-auth uninstall
rm "$HOME/.local/bin/github-agent-auth"
```

The first command removes local broker state, privileged files, logs, worker directories,
the service account and group, Git configuration, shims, and setup's shell PATH block.
Cleanup errors fail the command. The second command removes the local binary.

The GitHub App is external and may be shared, so uninstall does not delete it. Remove it
in GitHub settings to revoke it fully.

## Operator checklist

- Keep macOS, Xcode Command Line Tools, GitHub CLI, and AgentAuth updated.
- Review `install.sh` and pin a commit for reproducible installation.
- Install GitHub CLI from a trusted channel.
- Review the path printed by `update-gh` before approving sudo.
- Do not configure passwordless sudo for AgentAuth.
- Keep the App off every ruleset bypass list.
- Investigate unexpected audit entries, account changes, or signature failures.
- Run `github-agent-auth doctor` after setup, updates, or repairs.
