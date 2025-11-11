#!/bin/bash

# Check for dependencies
for pkg in jq curl; do
    if ! command -v "$pkg" &> /dev/null; then
        sudo apt install "$pkg" -y &> /dev/null
    fi
done

# Configuration
CLIENT_ID="${OPENVPN_CLIENT_ID:-}"
CLIENT_SECRET="${OPENVPN_CLIENT_SECRET:-}"
API_URL="https://$(echo "$OPENVPN_CLIENT_ID" | awk -F '.' '{print $2}').api.openvpn.com"

if [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ]; then
    echo "Error: OPENVPN_CLIENT_ID and OPENVPN_CLIENT_SECRET must be set"
    exit 1
fi

OUTPUT_DIR="./cloudconnexa_api_data"
API_ENDPOINTS=(
  "/api/v1/access-groups"
  "/api/v1/access-visibility/enabled"
  "/api/v1/devices"
  "/api/v1/device-postures"
  "/api/v1/dns-log/user-dns-resolutions/enabled"
  "/api/v1/dns-records"
  "/api/v1/location-contexts"
  "/api/v1/networks"
  "/api/v1/networks/routes"
  "/api/v1/networks/ip-services"
  "/api/v1/networks/applications"
  "/api/v1/hosts"
  "/api/v1/hosts/ip-services"
  "/api/v1/hosts/applications"
  "/api/v1/settings/auth/ldap/group-mappings"
  "/api/v1/settings/auth/saml/group-mappings"
  "/api/v1/settings/auth/trusted-devices-allowed"
  "/api/v1/settings/auth/two-factor-auth"
  "/api/v1/settings/dns/custom-servers"
  "/api/v1/settings/dns/default-suffix"
  "/api/v1/settings/dns/proxy-enabled"
  "/api/v1/settings/dns/zones"
  "/api/v1/settings/user/connect-auth"
  "/api/v1/settings/user/device-allowance"
  "/api/v1/settings/user/device-allowance-force-update"
  "/api/v1/settings/user/device-enforcement"
  "/api/v1/settings/user/profile-distribution"
  "/api/v1/settings/users/connection-timeout"
  "/api/v1/settings/wpc/client-options"
  "/api/v1/settings/wpc/default-region"
  "/api/v1/settings/wpc/domain-routing-subnet"
  "/api/v1/settings/wpc/routes-advanced-configuration-enabled"
  "/api/v1/settings/wpc/snat"
  "/api/v1/settings/wpc/subnet"
  "/api/v1/settings/wpc/topology"
  "/api/v1/users"
  "/api/v1/user-groups"
)
page=0
size=1000

# Trap for cleanup on interrupt
trap 'echo -e "\n\nScript interrupted. Partial data saved in ${OUTPUT_DIR}/"' INT TERM

# Generate OAuth token
echo "Generating OAuth token..."
API_TOKEN=$(curl -s -X POST "${API_URL}/api/v1/oauth/token?client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}&grant_type=client_credentials" | jq -r '.access_token')

if [ -z "${API_TOKEN}" ] || [ "${API_TOKEN}" == "null" ]; then
    echo "Failed to generate API token"
    exit 1
fi

echo -e "Token generated successfully\n"

mkdir -p "${OUTPUT_DIR}"

get_endpoint_name() {
    local endpoint="$1"
    count=$(grep -o "/" <<< "$endpoint" | wc -l)
    if [ "$count" -ge 4 ]; then
        echo "$(basename "$(dirname "$endpoint")")/$(basename "$endpoint")" | sed 's/\//-/g'
    else
        echo "$(basename "$endpoint")"
    fi
}

declare -A RESULTS
declare -A ITEM_COUNTS

