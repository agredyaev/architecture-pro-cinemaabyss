.PHONY: up down test test-migration publish-events k8s-apply k8s-delete

up:
	docker compose up --build -d

down:
	docker compose down

test:
	npm --prefix tests/postman run test:local

test-migration:
	@echo "--- Testing migration with 50% ---"
	sed -i 's/MOVIES_MIGRATION_PERCENT: "100"/MOVIES_MIGRATION_PERCENT: "50"/' docker-compose.yml
	make up
	make test
	@echo "--- Resetting migration to 100% ---"
	sed -i 's/MOVIES_MIGRATION_PERCENT: "50"/MOVIES_MIGRATION_PERCENT: "100"/' docker-compose.yml
	make down

publish-events:
	@echo "--- Publishing 3 of each event type ---"
	for i in {1..3}; do \
	  curl -X POST -H "Content-Type: application/json" -d '{"movie_id": '$i', "title": "Test Movie Event '$i'", "action": "viewed", "user_id": '$i'}' http://127.0.0.1:8082/api/events/movie; \
	  curl -X POST -H "Content-Type: application/json" -d '{"user_id": '$i', "username": "testuser'$i'", "action": "logged_in", "timestamp": "'$(date -u +"%Y-%m-%dT%H:%M:%SZ")'"}' http://127.0.0.1:8082/api/events/user; \
	  curl -X POST -H "Content-Type: application/json" -d '{"payment_id": '$i', "user_id": '$i', "amount": 9.99, "status": "completed", "timestamp": "'$(date -u +"%Y-%m-%dT%H:%M:%SZ")'", "method_type": "credit_card"}' http://127.0.0.1:8082/api/events/payment; \
	done

# ====================================================================================
# Kubernetes Targets
# ====================================================================================

k8s-apply:
	@echo "--- Deploying CinemaAbyss to Kubernetes ---"
	@echo "STEP 1: Applying namespace..."
	kubectl apply -f src/kubernetes/namespace.yaml
	@echo "STEP 2: IMPORTANT - Ensure you have a 'dockerconfigjson' secret. If not, create it first."
	@# Example: kubectl create secret generic dockerconfigjson --from-file=.dockerconfigjson=config.json --type=kubernetes.io/dockerconfigjson -n cinemaabyss
	@echo "STEP 3: Applying configs and secrets..."
	kubectl apply -f src/kubernetes/configmap.yaml
	kubectl apply -f src/kubernetes/secret.yaml
	kubectl apply -f src/kubernetes/postgres-init-configmap.yaml
	@echo "STEP 4: Deploying infrastructure (Postgres, Kafka)..."
	kubectl apply -f src/kubernetes/postgres.yaml
	kubectl apply -f src/kubernetes/kafka/kafka.yaml
	@echo "STEP 5: Deploying application services..."
	kubectl apply -f src/kubernetes/events-service.yaml
	kubectl apply -f src/kubernetes/movies-service.yaml
	kubectl apply -f src/kubernetes/monolith.yaml
	kubectl apply -f src/kubernetes/proxy-service.yaml
	@echo "STEP 6: Deploying ingress..."
	kubectl apply -f src/kubernetes/ingress.yaml
	@echo "--- Deployment finished ---"

k8s-delete:
	@echo "--- Deleting CinemaAbyss from Kubernetes ---"
	kubectl delete namespace cinemaabyss
	@echo "--- Deletion finished ---"