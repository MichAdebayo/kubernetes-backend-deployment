#!/usr/bin/env bash
set -euo pipefail

# Safe docker image cleanup for this project.
# Usage:
#   ./scripts/clean-images.sh --project sengsathit/brief-api,sengsathit/brief-mysql  # delete project images
#   ./scripts/clean-images.sh --delete-kind                             # delete kind node images (e.g., kindest/node:*)
#   ./scripts/clean-images.sh --prune --force                           # run `docker system prune -af`
#   ./scripts/clean-images.sh --help

DELETE_KIND=0
PRUNE=0
FORCE=0
PROJECT_PATTERNS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --delete-kind) DELETE_KIND=1; shift;;
    --prune) PRUNE=1; shift;;
    --force) FORCE=1; shift;;
    --project) PROJECT_PATTERNS="$2"; shift 2;;
    -h|--help) echo "Usage: $0 [--project pat1,pat2] [--delete-kind] [--prune] [--force]"; exit 0;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

if [[ $PRUNE -eq 0 && $DELETE_KIND -eq 0 && -z "$PROJECT_PATTERNS" ]]; then
  echo "Nothing to do. Pass --project, --delete-kind or --prune. Use --help for usage." >&2
  exit 1
fi

confirm() {
  if [[ $FORCE -eq 1 ]]; then
    return 0
  fi
  read -p "$1 (y/N) " yn
  [[ "$yn" =~ ^[Yy] ]]
}

remove_images_by_ids() {
  ids="$1"
  if [[ -z "$ids" ]]; then
    return
  fi
  echo "Removing images:"
  echo "$ids"
  if confirm "Proceed to delete these images?"; then
    docker rmi $ids || true
  else
    echo "Skipped deletion.";
  fi
}

# Delete project images matching provided patterns
if [[ -n "$PROJECT_PATTERNS" ]]; then
  IFS=',' read -r -a pats <<< "$PROJECT_PATTERNS"
  MATCH_IDS=""
  for p in "${pats[@]}"; do
    # docker images --format "{{.Repository}}:{{.Tag}} {{.ID}}"
    mapfile -t lines < <(docker images --format "{{.Repository}}:{{.Tag}} {{.ID}}" | grep -E "^${p}(:|$)" || true)
    for l in "${lines[@]}"; do
      id=$(echo "$l" | awk '{print $2}')
      MATCH_IDS+="$id "
    done
  done
  if [[ -n "$MATCH_IDS" ]]; then
    remove_images_by_ids "$MATCH_IDS"
  else
    echo "No images matched project patterns: $PROJECT_PATTERNS"
  fi
fi

# Delete kind node images (if requested)
if [[ $DELETE_KIND -eq 1 ]]; then
  mapfile -t kind_lines < <(docker images --format "{{.Repository}}:{{.Tag}} {{.ID}}" | grep -E "kindest/node" || true)
  KIDS=""
  for l in "${kind_lines[@]}"; do
    id=$(echo "$l" | awk '{print $2}')
    KIDS+="$id "
  done
  if [[ -n "$KIDS" ]]; then
    echo "Found kind node images:"
    printf "%s
" "${kind_lines[@]}"
    if confirm "Delete these kind node images? (This removes kind base images from your Docker daemon)"; then
      docker rmi $KIDS || true
    else
      echo "Skipped deletion of kind images."
    fi
  else
    echo "No kind node images found."
  fi
fi

# Prune if requested
if [[ $PRUNE -eq 1 ]]; then
  if confirm "Run 'docker system prune -af' (this will remove unused images, containers, networks)?"; then
    docker system prune -af || true
  else
    echo "Skipped prune."
  fi
fi

echo "Done."