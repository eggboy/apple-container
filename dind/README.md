# DinD and Cloud Native Buildpacks (`dind/`)

Apple `container` does not expose a Docker Engine API socket. Tools that require `DOCKER_HOST`, such as the Cloud Native Buildpacks `pack` CLI, cannot connect to `container` on their own.

This directory provides two ways to build images and run Docker-dependent workflows using Apple `container`:

| Script | Approach | Best For |
| :--- | :--- | :--- |
| [`cnb-dockerd.sh`](cnb-dockerd.sh) | Runs `docker:dind` inside an Apple container and publishes `/var/run/docker.sock` to the macOS host | Running `pack` (including `rebase`, `inspect`, `--publish`) or other tools that require a live Docker Engine API |
| [`cnb-build.sh`](cnb-build.sh) | Runs the CNB lifecycle (`/cnb/lifecycle/creator`) in an Apple container and exports an OCI layout | Building app images with Cloud Native Buildpacks without running `dockerd` or installing `pack` |

See [`cnb_apple_container_report.md`](cnb_apple_container_report.md) for benchmark comparisons, architecture notes, and configuration details (such as MTU 1280 tuning and Rosetta `binfmt_misc` registration).

## Prerequisites

- macOS on Apple Silicon (`arm64`)
- Apple [`container`](https://github.com/apple/container/releases) CLI (`>= 1.5.0`) with services started (`container system start`)
- `python3` and `curl`

---

## 1. Docker Engine in Apple Container (`cnb-dockerd.sh`)

`cnb-dockerd.sh` launches `docker:dind` in a privileged Apple container with Rosetta enabled for `amd64` images, sets the bridge MTU to `1280` to match the Apple container network interface, and forwards the Docker socket to `~/.cnb-dockerd/docker.sock`.

### Usage

```bash
# Start the Docker Engine container and export DOCKER_HOST
./cnb-dockerd.sh start
eval "$(./cnb-dockerd.sh env)"

# Run pack or any Docker API client against the socket
pack build --builder=gcr.io/buildpacks/builder sample-mvn

# Copy the built image from the inner Docker Engine into Apple container's image store
./cnb-dockerd.sh load sample-mvn

# Run the image with Apple container
container run --rm --arch amd64 -p 8080:8080 sample-mvn

# Check status, stop, or remove the engine container (volumes persist across stops/removals)
./cnb-dockerd.sh status
./cnb-dockerd.sh stop
./cnb-dockerd.sh rm
```

### Environment Variables

| Variable | Default | Description |
| :--- | :--- | :--- |
| `CNB_DOCKERD_NAME` | `cnb-dockerd` | Name of the Apple container running `dockerd` |
| `CNB_DOCKERD_SOCK` | `~/.cnb-dockerd/docker.sock` | Host path for the published Unix socket |
| `CNB_DOCKERD_VOLUME` | `cnb-docker-data` | Apple container volume persisted at `/var/lib/docker` |
| `CNB_DOCKERD_IMAGE` | `docker.io/library/docker:dind` | Container image used for the engine |
| `CNB_DOCKERD_CPUS` | `6` | CPUs allocated to the engine container |
| `CNB_DOCKERD_MEMORY` | `8G` | Memory allocated to the engine container |

---

## 2. Direct CNB Lifecycle Builder (`cnb-build.sh`)

`cnb-build.sh` runs the CNB `creator` binary inside the builder image using Apple `container`, exports the resulting image as an OCI layout (requires lifecycle platform API `>= 0.12`), and loads it into Apple `container`'s local image store. It keeps build caches in per-image volumes (`cnb-cache-<image>-<arch>`) and stores run image layouts under `CNB_HOME` (`~/.cache/cnb-container`).

### Usage

```bash
# Build from the current directory using the default builder (gcr.io/buildpacks/builder:latest)
./cnb-build.sh sample-mvn

# Build from a specific path with custom builder, environment variables, and resource limits
./cnb-build.sh \
  -p ~/src/sample-java-mvn \
  -B gcr.io/buildpacks/builder:latest \
  -e BP_JVM_VERSION=21 \
  -c 4 -m 4G \
  sample-mvn

# Discard the build cache before building
./cnb-build.sh --clear-cache sample-mvn
```

### Options

| Option | Default | Description |
| :--- | :--- | :--- |
| `-p, --path DIR` | `.` | Application source directory |
| `-B, --builder IMAGE` | `gcr.io/buildpacks/builder:latest` | CNB builder image |
| `-e, --env KEY=VALUE` | *(none)* | Build-time environment variable for buildpacks (repeatable) |
| `--platform OS/ARCH` | `linux/arm64` (falls back to `linux/amd64`) | Target build platform |
| `--clear-cache` | `false` | Delete the per-image build cache volume before building |
| `-c, --cpus N` | `4` | CPUs allocated to the build container |
| `-m, --memory SIZE` | `4G` | Memory allocated to the build container |
| `--log-level LEVEL` | `info` | Lifecycle log level (`debug`, `info`, `warn`, `error`) |