for endpoint in "${API_ENDPOINTS[@]}"; do
    echo "=== Fetching: ${endpoint} ==="

    RESPONSE=$(curl -s -X GET "${API_URL}${endpoint}?page=${page}&size=${size}" \
        -H 'accept: application/json' \
        -H "authorization: Bearer ${API_TOKEN}" \
        -H 'Content-Type: application/json')

    FILENAME=$(get_endpoint_name "$endpoint")
    NAME="${FILENAME}"

    if ! echo "${RESPONSE}" | jq empty 2>/dev/null; then
        echo "${RESPONSE}" > "${OUTPUT_DIR}/${FILENAME}.json"
        echo "Saved to ${OUTPUT_DIR}/${FILENAME}.json"
        RESULTS["${NAME}"]="saved"
        ITEM_COUNTS["${NAME}"]="1"
        echo "" && continue
    fi

    if [ -z "${RESPONSE// /}" ] || [ "${RESPONSE}" == "[]" ] || echo "${RESPONSE}" | jq -e '.statusError' >/dev/null 2>&1; then
        echo "Not configured, skipping..."
        RESULTS["${NAME}"]="skipped"
        ITEM_COUNTS["${NAME}"]="0"
        echo "" && continue
    fi

    TOTAL_PAGES=$(echo "${RESPONSE}" | jq -r '.totalPages // 0' 2>/dev/null)

    ALL_ITEMS=()
    ITEMS=$(echo "${RESPONSE}" | jq -c '.content[]? // .[]?' 2>/dev/null)

    if [ -z "${ITEMS}" ]; then
        echo "${RESPONSE}" | jq '.' > "${OUTPUT_DIR}/${FILENAME}.json"
        echo "Saved to ${OUTPUT_DIR}/${FILENAME}.json"
        RESULTS["${NAME}"]="saved"
        ITEM_COUNTS["${NAME}"]="1"
        echo "" && continue
    fi

    while IFS= read -r item; do
        echo "$item" | jq -e 'type != "number" and . != [] and . != null' >/dev/null 2>&1 && ALL_ITEMS+=("$item")
    done <<< "$ITEMS"

    if [ ${#ALL_ITEMS[@]} -eq 0 ]; then
        echo "Not configured, skipping..."
        RESULTS["${NAME}"]="skipped"
        ITEM_COUNTS["${NAME}"]="0"
        echo "" && continue
    fi

    if [ "$TOTAL_PAGES" -gt 1 ] 2>/dev/null; then
        for (( p=1; p<$TOTAL_PAGES; p++ )); do
            PAGE_ITEMS=$(curl -s -X GET "${API_URL}${endpoint}?page=${p}&size=${size}" \
                -H 'accept: application/json' \
                -H "authorization: Bearer ${API_TOKEN}" \
                -H 'Content-Type: application/json' | jq -c '.content[]?' 2>/dev/null)

            while IFS= read -r item; do
                [ -n "$item" ] && echo "$item" | jq -e 'type != "number" and . != [] and . != null' >/dev/null 2>&1 && ALL_ITEMS+=("$item")
            done <<< "$PAGE_ITEMS"
        done
    fi

    if [ ${#ALL_ITEMS[@]} -gt 0 ]; then
        printf '%s\n' "${ALL_ITEMS[@]}" | jq -s '.' > "${OUTPUT_DIR}/${FILENAME}.json"
        echo "Saved to ${OUTPUT_DIR}/${FILENAME}.json"
        RESULTS["${NAME}"]="saved"
        ITEM_COUNTS["${NAME}"]="${#ALL_ITEMS[@]}"
    else
        echo "Error, skipping..."
        RESULTS["${NAME}"]="error"
        ITEM_COUNTS["${NAME}"]="0"
    fi

    echo ""
done

# Generate report
echo "=========================================="
echo "           IMPORT SUMMARY REPORT          "
echo "           $(date '+%Y-%m-%d %H:%M:%S')   "
echo "=========================================="
echo ""
printf "%-46s %-20s %-10s\n" "ENDPOINT" "STATUS" "ITEMS"
printf "%-46s %-20s %-10s\n" "----------------------------------------------" "--------------------" "----------"

for name in $(echo "${!RESULTS[@]}" | tr ' ' '\n' | sort); do
    printf "%-46s %-20s %-10s\n" "${name}" "${RESULTS[$name]}" "${ITEM_COUNTS[$name]}"
done

echo ""
echo "=========================================="

# Count statistics
SAVED_COUNT=0
SKIPPED_COUNT=0
ERROR_COUNT=0

for status in "${RESULTS[@]}"; do
    case "$status" in
        "saved") ((SAVED_COUNT++)) ;;
        "skipped") ((SKIPPED_COUNT++)) ;;
        "error") ((ERROR_COUNT++)) ;;
    esac
done

echo "Total endpoints processed: ${#RESULTS[@]}"
echo "  - Saved: ${SAVED_COUNT}"
echo "  - Skipped (empty): ${SKIPPED_COUNT}"
echo "  - Errors: ${ERROR_COUNT}"
echo ""
echo "Data saved in: ${OUTPUT_DIR}/"
echo "=========================================="
