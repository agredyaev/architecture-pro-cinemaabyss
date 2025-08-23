#!/bin/bash
set -euo pipefail

# shellcheck source=scripts/helpers.sh
source "$(dirname "$0")/helpers.sh"

DOCKER_COMPOSE_FILE="docker-compose.yml"
REQUEST_COUNT=1000
TEST_SCENARIOS=("50" "100")
TOLERANCE=20
API_ENDPOINT="http://localhost:8000/api/movies"
MIGRATION_ENV_VAR="MOVIES_MIGRATION_PERCENT"
SYMBOL_PASSED="✓"
SYMBOL_FAILED="✗"
STATUS_PASSED="PASSED"
STATUS_FAILED="FAILED"

declare -A results

set_migration_percentage() {
    local percent="$1"
    sed -i "s/${MIGRATION_ENV_VAR}: .*/${MIGRATION_ENV_VAR}: \"${percent}\"/" "$DOCKER_COMPOSE_FILE"
}

generate_load() {
    ECHO_INFO "Generating ${REQUEST_COUNT} requests to ${API_ENDPOINT}..."
    for i in $(seq 1 "${REQUEST_COUNT}"); do
        curl -s -o /dev/null "$API_ENDPOINT"
    done
    sleep 2
}

within_tolerance() {
    local actual="$1" target="$2" tol="$3"
    awk -v a="$actual" -v t="$target" -v d="$tol" '
        BEGIN {
            if (t == 100) {
                exit !(a == 100.00)
            } else {
                exit !(a >= t - d && a <= t + d)
            }
        }
    '
}

analyze_results() {
    local percent="$1"
    ECHO_INFO "Analyzing results for ${percent}% migration..."

    local logs
    logs=$(docker compose logs proxy-service)

    local mono movies total
    mono=$(grep -c "Routing /api/movies request to Monolith" <<<"$logs" || true)
    movies=$(grep -c "Routing /api/movies request to Movies Service" <<<"$logs" || true)
    total=$((mono + movies))

    results["${percent}_total"]=$total
    results["${percent}_mono"]=$mono
    results["${percent}_movies"]=$movies
    results["${percent}_actual"]="N/A"
    results["${percent}_tolerance"]=$TOLERANCE
    results["${percent}_result"]=$STATUS_FAILED

    if [ "$total" -gt 0 ]; then
        local actual
        actual=$(awk -v m="$movies" -v t="$total" 'BEGIN{printf "%.2f", (m*100)/t}')
        results["${percent}_actual"]="$actual"
        if within_tolerance "$actual" "$percent" "$TOLERANCE"; then
            results["${percent}_result"]=$STATUS_PASSED
        fi
    fi
}

run_test_scenario() {
    local percent="$1"
    ECHO_HDR "Running test for ${percent}% migration..."
    set_migration_percentage "$percent"
    docker compose up -d --force-recreate proxy-service >/dev/null 2>&1
    sleep 2
    generate_load
    analyze_results "$percent"
}

print_header() {
    ECHO_HDR "Test Summary"
    local header_format="%-20s"
    local header_args=("Metric")
    for percent in "${TEST_SCENARIOS[@]}"; do
        header_format+=" | %-20s"
        header_args+=("${percent}% Migration")
    done
    printf "${header_format}\n" "${header_args[@]}"
    printf -- "--------------------------------------------------------------\n"
}

fmt_result_string() {
    local res="$1"
    if [[ "$res" == "$STATUS_PASSED" ]]; then
        printf "%b" "${GREEN}${SYMBOL_PASSED} ${STATUS_PASSED}${RESET}"
    else
        printf "%b" "${RED}${SYMBOL_FAILED} ${STATUS_FAILED}${RESET}"
    fi
}

fmt_cell() {
    local content="$1"
    local visible_len="$2"
    local col_width=20
    local padding=$((col_width - visible_len))
    printf "%s%*s" "$content" "$padding" ""
}

print_table_row() {
    local metric="$1"
    local key="$2"
    local prefix="${3:-}"
    local suffix="${4:-}"

    printf "%-20s" "$metric"

    for percent in "${TEST_SCENARIOS[@]}"; do
        local value="${results[${percent}_${key}]}"
        local cell_content
        local visible_len

        if [[ "$key" == "result" ]]; then
            cell_content=$(fmt_result_string "$value")
            visible_len=$(( ${#SYMBOL_PASSED} + 1 + ${#STATUS_PASSED} ))
        else
            if [[ "$value" == "N/A" ]]; then
                cell_content="N/A"
            else
                cell_content="${prefix}${value}${suffix}"
            fi
            visible_len=${#cell_content}
        fi
        printf " | %s" "$(fmt_cell "$cell_content" "$visible_len")"
    done
    printf "\n"
}

print_summary_report() {
    print_header

    print_table_row "Total Requests" "total"
    print_table_row "Monolith Requests" "mono"
    print_table_row "Movies Requests" "movies"
    print_table_row "Actual Percentage" "actual" "" "%"
    print_table_row "Tolerance" "tolerance" "±" "%"
    print_table_row "Result" "result"

    printf -- "--------------------------------------------------------------\n"
}

check_final_status() {
    local all_passed=true
    for percent in "${TEST_SCENARIOS[@]}"; do
        if [[ "${results[${percent}_result]}" != "$STATUS_PASSED" ]]; then
            all_passed=false
            break
        fi
    done

    if $all_passed; then
        printf "%b\n" "${GREEN}${SYMBOL_PASSED} All tests passed!${RESET}"
        return 0
    else
        printf "%b\n" "${RED}${SYMBOL_FAILED} Some tests failed.${RESET}"
        return 1
    fi
}

main() {
    trap 'ECHO_HDR "Cleaning up..."; set_migration_percentage 50 >/dev/null 2>&1; make down >/dev/null 2>&1' EXIT

    ECHO_HDR "Setting up test environment..."
    make up >/dev/null 2>&1
    sleep 5

    for percent in "${TEST_SCENARIOS[@]}"; do
        run_test_scenario "$percent"
    done

    print_summary_report
    check_final_status
}

main