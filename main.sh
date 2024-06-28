#!/usr/bin/with-contenv bashio

source config.sh
source cloudflare_api.sh
source update_dns.sh

v4=""
v4new=""
v6=""
v6new=""
prefix=""

load_config

while true; do
    bashio::cache.flush_all

    v6_addresses=$(bashio::network.ipv6_address)
    for getv6 in $v6_addresses; do
        if [[ "$getv6" != fe80* && "$getv6" != fc* && "$getv6" != fd* ]]; then
            v6new="${getv6:0:38}"
            break
        fi
    done

    if [[ -n "${v6new}" && "${legacy}" != true ]]; then
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

        if [[ ${customen} == true ]]; then
            parse_records
        fi
    else
        echo "IPs haven't changed since the last update"
    fi

    sleep "${refresh}"
done
