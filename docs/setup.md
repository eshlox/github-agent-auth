# First setup

## 1. Create a private GitHub App

Open **GitHub Settings > Developer settings > GitHub Apps > New GitHub App**. For an
organization-owned App, start in the organization's settings.

Configure:

- Homepage URL: `https://github.com/eshlox/github-agent-auth`
- Webhook: disabled
- Contents: read and write
- Issues: read and write
- Pull requests: read and write
- Metadata: read-only
- Installation scope: only this account

Create the App, note its **App ID**, and generate and download a private key.

## 2. Install the App

On the App page, select **Install App**, choose **Only select repositories**, and select
your first repository.

The number at the end of the resulting URL is the installation ID:

```text
https://github.com/settings/installations/INSTALLATION_ID
```

## 3. Configure AgentAuth

From the selected repository:

```sh
cd ~/projects/my-repository
github-agent-auth setup \
  --app-id APP_ID \
  --installation-id INSTALLATION_ID \
  --private-key "$HOME/Downloads/APP.private-key.pem"
github-agent-auth doctor
rm "$HOME/Downloads/APP.private-key.pem"
```

Delete the downloaded key only after setup and `doctor` succeed. Setup verifies the key,
App, installation, repository, and permissions before installing a protected root-owned
copy.

Setup also installs the LaunchDaemon, isolated worker account, protected GitHub CLI copy,
and command wrappers. Run setup only once. For more repositories, follow
[Add or remove repositories](repositories.md).
