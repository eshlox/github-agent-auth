# Security policy and design

Do not open a public issue for a suspected vulnerability or compromised release. Use
GitHub's private vulnerability reporting for this repository. Include the affected
version, macOS version, reproduction steps, and relevant signature, checksum, or
Gatekeeper output. Never include private keys, installation tokens, authorization
headers, or other secrets.

Only the latest published release receives security fixes. A release is supported only
after its Developer ID signed and notarized archive, checksum, and reviewed Homebrew
formula are published. Source snapshots and artifacts from untrusted forks are not
release builds.

## Security objective

AgentAuth lets an untrusted process running as one configured macOS user perform a small
set of GitHub operations without giving that process a reusable GitHub credential. It
protects the GitHub App private key and short-lived installation tokens and limits their
use to explicitly configured repositories, permissions, Git transport, and GitHub CLI
commands.

AgentAuth is a credential and operation boundary, not a general coding-agent sandbox. A
process running as the configured user can still read and modify that user's files,
rewrite source and Git history, invoke any operation the broker deliberately allows, and
misrepresent local command output.

## Protected assets and trust assumptions

Protected assets are the GitHub App private key, installation tokens, root-owned
repository and permission policy, privileged executables, and audit records. The design
assumes that macOS, the kernel, root, launchd, sudo, Directory Services, Apple's Xcode
Command Line Tools, the installed protected GitHub CLI, and GitHub are not compromised.
It also assumes the administrator reviews the source of a GitHub CLI refresh before
approving it.

Root or kernel compromise is outside the model. So are malicious GitHub responses,
vulnerabilities in GitHub, Xcode's HTTPS transport, or the protected GitHub CLI, and
physical attacks against an unlocked Mac. A compromised configured user is inside the
model only with respect to broker credentials and broker-enforced remote operations, not
the integrity or confidentiality of that user's local account.

## Process and credential flow

The root-owned LaunchDaemon authenticates each Unix-domain socket client using
`getpeereid`. Only the non-root UID recorded at setup is accepted. A request must identify
one configured `owner/repository` and one supported operation before the broker mints or
reuses a short-lived GitHub App installation token.

The root process owns the App key, validates policy, mints tokens, and records decisions.
It launches credential-bearing tools as the hidden, password-disabled, non-login
`_github-agent-auth` worker account. They run neither as root nor as the configured user.
The user-facing socket streams only Git protocol data or output from an allowlisted
command; it never returns a key, token, authorization header, or child environment.

For Git HTTPS remotes, a global `insteadOf` rule selects `git-remote-agentauth`. The
broker accepts only Git's `capabilities` and `stateless-connect` protocol for
`git-upload-pack` or `git-receive-pack`. It launches the absolute, root-owned Xcode
`git-remote-http` path with credential helpers, redirects, interactive prompts, and the
working repository disabled. The user's Git executable remains untrusted and never
receives the token.

For GitHub CLI operations, the user-facing `gh` shim validates a strict command allowlist
and sends structured arguments plus the current repository to the broker. The broker
validates them again and adds the fixed repository itself. It runs the root-owned
protected GitHub CLI with an otherwise empty environment, isolated configuration and
temporary directories, disabled prompts, and closed standard input.

## Security decisions

### Root-owned LaunchDaemon

The daemon needs access to the App key and policy even when no user is logged in. Root
ownership prevents the configured user from replacing the daemon, configuration, key, or
LaunchDaemon definition. Root necessarily handles the small, fixed GitHub App token API
exchange; general Git transport and GitHub CLI network parsing are delegated to the
isolated worker.

### Dedicated worker account

`_github-agent-auth` is a real local Directory Services account with a dynamically
allocated system UID and GID. It is hidden, has a disabled password, uses
`/usr/bin/false` as its shell, and cannot log in. A dedicated identity avoids giving
tokens to root, the configured user, or a shared account such as `nobody`. Its home,
configuration, and temporary directories are isolated with mode `0700`.

### Root-owned App key and configuration

The private key is stored as a root-owned `0600` file. Configuration is root-owned and
not writable by group or others. Mutations require both root and a `SUDO_UID` matching
the configured client UID, preventing another administrator session from casually
changing this user's policy through the public command surface.

### Kernel-authenticated local socket

The broker trusts the peer UID reported by the kernel rather than a username, path,
environment variable, or client-provided identity. The socket is not a token API: a
successful request performs one bounded operation and streams only its result.

### GitHub App installation tokens

