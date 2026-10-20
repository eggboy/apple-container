#!/usr/bin/env bash
#
# cnb-build.sh - Build an OCI image from source with Cloud Native Buildpacks using only
# Apple's `container` CLI: no Docker daemon and no `pack` required.
#
# The CNB lifecycle ("creator") that ships inside the builder image is run directly in
# an Apple container. It exports the app image as an OCI image layout (lifecycle
# experimental feature, platform API >= 0.12), which is then loaded into Apple
# container's local image store.
#
# Usage: cnb-build.sh [options] <image>
#
# Options:
#   -p, --path DIR          App source directory (default: current directory)
#   -B, --builder IMAGE     Builder image (default: gcr.io/buildpacks/builder:latest)
#   -e, --env KEY=VALUE     Build-time environment variable for the buildpacks, like
#                           `pack build --env` (repeatable)
#       --platform OS/ARCH  Build platform (default: linux/arm64 if the builder has it,
#                           otherwise linux/amd64, which runs under Rosetta)
#       --clear-cache       Discard the build cache before building
#   -c, --cpus N            CPUs for the build container (default: 4)
#   -m, --memory SIZE       Memory for the build container (default: 4G)
#       --log-level LEVEL   Lifecycle log level: debug|info|warn|error (default: info)
#   -h, --help              Show this help
#
# State: CNB_HOME (default: ~/.cache/cnb-container) keeps the OCI layouts of the run
# image and of the last build of each app (used for layer reuse). Build caches live
# in Apple container volumes named cnb-cache-<image>-<arch>.
#
# Example:
#   cnb-build.sh -p ~/src/sample-java-mvn sample-mvn
#   container run --rm --arch amd64 -p 8080:8080 sample-mvn
set -euo pipefail

die() { printf 'cnb-build: error: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*" >&2; }
usage() { awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"; }

APP_DIR=.
BUILDER=gcr.io/buildpacks/builder:latest
PLATFORM=
CPUS=4
MEMORY=4G
LOG_LEVEL=info
CLEAR_CACHE=false
CNB_HOME=${CNB_HOME:-$HOME/.cache/cnb-container}
BUILD_ENV=()
IMAGE=

need_arg() { [[ $# -ge 2 && -n $2 ]] || die "option $1 needs a value"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p | --path) need_arg "$@"; APP_DIR=$2; shift 2 ;;
    -B | --builder) need_arg "$@"; BUILDER=$2; shift 2 ;;
    -e | --env)
      need_arg "$@"
      [[ $2 =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || die "--env expects KEY=VALUE, got '$2'"
      BUILD_ENV+=("$2"); shift 2 ;;
    --platform) need_arg "$@"; PLATFORM=$2; shift 2 ;;
    --clear-cache) CLEAR_CACHE=true; shift ;;
    -c | --cpus) need_arg "$@"; CPUS=$2; shift 2 ;;
    -m | --memory) need_arg "$@"; MEMORY=$2; shift 2 ;;
    --log-level) need_arg "$@"; LOG_LEVEL=$2; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *) [[ -z $IMAGE ]] || die "unexpected argument: $1"; IMAGE=$1; shift ;;
  esac
done
[[ -n $IMAGE ]] || { usage >&2; exit 1; }
APP_DIR=$(cd "$APP_DIR" 2>/dev/null && pwd -P) || die "app directory not found: $APP_DIR"
command -v container >/dev/null || die "Apple 'container' CLI not found"
command -v python3 >/dev/null || die "python3 is required"
container system status >/dev/null 2>&1 || die "container services are not running (run: container system start)"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cnb-build.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# --- small JSON / OCI-layout helpers ---------------------------------------------------
cat >"$WORK/cnb.py" <<'PY'
import io, json, os, shutil, sys, tarfile

INDEX_TYPES = {"application/vnd.oci.image.index.v1+json",
               "application/vnd.docker.distribution.manifest.list.v2+json"}

def ref(name):
    """Normalise an image reference the way the lifecycle (go-containerregistry) does.
    Prints '<full reference> <path of its OCI layout below the layout dir>'."""
    if "@" in name:
        sys.exit(f"digest references are not supported: {name}")
    repo, tag = name, "latest"
    if ":" in repo.rsplit("/", 1)[-1]:
        repo, tag = repo.rsplit(":", 1)
    first, _, rest = repo.partition("/")
    registry = "docker.io"
    if rest and ("." in first or ":" in first or first == "localhost"):
        registry, repo = first, rest
    if registry in ("docker.io", "index.docker.io"):
        registry = "docker.io"
        if "/" not in repo:
            repo = "library/" + repo
    layout_registry = "index.docker.io" if registry == "docker.io" else registry
    print(f"{registry}/{repo}:{tag}", f"{layout_registry}/{repo}/{tag}")

