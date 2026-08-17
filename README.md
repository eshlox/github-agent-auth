# AgentAuth for GitHub

<p align="center">
  <img src="docs/assets/agentauth-logo.png" alt="AgentAuth security robot" width="180">
</p>

AgentAuth gives local coding agents restricted Git and GitHub CLI access without exposing
a reusable credential. It is native Swift for Apple Silicon macOS.

This project is not affiliated with GitHub.

## Start here

1. [Build and install AgentAuth](docs/install.md)
2. [Create the GitHub App and run first setup](docs/setup.md)
3. [Use AgentAuth](docs/usage.md)

## Reference

- [Permission profiles](docs/permissions.md)
- [Add or remove repositories](docs/repositories.md)
- [Update AgentAuth or GitHub CLI](docs/update.md)
- [Check or diagnose the installation](docs/diagnose.md)
- [Uninstall](docs/uninstall.md)
- [Threat model and security decisions](SECURITY.md)
- [Local signed release process](docs/local-release.md)

No prebuilt binaries are published. Build from reviewed source and never build or install
the user-facing binary with `sudo`.

## License

[Apache License 2.0](LICENSE)
