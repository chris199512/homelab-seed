# shellcheck shell=bash
# DNS provider for the ACME challenge: mittwald (https://api.mittwald.de/v2).
# mittwald has no certbot plugin, so certbot calls this through manual hooks.
#
# Requires a DNS zone "_acme-challenge.<fqdn>" in mStudio. Settings:
#   MITTWALD_API_TOKEN  API token (from ACME_DNS_API_TOKEN)
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

# mittwald_project_for <fqdn> <domains-json>: project ID of the longest
# registered domain the FQDN equals or ends with.
mittwald_project_for() {
    jq -r --arg f "$1" '
        [.[] | select(.domain as $d | $f == $d or ($f | endswith("." + $d)))]
        | sort_by(.domain | length) | last | .projectId // empty' <<<"$2"
}

mittwald_challenge_zone() {
    local fqdn=$1 project zone
    project=$(mittwald_project_for "$fqdn" "$(mittwald_api GET /domains)")
    [[ -n $project ]] || die "No domain in the mittwald account matches $fqdn"
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
