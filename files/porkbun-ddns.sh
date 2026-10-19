#!/usr/bin/env bash
# Keep Porkbun A records pointed at this network's public IPv4.
set -euo pipefail

# shellcheck source=/dev/null
source /etc/homeserver/config.env

API="https://api.porkbun.com/api/json/v3"
CACHE_DIR=/var/lib/porkbun-ddns
CACHE="$CACHE_DIR/last_ip"
mkdir -p "$CACHE_DIR"

auth=$(jq -n --arg a "$PORKBUN_API_KEY" --arg s "$PORKBUN_SECRET_KEY" \
  '{apikey: $a, secretapikey: $s}')

post() { # post <url> <json>
  curl -fsS --max-time 20 -X POST -H 'Content-Type: application/json' -d "$2" "$1"
}

# IPv4-only host so we always get the v4 address.
ip=$(post "https://api-ipv4.porkbun.com/api/json/v3/ping" "$auth" | jq -r '.yourIp // empty')
if ! [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "could not get public IPv4 (got '$ip')" >&2
  exit 1
fi

# Unchanged IP: skip API calls, but re-verify records at least hourly.
if [[ -f $CACHE && $(cat "$CACHE") == "$ip" ]] && [[ -n $(find "$CACHE" -mmin -60) ]]; then
  exit 0
fi

for rec in $DDNS_RECORDS; do
  sub=""; [[ $rec != "@" ]] && sub="$rec"
  path="$DDNS_DOMAIN/A${sub:+/$sub}"
  fqdn="${sub:+$sub.}$DDNS_DOMAIN"

  current=$(post "$API/dns/retrieveByNameType/$path" "$auth" | jq -r '.records[0].content // empty')

  if [[ -z $current ]]; then
    body=$(jq --arg n "$sub" --arg c "$ip" --arg t "$DDNS_TTL" \
      '. + {name: $n, type: "A", content: $c, ttl: $t}' <<<"$auth")
    post "$API/dns/create/$DDNS_DOMAIN" "$body" | jq -e '.status == "SUCCESS"' >/dev/null
    echo "$fqdn: created A -> $ip"
  elif [[ $current != "$ip" ]]; then
    body=$(jq --arg c "$ip" --arg t "$DDNS_TTL" '. + {content: $c, ttl: $t}' <<<"$auth")
    post "$API/dns/editByNameType/$path" "$body" | jq -e '.status == "SUCCESS"' >/dev/null
    echo "$fqdn: updated A $current -> $ip"
  fi
done

echo "$ip" >"$CACHE"
