# shellcheck shell=bash
# DNS provider for the ACME challenge: mittwald (https://api.mittwald.de/v2).
#
# Requires a DNS zone "_acme-challenge.<fqdn>" in mStudio. Settings:
#   MITTWALD_API_TOKEN  API token
#   MITTWALD_DOMAIN     registered domain the FQDN belongs to
#
# A provider implements dns_set_txt <fqdn> <value> and dns_clear_txt <fqdn>.

mittwald_api() {
    local method=$1 path=$2
    shift 2
    curl -sS --fail-with-body -X "$method" \
        -H "Authorization: Bearer $MITTWALD_API_TOKEN" \
        -H 'Content-Type: application/json' \
        "$@" "https://api.mittwald.de/v2$path"
}

mittwald_challenge_zone() {
    local fqdn=$1 project zone
    project=$(mittwald_api GET /domains |
        jq -r --arg d "$MITTWALD_DOMAIN" 'first(.[] | select(.domain == $d) | .projectId) // empty')
    [[ -n $project ]] || die "Domain $MITTWALD_DOMAIN not found in the mittwald account"
    zone=$(mittwald_api GET "/projects/$project/dns-zones" |
        jq -r --arg z "_acme-challenge.$fqdn" 'first(.[] | select(.domain == $z) | .id) // empty')
    [[ -n $zone ]] || die "DNS zone _acme-challenge.$fqdn not found – create it in mStudio first"
    echo "$zone"
}

dns_set_txt() {
    local zone body
    zone=$(mittwald_challenge_zone "$1")
    body=$(jq -n --arg v "$2" '{entries: [$v], settings: {ttl: {auto: true}}}')
    mittwald_api PUT "/dns-zones/$zone/record-sets/txt" -d "$body" >/dev/null
}

dns_clear_txt() {
    local zone
    zone=$(mittwald_challenge_zone "$1")
    mittwald_api PUT "/dns-zones/$zone/record-sets/txt" -d '{}' >/dev/null
}
