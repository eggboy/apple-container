# Container Registry Login (`registry-login/`)

Apple `container` does not support Docker credential helpers (`credHelpers` or `credsStore`). Instead, it stores static credentials per registry host in the macOS Keychain (`com.apple.container.registry`) through `container registry login`.

The scripts in this directory automate authentication for Google Artifact Registry and Docker Hub. Each script works both as a sourced shell function and as a standalone executable, in Zsh or Bash (including macOS stock `/bin/bash` 3.2 and Homebrew Bash 5.x).

---

## 1. Google Artifact Registry (`gar-login/`)

- [`gar-login/ar-login.zsh`](gar-login/ar-login.zsh) (Zsh)
- [`gar-login/ar-login.bash`](gar-login/ar-login.bash) (Bash 3.2+ and 5.x)

`ar-login` authenticates Apple `container` against Google Artifact Registry (`<region>-docker.pkg.dev`). By default, it mints a short-lived OAuth access token (~1 hour) with `gcloud auth print-access-token` and passes it to `container registry login` over `stdin`. It also supports long-lived service-account JSON keys via `-k / --key`, and checks `/v2/` before logging in so mistyped regions fail fast instead of hitting wildcard DNS redirects.

> [!IMPORTANT]
> Google Artifact Registry omits `service=` from its `/v2/` `WWW-Authenticate` challenge header. You must use Apple `container >= 1.6.0`, which includes the fix for parsing that challenge.

### Installation

Source the script in your shell RC file or run the file as an executable:

```bash
# Zsh (~/.zshrc)
echo "source /path/to/apple-container/registry-login/gar-login/ar-login.zsh" >> ~/.zshrc

# Bash (~/.bashrc or ~/.bash_profile)
echo "source /path/to/apple-container/registry-login/gar-login/ar-login.bash" >> ~/.bashrc
```

### Usage

```bash
# Log in to the default host ($AR_LOGIN_HOSTS, or asia-southeast1-docker.pkg.dev if unset)
ar-login

# Log in to one or more regions or full hostnames
ar-login us europe-west1 asia-east1-docker.pkg.dev

# Mint a token for a specific gcloud account
ar-login -a me@example.com us

# Authenticate with a service-account JSON key file (or pipe from stdin with -k -)
ar-login -k ~/sa-key.json us
gcloud secrets versions access latest --secret=sa-key | ar-login -k - us

# Preview which hosts and username would be used without logging in
ar-login -n us europe-west1
```

---

## 2. Docker Hub (`docker-login/`)

- [`docker-login/hub-login.zsh`](docker-login/hub-login.zsh) (Zsh)
- [`docker-login/hub-login.bash`](docker-login/hub-login.bash) (Bash 3.2+ and 5.x)

`hub-login` authenticates Apple `container` against Docker Hub (`docker.io`, stored as `registry-1.docker.io` in `container registry list`). To keep credentials out of shell history and process listings (`ps`), `hub-login` rejects tokens passed as command-line flags and reads from `--token-file`, piped `stdin`, or a hidden interactive prompt.

### Installation

Source the script in your shell RC file or run the file as an executable:

```bash
# Zsh (~/.zshrc)
echo "source /path/to/apple-container/registry-login/docker-login/hub-login.zsh" >> ~/.zshrc

# Bash (~/.bashrc or ~/.bash_profile)
echo "source /path/to/apple-container/registry-login/docker-login/hub-login.bash" >> ~/.bashrc
```

### Usage

```bash
# Interactive prompt (input is hidden)
hub-login -u <username>

# Pipe token from clipboard or macOS Keychain
pbpaste | hub-login -u <username>
security find-generic-password -s docker-hub -w | hub-login -u <username>

# Read token from a file
hub-login -u <username> -t ~/.config/docker-hub-token

# Set a default username via HUB_LOGIN_USER
export HUB_LOGIN_USER=<username>
hub-login
```

After logging in, push images using the `docker.io/<username>/<image>:<tag>` prefix:

```bash
container image push docker.io/<username>/<image>:<tag>
```
