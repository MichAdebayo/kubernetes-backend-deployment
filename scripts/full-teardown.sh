#!/usr/bin/env bash
set -euo pipefail

# Tear down all namespaced resources for this project and optionally delete the local cluster.
# Usage: ./scripts/full-teardown.sh [--yes] [--delete-cluster] [--cluster-provider kind|minikube]

# Load .env if present
if [ -f ".env" ]; then
  # shellcheck disable=SC1091
  set -a; . .env; set +a
fi

DELETE_CLUSTER=0
YES=0
CLUSTER_PROVIDER="${CLUSTER_PROVIDER:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) YES=1; shift;;
    --delete-cluster) DELETE_CLUSTER=1; shift;;
    --cluster-provider) CLUSTER_PROVIDER="$2"; shift 2;;
    -h|--help) echo "Usage: $0 [--yes] [--delete-cluster] [--cluster-provider kind|minikube]"; exit 0;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

NAMESPACE="brief-ns"

if [[ $YES -ne 1 ]]; then
  echo "This will delete all resources in namespace '$NAMESPACE' (manifests/, jobs, pvc, pv, ingress) and optionally the cluster."
  read -p "Continue? (y/N) " yn
  [[ "$yn" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }
fi

echo "Deleting manifests in manifests/ (namespace $NAMESPACE)..."
kubectl delete -f manifests/ -n "$NAMESPACE" --ignore-not-found || true

echo "Deleting Jobs, CronJobs..."
kubectl delete job --all -n "$NAMESPACE" --ignore-not-found || true
kubectl delete cronjob --all -n "$NAMESPACE" --ignore-not-found || true

echo "Deleting PVCs in $NAMESPACE..."
kubectl delete pvc --all -n "$NAMESPACE" --ignore-not-found || true

# Delete PVs that are bound to this namespace (safe)
pvs_to_delete=$(kubectl get pv -o jsonpath='{range .items[?(@.spec.claimRef.namespace=="'"$NAMESPACE"'" )]}{.metadata.name}{"\n"}{end}' || true)
if [[ -n "$pvs_to_delete" ]]; then
  echo "Deleting PVs bound to namespace $NAMESPACE:"
  echo "$pvs_to_delete"
  for pv in $pvs_to_delete; do
    kubectl delete pv "$pv" --ignore-not-found || true
  done
else
  echo "No PVs bound to $NAMESPACE."
fi

echo "Deleting secrets/configmaps/ingress in $NAMESPACE..."
kubectl delete secret --all -n "$NAMESPACE" --ignore-not-found || true
kubectl delete configmap --all -n "$NAMESPACE" --ignore-not-found || true
kubectl delete ingress --all -n "$NAMESPACE" --ignore-not-found || true
kubectl delete svc --all -n "$NAMESPACE" --ignore-not-found || true
kubectl delete deploy --all -n "$NAMESPACE" --ignore-not-found || true
kubectl delete rs --all -n "$NAMESPACE" --ignore-not-found || true
kubectl delete pod --all -n "$NAMESPACE" --ignore-not-found || true

echo "Deleting namespace $NAMESPACE..."
kubectl delete namespace "$NAMESPACE" --ignore-not-found || true

# Try to uninstall ingress-nginx if present
if kubectl get ns ingress-nginx >/dev/null 2>&1; then
  if command -v helm >/dev/null 2>&1 && helm ls -n ingress-nginx | grep -q ingress-nginx; then
    echo "Uninstalling ingress-nginx Helm release..."
    helm uninstall ingress-nginx -n ingress-nginx || true
  fi
  echo "Deleting ingress-nginx namespace..."
  kubectl delete namespace ingress-nginx --ignore-not-found || true
fi

if [[ $DELETE_CLUSTER -eq 1 ]]; then
  provider="$CLUSTER_PROVIDER"
  if [[ -z "$provider" ]]; then
    ctx=$(kubectl config current-context 2>/dev/null || true)
    if [[ "$ctx" == kind* ]]; then provider="kind"; fi
    if command -v minikube >/dev/null 2>&1 && minikube status >/dev/null 2>&1 && minikube status | grep -qi running; then provider="minikube"; fi
  fi

  if [[ "$provider" == "kind" ]]; then
    echo "Deleting kind cluster (brief-cluster)..."
    kind delete cluster --name brief-cluster || true
  elif [[ "$provider" == "minikube" ]]; then
    echo "Deleting minikube profile..."
    minikube delete --profile "${MINIKUBE_PROFILE:-minikube}" || true
  else
    echo "No cluster deletion performed. Provide --cluster-provider kind|minikube or set context appropriately."
  fi
fi

echo "Teardown complete."