def builder_info(platform):
    """Reads `container image inspect <builder>` JSON on stdin.
    Prints '<run image> <platform API> <CNB uid> <CNB gid>'."""
    os_, arch = platform.split("/")[:2]
    variants = json.load(sys.stdin)[0]["variants"]
    cfg = next((v["config"]["config"] for v in variants
                if (v["platform"]["os"], v["platform"]["architecture"]) == (os_, arch)), None)
    if cfg is None:
        sys.exit(f"the builder has no {platform} variant")
    labels = cfg.get("Labels") or {}
    if "io.buildpacks.builder.metadata" not in labels:
        sys.exit("not a CNB builder image (no io.buildpacks.builder.metadata label)")
    md = json.loads(labels["io.buildpacks.builder.metadata"])
    run = ((md.get("images") or [{}])[0].get("image")
           or md.get("stack", {}).get("runImage", {}).get("image"))
    if not run:
        sys.exit("the builder metadata does not name a run image")
    apis = md["lifecycle"]["apis"]["platform"]["supported"]
    best = max(apis, key=lambda s: tuple(int(x) for x in s.split(".")))
    if tuple(int(x) for x in best.split(".")) < (0, 12):
        sys.exit(f"the builder's lifecycle only supports platform API <= {best}; OCI layout export needs >= 0.12")
    env = dict(e.split("=", 1) for e in cfg.get("Env", []) if "=" in e)
    print(run, best, env.get("CNB_USER_ID", "1000"), env.get("CNB_GROUP_ID", "1000"))

def image_id():
    print(json.load(sys.stdin)[0]["id"])

def flatten(src_tar, dest, platform):
    """`container image save` output -> single-manifest OCI layout, which is what the
    lifecycle expects for the run image (Apple container nests an extra index)."""
    os_, arch = platform.split("/")[:2]
    tmp = dest + ".tmp"
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    with tarfile.open(src_tar) as t:
        if hasattr(tarfile, "data_filter"):
            t.extractall(tmp, filter="data")
        else:
            t.extractall(tmp)
    def blob(d):
        algo, hexd = d["digest"].split(":", 1)
        with open(os.path.join(tmp, "blobs", algo, hexd)) as f:
            return json.load(f)
    def resolve(d):
        if d.get("mediaType") not in INDEX_TYPES:
            return [d]
        found = []
        for m in blob(d)["manifests"]:
            p = m.get("platform")
            if p and (p.get("os"), p.get("architecture")) != (os_, arch):
                continue
            found += resolve(m)
        return found
    with open(os.path.join(tmp, "index.json")) as f:
        top = json.load(f)
    found = [x for m in top["manifests"] for x in resolve(m)]
    if len(found) != 1:
        sys.exit(f"expected one {platform} manifest in the run image, found {len(found)}")
    desc = {k: found[0][k] for k in ("mediaType", "digest", "size")}
    with open(os.path.join(tmp, "index.json"), "w") as f:
        json.dump({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.index.v1+json",
                   "manifests": [desc]}, f)
    shutil.rmtree(dest, ignore_errors=True)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    os.rename(tmp, dest)

def package(layout, full_ref, out):
    """Lifecycle OCI layout -> tarball that `container image load` accepts, named
    <full_ref>. Also deletes blobs that the current image no longer references."""
    with open(os.path.join(layout, "index.json")) as f:
        index = json.load(f)
    if len(index.get("manifests", [])) != 1:
        sys.exit(f"expected exactly one manifest in {layout}/index.json")
    desc = index["manifests"][0]
    ann = desc.setdefault("annotations", {})
    ann["org.opencontainers.image.ref.name"] = full_ref
    ann["io.containerd.image.name"] = full_ref
    def path(digest):
        algo, hexd = digest.split(":", 1)
        return os.path.join(layout, "blobs", algo, hexd)
    with open(path(desc["digest"])) as f:
        manifest = json.load(f)
    keep = {desc["digest"], manifest["config"]["digest"]} | {l["digest"] for l in manifest["layers"]}
    for algo in os.listdir(os.path.join(layout, "blobs")):
        for hexd in os.listdir(os.path.join(layout, "blobs", algo)):
            if f"{algo}:{hexd}" not in keep:
                os.remove(os.path.join(layout, "blobs", algo, hexd))
    data = json.dumps(index).encode()
    with tarfile.open(out, "w") as tar:
        tar.add(os.path.join(layout, "oci-layout"), "oci-layout")
        info = tarfile.TarInfo("index.json")
        info.size = len(data)
        tar.addfile(info, io.BytesIO(data))
        tar.add(os.path.join(layout, "blobs"), "blobs")

if __name__ == "__main__":
    cmd, *args = sys.argv[1:]
    {"ref": ref, "builder-info": builder_info, "image-id": image_id,
     "flatten": flatten, "package": package}[cmd](*args)
PY
py() { python3 "$WORK/cnb.py" "$@"; }

out=$(py ref "$IMAGE") || exit 1
read -r IMAGE_REF IMAGE_LAYOUT <<<"$out"

# --- 1. builder -----------------------------------------------------------------------
step "Pulling builder $BUILDER"
if [[ -z $PLATFORM ]]; then
  if container image pull --progress none --platform linux/arm64 "$BUILDER" >/dev/null 2>&1; then
    PLATFORM=linux/arm64
  else
    PLATFORM=linux/amd64
  fi
