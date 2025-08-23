#!/bin/bash

set -e

source "$(dirname "$0")/helpers.sh"

ECHO_HDR "--- Publishing 10 test events to Kafka ---"

for i in {1..10}; do
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  movie_payload=$(jq -n --arg i "$i" --arg ts "$timestamp" '{movie_id: ($i|tonumber), title: ("Test Movie " + $i), action: "view", timestamp: $ts}')
  publish_event "movie" "$i" "$movie_payload"

  user_payload=$(jq -n --arg i "$i" --arg ts "$timestamp" '{user_id: ($i|tonumber), username: ("testuser"+$i), action: "logged_in", timestamp: $ts}')
  publish_event "user" "$i" "$user_payload"

  payment_payload=$(jq -n --arg i "$i" --arg ts "$timestamp" '{payment_id: ($i|tonumber), user_id: ($i|tonumber), amount: 9.99, status: "completed", timestamp: $ts, method_type: "credit_card"}')
  publish_event "payment" "$i" "$payment_payload"
done