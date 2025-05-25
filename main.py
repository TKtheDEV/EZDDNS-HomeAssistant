import requests
import time
import json
import os


def bashio_config(key):
    value = os.getenv(key)
    if value is None:
        raise KeyError(f"Configuration key '{key}' not found in environment variables.")
    return value


# Load configuration
supervisor_token = bashio_config("supervisorToken")
zone_id = bashio_config("zoneId")
api_token = bashio_config("apiToken")
hostfqdn = bashio_config("hostfqdn")
v4_enabled = bashio_config("v4Enabled") == "true"
prefix_length = int(bashio_config("prefixLength"))
refresh = int(bashio_config("refresh"))
dnsttl = int(bashio_config("dnsttl"))
proxied = bashio_config("proxied").lower() == "true"
legacy_mode = bashio_config("legacyMode").lower() == "true"
custom_enabled = bashio_config("customEnabled").lower() == "true"
custom_records = bashio_config("customRecords")

refresh_min = refresh // 60
fail_count = 0
success_count = 0
hextets = prefix_length // 16
v6 = None
v4 = None
prefix = None


def get_ipv6_from_supervisor():
    try:
        response = requests.get("http://supervisor/network/info", headers={
            "Authorization": f"Bearer {supervisor_token}"
        }, timeout=5)
        response.raise_for_status()
        data = response.json()

        interfaces = data.get("result", {}).get("interfaces", [])
        for iface in interfaces:
            for addr in iface.get("addresses", []):
                if addr.get("scope") == "global" and not addr.get("deprecated", False) and addr.get("valid", False):
                    return addr["address"].split("/")[0]
    except Exception as e:
        print(f"Error retrieving IPv6: {e}")

    return None


def cf_api(method, endpoint, data=None):
    url = f"https://api.cloudflare.com/client/v4/zones/{zone_id}/{endpoint}"
    headers = {
        "Authorization": f"Bearer {api_token}",
        "Content-Type": "application/json"
    }
    response = requests.request(method, url, headers=headers, json=data)
    response.raise_for_status()
    return response.json()


def cf_manage_record(fqdn, record_type, record_value):
    try:
        response = cf_api("GET", f"dns_records?type={record_type}&name={fqdn}")
        record_id = None
        for record in response.get("result", []):
            if record["name"] == fqdn and record["type"] == record_type:
                record_id = record["id"]
                break

        record_data = {
            "type": record_type,
            "name": fqdn,
            "content": record_value,
            "ttl": dnsttl,
            "proxied": proxied
        }

        if record_id:
            print(f"Updating {fqdn} ({record_type})")
            cf_api("PUT", f"dns_records/{record_id}", data=record_data)
        else:
            print(f"Creating {fqdn} ({record_type})")
            cf_api("POST", "dns_records", data=record_data)
    except Exception as e:
        print(f"Failed to manage DNS record {fqdn}: {e}")


def parse_records():
    if not custom_records:
        print("Error: customRecords is empty")
        return

    for line in custom_records.strip().split("\n"):
        parts = line.strip().split(",")
        if len(parts) < 2:
            continue
        record_fqdn, record_type, *suffix_parts = parts
        suffix = suffix_parts[0] if suffix_parts else ""

        if record_type == "A":
            record_value = v4
        elif record_type == "AAAA":
            if suffix:
                if prefix and all(c in "0123456789abcdefABCDEF:" for c in suffix):
                    record_value = f"{prefix}{suffix}"
                else:
                    print(f"Skipping {record_fqdn}: invalid prefix/suffix")
                    continue
            else:
                record_value = v6
        else:
            continue

        if not record_value:
            print(f"Skipping {record_fqdn}: invalid value")
            continue

        cf_manage_record(record_fqdn, record_type, record_value)


print("+++ Startup of EZDDNS (Python version) complete... +++")

while True:
    v6new = get_ipv6_from_supervisor()
    if v6new and not legacy_mode:
        prefix_tmp = ":".join(v6new.split(":")[:hextets])
        next_hextet = v6new.split(":")[hextets] if len(v6new.split(":")) > hextets else "0000"
        padded_next_hextet = next_hextet.zfill(4)
        remainder = prefix_length % 16
        cut_length = remainder // 4 if remainder else 0
        prefix = f"{prefix_tmp}:{padded_next_hextet[:cut_length]}" if cut_length else f"{prefix_tmp}:"
    else:
        v6new = None
        prefix = None

    try:
        trace_resp = requests.get("https://one.one.one.one/cdn-cgi/trace", timeout=5)
        v4new = next((line.split("=")[1] for line in trace_resp.text.splitlines() if line.startswith("ip=")), None)
    except Exception as e:
        print(f"Error retrieving IPv4: {e}")
        v4new = None

    if (not v6new) and (not v4new or not v4_enabled):
        success_count = 0
        fail_count += 1
        print(f"No Internet Connection detected for {refresh_min * fail_count} minutes. Retrying in {refresh_min} minutes...")
    else:
        fail_count = 0
        success_count += 1

        if v6new != v6 or v4new != v4:
            v6, v4 = v6new, v4new
            print(f"\nNew public IP config:\nPrefix: {prefix}\nIPv6: {v6}\nIPv4: {v4}\n")

            if hostfqdn and not legacy_mode and v6:
                cf_manage_record(hostfqdn, "AAAA", v6)
            if hostfqdn and v4_enabled and v4:
                cf_manage_record(hostfqdn, "A", v4)
            if custom_enabled:
                parse_records()

            print(f"Updated DNS records. Sleeping for {refresh_min} minutes.")
            success_count = 0
        else:
            print(f"No IP changes for {refresh_min * success_count} minutes. Sleeping {refresh_min} minutes.\nCurrent IPs:\nPrefix: {prefix}\nIPv6: {v6}\nIPv4: {v4}")

    time.sleep(refresh)
