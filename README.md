# Utilities for Apple Container on macOS

This repository hosts scripts and utilities for Apple's [`container`](https://github.com/apple/container) CLI on macOS. Use these tools when you cannot install Docker Desktop for Mac, OrbStack, or other third-party container runtimes.

## Contents

### [DinD & Cloud Native Buildpacks (`dind/`)](dind/README.md)

Utilities for running Docker-dependent workflows and Cloud Native Buildpacks (`cnb`) using Apple `container`:

- **[`cnb-dockerd.sh`](dind/cnb-dockerd.sh)**: Runs a Docker Engine (`docker:dind`) inside an Apple container and publishes its Unix socket on macOS so tools that require the Docker Engine API (such as the `pack` CLI) work out of the box.
- **[`cnb-build.sh`](dind/cnb-build.sh)**: Builds OCI images from source with Cloud Native Buildpacks inside an Apple container without running `dockerd` or installing `pack`.
- **[`cnb_apple_container_report.md`](dind/cnb_apple_container_report.md)**: Technical report comparing both approaches.

See [`dind/README.md`](dind/README.md) for usage and configuration details.

### [Container Registry Login (`registry-login/`)](registry-login/README.md)

Shell helpers (`zsh` and `bash`) to authenticate Apple `container` against container registries and store credentials in the macOS Keychain:

- **[`gar-login/`](registry-login/gar-login/)**: Logs in to Google Artifact Registry (`<region>-docker.pkg.dev`) using short-lived `gcloud` OAuth access tokens or service-account keys.
- **[`docker-login/`](registry-login/docker-login/)**: Logs in to Docker Hub (`docker.io`) using personal access tokens read from a file, `stdin`, or a hidden prompt.

See [`registry-login/README.md`](registry-login/README.md) for installation and usage instructions.
