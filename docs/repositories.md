# Add or remove repositories

## Add

First add the repository to the existing App installation in GitHub settings. Then:

```sh
cd ~/projects/another-repository
github-agent-auth repo add
github-agent-auth list
```

This reuses the configured App, installation, and private key. It does not import an
unrelated App or move the configuration to another Mac.

## Remove

```sh
cd ~/projects/another-repository
github-agent-auth repo remove
```
