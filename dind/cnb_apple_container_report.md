# Cloud Native Buildpacks + Apple `container`: every angle checked

Environment: macOS 26.7.1 (arm64), Apple `container` 1.5.0, `pack` 0.40.9

## Verdict

> [!IMPORTANT]
> **Apple `container` cannot be a backend for `pack` on its own.** `pack` only talks to the Docker Engine API (`DOCKER_HOST`), and `container` 1.5.0 doesn't expose a Docker-compatible endpoint: there is no socket, flag, system property or plugin for it. Pointing `pack` straight at Apple container can't work.

Cloud Native Buildpacks builds do work **using only Apple `container`, with no Docker Desktop**, in two ways. I tested both end to end on your `sample-java-mvn`. Each built the image, loaded it into `container`'s image store, ran it, and `curl` returned `hello, world`.

| | **A. Docker Engine *inside* Apple container** | **B. Docker-free: run the CNB lifecycle directly** |
|---|---|---|
| Command | your exact command: `pack build --builder=gcr.io/buildpacks/builder sample-mvn` (only `DOCKER_HOST` set) | `cnb-build.sh sample-mvn` |
| How | `dockerd` runs in a `container` VM; `--publish-socket` exposes its API on macOS | the builder's `/cnb/lifecycle/creator` runs in `container`, exports an OCI layout, then `container image load` |
| Result image | lands in the engine; `cnb-dockerd.sh load sample-mvn` copies it to Apple container | lands in Apple container directly |
| First build (cold) | 1 m 33 s (Maven 41 s) | 1 m 03 s (Maven 39 s) |
| Rebuild | cached as usual by pack | 26 s (JDK cache hit, Maven 4 s, layers reused) |
| Features | all of `pack` (`rebase`, `inspect`, `--publish`, untrusted builders, ...) | build + cache + layer reuse + `--env`; no rebase or publish |
| Maturity | stable features only | depends on the lifecycle's **experimental** OCI-layout export |

## Angles checked

