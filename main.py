#!/usr/bin/env python3
import os
import time
import json
import requests
import logging

logging.basicConfig(level=logging.INFO, format="%(message)s")

# --- Load Environment Variables ---
def get_env_bool(key, default="false"):
    return os.getenv(key, default).lower() in ("1", "true", "yes", "on")

def get_env_int(key, default):
    try:
        return int(os.getenv(key, str(default)))
    except (TypeError, ValueError):
        return default

SUPERVISOR_TOKEN = os.getenv("SUPERVISOR_TOKEN")
ZONE_ID = os.getenv("ZONE_ID")
API_TOKEN = os.getenv("API_TOKEN")
HOSTFQDN = os.getenv("HOSTFQDN")

V4_ENABLED = get_env_bool("V4_ENABLED", "false")
PREFIX_LENGTH = get_env_int("PREFIX_LENGTH", 56)
REFRESH = get_env_int("REFRESH", 300)
DNS_TTL = get_env_int("DNS_TTL", 1)
PROXIED = get_env_bool("PROXIED", "false")
LEGACY_MODE = get_env_bool("LEGACY_MODE", "false")
CUSTOM_ENABLED = get_env_bool("CUSTOM_ENABLED", "false")
CUSTOM_RECORDS = os.getenv("CUSTOM_RECORDS", "")

# --- Global State ---
v6_old = None
v4_old = None
prefix = None

# --- Supervisor IPv6 Fetch ---
def get_ipv6_from_supervisor():
    try:
        resp = requests.get(
            "http://supervisor/network/info",
            headers={"Authorization": f"Bearer {SUPERVISOR_TOKEN}"},
            timeout=5
        )

        try:
            data = resp.json()
        except json.JSONDecodeError:
            logging.error("Supervisor returned non-JSON or invalid response.")
            return "Unavailable"

        for iface in data["data"]["interfaces"]:
            if not iface.get("enabled"):
                continue

            for ip in iface.get("ipv6", {}).get("address", []):
                ip_only = ip.split("/")[0]
                if ip_only.startswith("200"):  # GUA only
                    logging.info(f"Selected IPv6: {ip_only}")
                    return ip_only

        logging.warning("No valid global IPv6 address found.")
    except Exception as e:
        logging.error(f"IPv6 fetch failed: {e}")

    return "Unavailable"

# --- Public IPv4 Fetch ---
def get_public_ipv4():
    try:
        r = requests.get("https://one.one.one.one/cdn-cgi/trace", timeout=10)
        for line in r.text.splitlines():
            if line.startswith("ip="):
                return line.split("=")[1]
    except Exception as e:
        logging.error(f"IPv4 fetch failed: {e}")
    return "Unavailable"

# --- Cloudflare API Wrapper ---
def cf_api(method, endpoint, data=None):
    url = f"https://api.cloudflare.com/client/v4/zones/{ZONE_ID}/{endpoint}"
    headers = {
        "Authorization": f"Bearer {API_TOKEN}",
        "Content-Type": "application/json"
    }
    return requests.request(method, url, headers=headers, json=data).json()

def cf_manage_record(fqdn, record_type, record_value):
    if not fqdn:
        logging.warning(f"Skipping DNS update: fqdn is empty.")
        return

    logging.info(f"Managing record {fqdn} ({record_type}) → {record_value}")
    query = cf_api("GET", f"dns_records?type={record_type}&name={fqdn}")
    record_id = query["result"][0]["id"] if query.get("result") else None

    payload = {
        "type": record_type,
        "name": fqdn,
        "content": record_value,
        "ttl": DNS_TTL,
        "proxied": PROXIED
    }

    if record_id:
        cf_api("PUT", f"dns_records/{record_id}", payload)
    else:
        cf_api("POST", "dns_records", payload)

# --- IPv6 Prefix Generator ---
def calculate_prefix(ipv6):
    if ipv6 == "Unavailable":
        return "Unavailable"

    hextets = PREFIX_LENGTH // 16
    parts = ipv6.split(":")[:hextets]
    base = ":".join(parts)

    if PREFIX_LENGTH % 16 != 0:
        next_part = ipv6.split(":")[hextets]
        padded = next_part.rjust(4, "0")
        cut_len = PREFIX_LENGTH % 16 // 4
        return base + ":" + padded[:cut_len]
    else:
        return base + ":"

# --- Custom Records Parser ---
def parse_custom_records(v4, v6, prefix):
    for line in CUSTOM_RECORDS.strip().splitlines():
        try:
            fqdn, rtype, suffix = (line.strip() + ",,").split(",")[:3]
            if not fqdn or not rtype:
                continue

            if rtype == "A" and v4 != "Unavailable":
                cf_manage_record(fqdn, "A", v4)
            elif rtype == "AAAA":
                value = prefix + suffix if suffix and prefix != "Unavailable" else v6
                if value and ":" in value:
                    cf_manage_record(fqdn, "AAAA", value)
        except Exception as e:
            logging.error(f"Failed to process custom record: {line} → {e}")

# --- Main Loop ---
logging.info("+++ EZDDNS Python add-on started +++")

while True:
    v6_new = get_ipv6_from_supervisor()
    v4_new = get_public_ipv4() if V4_ENABLED else "Unavailable"
    prefix = calculate_prefix(v6_new) if not LEGACY_MODE else "Unavailable"

    logging.info(f"New IPs → IPv6: {v6_new} | IPv4: {v4_new} | Prefix: {prefix}")

    if v6_new != v6_old or v4_new != v4_old:
        if HOSTFQDN:
            if v6_new != "Unavailable" and not LEGACY_MODE:
                cf_manage_record(HOSTFQDN, "AAAA", v6_new)
            if v4_new != "Unavailable" and V4_ENABLED:
                cf_manage_record(HOSTFQDN, "A", v4_new)

        if CUSTOM_ENABLED:
            parse_custom_records(v4_new, v6_new, prefix)

        v6_old = v6_new
        v4_old = v4_new
    else:
        logging.info(f"No IP changes. Sleeping {REFRESH // 60} minutes.")

    time.sleep(REFRESH)
