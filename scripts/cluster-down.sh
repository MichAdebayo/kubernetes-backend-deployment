#!/usr/bin/env bash
set -euo pipefail

# Simple script to stop or delete local clusters (kind, minikube, docker-desktop).
# Usage: ./scripts/cluster-down.sh [--provider kind|minikube|docker-desktop] [--cluster-name NAME] [--force]

# Load .env if present
if [ -f ".env" ]; then
  # shellcheck disable=SC1091
  set -a; . .env; set +a
fi

provider="${PROVIDER:-}"
cluster_name="${CLUSTER_NAME:-}"
force=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider) provider="$2"; shift 2;;
    --cluster-name) cluster_name="$2"; shift 2;;
    --force) force=1; shift;;
    -h|--help) echo "Usage: $0 [--provider kind|minikube|docker-desktop] [--cluster-name NAME] [--force]"; exit 0;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

# auto-detect if provider not given
if [[ -z "$provider" ]]; then
  ctx=$(kubectl config current-context 2>/dev/null || true)
  if command -v kind >/dev/null 2>&1 && [[ "$(kind get clusters 2>/dev/null || true)" != "" ]]; then
    provider="kind"
  elif command -v minikube >/dev/null 2>&1 && minikube status >/dev/null 2>&1 && minikube status | grep -qi running; then
    provider="minikube"
  elif [[ "$ctx" == *"docker-desktop"* ]]; then
    provider="docker-desktop"
  else
    echo "Cannot detect provider automatically. Provide --provider kind|minikube|docker-desktop"
    exit 1
  fi
fi

cluster_name="${cluster_name:-brief-cluster}"

case "$provider" in
  kind)
    if [[ "$force" -ne 1 ]]; then
      read -p "This will delete the kind cluster '$cluster_name'. Continue? (y/N) " yn
      [[ "$yn" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }
    fi
    echo "Deleting kind cluster '$cluster_name'..."
    kind delete cluster --name "$cluster_name"
    echo "kind cluster deleted."
    ;;
  minikube)
    echo "Stopping minikube (profile: ${cluster_name:-minikube})..."
    minikube stop --profile "${cluster_name:-minikube}"
    echo "minikube stopped."
    ;;
  docker-desktop)
    if [[ "$force" -ne 1 ]]; then
      read -p "To stop docker-desktop cluster you must quit Docker Desktop. Quit Docker now? (y/N) " yn
      [[ "$yn" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }
    fi
    echo "Quitting Docker Desktop..."
    osascript -e 'quit app "Docker"' || echo "Could not quit Docker automatically; please quit Docker Desktop manually."
    echo "Docker Desktop quit (or attempted)."
    ;;
  *)
    echo "Unsupported provider: $provider"
    exit 1
    ;;
esac

echo "Done."