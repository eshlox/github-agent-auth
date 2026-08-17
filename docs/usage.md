# Usage

Use Git and the supported GitHub CLI commands normally:

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
extensions, repository overrides, editors, web flows, arbitrary file inputs, and bulk
operations are blocked.

See [Add or remove repositories](repositories.md) and [Permission profiles](permissions.md).
