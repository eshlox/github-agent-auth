# Security policy

Do not open a public issue for a suspected vulnerability or compromised release.
Use GitHub's private vulnerability reporting for this repository. Include the affected
version, macOS version, reproduction steps, and any signature, checksum, or Gatekeeper
output. Do not include private keys, installation tokens, or other secrets.

Only the latest release is supported with security fixes. A release is supported only
after its signed and notarized archive, checksum, and reviewed Homebrew formula are all
published. Source snapshots and artifacts from untrusted forks are not release builds.

## Security model

The root LaunchDaemon owns the GitHub App key, repository policy, token minting, Git
HTTPS transport, restricted GitHub CLI execution, and audit log. Git and GitHub CLI run
as the hidden, dedicated `_github-agent-auth` account rather than root or the configured user. The
configured user can request supported operations but cannot read broker credentials or change the
repository allowlist without administrator approval. The socket authenticates clients
with the kernel-reported peer UID.

The broker does not accept arbitrary commands. Git is limited to the stateless remote
transport. GitHub CLI is limited to the documented built-in repository and pull-request
commands, an isolated configuration, fixed repository selection, and a clean
environment. Default-branch protection remains a GitHub ruleset responsibility.

The model excludes compromise of root, the kernel, Xcode Command Line Tools, the copied
GitHub CLI binary, or GitHub itself. It also excludes local source-code integrity:
AgentAuth protects remote credentials and operations, not the user's working tree.
