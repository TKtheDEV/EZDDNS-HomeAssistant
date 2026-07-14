#!/usr/bin/with-contenv bashio
set -o pipefail
shopt -s nocasematch

# ----------------------------------
# GLOBALS
# ----------------------------------

ZONE_ID=$(bashio::config "zoneId")
API_TOKEN=$(bashio::config "apiToken")
HOSTFQDN=$(bashio::config "hostfqdn")
V4_ENABLED=$(bashio::config "v4Enabled")
PREFIX_LENGTH=$(bashio::config "prefixLength")
REFRESH=$(bashio::config "refresh")
DNS_TTL=$(bashio::config "dnsttl")
PROXIED=$(bashio::config "proxied")
LEGACY_MODE=$(bashio::config "legacyMode")
CUSTOM_ENABLED=$(bashio::config "customEnabled")
CUSTOM_RECORDS=$(bashio::config "customRecords")

REFRESH_MIN=$((REFRESH / 60))
HEXTETS=$((PREFIX_LENGTH / 16))

CURRENT_V6=""
CURRENT_V4=""
CURRENT_PREFIX=""
FAIL_COUNT=0
SUCCESS_COUNT=0

# ----------------------------------
# FUNCTIONS
# ----------------------------------

log_error() {
    bashio::log.error "$1"
}

log_warning() {
    bashio::log.warning "$1"
}

log_info() {
    bashio::log.info "$1"
}

is_valid_ipv6() {
    local ip=${1,,}
    [[ "$ip" == *:* && "$ip" =~ ^[0-9a-f:]+$ ]]
}

is_gua_ipv6() {
    local ip=${1,,}

    # Globally routable unicast space is currently 2000::/3.
    is_valid_ipv6 "$ip" && [[ "$ip" =~ ^[23] ]]
}

is_ula_ipv6() {
    local ip=${1,,}

    # Unique-local address space is fc00::/7.
    is_valid_ipv6 "$ip" && [[ "$ip" =~ ^f[cd] ]]
}

