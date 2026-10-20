#!/usr/bin/env bash
#
# cnb-dockerd.sh - Run a Docker Engine *inside an Apple container* and publish its
# API socket on macOS, so tools that only speak the Docker Engine API (such as the
# Cloud Native Buildpacks `pack` CLI) work without Docker Desktop.
#
# Usage: cnb-dockerd.sh <command>
#
# Commands:
#   start        Create (first run) or start the engine and wait until it answers
#   env          Print the DOCKER_HOST export line:  eval "$(cnb-dockerd.sh env)"
#   load IMAGE   Copy IMAGE from the engine into Apple container's image store
#   status       Show whether the engine is running and reachable
#   stop         Stop the engine (images and build caches are kept)
#   rm           Delete the engine container (the data volume is kept)
#
# Example:
#   cnb-dockerd.sh start && eval "$(cnb-dockerd.sh env)"
#   pack build --builder=gcr.io/buildpacks/builder sample-mvn
#   cnb-dockerd.sh load sample-mvn
#   container run --rm --arch amd64 -p 8080:8080 sample-mvn
#
# Settings (environment variables, defaults in brackets):
#   CNB_DOCKERD_NAME [cnb-dockerd]   CNB_DOCKERD_SOCK [~/.cnb-dockerd/docker.sock]
#   CNB_DOCKERD_VOLUME [cnb-docker-data]   CNB_DOCKERD_IMAGE [docker.io/library/docker:dind]
#   CNB_DOCKERD_CPUS [6]   CNB_DOCKERD_MEMORY [8G]
set -euo pipefail

NAME=${CNB_DOCKERD_NAME:-cnb-dockerd}
SOCK=${CNB_DOCKERD_SOCK:-$HOME/.cnb-dockerd/docker.sock}
VOLUME=${CNB_DOCKERD_VOLUME:-cnb-docker-data}
IMAGE=${CNB_DOCKERD_IMAGE:-docker.io/library/docker:dind}
CPUS=${CNB_DOCKERD_CPUS:-6}
MEMORY=${CNB_DOCKERD_MEMORY:-8G}

die() { printf 'cnb-dockerd: error: %s\n' "$*" >&2; exit 1; }
usage() { awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"; }
api() { curl -fsS --unix-socket "$SOCK" "http://localhost$1" "${@:2}"; }
reachable() { api /_ping --max-time 3 >/dev/null 2>&1; }

need_tools() {
  command -v container >/dev/null || die "Apple 'container' CLI not found"
  command -v python3 >/dev/null || die "python3 is required"
}

# Prints absent | running | stopped, from `.[0].status.state` of `container inspect`.
state() {
  local json
  json=$(container inspect "$NAME" 2>/dev/null) || { echo absent; return; }
  python3 -c 'import json, sys
d = json.load(sys.stdin)
print("running" if d and d[0].get("status", {}).get("state") == "running" else "stopped")' <<<"$json"
}

cmd_start() {
  need_tools
  case "$(state)" in
    running) ;;
    absent)
      mkdir -p "$(dirname "$SOCK")"
      # The runtime unlinks a stale host socket before binding and removes it on stop;
      # this is belt and braces for a leftover file from an older engine or a crash.
      rm -f "$SOCK"
      container volume inspect "$VOLUME" >/dev/null 2>&1 || container volume create "$VOLUME" >/dev/null
      # --cap-add ALL + no masked/read-only /proc and /sys paths ~= `docker run --privileged`,
      #   which dockerd needs (e.g. it must write /proc/sys/net/ipv4/ip_forward).
      # --rosetta registers Rosetta for x86_64 binaries with binfmt flag "F", so amd64-only
      #   builder images (like gcr.io/buildpacks/builder) also run in the nested containers.
      # --mtu matches the 1280-byte MTU of the Apple container network interface.
      # containerd-snapshotter=false: classic image store, faster for pack's daemon export.
      container run -d --progress none --name "$NAME" \
        --cap-add ALL --read-only-path NONE --masked-path NONE --rosetta \
        -c "$CPUS" -m "$MEMORY" \
        -v "$VOLUME:/var/lib/docker" \
        --publish-socket "$SOCK:/var/run/docker.sock" \
        "$IMAGE" dockerd --host=unix:///var/run/docker.sock --mtu=1280 \
        --feature containerd-snapshotter=false >/dev/null
      ;;
    *)
      rm -f "$SOCK"  # same belt and braces as above
      local out
      out=$(container start "$NAME" 2>&1) || { printf '%s\n' "$out" >&2; die "could not start $NAME"; }
      ;;
  esac
  for _ in $(seq 1 60); do reachable && break; sleep 1; done
  reachable || die "engine not reachable at $SOCK (see: container logs $NAME)"
  echo "Docker Engine is ready. Point pack at it with:"
  echo "  export DOCKER_HOST=unix://$SOCK"
}

cmd_load() {
  local image=${1:?usage: cnb-dockerd.sh load IMAGE} tmp log
  reachable || die "engine is not running (run: cnb-dockerd.sh start)"
  tmp=$(mktemp "${TMPDIR:-/tmp}/cnb-dockerd-image.XXXXXX")
  log=$(mktemp "${TMPDIR:-/tmp}/cnb-dockerd-load.XXXXXX")
  # `docker save` output (Docker >= 25) is an OCI image layout that `container image load` accepts.
  if ! api "/images/$image/get" -o "$tmp"; then
    rm -f "$tmp" "$log"
    die "image '$image' not found in the engine"
  fi
  if ! container image load -i "$tmp" >"$log" 2>&1; then
    cat "$log" >&2
    rm -f "$tmp" "$log"
    die "container image load failed"
  fi
  rm -f "$tmp" "$log"
  echo "Loaded '$image' into Apple container (see: container image ls)"
}

cmd_status() {
  need_tools
  echo "container '$NAME': $(state)"
  if reachable; then echo "engine: reachable at unix://$SOCK"; else echo "engine: not reachable"; fi
}

case "${1:-}" in
  start) cmd_start ;;
  env) echo "export DOCKER_HOST=unix://$SOCK" ;;
  load) shift; cmd_load "$@" ;;
  status) cmd_status ;;
  stop) container stop "$NAME" >/dev/null && echo "stopped $NAME" ;;
  rm) container stop "$NAME" >/dev/null 2>&1 || true; container rm "$NAME" >/dev/null && echo "deleted $NAME (volume $VOLUME kept)" ;;
  -h | --help | help) usage ;;
  *) usage >&2; exit 1 ;;
esac
