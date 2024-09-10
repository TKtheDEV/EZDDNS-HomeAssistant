#!/usr/bin/with-contenv bashio

zoneId=$(bashio::config "zoneId")
apiToken=$(bashio::config "apiToken")
hostfqdn=$(bashio::config "hostfqdn")
v4Enabled=$(bashio::config "v4Enabled")
prefixLength=$(bashio::config "prefixLength")
refresh=$(bashio::config "refresh")
dnsttl=$(bashio::config "dnsttl")
proxied=$(bashio::config "proxied")
legacyMode=$(bashio::config "legacyMode")
customEnabled=$(bashio::config "customEnabled")
customRecords=$(bashio::config "customRecords")

v4=""
v4new=""
v6=""
v6new=""
prefix=""
hextets=$((prefixLength / 16))

cf_get_record_id() {
    fqdn=$1
    record_type=$2
    api_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${zoneId}/dns_records?type=${record_type}&name=${fqdn}" \
        -H "Authorization: Bearer ${apiToken}" \
        -H "Content-Type: application/json")
    if [[ $? -ne 0 ]]; then
        echo "Failed to communicate with Cloudflare API"
        return 1
    fi
    success=$(echo "$api_response" | grep -o '"success":true')
    if [[ -z "$success" ]]; then
        echo "Failed to fetch record ID for ${fqdn} (${record_type}) from Cloudflare API"
        return 1
    fi
    record_id=$(echo "$api_response" | grep -oE '"id":"[^"]+"' | head -n 1 | cut -d':' -f2 | tr -d '"')
    echo "$record_id"
    return 0
}

cf_create_record() {
    fqdn=$1
    record_type=$2
    record_value=$3
    api_response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${zoneId}/dns_records" \
        -H "Authorization: Bearer ${apiToken}" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"${record_type}\",\"name\":\"${fqdn}\",\"content\":\"${record_value}\",\"ttl\":${dnsttl},\"proxied\":${proxied}}")
    if [[ $? -ne 0 ]]; then
        echo "Failed to communicate with Cloudflare API"
        return 1
    fi
    success=$(echo "$api_response" | grep -o '"success":true')
    if [[ -z "$success" ]]; then
        echo "Failed to create ${record_type} record for ${fqdn} via Cloudflare API."
        return 1
    else 
        echo "Created ${record_type} record for ${fqdn} with IP ${record_value}."
    fi
    return 0
}

cf_update_record() {
    fqdn=$1
    record_type=$2
    record_value=$3
    record_id=$4
    response=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${zoneId}/dns_records/${record_id}" \
        -H "Authorization: Bearer ${apiToken}" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"${record_type}\",\"name\":\"${fqdn}\",\"content\":\"${record_value}\",\"ttl\":${dnsttl},\"proxied\":${proxied}}")
    if [[ $? -ne 0 ]]; then
        echo "Failed to communicate with Cloudflare API"
        return 1
    fi
    success=$(echo "$response" | grep -o '"success":true')
    if [[ -z "$success" ]]; then
        echo "Failed to update ${record_type} record for ${fqdn} via Cloudflare API."
        return 1
    else 
        echo "Updated ${record_type} record for ${fqdn} with IP ${record_value}."
    fi
    return 0
}

cf_update_dns_record() {
    fqdn=$1
    record_type=$2
    record_value=$3
    record_id=$(cf_get_record_id "${fqdn}" "${record_type}")
    if [[ -z "$record_id" ]]; then
        echo "Creating new ${record_type} record for ${fqdn} with IP ${record_value}."
        cf_create_record "${fqdn}" "${record_type}" "${record_value}"
    else
        echo "Updating ${record_type} record for ${fqdn} with IP ${record_value} (CF-ID: ${record_id})."
        cf_update_record "${fqdn}" "${record_type}" "${record_value}" "${record_id}"
    fi
}

parse_records() {
    echo "$customRecords" | while IFS= read -r line; do
        record_fqdn=$(echo "$line" | cut -d',' -f1)
        record_type=$(echo "$line" | cut -d',' -f2)
        suffix=$(echo "$line" | cut -d',' -f3)
        if [[ "${record_type}" == "AAAA" ]]; then
            if [[ -n "${suffix}" ]]; then
                record_value="${prefix}${suffix}"
            else
                record_value="${v6}"
            fi
        else
            record_value="${v4}"
        fi
        cf_update_dns_record "${record_fqdn}" "${record_type}" "${record_value}"
    done
}

while true; do
    bashio::cache.flush_all
    for getv6 in $(bashio::network.ipv6_address); do
        if [[ "$getv6" != fe80* && "$getv6" != fc* && "$getv6" != fd* && "${legacyMode}" != true ]]; then
            v6new="${getv6%%/*}"
            prefixTmp=$(echo "$v6new" | cut -d':' -f1-$hextets)
            nextHextet=$(echo "$v6new" | cut -d':' -f$((hextets + 1)))
            paddedNextHextet=$(printf "%04s" "$nextHextet")
            remainder=$((prefixLength % 16))
            if [ "$remainder" -ne 0 ]; then
                cut_length=$((remainder / 4))
                prefix="${prefixTmp}:$(echo "$paddedNextHextet" | cut -c1-$cut_length)"
            else
                prefix="${prefixTmp}:"
            fi
            break
        fi
    done

    if [[ -z "$v6new" ]]; then
        v6new="Unavailable"
        prefix="Unavailable"
    fi

    getv4=$(curl -s -4 https://one.one.one.one/cdn-cgi/trace | grep 'ip=' | cut -d'=' -f2)
    if [[ "${getv4}" == *.*.*.* && "${v4Enabled}" == true ]]; then
        v4new="${getv4}"
    else
        v4new="Unavailable"
    fi

    if [[ "${v6new}" != "${v6}" || "${v4new}" != "${v4}" ]]; then
        v6="${v6new}"
        v4="${v4new}"
        echo "Your new public IP config: Prefix: ${prefix} IPv6: ${v6} IPv4: ${v4}"

        if [[ -n "${hostfqdn}" ]]; then
            if [[ "${legacyMode}" == false ]]; then
                cf_update_dns_record "${hostfqdn}" "AAAA" "${v6}"
            fi

            if [[ ${v4Enabled} == true ]]; then
                cf_update_dns_record "${hostfqdn}" "A" "${v4}"
            fi
        fi

        if [[ ${customEnabled} = true ]]; then
            parse_records
        fi
    else
        echo "IPs haven't changed since the last update"
    fi

    echo "Waiting $((refresh / 60)) minutes until the next update"
    sleep "${refresh}"
done
# (C) GitHub\TKtheDEV