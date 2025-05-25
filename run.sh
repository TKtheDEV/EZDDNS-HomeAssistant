#!/usr/bin/with-contenv bashio

# ----------------------------------
# Configuration
# ----------------------------------

supervisorToken=$(bashio::config "supervisorToken")
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

refreshMin=$((refresh / 60))
hextets=$((prefixLength / 16))
failCount=0
successCount=0

v6=""
v4=""
prefix=""

bashio::log.info "+++ EZDDNS Startup Complete +++"

# ----------------------------------
# Functions
# ----------------------------------

get_ipv6_from_supervisor() {
    local ipv6 api_response

    api_response=$(curl -sfSL -H "Authorization: Bearer ${supervisorToken}" http://supervisor/network/info)
    if [[ -z "$api_response" ]]; then
        bashio::log.warning "Empty or failed response from Supervisor"
        echo "Unavailable"
        return 0
    fi

    ipv6=$(echo "$api_response" | jq -r '
        .data.interfaces[]
        | select(.primary == true and .ipv6.address != null)
        | .ipv6.address[]
        | select(startswith("fe80::") | not)
        | select(startswith("fd") | not)
        | . ' | head -n 1)

    if [[ -z "$ipv6" || ! "$ipv6" =~ ^[0-9a-fA-F:]+(/[0-9]+)?$ ]]; then
        bashio::log.warning "No valid global IPv6 address found on primary interface"
        echo "Unavailable"
    else
        echo "${ipv6%%/*}"
    fi
}

get_ipv4() {
    local ipv4
    ipv4=$(curl -sf -4 https://one.one.one.one/cdn-cgi/trace | grep 'ip=' | cut -d'=' -f2)
    [[ "$ipv4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$ipv4" || echo "Unavailable"
}

cf_api() {
    local method=$1
    local endpoint=$2
    local data=${3:-}

    curl -s -X "$method" "https://api.cloudflare.com/client/v4/zones/${zoneId}/${endpoint}" \
        -H "Authorization: Bearer ${apiToken}" \
        -H "Content-Type: application/json" \
        ${data:+--data "$data"}
}

cf_manage_record() {
    local fqdn=$1
    local record_type=$2
    local record_value=$3

    if [[ -z "$fqdn" || -z "$record_type" || -z "$record_value" || "$record_value" == "Unavailable" ]]; then
        bashio::log.warning "Skipping invalid DNS record: $fqdn ($record_type) = $record_value"
        return 1
    fi

    local record_id
    record_id=$(cf_api GET "dns_records?type=${record_type}&name=${fqdn}" | grep -oE '"id":"[0-9a-fA-F]{32}"' | cut -d'"' -f4)

    if [[ "$record_id" =~ ^[0-9a-fA-F]{32}$ ]]; then
        bashio::log.info "Updating $fqdn ($record_type)"
        cf_api PUT "dns_records/${record_id}" "{\"type\":\"${record_type}\",\"name\":\"${fqdn}\",\"content\":\"${record_value}\",\"ttl\":${dnsttl},\"proxied\":${proxied}}"
    else
        bashio::log.info "Creating $fqdn ($record_type)"
        cf_api POST "dns_records" "{\"type\":\"${record_type}\",\"name\":\"${fqdn}\",\"content\":\"${record_value}\",\"ttl\":${dnsttl},\"proxied\":${proxied}}"
    fi
}

extract_prefix() {
    local ip=$1
    local prefixTmp nextHextet padded remainder cut_length

    prefixTmp=$(echo "$ip" | cut -d':' -f1-$hextets)
    nextHextet=$(echo "$ip" | cut -d':' -f$((hextets + 1)))
    padded=$(printf "%04s" "$nextHextet")
    remainder=$((prefixLength % 16))

    if [[ $remainder -ne 0 ]]; then
        cut_length=$((remainder / 4))
        echo "${prefixTmp}:$(echo "$padded" | cut -c1-"$cut_length")"
    else
        echo "${prefixTmp}:"
    fi
}

parse_records() {
    if [[ -z "$customRecords" ]]; then
        bashio::log.warning "No custom records defined."
        return
    fi

    echo "$customRecords" | while IFS=, read -r record_fqdn record_type suffix; do
        [[ -z "$record_fqdn" || -z "$record_type" ]] && continue

        local record_value=""
        if [[ "$record_type" == "A" ]]; then
            record_value="$v4"
        elif [[ "$record_type" == "AAAA" ]]; then
            if [[ -n "$suffix" ]]; then
                if [[ "$prefix" != "Unavailable" && "$suffix" =~ ^[0-9a-fA-F:]+$ ]]; then
                    record_value="${prefix}${suffix}"
                else
                    bashio::log.warning "Skipping $record_fqdn: invalid prefix or suffix"
                    continue
                fi
            else
                record_value="$v6"
            fi
        fi

        [[ "$record_value" != "Unavailable" ]] && cf_manage_record "$record_fqdn" "$record_type" "$record_value"
    done
}

# ----------------------------------
# Main Loop
# ----------------------------------

while true; do
    v6new=$(get_ipv6_from_supervisor)
    bashio::log.info "getting IPv4"
    v4new=$( [[ "$v4Enabled" == "true" ]] && get_ipv4 || echo "Unavailable" )
    bashio::log.info "after IPv4"
    if [[ "$v6new" == "Unavailable" && "$v4new" == "Unavailable" ]]; then
        ((failCount++))
        successCount=0
        bashio::log.warning "No valid IPs. Sleeping $refreshMin minutes (failCount=$failCount)..."
        sleep "$refresh"
        continue
    fi
    bashio::log.info "after Unavailable"

    ((successCount++))
    failCount=0

    # IPs changed?
    if [[ "$v6new" != "$v6" || "$v4new" != "$v4" ]]; then
        v6="$v6new"
        v4="$v4new"

        prefix="Unavailable"
        if [[ "$v6" != "Unavailable" && "$legacyMode" != "true" ]]; then
            prefix=$(extract_prefix "$v6")
        fi

        bashio::log.info "IP Change Detected:"
        bashio::log.info "IPv6: $v6"
        bashio::log.info "IPv4: $v4"
        bashio::log.info "Prefix: $prefix"

        [[ -n "$hostfqdn" && "$legacyMode" != "true" && "$v6" != "Unavailable" ]] && cf_manage_record "$hostfqdn" "AAAA" "$v6"
        [[ -n "$hostfqdn" && "$v4Enabled" == "true" && "$v4" != "Unavailable" ]] && cf_manage_record "$hostfqdn" "A" "$v4"
        [[ "$customEnabled" == "true" ]] && parse_records

        successCount=0
        bashio::log.info "DNS records updated. Sleeping $refreshMin minutes."
    else
        bashio::log.info "No IP changes for $((refreshMin * successCount)) minutes. Sleeping $refreshMin minutes."
    fi

    sleep "$refresh"
done
