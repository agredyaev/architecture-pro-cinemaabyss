.PHONY: up down test test-migration publish-events

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