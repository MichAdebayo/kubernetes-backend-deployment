#!/usr/bin/env bash
set -euo pipefail

# Create a local kind cluster, install ingress-nginx, deploy manifests, init & seed DB, and run endpoint checks
# Usage: ./scripts/cluster-up.sh [--cluster-name brief-cluster] [--skip-ingress-install]

# Load .env if present (export variables to environment)
if [ -f ".env" ]; then
  # shellcheck disable=SC1091
  set -a; . .env; set +a
fi

CLUSTER_NAME="${CLUSTER_NAME:-brief-cluster}"
SKIP_INGRESS="${SKIP_INGRESS:-0}"
TIMEOUT="${TIMEOUT:-300}"
INGRESS_TIMEOUT="${INGRESS_TIMEOUT:-600}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-name) CLUSTER_NAME="$2"; shift 2;;
    --skip-ingress-install) SKIP_INGRESS=1; shift;;
    -h|--help) echo "Usage: $0 [--cluster-name brief-cluster] [--skip-ingress-install]"; exit 0;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

command -v kind >/dev/null 2>&1 || { echo "kind is required. Install from https://kind.sigs.k8s.io/"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required."; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "docker is required."; exit 1; }

echo "Creating kind cluster '$CLUSTER_NAME' (if missing)..."
if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
  echo "Cluster '${CLUSTER_NAME}' already exists. Skipping creation."
else
  kind create cluster --name "$CLUSTER_NAME"
fi

echo "Waiting for nodes to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=${TIMEOUT}s

# Ingress installation deferred until core services (mysql + api) are ready.
# Use --skip-ingress-install to avoid installing the controller entirely.
if [[ $SKIP_INGRESS -eq 1 ]]; then
  echo "Skipping ingress install as requested."
fi

echo "Applying namespace first (manifests/namespace.yaml)..."
if [[ -f "manifests/namespace.yaml" ]]; then
  echo "Applying manifests/namespace.yaml..."
  kubectl apply -f manifests/namespace.yaml
else
  echo "Warning: manifests/namespace.yaml not found; continuing"
fi

echo "Applying remaining manifests (excluding namespace.yaml and ingress.yaml)..."
for f in manifests/*.yaml; do
  filename=$(basename "$f")
  if [[ "$filename" == "ingress.yaml" || "$filename" == "namespace.yaml" ]]; then
    echo "Deferring $f until later."
    continue
  fi
  echo "Applying $f..."
  kubectl apply -f "$f"
done

echo "Waiting for mysql deployment rollout..."
kubectl -n brief-ns rollout status deployment/mysql --timeout=${TIMEOUT}s

echo "Waiting for api deployment rollout..."
kubectl -n brief-ns rollout status deployment/brief-api --timeout=${TIMEOUT}s

# Label nodes so ingress can schedule on kind control-plane nodes
echo "Labeling nodes for ingress scheduling (ingress-ready=true)..."
kubectl label node --all ingress-ready=true --overwrite || true

# Install ingress after core services are ready, unless skipped
if [[ $SKIP_INGRESS -eq 0 ]]; then
  echo "Installing ingress-nginx for kind..."
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.1/deploy/static/provider/kind/deploy.yaml
  echo "Waiting for ingress controller pods (timeout: ${INGRESS_TIMEOUT}s)..."
  if ! kubectl -n ingress-nginx wait --for=condition=Ready pod -l app.kubernetes.io/component=controller --timeout=${INGRESS_TIMEOUT}s; then
    echo "ERROR: Ingress controller pods did not become Ready within ${INGRESS_TIMEOUT}s"
    echo "Collecting diagnostics from namespace 'ingress-nginx'..."
    POD_DUMP="/tmp/ingress-pods-$$.txt"
    kubectl get pods -n ingress-nginx -o wide > "$POD_DUMP" 2>&1 || true
    echo "Saved pod list to $POD_DUMP"

    for p in $(kubectl get pods -n ingress-nginx -o name 2>/dev/null || true); do
      NAME=${p#pod/}
      echo "\n===== Logs for pod: $NAME (controller) ====="
      kubectl logs -n ingress-nginx "$NAME" -c controller > "/tmp/${NAME}-controller.log" 2>&1 || true
      tail -n 200 "/tmp/${NAME}-controller.log" || true

      echo "\n===== Logs for pod: $NAME (admission-webhook) ====="
      kubectl logs -n ingress-nginx "$NAME" -c admission-webhook > "/tmp/${NAME}-admission.log" 2>&1 || true
      tail -n 200 "/tmp/${NAME}-admission.log" || true
    done

    echo "See /tmp/ingress-pods-$$.txt and /tmp/*-controller.log for details."
    exit 1
  fi

  # Apply ingress resource only after controller is Ready
  if [[ -f "manifests/ingress.yaml" ]]; then
    echo "Waiting for admission webhook endpoints to be ready (timeout: ${INGRESS_TIMEOUT}s)..."
    START_TS=$(date +%s)
    while true; do
      # check if endpoints exist and have addresses
      if kubectl -n ingress-nginx get endpoints ingress-nginx-controller-admission -o jsonpath='{.subsets[*].addresses[*].ip}' >/dev/null 2>&1; then
        echo "Admission webhook endpoints appear to be present."
        break
      fi
      NOW_TS=$(date +%s)
      ELAPSED=$((NOW_TS-START_TS))
      if [[ $ELAPSED -ge ${INGRESS_TIMEOUT} ]]; then
        echo "ERROR: admission webhook endpoints not ready after ${INGRESS_TIMEOUT}s"
        echo "Collecting diagnostics from namespace 'ingress-nginx'..."
        POD_DUMP="/tmp/ingress-pods-$$.txt"
        kubectl get pods -n ingress-nginx -o wide > "$POD_DUMP" 2>&1 || true
        echo "Saved pod list to $POD_DUMP"

        for p in $(kubectl get pods -n ingress-nginx -o name 2>/dev/null || true); do
          NAME=${p#pod/}
          echo "\n===== Pod: $NAME ====="
          # list containers for this pod
          CONTAINERS=$(kubectl get pod "$NAME" -n ingress-nginx -o jsonpath='{.spec.containers[*].name}' 2>/dev/null || true)
          for c in $CONTAINERS; do
            echo "\n----- Logs for container: $c -----"
            kubectl logs -n ingress-nginx "$NAME" -c "$c" --tail=200 > "/tmp/${NAME}-${c}.log" 2>&1 || true
            tail -n 200 "/tmp/${NAME}-${c}.log" || true
          done
        done

        echo "See /tmp/ingress-pods-$$.txt and /tmp/* for details."
        exit 1
      fi
      sleep 2
    done

    echo "Applying Ingress manifest now that controller and webhook endpoints are ready..."
    if ! kubectl apply -f manifests/ingress.yaml; then
      echo "ERROR: Failed to apply Ingress manifest. Collecting diagnostics..."
      kubectl get pods -n ingress-nginx -o wide || true
      for p in $(kubectl get pods -n ingress-nginx -o name 2>/dev/null || true); do
        NAME=${p#pod/}
        CONTAINERS=$(kubectl get pod "$NAME" -n ingress-nginx -o jsonpath='{.spec.containers[*].name}' 2>/dev/null || true)
        for c in $CONTAINERS; do
          echo "\n----- $NAME ($c) -----"
          kubectl logs -n ingress-nginx "$NAME" -c "$c" --tail=200 || true
        done
      done
      exit 1
    fi
  else
    echo "No ingress manifest found at manifests/ingress.yaml; skipping apply."
  fi
else
  echo "Skipping ingress install as requested."
fi

# Initialize DB schema (job)
if kubectl -n brief-ns get job db-init-clients >/dev/null 2>&1; then
  echo "db-init-clients job already applied. Running again to ensure schema..."
  kubectl -n brief-ns delete job db-init-clients --ignore-not-found || true
fi
kubectl apply -f manifests/db-init-job.yaml
kubectl -n brief-ns wait --for=condition=complete job/db-init-clients --timeout=120s || true
kubectl logs -n brief-ns job/db-init-clients || true
kubectl delete job db-init-clients -n brief-ns --ignore-not-found || true

# Seed DB
if kubectl -n brief-ns get job db-seed-clients >/dev/null 2>&1; then
  kubectl -n brief-ns delete job db-seed-clients --ignore-not-found || true
fi
kubectl apply -f manifests/db-seed-job.yaml
kubectl -n brief-ns wait --for=condition=complete job/db-seed-clients --timeout=120s || true
kubectl logs -n brief-ns job/db-seed-clients || true
kubectl delete job db-seed-clients -n brief-ns --ignore-not-found || true

# Port-forward ingress controller locally for tests (if installed)
PORT_FORWARD_PID=""
if kubectl -n ingress-nginx get svc ingress-nginx-controller >/dev/null 2>&1; then
  echo "Port-forwarding ingress controller to localhost:8081..."
  kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8081:80 >/dev/null 2>&1 &
  PORT_FORWARD_PID=$!
  # give it a moment
  sleep 2
else
  echo "Ingress controller not found; trying to test via ClusterIP directly."
fi

# Helper to cleanup background port-forward
cleanup() {
  if [[ -n "$PORT_FORWARD_PID" ]]; then
    echo "Stopping port-forward (pid $PORT_FORWARD_PID)..."
    kill "$PORT_FORWARD_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "Running endpoint checks through Ingress (or Service)..."
BASE_URL="http://localhost:8081/brief-ns"
# fallback to direct service if ingress not present
if ! curl -sSf "$BASE_URL/health" >/dev/null 2>&1; then
  echo "Ingress test failed, trying direct Service port-forward..."
  kubectl -n brief-ns port-forward svc/api-service 8080:80 >/dev/null 2>&1 &
  PF_PID=$!
  sleep 1
  BASE_URL="http://localhost:8080"
  # ensure we kill port-forward on exit
  trap 'kill $PF_PID 2>/dev/null || true; cleanup' EXIT
fi

echo "Checking health..."
if ! curl -sSf "$BASE_URL/health" >/dev/null 2>&1; then
  echo "Health check failed at $BASE_URL/health"
  exit 1
fi

echo "Listing clients..."
if ! curl -sSf "$BASE_URL/clients" >/dev/null 2>&1; then
  echo "GET /clients failed"
  exit 1
fi

# Create a test client
echo "Creating a test client..."
PAYLOAD='{"first_name":"Test","last_name":"Runner","email":"test+runner@example.com"}'
POST_HTTP=$(curl -s -o /tmp/resp -w "%{http_code}" -X POST "$BASE_URL/clients" -H "Content-Type: application/json" -d "$PAYLOAD")
if [[ "$POST_HTTP" != "200" && "$POST_HTTP" != "201" ]]; then
  echo "POST /clients failed (status $POST_HTTP). Response:"; cat /tmp/resp; exit 1
fi

# Confirm client exists
COUNT_BEFORE=$(curl -s "$BASE_URL/clients" | jq '. | length' || echo "0")
if [[ -z "$COUNT_BEFORE" || "$COUNT_BEFORE" -lt 1 ]]; then
  echo "No clients found after create. Output:"; curl -s "$BASE_URL/clients"; exit 1
fi

# Fetch first client id
FIRST_ID=$(curl -s "$BASE_URL/clients" | jq '.[0].id' || echo "")
if [[ -z "$FIRST_ID" ]]; then
  echo "Could not find an id for first client"; exit 1
fi

# Get by id
if ! curl -sSf "$BASE_URL/clients/$FIRST_ID" >/dev/null 2>&1; then
  echo "GET /clients/$FIRST_ID failed"; exit 1
fi

# Delete by id
DEL_HTTP=$(curl -s -o /tmp/dresp -w "%{http_code}" -X DELETE "$BASE_URL/clients/$FIRST_ID")
if [[ "$DEL_HTTP" == "200" || "$DEL_HTTP" == "204" ]]; then
  echo "Delete succeeded for id $FIRST_ID"
else
  echo "DELETE /clients/$FIRST_ID failed (status $DEL_HTTP). Response:"; cat /tmp/dresp; exit 1
fi

# Final sanity: list clients
curl -s "$BASE_URL/clients" | jq '. | length' || true

echo "All checks passed. Cluster is up and endpoints are working."

# Keep the script exit successful
exit 0
