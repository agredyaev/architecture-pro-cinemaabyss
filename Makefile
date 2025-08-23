MAKEFLAGS += --no-print-directory

GREEN := \033[32m
RED := \033[31m
YELLOW := \033[33m
CYAN := \033[36m
BOLD := \033[1m
RESET := \033[0m

ECHO_INFO = printf "$(CYAN)[INFO] %s$(RESET)\n"
ECHO_WARN = printf "$(YELLOW)[WARN] %s$(RESET)\n"
ECHO_OK   = printf "$(GREEN)[OK] %s$(RESET)\n"
ECHO_ERR  = printf "$(RED)[ERROR] %s$(RESET)\n"
ECHO_HDR  = printf "$(BOLD)$(CYAN)===== %s =====$(RESET)\n"

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help message
	@$(ECHO_HDR) "Available commands"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: up
up: ## Start all services in detached mode
	@$(ECHO_INFO) "Starting containers..."
	@docker compose up --build -d
	@$(ECHO_OK) "Containers started."

.PHONY: down
down: ## Stop and remove all services
	@$(ECHO_INFO) "Stopping containers..."
	@docker compose down
	@$(ECHO_OK) "Containers stopped."

.PHONY: test
test: ## Run Postman tests against the local environment
	@$(ECHO_INFO) "Running Postman tests..."
	@npm --prefix tests/postman run test:local

.PHONY: recreate-proxy
recreate-proxy: ## Force recreate the proxy service
	@$(ECHO_INFO) "Recreating proxy-service..."
	@docker compose up -d --force-recreate proxy-service
	@$(ECHO_OK) "Proxy service recreated."

.PHONY: run-load-test
run-load-test: ## Run a load test with a given migration percentage (default: 0). Usage: make run-load-test PERCENT=50
	@bash scripts/run-load-test.sh $(PERCENT)

.PHONY: test-migration
test-migration: ## Run a full migration test suite (50%, 100%)
	@bash scripts/migration-test.sh

.PHONY: publish-events
publish-events: ## Publish test events to Kafka
	@bash scripts/publish-events.sh

.PHONY: k8s-apply
k8s-apply: ## Deploy the application to Kubernetes using raw manifests
	@$(ECHO_HDR) "Deploying CinemaAbyss to Kubernetes"
	@$(ECHO_INFO) "STEP 1: Applying namespace..."
	@kubectl apply -f src/kubernetes/namespace.yaml
	@$(ECHO_INFO) "STEP 2: Ensure you have a 'dockerconfigjson' secret if needed."
	@$(ECHO_INFO) "STEP 3: Applying configs and secrets..."
	@kubectl apply -f src/kubernetes/configmap.yaml
	@kubectl apply -f src/kubernetes/secret.yaml
	@kubectl apply -f src/kubernetes/postgres-init-configmap.yaml
	@$(ECHO_INFO) "STEP 4: Deploying infrastructure (Postgres, Kafka)..."
	@kubectl apply -f src/kubernetes/postgres.yaml
	@kubectl apply -f src/kubernetes/kafka/kafka.yaml
	@$(ECHO_INFO) "STEP 5: Deploying application services..."
	@kubectl apply -f src/kubernetes/events-service.yaml
	@kubectl apply -f src/kubernetes/movies-service.yaml
	@kubectl apply -f src/kubernetes/monolith.yaml
	@kubectl apply -f src/kubernetes/proxy-service.yaml
	@$(ECHO_INFO) "STEP 6: Deploying ingress..."
	@kubectl apply -f src/kubernetes/ingress.yaml
	@$(ECHO_OK) "Deployment finished."

.PHONY: k8s-delete
k8s-delete: ## Delete the application from Kubernetes
	@$(ECHO_INFO) "Deleting CinemaAbyss from Kubernetes..."
	@kubectl delete namespace cinemaabyss
	@$(ECHO_OK) "Deletion finished."

.PHONY: helm-install
helm-install: ## Deploy the application to Kubernetes using Helm
	@$(ECHO_INFO) "Deploying CinemaAbyss to Kubernetes using Helm..."
	@helm upgrade --install cinemaabyss ./src/kubernetes/helm -n cinemaabyss --create-namespace
	@$(ECHO_OK) "Deployment finished."

.PHONY: helm-delete
helm-delete: ## Delete the application from Kubernetes using Helm
	@$(ECHO_INFO) "Deleting CinemaAbyss from Kubernetes using Helm..."
	@helm delete cinemaabyss -n cinemaabyss
	@$(ECHO_OK) "Deletion finished."