| Angle | Result | Evidence / notes |
|---|---|---|
| Docker-API socket built into `container` | ❌ none | Plugins: `container-core-images`, `container-network-vmnet`, `container-runtime-linux`, `machine-apiserver`, `k8s`. No Docker-related strings in `container` or `container-apiserver`. No matching `system property`. |
| `--publish-socket` | ✅ container → host only | Used in A to expose `/var/run/docker.sock` as `~/.cnb-dockerd/docker.sock`. The connection survives `stop`/`start`. |
| Host → container socket mounts | ❌ | Bind mounts are virtiofs; `--ssh` only forwards the SSH agent. Not needed in A, because the lifecycle containers run *inside* the engine VM. |
| Privileged containers (needed by `dockerd`) | ✅ with flags | By default `/proc/sys` is read-only, so dockerd fails with `ip_forward: read-only file system`. `--cap-add ALL --read-only-path NONE --masked-path NONE` is enough. |
| amd64 builder on Apple Silicon | ✅ Rosetta | The `gcr.io/buildpacks/builder` tags I checked (`latest`, `google-22`, `google-24`, `v1`) are all single-arch manifests; `latest` (Ubuntu 24.04, lifecycle 0.21.23) is linux/amd64 only. `--platform linux/amd64` turns Rosetta on automatically. |
| Rosetta inside nested (Docker) containers | ✅ | `--rosetta` registers `binfmt_misc` x86_64 → `/run/rosetta/rosetta` with flags `OCF`. The `F` flag makes it work in the engine's own containers. |
| Networking for nested containers | ✅, with a fix | The `container` NIC has MTU **1280**; Docker's default bridge uses 1500. With the default, Maven took **2 m 52 s**. With `dockerd --mtu=1280`: **41 s**. |
| Docker image store vs `pack` | ✅, with a tweak | Docker 29 defaults to the containerd store, and pack warns that daemon export may be much slower (pack#2272). `--feature containerd-snapshotter=false` removes the warning. |
| `container image load` | ✅ | Accepts `docker save` output as-is. For lifecycle layouts it needs a full-name annotation (the lifecycle writes only `latest`); `cnb-build.sh` adds it. |
| Bind mounts for app source | ⚠️ | Files show as `root`-owned and `chown` does nothing, so the source is **copied** into the build container (as `pack` does). This also stops `google.java.clear-source` from deleting files in your checkout. |
| `container machine` | ⚠️ possible, not needed | Could host `dockerd`, but `machine create` has no socket or port publishing options, so you'd need unauthenticated TCP. Option A is simpler. |
| `container build` (BuildKit + Dockerfile) | ⚠️ not pursued | Could run detect/build inside a Dockerfile, but it skips the CNB exporter (no proper layers, labels, SBOM or rebase). |
| Third-party Docker-API shims (e.g. socktainer) | not evaluated | Not part of Apple container; the GitHub check was declined; |
| Running the result | ✅ needs `--arch amd64` | Without it: `Error: platform linux/arm64`, because the image is amd64-only like its builder. |

## Option A: `pack` unchanged ([cnb-dockerd.sh](cnb-dockerd.sh))

```bash
cnb-dockerd.sh start                      # first run creates volume cnb-docker-data + container cnb-dockerd
export DOCKER_HOST=unix://$HOME/.cnb-dockerd/docker.sock    # or: eval "$(cnb-dockerd.sh env)"
pack build --builder=gcr.io/buildpacks/builder sample-mvn
cnb-dockerd.sh load sample-mvn            # copy the image into Apple container
container run --rm --arch amd64 -p 8080:8080 sample-mvn
cnb-dockerd.sh stop                       # images and build caches persist in the volume
```

What `start` runs under the hood:

```bash
container run -d --name cnb-dockerd --cap-add ALL --read-only-path NONE --masked-path NONE --rosetta \
  -c 6 -m 8G -v cnb-docker-data:/var/lib/docker \
  --publish-socket ~/.cnb-dockerd/docker.sock:/var/run/docker.sock \
  docker.io/library/docker:dind dockerd --host=unix:///var/run/docker.sock --mtu=1280 \
  --feature containerd-snapshotter=false
```

## Option B: no Docker at all ([cnb-build.sh](cnb-build.sh))

```bash
cd /tmp/buildpack-samples/sample-java-mvn
cnb-build.sh sample-mvn                       # options: -p DIR, -B BUILDER, -e KEY=VAL, --clear-cache
container run --rm --arch amd64 -p 8080:8080 sample-mvn
```

What it does:
1. Pulls the builder. It picks arm64 if the builder has it, otherwise amd64 under Rosetta.
2. Reads the run image, platform API and CNB user from the builder's metadata label.
3. Exports the run image with `container image save` and flattens Apple's nested index into the single-manifest OCI layout the lifecycle expects.
4. Runs `creator -layout` in the builder, using a per-app cache volume `cnb-cache-<image>-<arch>`. `-e` values become `/platform/env` files, the same way `pack build --env` works.
5. Names the result, removes stale blobs, and runs `container image load`.

> [!WARNING]
> Option B relies on the lifecycle's experimental "export to OCI layout" feature (`CNB_EXPERIMENTAL_MODE=warn`). It worked with lifecycle 0.21.23 / platform API 0.15, but it isn't a stable contract like `pack` + Docker API.

## Your machine right now
- Images in Apple container: `sample-mvn:latest` (built by Option B), plus `gcr.io/buildpacks/builder`, `gcr.io/buildpacks/google-24/run` and `docker:dind`.
- Option A engine: container `cnb-dockerd` (stopped), volume `cnb-docker-data` (holds the builder and the pack-built `sample-mvn`), socket path `~/.cnb-dockerd/docker.sock`.
- Option B build cache: volume `cnb-cache-sample-mvn-latest-amd64`. Layouts go to `~/.cache/cnb-container` on first use.
