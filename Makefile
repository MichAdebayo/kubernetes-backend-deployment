.PHONY: up up-no-ingress init seed test down teardown logs port-forward-ingress port-forward-service

# Load .env if present (allows per-user overrides without editing Makefile)
ifneq (,$(wildcard .env))
include .env
export
endif

# Variables (override on command-line or in .env)
CLUSTER_NAME ?= brief-cluster
INGRESS_NS ?= ingress-nginx
NAMESPACE ?= brief-ns

# Start cluster, install ingress, deploy manifests, init & seed DB, run checks
up:
	@echo "Starting cluster and deploying stack..."
	./scripts/cluster-up.sh --cluster-name $(CLUSTER_NAME)

up-no-ingress:
	@echo "Starting stack and skipping ingress installation..."
	./scripts/cluster-up.sh --cluster-name $(CLUSTER_NAME) --skip-ingress-install

# Initialize DB schema only
init:
	@echo "Applying DB init job..."
	kubectl apply -f manifests/db-init-job.yaml
	kubectl -n $(NAMESPACE) wait --for=condition=complete job/db-init-clients --timeout=120s || true
	kubectl logs -n $(NAMESPACE) job/db-init-clients || true
	kubectl delete job db-init-clients -n $(NAMESPACE) --ignore-not-found || true

# Seed DB with sample clients
seed:
	@echo "Applying DB seed job..."
	kubectl apply -f manifests/db-seed-job.yaml
	kubectl -n $(NAMESPACE) wait --for=condition=complete job/db-seed-clients --timeout=120s || true
	kubectl logs -n $(NAMESPACE) job/db-seed-clients || true
	kubectl delete job db-seed-clients -n $(NAMESPACE) --ignore-not-found || true

# Run a quick sanity test against the service (requires kubectl port-forward)
test:
	@echo "Testing endpoints via Service port-forward (temporary)..."
	kubectl -n $(NAMESPACE) port-forward svc/api-service 8080:80 >/dev/null 2>&1 &
	PF=$$!; sleep 1; \
	set -e; \
	curl -sSf http://localhost:8080/health >/dev/null; \
	curl -sSf http://localhost:8080/clients >/dev/null; \
	curl -s -X POST -H 'Content-Type: application/json' -d '{"first_name":"Test","last_name":"User","email":"test@example.com"}' http://localhost:8080/clients >/dev/null; \
	kill $$PF || true; echo "Tests passed."

# Stop / delete cluster safely
down:
	@echo "Stopping / deleting local cluster (kind by default)..."
	./scripts/cluster-down.sh --provider kind --cluster-name $(CLUSTER_NAME) --force

# Full teardown of namespace + optional cluster deletion
teardown:
	@echo "Full teardown of project resources (namespace $(NAMESPACE))..."
	./scripts/full-teardown.sh --yes --delete-cluster --cluster-provider kind
# Clean project-related Docker images (interactive)
clean-images:
	@echo "Clean project / kind images and optionally prune Docker (interactive)."
	./scripts/clean-images.sh
# Tail API logs
logs:
	@echo "Tailing API logs..."
	kubectl logs -n $(NAMESPACE) -l app=brief-api -f

# Port-forward ingress for manual testing
port-forward-ingress:
	@echo "Port-forwarding ingress controller to localhost:8081 (requires ingress-nginx installed)..."
	kubectl -n $(INGRESS_NS) port-forward svc/ingress-nginx-controller 8081:80

# Port-forward service for manual testing
port-forward-service:
	@echo "Port-forwarding api service to localhost:8080..."
	kubectl -n $(NAMESPACE) port-forward svc/api-service 8080:80
