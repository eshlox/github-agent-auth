# Permission profiles

## Core

The default `core` profile uses:

- Metadata: read
- Contents: read and write
- Issues: read and write
- Pull requests: read and write

## Developer

The `developer` profile adds read-only Actions, Checks, Commit statuses, Code Quality,
Code scanning alerts, Dependabot alerts, Deployments, Discussions, and Merge queues.
Configure these permissions on the GitHub App before setup, then run:

```sh
github-agent-auth setup \
  --app-id APP_ID \
  --installation-id INSTALLATION_ID \
  --private-key /path/to/private-key.pem \
  --permissions developer
```

Read the additional context as JSON:

```sh
github-agent-auth context code-quality
github-agent-auth context code-scanning
github-agent-auth context dependabot
github-agent-auth context deployments
github-agent-auth context discussions
github-agent-auth context merge-queue
```

The profile excludes secrets, secret-scanning alerts, private security advisories,
environments, administration, and workflow modification. General `gh api` remains
blocked.

The App permissions and local profile are separate caps. Expanding the App does not
expand broker tokens. Change the local cap with administrator approval:

```sh
github-agent-auth permissions set developer
github-agent-auth permissions
```
