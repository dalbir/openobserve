#!/usr/bin/env bash
#
# 1. Go to the repo root (where web/ and deploy/ both exist)
#cd /path/to/openobserve      # e.g. .../Git/observer/openobserve

# 2. Confirm the layout — you should see BOTH of these:
#ls -d web deploy/build/Dockerfile

# 3. Run the script pointing at the Dockerfile via its full path
#./build-branded.sh --deploy -f deploy/build/Dockerfile


# build-branded.sh
# -----------------
# Builds a custom-branded OpenObserve Docker image (Option A: UI embedded in the
# Rust binary) and optionally recreates the running compose service.
#
# The web/ UI is compiled and baked into the Rust binary during the Docker build,
# so this script must be run whenever you change anything under web/ and want it
# reflected in the deployed image.
#
# Usage:
#   ./build-branded.sh                       # auto-increment patch, build only
#   ./build-branded.sh -v 0.3.0              # build with an explicit version tag
#   ./build-branded.sh -v 0.3.0 --deploy     # build, then recreate compose service
#   ./build-branded.sh --deploy              # auto-version, build, and deploy
#   ./build-branded.sh --no-cache            # force a clean rebuild
#
# Options:
#   -n, --name       Image name            (default: my-openobserve)
#   -v, --version    Version tag           (default: auto-increment from VERSION file)
#   -f, --file       Dockerfile path       (default: deploy/build/Dockerfile)
#   -s, --service    Compose service name  (default: openobserve)
#       --deploy     Recreate the compose service after a successful build
#       --no-cache   Build without using Docker layer cache
#   -h, --help       Show this help message
#
set -euo pipefail

# ---------- Defaults ---------------------------------------------------------
IMAGE_NAME="my-openobserve"
DOCKERFILE="./build/Dockerfile"
SERVICE_NAME="openobserve"
BUILD_CONTEXT="."
VERSION_FILE=".branded-version"
VERSION=""
DEPLOY=false
NO_CACHE=""

# ---------- Colors -----------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ---------- Help -------------------------------------------------------------
usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ---------- Parse args -------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--name)     IMAGE_NAME="$2"; shift 2 ;;
    -v|--version)  VERSION="$2"; shift 2 ;;
    -f|--file)     DOCKERFILE="$2"; shift 2 ;;
    -s|--service)  SERVICE_NAME="$2"; shift 2 ;;
    --deploy)      DEPLOY=true; shift ;;
    --no-cache)    NO_CACHE="--no-cache"; shift ;;
    -h|--help)     usage ;;
    *) err "Unknown option: $1"; echo "Run '$0 --help' for usage."; exit 1 ;;
  esac
done

# ---------- Pre-flight checks ------------------------------------------------
command -v docker >/dev/null 2>&1 || { err "docker is not installed or not on PATH."; exit 1; }

if ! docker info >/dev/null 2>&1; then
  err "Docker daemon is not running or you lack permission (try: sudo usermod -aG docker \$USER)."
  exit 1
fi

if [[ ! -f "$DOCKERFILE" ]]; then
  err "Dockerfile not found at: $DOCKERFILE"
  err "Run this script from the openobserve repo root, or pass -f <path>."
  exit 1
fi

# ---------- Determine version tag --------------------------------------------
if [[ -z "$VERSION" ]]; then
  if [[ -f "$VERSION_FILE" ]]; then
    CURRENT="$(cat "$VERSION_FILE")"
  else
    CURRENT="0.1.0"
  fi
  # Auto-increment the patch component (x.y.Z -> x.y.Z+1)
  IFS='.' read -r MAJ MIN PAT <<< "$CURRENT"
  MAJ="${MAJ:-0}"; MIN="${MIN:-1}"; PAT="${PAT:-0}"
  PAT=$((PAT + 1))
  VERSION="${MAJ}.${MIN}.${PAT}"
  info "Auto-incremented version: ${CURRENT} -> ${VERSION}"
fi

TAG_VERSION="${IMAGE_NAME}:v${VERSION}-branded"
TAG_LATEST="${IMAGE_NAME}:branded"

# ---------- Build ------------------------------------------------------------
export DOCKER_BUILDKIT=1   # faster builds + better layer caching

info "Building branded OpenObserve image..."
info "  Image tags : ${TAG_VERSION}, ${TAG_LATEST}"
info "  Dockerfile : ${DOCKERFILE}"
info "  BuildKit   : enabled"
[[ -n "$NO_CACHE" ]] && warn "Cache disabled (--no-cache): expect a full recompile."

START_TS=$(date +%s)

if docker build $NO_CACHE \
      -t "$TAG_VERSION" \
      -t "$TAG_LATEST" \
      -f "$DOCKERFILE" \
      "$BUILD_CONTEXT"; then
  ELAPSED=$(( $(date +%s) - START_TS ))
  ok "Build succeeded in ${ELAPSED}s."
  echo "$VERSION" > "$VERSION_FILE"
  ok "Recorded version ${VERSION} in ${VERSION_FILE}."
else
  err "Docker build failed."
  err "If it failed while fetching Rust crates, the container could not reach crates.io"
  err "(likely the same firewall that blocked your local rustup). Ask IT to allowlist"
  err "crates.io + static.rust-lang.org for Docker egress, or use the nginx approach."
  exit 1
fi

# ---------- Deploy (optional) ------------------------------------------------
if $DEPLOY; then
  info "Deploying: recreating compose service '${SERVICE_NAME}'..."

  # Support both 'docker compose' (v2) and legacy 'docker-compose' (v1)
  if docker compose version >/dev/null 2>&1; then
    COMPOSE="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE="docker-compose"
  else
    err "Neither 'docker compose' nor 'docker-compose' is available. Skipping deploy."
    err "Update your compose file to image: ${TAG_VERSION} and recreate manually."
    exit 1
  fi

  warn "Ensure your compose file points to image: ${TAG_VERSION} (or ${TAG_LATEST})."
  if $COMPOSE up -d --force-recreate "$SERVICE_NAME"; then
    ok "Service '${SERVICE_NAME}' recreated with the new image."
  else
    err "Failed to recreate the compose service."
    exit 1
  fi
fi

# ---------- Summary ----------------------------------------------------------
echo
ok "Done."
echo -e "  Version tag : ${GREEN}${TAG_VERSION}${NC}"
echo -e "  Latest tag  : ${GREEN}${TAG_LATEST}${NC}"
echo
info "Point your docker-compose.yml at:"
echo "    services:"
echo "      ${SERVICE_NAME}:"
echo "        image: ${TAG_VERSION}"
echo
$DEPLOY || info "Tip: re-run with --deploy to build AND recreate the service in one go."
