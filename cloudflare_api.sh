#!/usr/bin/env bash

get_record_id() {
    local fqdn=$1
    local record_type=$2
    echo "Fetching record ID for ${fqdn} (${record_type})"
    local response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${zoneId}/dns_records?type=${record_type}&name=${fqdn}" \
        -H "Authorization: Bearer ${apiToken}" \
        -H "Content-Type: application/json")
    echo "API Response: $response"

    if [[ $? -ne 0 || -z $response ]]; then
        echo "Failed to fetch record ID for ${fqdn} (${record_type}) from Cloudflare API"
        return 1
    fi

    local record_id=$(echo "$response" | grep -oE '"id":"\K[^"]+')
    if [[ -z "$record_id" ]]; then
        echo "No record ID found for ${fqdn} (${record_type})"
        return 1
    fi

    echo "$record_id"
}

update_record() {
    local record_id=$1
    local fqdn=$2
    local record_type=$3
    local record_value=$4
    local response=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${zoneId}/dns_records/${record_id}" \
        -H "Authorization: Bearer ${apiToken}" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"${record_type}\",\"name\":\"${fqdn}\",\"content\":\"${record_value}\",\"ttl\":60,\"proxied\":false}")

    if [[ $? -ne 0 || -z $response ]]; then
        echo "Failed to update record ${record_id} (${record_type}) for ${fqdn} on Cloudflare"
        return 1
    fi

    if ! echo "$response" | grep -q '"success":true'; then
        echo "Failed to update record: ${response}"
        return 1
    fi

    echo "$response"
}

create_record() {
    local fqdn=$1
    local record_type=$2
    local record_value=$3
    local response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${zoneId}/dns_records" \
        -H "Authorization: Bearer ${apiToken}" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"${record_type}\",\"name\":\"${fqdn}\",\"content\":\"${record_value}\",\"ttl\":60,\"proxied\":false}")

    if [[ $? -ne 0 || -z $response ]]; then
        echo "Failed to create record (${record_type}) for ${fqdn} on Cloudflare"
        return 1
    fi

    if ! echo "$response" | grep -q '"success":true'; then
        echo "Failed to create record: ${response}"
        return 1
    fi

    echo "$response"
}