fi
container image pull --progress none --platform "$PLATFORM" "$BUILDER" >/dev/null
ARCH=${PLATFORM#*/}
ARCH=${ARCH%%/*}
out=$(container image inspect "$BUILDER" | py builder-info "$PLATFORM") || exit 1
read -r RUN_IMAGE PLATFORM_API CNB_UID CNB_GID <<<"$out"
echo "platform $PLATFORM, lifecycle platform API $PLATFORM_API, run image $RUN_IMAGE, CNB user $CNB_UID:$CNB_GID" >&2

# --- 2. run image as an OCI layout (refreshed only when the image changes) --------------
LAYOUT_ROOT="$CNB_HOME/${PLATFORM//\//-}"
out=$(py ref "$RUN_IMAGE") || exit 1
read -r RUN_REF RUN_LAYOUT <<<"$out"
step "Preparing run image $RUN_REF"
container image pull --progress none --platform "$PLATFORM" "$RUN_REF" >/dev/null
RUN_ID=$(container image inspect "$RUN_REF" | py image-id)
STAMP="$LAYOUT_ROOT/.stamps/$(printf '%s' "$RUN_LAYOUT" | tr '/' '_')"
if [[ ! -f $LAYOUT_ROOT/$RUN_LAYOUT/index.json || "$(cat "$STAMP" 2>/dev/null)" != "$RUN_ID" ]]; then
  container image save --platform "$PLATFORM" -o "$WORK/run.tar" "$RUN_REF" >/dev/null
  py flatten "$WORK/run.tar" "$LAYOUT_ROOT/$RUN_LAYOUT" "$PLATFORM"
  mkdir -p "$(dirname "$STAMP")"
  printf '%s\n' "$RUN_ID" >"$STAMP"
  rm -f "$WORK/run.tar"
fi

# --- 3. build cache volume ------------------------------------------------------------
VOLUME="cnb-cache-$(printf '%s' "${IMAGE_REF#docker.io/library/}-$ARCH" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9' '-' | cut -c1-80)"
if $CLEAR_CACHE; then
  container volume rm "$VOLUME" >/dev/null 2>&1 || true
fi
container volume inspect "$VOLUME" >/dev/null 2>&1 || container volume create "$VOLUME" >/dev/null

# --- 4. run the lifecycle -------------------------------------------------------------
ENV_ARGS=()
for kv in ${BUILD_ENV[@]+"${BUILD_ENV[@]}"}; do ENV_ARGS+=(-e "CNB_BUILD_ENV__$kv"); done

# Runs as root inside the builder: copy the source (pack does the same, so buildpacks
# that delete source files never touch your checkout), write the build env files, then
# hand over to the creator, which chowns its dirs and drops to the CNB user itself.
INNER='set -euo pipefail
mkdir -p /workspace /platform/env
cp -a /src/. /workspace/
for v in $(compgen -e); do
  case "$v" in
    CNB_BUILD_ENV__*) printf "%s" "${!v}" > "/platform/env/${v#CNB_BUILD_ENV__}"; unset "$v" ;;
  esac
done
chown -R "$CNB_USER_ID:$CNB_GROUP_ID" /workspace
exec /cnb/lifecycle/creator -app=/workspace -layers=/layers -platform=/platform \
  -cache-dir=/cache -layout -layout-dir=/layout-repo \
  -run-image="$CNB_RUN_REF" -log-level="$CNB_LOG_LEVEL" "$CNB_OUT_REF"'

step "Building $IMAGE_REF from $APP_DIR"
container run --rm --progress none --platform "$PLATFORM" -u 0:0 -c "$CPUS" -m "$MEMORY" \
  --mount "type=bind,source=$APP_DIR,target=/src,readonly" \
  -v "$LAYOUT_ROOT:/layout-repo" \
  -v "$VOLUME:/cache" \
  -e "CNB_PLATFORM_API=$PLATFORM_API" -e CNB_EXPERIMENTAL_MODE=warn \
  -e "CNB_RUN_REF=$RUN_REF" -e "CNB_OUT_REF=$IMAGE_REF" -e "CNB_LOG_LEVEL=$LOG_LEVEL" \
  ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} \
  "$BUILDER" bash -c "$INNER"

# --- 5. load into Apple container -----------------------------------------------------
OUT="$LAYOUT_ROOT/$IMAGE_LAYOUT"
[[ -f $OUT/index.json ]] || die "the build did not produce an image at $OUT"
step "Loading $IMAGE_REF into Apple container"
py package "$OUT" "$IMAGE_REF" "$WORK/image.tar"
if ! container image load -i "$WORK/image.tar" >"$WORK/load.log" 2>&1; then
  cat "$WORK/load.log" >&2
  die "container image load failed"
fi

ARCH_FLAG=
[[ $ARCH == "$(uname -m | sed 's/x86_64/amd64/')" ]] || ARCH_FLAG=" --arch $ARCH"
printf '\nSuccessfully built %s\nRun it with:  container run --rm%s -p 8080:8080 %s\n' \
  "$IMAGE_REF" "$ARCH_FLAG" "$IMAGE"
