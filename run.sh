#!/usr/bin/with-contenv bashio

# Load configuration
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

# Convert refresh time from seconds to minutes
refreshMin=$((refresh / 60))
failCount=0
successCount=0
hextets=$((prefixLength / 16))
v6=
v4=
prefix=

# Get a valid, global, non-deprecated IPv6 address from Supervisor
get_ipv6_from_supervisor() {
    local api_response ipv6

    api_response=$(curl -sSL -H "Authorization: Bearer ${supervisorToken}" http://supervisor/network/info)

    echo "$api_response" | tr -d '\n' | sed 's/},{/}\n{/g' | while read -r entry; do
        if echo "$entry" | grep -q '"scope":"global"' &&
           ! echo "$entry" | grep -q '"deprecated":true' &&
           echo "$entry" | grep -q '"valid":true'; then
            ipv6=$(echo "$entry" | grep -oE '"address":"[^"]+"' | cut -d':' -f2- | tr -d '"' | cut -d'/' -f1)
            echo "$ipv6"
            return 0
        fi
    done

    echo "Unavailable"
}

# Cloudflare API helper
cf_api() {
    local method=$1
    local endpoint=$2
    local data=${3:-}

    curl -s -X "$method" "https://api.cloudflare.com/client/v4/zones/${zoneId}/${endpoint}" \
        -H "Authorization: Bearer ${apiToken}" \
        -H "Content-Type: application/json" \
        ${data:+--data "$data"}
}

# Create or update DNS record
cf_manage_record() {
    local fqdn=$1
    local record_type=$2
    local record_value=$3

    if [[ -z "$fqdn" || -z "$record_type" || -z "$record_value" ]]; then
        echo "Error: Missing parameters for cf_manage_record" >&2
        return 1
    fi

    local record_id
    record_id=$(cf_api GET "dns_records?type=${record_type}&name=${fqdn}" | grep -oE '"id":"[0-9a-fA-F]{32}"' | grep -oE '[0-9a-fA-F]{32}')

    if [[ $record_id =~ ^[0-9a-fA-F]{32}$ ]]; then
        echo "Updating ${fqdn} ($record_type)"
        cf_api PUT "dns_records/${record_id}" "{\"type\":\"${record_type}\",\"name\":\"${fqdn}\",\"content\":\"${record_value}\",\"ttl\":${dnsttl},\"proxied\":${proxied}}"
    else
        echo "Creating ${fqdn} ($record_type)"
        cf_api POST "dns_records" "{\"type\":\"${record_type}\",\"name\":\"${fqdn}\",\"content\":\"${record_value}\",\"ttl\":${dnsttl},\"proxied\":${proxied}}"
    fi
}

# Process user-defined custom records
parse_records() {
    if [[ -z "$customRecords" ]]; then
        echo "Error: customRecords is empty" >&2
        return
    fi

    echo "$customRecords" | while IFS=, read -r record_fqdn record_type suffix; do
        [[ -z "$record_fqdn" || -z "$record_type" ]] && continue

        local record_value
        if [[ "$record_type" == "A" ]]; then
            record_value="$v4"
        elif [[ "$record_type" == "AAAA" ]]; then
            if [[ -n "$suffix" ]]; then
                if [[ "$prefix" != "Unavailable" && "$suffix" =~ ^[0-9a-fA-F:]+$ ]]; then
                    record_value="${prefix}${suffix}"
                else
                    echo "Skipping ${record_fqdn}: invalid prefix/suffix" >&2
                    continue
                fi
            else
                record_value="$v6"
            fi
        fi

        if [[ -z "$record_value" || "$record_value" == "Unavailable" ]]; then
            echo "Skipping ${record_fqdn}: invalid value" >&2
            continue
        fi

        cf_manage_record "$record_fqdn" "$record_type" "$record_value"
    done
}

# ------------------------------
# MAIN LOOP
# ------------------------------

echo "+++ Startup of EZDDNS by TKtheDEV complete... +++"

while true; do
    v6new=$(get_ipv6_from_supervisor)

    if [[ "$v6new" != "Unavailable" && "$legacyMode" != "true" ]]; then
        prefixTmp=$(echo "$v6new" | cut -d':' -f1-$hextets)
        nextHextet=$(echo "$v6new" | cut -d':' -f$((hextets + 1)))
        paddedNextHextet=$(printf "%04s" "$nextHextet")
        remainder=$((prefixLength % 16))

        if [[ "$remainder" -ne 0 ]]; then
            cut_length=$((remainder / 4))
            prefix="${prefixTmp}:$(echo "$paddedNextHextet" | cut -c1-"$cut_length")"
        else
            prefix="${prefixTmp}:"
        fi
    else
        v6new="Unavailable"
        prefix="Unavailable"
    fi

    v4new=$(curl -s -4 https://one.one.one.one/cdn-cgi/trace | grep 'ip=' | cut -d'=' -f2)
    [[ "$v4new" != *.*.*.* || "$v4Enabled" != "true" ]] && v4new="Unavailable"

    if [[ "$v6new" == "Unavailable" && "$v4new" == "Unavailable" ]]; then
        successCount=0
        ((failCount++))
        echo "No Internet Connection detected for $((refreshMin * failCount)) minutes. Retrying in ${refreshMin} minutes..."
    else
        failCount=0
        ((successCount++))

        if [[ "$v6new" != "$v6" || "$v4new" != "$v4" ]]; then
            v6="$v6new"
            v4="$v4new"

            echo -e "\nNew public IP config:\nPrefix: $prefix\nIPv6: $v6\nIPv4: $v4\n"

            [[ -n "$hostfqdn" && "$legacyMode" != "true" && "$v6" != "Unavailable" ]] && cf_manage_record "$hostfqdn" "AAAA" "$v6"
            [[ -n "$hostfqdn" && "$v4Enabled" == "true" && "$v4" != "Unavailable" ]] && cf_manage_record "$hostfqdn" "A" "$v4"
            [[ "$customEnabled" == "true" ]] && parse_records

            echo "Updated DNS records. Sleeping for ${refreshMin} minutes."
            successCount=0
        else
            echo -e "No IP changes for $((refreshMin * successCount)) minutes. Sleeping ${refreshMin} minutes.\nCurrent IPs:\nPrefix: $prefix\nIPv6: $v6\nIPv4: $v4"
        fi
    fi

    sleep "$refresh"
done
