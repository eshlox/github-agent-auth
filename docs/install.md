# Install

## Requirements

- macOS 13 or later on Apple Silicon
- Xcode
- GitHub CLI
- Administrator access during setup and maintenance

## 1. Prepare Xcode

Install Xcode from the Mac App Store, then run:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
```

Install GitHub CLI from a trusted source, for example:

```sh
brew install gh
```

## 2. Build and install

```sh
git clone https://github.com/eshlox/github-agent-auth.git
cd github-agent-auth
git log -1 --show-signature
```

For a reproducible build, first check out a reviewed commit:

```sh
git checkout --detach COMMIT_SHA
```

Build, verify, test, and install:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build -c release
/usr/bin/codesign --verify --strict .build/release/github-agent-auth
.build/release/github-agent-auth self-test
mkdir -p "$HOME/.local/bin"
/usr/bin/install -m 0755 \
  .build/release/github-agent-auth "$HOME/.local/bin/github-agent-auth"
```

Add it to your shell path:

```sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zprofile"
export PATH="$HOME/.local/bin:$PATH"
```

Do not use `sudo` for the build or copy. Continue with [first setup](setup.md).
