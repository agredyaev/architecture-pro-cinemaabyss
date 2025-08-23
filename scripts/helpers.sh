#!/bin/bash

GREEN=$'\033[32m'
RED=$'\033[31m'
YELLOW=$'\033[33m'
CYAN=$'\033[36m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

ECHO_INFO() { printf "${CYAN}[INFO] %s${RESET}\n" "$@"; }
ECHO_WARN() { printf "${YELLOW}[WARN] %s${RESET}\n" "$@"; }
ECHO_OK()   { printf "${GREEN}[OK] %s${RESET}\n" "$@"; }
ECHO_ERR()  { printf "${RED}[ERROR] %s${RESET}\n" "$@"; }
ECHO_HDR()  { printf "${BOLD}${CYAN}===== %s =====${RESET}\n" "$@"; }

publish_event() {
  local event_type="$1"
  local event_num="$2"
  local json_payload="$3"
  local url="http://127.0.0.1:8082/api/events/${event_type}"

  if curl -s -X POST -H "Content-Type: application/json" -d "$json_payload" "$url" >/dev/null; then
    ECHO_INFO "${event_type} event ${event_num} sent"
  else
    ECHO_ERR "${event_type} event ${event_num} failed"
  fi
}