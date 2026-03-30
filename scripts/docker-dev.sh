#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE_TAG="${QQ_DEV_IMAGE_TAG:-quick-question-dev}"

usage() {
  cat <<'EOF'
Usage:
  scripts/docker-dev.sh print-json
  scripts/docker-dev.sh build
  scripts/docker-dev.sh shell
  scripts/docker-dev.sh test

Commands:
  print-json  Print resolved repo_root, git_dir, mount_root, and image_tag
  build       Build the dev image from .devcontainer/Dockerfile
  shell       Open an interactive shell in the dev container
  test        Run postCreate + test.sh + capability validate + doctor in the dev container
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command not found: $1" >&2
    exit 1
  fi
}

git_dir_abs() {
  local git_dir
  git_dir="$(git -C "$REPO_ROOT" rev-parse --git-dir)"
  python3 - "$REPO_ROOT" "$git_dir" <<'PY'
import sys
from pathlib import Path

repo_root = Path(sys.argv[1]).resolve()
git_dir = Path(sys.argv[2])
if not git_dir.is_absolute():
    git_dir = (repo_root / git_dir).resolve()
print(git_dir)
PY
}

mount_root_abs() {
  local git_dir
  git_dir="$(git_dir_abs)"
  python3 - "$REPO_ROOT" "$git_dir" <<'PY'
import os
import sys

repo_root = os.path.realpath(sys.argv[1])
git_dir = os.path.realpath(sys.argv[2])
print(os.path.commonpath([repo_root, git_dir]))
PY
}

print_json() {
  local git_dir mount_root
  git_dir="$(git_dir_abs)"
  mount_root="$(mount_root_abs)"
  python3 - "$REPO_ROOT" "$git_dir" "$mount_root" "$IMAGE_TAG" <<'PY'
import json
import sys

print(json.dumps({
    "repo_root": sys.argv[1],
    "git_dir": sys.argv[2],
    "mount_root": sys.argv[3],
    "image_tag": sys.argv[4],
}, indent=2))
PY
}

docker_build() {
  require_cmd docker
  docker build -f "$REPO_ROOT/.devcontainer/Dockerfile" -t "$IMAGE_TAG" "$REPO_ROOT"
}

ensure_image() {
  require_cmd docker
  if ! docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
    echo "Dev image '$IMAGE_TAG' not found. Building it now..."
    docker_build
  fi
}

docker_run_base() {
  local mount_root
  mount_root="$(mount_root_abs)"
  docker run --rm \
    -v "$mount_root:$mount_root" \
    -w "$REPO_ROOT" \
    "$IMAGE_TAG" \
    "$@"
}

docker_shell() {
  ensure_image
  docker_run_base -it bash
}

docker_test() {
  ensure_image
  docker_run_base \
    bash -lc "git config --global --add safe.directory '$REPO_ROOT' && \
      bash .devcontainer/postCreate.sh && \
      ./test.sh && \
      python3 ./scripts/qq-capability.py validate --pretty && \
      ./scripts/qq-doctor.sh --pretty"
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    print-json)
      print_json
      ;;
    build)
      docker_build
      ;;
    shell)
      docker_shell
      ;;
    test)
      docker_test
      ;;
    ""|-h|--help|help)
      usage
      ;;
    *)
      echo "Error: unknown command: $cmd" >&2
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