fetch_cloudflare_trace_ip() {
    local family=$1
    local source_address=${2:-}
    local response ip
    local -a curl_args=(
        -sfSL
        --connect-timeout 10
        --max-time 20
        --noproxy "*"
        "$family"
    )

    if [[ -n "$source_address" ]]; then
        # Bind the probe to a specific local source address. This lets us
        # determine whether a ULA has working NAT66/NPTv6 Internet access.
        curl_args+=(--interface "$source_address")
    fi

    if ! response=$(curl "${curl_args[@]}" https://one.one.one.one/cdn-cgi/trace); then
        return
    fi

    ip=$(awk -F= '$1 == "ip" { print $2; exit }' <<< "$response" | tr -d '\r')
    [[ -n "$ip" ]] || return

    printf '%s\n' "$ip"
}

fetch_ipv6() {
    local response addresses address observed
    local -a gua_addresses=()
    local -a ula_addresses=()

    if ! response=$(
        curl -sfSL \
            -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
            http://supervisor/network/info
    ); then
        log_error "Communication with Supervisor API failed"
        echo "Unavailable"
        return
    fi

    if ! addresses=$(
        jq -r '
            .data.interfaces[]?
            | select(.primary == true)
            | .ipv6.address[]?
        ' <<< "$response"
    ); then
        log_error "Supervisor returned invalid JSON or no usable address"
        echo "Unavailable"
        return
    fi

    while IFS= read -r address; do
        address=${address%%/*}
        address=${address//[[:space:]]/}
        [[ -n "$address" ]] || continue

        if is_gua_ipv6 "$address"; then
            gua_addresses+=("$address")
        elif is_ula_ipv6 "$address"; then
            ula_addresses+=("$address")
        fi
    done <<< "$addresses"

    if (( ${#gua_addresses[@]} > 0 )); then
        printf '%s\n' "${gua_addresses[0]}"
        return
    fi
    
    for address in "${ula_addresses[@]}"; do
        if observed=$(fetch_cloudflare_trace_ip -6 "$address") \
            && is_gua_ipv6 "$observed"; then
            log_info "No native IPv6 GUA found; ULA $address reaches the Internet as $observed"
            printf '%s\n' "$observed"
            return
        fi

        log_warning "ULA $address could not reach the IPv6 Internet"
    done

    if (( ${#ula_addresses[@]} > 0 )); then
        log_error "No native IPv6 GUA found and no ULA had working IPv6 Internet access"
    else
        log_error "No usable IPv6 GUA or ULA found on the primary interface"
    fi

    echo "Unavailable"
}

fetch_ipv4() {
    local ipv4

    if ! ipv4=$(fetch_cloudflare_trace_ip -4); then
        log_error "Failed to fetch IPv4 from Cloudflare"
        echo "Unavailable"
        return
    fi

    if [[ "$ipv4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ipv4"
    else
        log_error "Invalid IPv4 address format"
        echo "Unavailable"
    fi
}

call_cf_api() {
    local method=$1
    local endpoint=$2
    local payload=${3:-}
    local response

    if [[ -z "$method" || -z "$endpoint" ]]; then
        log_error "Cloudflare API call missing method or endpoint"
        return
    fi

    if ! response=$(curl -sfSL -X "$method" "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/${endpoint}" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json" \
        ${payload:+--data "$payload"}); then
        log_error "Cloudflare API call failed: $method $endpoint"
        return
    fi

    if [[ -z "$response" ]]; then
        log_error "Cloudflare API returned empty response"
        return
    fi

    if ! jq -e '.success == true' <<< "$response" >/dev/null 2>&1; then
        log_error "Cloudflare API error: $(jq -c '.errors' <<< "$response")"
        return
    fi

    printf "%s\n" "$response"
}

get_or_create_dns_record() {
    local fqdn=$1
    local record_type=$2
    local content=$3
    local record_id

    if [[ -z "$fqdn" || -z "$record_type" || -z "$content" || "$content" == "Unavailable" ]]; then
        log_error "Missing parameters for DNS record management: $fqdn $record_type $content"
        return
    fi

    if ! record_id=$(call_cf_api GET "dns_records?type=${record_type}&name=${fqdn}" | jq -r '.result[0].id // empty'); then
        log_error "Unable to query existing record ID for $fqdn"
        return
    fi

    local payload
    payload=$(jq -cn \
        --arg type "$record_type" \
        --arg name "$fqdn" \
        --arg content "$content" \
        --argjson ttl "$DNS_TTL" \
        --argjson proxied "$PROXIED" \
        '{type:$type,name:$name,content:$content,ttl:$ttl,proxied:$proxied}')

    if [[ -n "$record_id" ]]; then
        if call_cf_api PUT "dns_records/${record_id}" "$payload"; then
            log_info "Updated DNS record: $fqdn -> $content"
        fi
    else
        if call_cf_api POST "dns_records" "$payload"; then
            log_info "Created DNS record: $fqdn -> $content"
        fi
    fi
}

generate_ipv6_prefix() {
    local ip=$1
    local prefix_tmp next_hextet padded remainder cut_length

    prefix_tmp=$(cut -d':' -f1-"$HEXTETS" <<< "$ip")
    next_hextet=$(cut -d':' -f$((HEXTETS + 1)) <<< "$ip")
    padded=$(printf "%04s" "$next_hextet")
    remainder=$((PREFIX_LENGTH % 16))

    if (( remainder > 0 )); then
        cut_length=$((remainder / 4))
        echo "${prefix_tmp}:$(cut -c1-"$cut_length" <<< "$padded")"
    else
        echo "${prefix_tmp}:"
    fi
}

process_custom_records() {
    if [[ -z "$CUSTOM_RECORDS" ]]; then
        log_warning "No custom records defined."
        return
    fi

    while IFS=, read -r record_fqdn record_type suffix; do
        [[ -z "$record_fqdn" || -z "$record_type" ]] && continue

        local value="Unavailable"
        if [[ "$record_type" == "A" ]]; then
            if [[ "$CURRENT_V4" != "Unavailable" ]]; then
                value="$CURRENT_V4"
            else
                log_error "Skipping A record for $record_fqdn: no valid IPv4 available."
                continue
            fi
        elif [[ "$record_type" == "AAAA" ]]; then
            if [[ -n "$suffix" ]]; then
                if [[ "$CURRENT_PREFIX" != "Unavailable" && "$suffix" =~ ^[0-9a-fA-F:]+$ ]]; then
                    value="${CURRENT_PREFIX}${suffix}"
                else
                    log_error "Skipping AAAA record for $record_fqdn: no valid IPv6 available or malformed suffix."
                    continue
                fi
            else
                if [[ "$CURRENT_V6" != "Unavailable" ]]; then
                    value="$CURRENT_V6"
                else
                    log_error "Skipping AAAA record for $record_fqdn: no valid IPv6 available."
                    continue
                fi
            fi
        else
            log_error "Unknown record type: $record_type for $record_fqdn. Skipping."
            continue
        fi
        value=${value//[[:space:]]/}
        get_or_create_dns_record "$record_fqdn" "$record_type" "$value"
    done <<< "$CUSTOM_RECORDS"
}

main() {
    while true; do
        local new_v6 new_v4

        if [[ "$LEGACY_MODE" == "true" ]]; then
            new_v6="Unavailable"
        else
            if ! new_v6=$(fetch_ipv6); then new_v6="Unavailable"; fi
        fi

        if [[ "$V4_ENABLED" == "true" ]]; then
            if ! new_v4=$(fetch_ipv4); then new_v4="Unavailable"; fi
        else
            new_v4="Unavailable"
        fi

        if [[ "$new_v6" == "Unavailable" && "$new_v4" == "Unavailable" ]]; then
            FAIL_COUNT=$((FAIL_COUNT + 1))
            SUCCESS_COUNT=0
            log_error "No usable IP found since $((REFRESH_MIN * FAIL_COUNT)) minutes. Retrying in $REFRESH_MIN minutes."
            sleep "$REFRESH"
            continue
        fi

        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        FAIL_COUNT=0

        if [[ "$new_v6" != "$CURRENT_V6" || "$new_v4" != "$CURRENT_V4" ]]; then
            CURRENT_V6="$new_v6"
            CURRENT_V4="$new_v4"

            CURRENT_PREFIX="Unavailable"
            if [[ "$LEGACY_MODE" != "true" && "$CURRENT_V6" != "Unavailable" ]]; then
                CURRENT_PREFIX=$(generate_ipv6_prefix "$CURRENT_V6")
            fi

            log_info "IP Change Detected:"
            log_info "IPv6: $CURRENT_V6 Prefix: $CURRENT_PREFIX/$PREFIX_LENGTH IPv4: $CURRENT_V4"

            if [[ -n "$HOSTFQDN" && "$LEGACY_MODE" != "true" ]]; then
                if [[ "$CURRENT_V6" != "Unavailable" ]]; then
                    get_or_create_dns_record "$HOSTFQDN" "AAAA" "$CURRENT_V6"
                else
                    log_error "Skipping AAAA record for $HOSTFQDN: no valid IPv6 available."
                fi
            fi

            if [[ -n "$HOSTFQDN" && "$V4_ENABLED" == "true" ]]; then
                if [[ "$CURRENT_V4" != "Unavailable" ]]; then
                    get_or_create_dns_record "$HOSTFQDN" "A" "$CURRENT_V4"
                else
                    log_error "Skipping A record for $HOSTFQDN: no valid IPv4 available."
                fi
            fi

            if [[ "$CUSTOM_ENABLED" == "true" ]]; then
                process_custom_records
            fi

            SUCCESS_COUNT=0
            log_info "DNS update complete. Sleeping for $REFRESH_MIN minutes."
        else
            log_info "No IP change for $((SUCCESS_COUNT * REFRESH_MIN)) minutes."
        fi

        sleep "$REFRESH"
    done
}

main

# (C) GitHub\TKtheDEV
