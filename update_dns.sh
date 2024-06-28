#!/usr/bin/env bash

update_dns_record() {
    local fqdn=$1
    local record_type=$2
    local record_value=$3
    echo "Updating ${record_type} record for ${fqdn} with value ${record_value}"
    echo "Calling get_record_id function"
    local record_id
    record_id=$(get_record_id "${fqdn}" "${record_type}")
    echo "Record ID fetched: ${record_id}"

    if [[ $? -ne 0 || -z "${record_id}" ]]; then
        local response
        response=$(create_record "${fqdn}" "${record_type}" "${record_value}")
        if [[ $? -eq 0 ]]; then
            echo "Created ${record_type} record for ${fqdn}: $response"
        fi
    else
        local response
        response=$(update_record "${record_id}" "${fqdn}" "${record_type}" "${record_value}")
        if [[ $? -eq 0 ]]; then
            echo "Updated ${record_type} record for ${fqdn}: $response"
        fi
    fi
}

parse_records() {
    echo "$records" | while IFS= read -r line; do
        local record_fqdn=$(echo "$line" | cut -d',' -f1)
        local record_type=$(echo "$line" | cut -d',' -f2)
        local suffix=$(echo "$line" | cut -d',' -f3)

        if [[ "${record_type}" == "AAAA" ]]; then
            if [[ -n "${suffix}" ]]; then
                record_value="${prefix}${suffix}"
            else
                record_value="${v6}"
            fi
        else
            record_value="${v4}"
        fi

        update_dns_record "${record_fqdn}" "${record_type}" "${record_value}"
    done
}
