# Update

## AgentAuth

```sh
cd /path/to/github-agent-auth
git fetch origin
git checkout --detach COMMIT_SHA
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build -c release
.build/release/github-agent-auth self-test
/usr/bin/install -m 0755 \
  .build/release/github-agent-auth "$HOME/.local/bin/github-agent-auth"
github-agent-auth install-service
github-agent-auth doctor
```

Review `COMMIT_SHA` before updating. `install-service` refreshes the protected root-owned
copy after the user-facing binary is replaced.

## GitHub CLI

```sh
brew upgrade gh
github-agent-auth update-gh
github-agent-auth doctor
```

Review the source path printed by `update-gh` before approving administrator access.