Tokens are short-lived and minted for exactly one configured installation and repository.
Every request includes the local permission cap. The default `core` cap contains only
metadata read, contents read/write, and pull-request read/write. `ci-read` adds Actions,
Checks, and Commit statuses read-only. Expanding the GitHub App later does not silently
expand locally requested token permissions.

### Fixed GitHub origins and repositories

Only exactly `github.com` and the compiled-in `https://api.github.com` origin are
accepted. Credentials in URLs, alternate schemes, ports, redirects, repository override
flags, and unlisted repositories are rejected. This prevents a caller from redirecting
credentials to another host or widening repository scope.

### Restricted Git transport

The broker exposes only stateless fetch and push transport, not arbitrary `git`
subcommands. The privileged helper uses `GIT_DIR=/dev/null`, so it cannot inspect or
modify the user's worktree or object database. Branch protection and review requirements
remain GitHub responsibilities and should be enforced with rulesets that the App cannot
bypass.

### Restricted GitHub CLI

Only the documented `repo view` and pull-request commands are accepted. Arbitrary API
calls, aliases, extensions, merge commands, repository overrides, editor and web flows,
templates, debug output, and arbitrary file or standard-input consumption are denied.
`pr create` requires explicit head, title, and body values. This reduces token escape and
prevents the worker from reading attacker-selected local files. Merging is intentionally
left to a separately authorized, reviewed workflow.

### Protected GitHub CLI copy

Homebrew is designed for a single user and its prefix is normally writable by that user.
Executing `/opt/homebrew/bin/gh` with a token would therefore let a compromised user
replace the executable and receive the token. Setup copies the selected CLI atomically to
`/Library/PrivilegedHelperTools/agentauth-gh`, owned by root and not writable by the
configured user. The original installation remains untouched and is never executed with
a broker token.

After updating the user-installed CLI, `github-agent-auth update-gh` explicitly refreshes
the protected copy under administrator approval. The destination is written to a
temporary file, set to mode `0755`, checked with `codesign --verify --strict`, and renamed
atomically. Existing processes continue using their already opened version; new requests
use the replacement.

This check proves internal code-signature consistency, not publisher identity. Homebrew
`gh` binaries may be user-owned and ad-hoc signed. Consequently, approving `update-gh`
means trusting the selected source binary and its installation channel. A compromised
configured user with an already cached or passwordless sudo authorization may be able to
approve a malicious replacement; do not grant unattended sudo access to this command.
Independent Homebrew bottle-provenance verification is not currently implemented.

### Clean subprocess environments

Credential-bearing subprocesses receive an explicit environment rather than the daemon
or user's environment. Interactive prompts, pagers, editors, aliases, extensions,
credential helpers, redirects, and user configuration are disabled or isolated. This
reduces environment-variable injection and accidental secret disclosure.

### Audit logging

Every allow or deny policy decision for a valid broker request records timestamp, peer
UID, repository, normalized operation, and decision in
`/var/log/github-agent-auth.log`. Malformed requests rejected before policy evaluation
are not recorded there. Arguments and credentials are omitted. The file is root-owned
with mode `0600` and appended under a process lock. It is not tamper-proof against root
and is removed during uninstall.

### Signed and notarized releases

Published binaries are built on a dedicated Apple Silicon Mac, signed with Developer ID,
notarized by Apple, Gatekeeper-checked, checksummed, and released through a reviewed
Homebrew formula. Source builds are supported for development but do not provide the same
publisher verification.

### Explicit complete local uninstall

`github-agent-auth uninstall` removes the LaunchDaemon, socket, privileged executables,
configuration, private key, logs, worker directories, service account and group, Git URL
rewrite, wrappers, and the exact shell PATH block created by setup. Cleanup errors are
reported instead of silently declaring success. `brew uninstall github-agent-auth`
removes the package-manager receipt and remaining user-facing executable.

The GitHub App and installation are not deleted automatically. They are external
resources that may be shared or require separate GitHub authorization. Remove them in
GitHub settings to revoke the installation completely.

## Residual risks and operational controls

- Protect default branches with reviewed pull requests and required checks; never give
  the App ruleset bypass permission.
- Keep macOS, Xcode Command Line Tools, GitHub CLI, and AgentAuth updated.
- Install GitHub CLI only through a trusted channel and review the path printed by
  `update-gh` before approving sudo.
- Do not configure passwordless sudo for AgentAuth privileged commands.
- Treat unexpected audit entries, worker-account changes, signature failures, or a
  changed privileged binary as a potential compromise.
- Run `github-agent-auth doctor` after installation or repair and perform release
  verification with a disposable private repository.
