#!/usr/bin/with-contenv bashio

v4=""
v4new=""
v6=""
v6new=""
prefix=""
prefixLength=$(bashio::config "prefixLength")
legacy=$(bashio::config "legacy")
v4en=$(bashio::config "v4En")
customen=$(bashio::config "customEn")
hafqdn=$(bashio::config "fqdn")
refresh=$(bashio::config "refresh")
zoneId=$(bashio::config "zoneId")
apiToken=$(bashio::config "apiToken")
records=$(bashio::config "records")

if [[ ${prefixLength} == 64 ]]; then
    prefixCount=$(( (prefixLength / 4) + 4 ))
else
    prefixCount=$(( (prefixLength / 4) + 3 ))
fi

get_record_id() {
    echo get_record_begin
    fqdn=$1
    record_type=$2
    response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${zoneId}/dns_records?type=${record_type}&name=${fqdn}" \
        -H "Authorization: Bearer ${apiToken}" \
        -H "Content-Type: application/json")
    echo $response
    if [[ $? -ne 0 ]]; then
        echo "Failed to fetch record ID for ${fqdn} (${record_type}) from Cloudflare API"
        return 1
    fi
    echo get_record_out
    echo "$response" | grep -oE '"id":"\K[^"]+'
}

update_record() {
    record_id=$1
    fqdn=$2
    record_type=$3
    record_value=$4
    response=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${zoneId}/dns_records/${record_id}" \
        -H "Authorization: Bearer ${apiToken}" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"${record_type}\",\"name\":\"${fqdn}\",\"content\":\"${record_value}\",\"ttl\":60,\"proxied\":false}")
    if [[ $? -ne 0 ]]; then
        echo "Failed to update record ${record_id} (${record_type}) for ${fqdn} on Cloudflare"
        return 1
    fi
    echo "$response"
}

create_record() {
    fqdn=$1
    record_type=$2
    record_value=$3
    response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${zoneId}/dns_records" \
        -H "Authorization: Bearer ${apiToken}" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"${record_type}\",\"name\":\"${fqdn}\",\"content\":\"${record_value}\",\"ttl\":60,\"proxied\":false}")
    if [[ $? -ne 0 ]]; then
        echo "Failed to create record (${record_type}) for ${fqdn} on Cloudflare"
        return 1
    fi
    echo "$response"
}

update_dns_record() {
    fqdn=$1
    record_type=$2
    record_value=$3
    echo "Updating ${record_type} record for ${fqdn} with value ${record_value}"
    record_id=$(get_record_id "${fqdn}" "${record_type}")
    if [[ -z "${record_id}" ]]; then
        response=$(create_record "${fqdn}" "${record_type}" "${record_value}")
        echo "Created ${record_type} record for ${fqdn}: $response"
    else
        response=$(update_record "${record_id}" "${fqdn}" "${record_type}" "${record_value}")
        echo "Updated ${record_type} record for ${fqdn}: $response"
    fi
}

parse_records() {
    echo "$records" | while IFS= read -r line; do
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

        update_dns_record "${record_fqdn}" "${record_type}" "${record_value}"
    done
}

while true; do
    bashio::cache.flush_all

    for getv6 in $(bashio::network.ipv6_address); do
        if [[ "$getv6" != fe80* && "$getv6" != fc* && "$getv6" != fd* ]]; then
            v6new="${getv6:0:38}"
            break
        fi
    done
    if [[ "${getv6}" != "null" && "${getv6}" != "" && "${getv6}" != "Unavailable" && "${legacy}" != true ]]; then
        prefix="${v6new:0:${prefixCount}}"
    else
        v6new="Unavailable"
        prefix="Unavailable"
    fi

    getv4=$(curl -s -4 ifconfig.co)
    if [[ "${getv4}" == *.*.*.* && "${v4en}" == true ]]; then
        v4new="${getv4}"
    else
        v4new="Unavailable"
    fi

    if [[ "${v6new}" != "${v6}" || "${v4new}" != "${v4}" ]]; then
        v6="${v6new}"
        v4="${v4new}"
        echo "Your new public IP config: Prefix: ${prefix} IPv6: ${v6} IPv4: ${v4}"

        if [[ -n "${hafqdn}" ]]; then
            if [[ "${legacy}" == false ]]; then
                update_dns_record "${hafqdn}" "AAAA" "${v6}"
            fi

            if [[ ${v4en} == true ]]; then
                update_dns_record "${hafqdn}" "A" "${v4}"
            fi
        fi

        if [[ ${customen} = true ]]; then
            parse_records
        fi
    else
        echo "IPs haven't changed since the last update"
    fi

    sleep "${refresh}"
done
