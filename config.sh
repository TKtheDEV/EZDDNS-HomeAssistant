#!/usr/bin/env bash

load_config() {
    prefixLength=$(bashio::config "prefixLength")
    legacy=$(bashio::config "legacy")
    v4en=$(bashio::config "v4En")
    customen=$(bashio::config "customEn")
    hafqdn=$(bashio::config "fqdn")
    refresh=$(bashio::config "refresh")
    zoneId=$(bashio::config "zoneId")
    apiToken=$(bashio::config "apiToken")
    records=$(bashio::config "records")

    if [[ -z $prefixLength || -z $zoneId || -z $apiToken ]]; then
        echo "Missing required configuration parameters."
        exit 1
    fi

    if [[ ${prefixLength} == 64 ]]; then
        prefixCount=$(( (prefixLength / 4) + 4 ))
    else
        prefixCount=$(( (prefixLength / 4) + 3 ))
    fi
}
