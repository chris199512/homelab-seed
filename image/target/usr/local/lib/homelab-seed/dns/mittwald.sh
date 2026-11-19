# shellcheck shell=bash
# DNS provider for the ACME challenge: mittwald (https://api.mittwald.de/v2).
# mittwald has no certbot plugin, so certbot calls this through manual hooks.
#
# Requires a DNS zone "_acme-challenge.<fqdn>" in mStudio. Settings:
#   MITTWALD_API_TOKEN   API token (from ACME_DNS_API_TOKEN)
#   MITTWALD_PROJECT_ID  optional project ID or short ID (from
#                        ACME_DNS_MITTWALD_PROJECT); without it the project is
#                        looked up in the list of all domains
#
# A provider implements dns_set_txt <fqdn> <value> and dns_clear_txt <fqdn>,
# and optionally dns_check <fqdn>, which runs before certbot is started.

# mittwald_api <method> <path> [curl args]: prints the response body, fails on
# HTTP errors. -L: short IDs (p-xxxxxx) redirect to the project's UUID.
mittwald_api() {
    local method=$1 path=$2
    shift 2
    curl -sS -L --fail-with-body -X "$method" \
        -H "Authorization: Bearer $MITTWALD_API_TOKEN" \
        -H 'Content-Type: application/json' \
        "$@" "https://api.mittwald.de/v2$path"
}

# mittwald_get <path>: like mittwald_api GET, but stops with the API's error.
mittwald_get() {
    local out
    out=$(mittwald_api GET "$1" 2>&1) || die "mittwald API: GET $1 failed: ${out:0:300}"
    printf '%s\n' "$out"
}

# mittwald_project_for <fqdn> <domains-json>: project ID of the longest
# registered domain the FQDN equals or ends with.
mittwald_project_for() {
    jq -r --arg f "$1" '
        [.[] | select(.domain as $d | $f == $d or ($f | endswith("." + $d)))]
        | sort_by(.domain | length) | last | .projectId // empty' <<<"$2"
}

# mittwald_project <fqdn>: the configured project, or the one owning the domain.
mittwald_project() {
    local domains project
    if [[ -n ${MITTWALD_PROJECT_ID:-} ]]; then
        printf '%s\n' "$MITTWALD_PROJECT_ID"
        return
    fi
    domains=$(mittwald_get /domains) ||
        die "Listing the domains failed – set ACME_DNS_MITTWALD_PROJECT to skip this lookup"
    project=$(mittwald_project_for "$1" "$domains")
    [[ -n $project ]] || die "No domain in the mittwald account matches $1 – set ACME_DNS_MITTWALD_PROJECT"
    printf '%s\n' "$project"
}

mittwald_challenge_zone() {
    local fqdn=$1 project zones zone
    project=$(mittwald_project "$fqdn") || return 1
    zones=$(mittwald_get "/projects/$project/dns-zones") || return 1
    zone=$(jq -r --arg z "_acme-challenge.$fqdn" 'first(.[] | select(.domain == $z) | .id) // empty' <<<"$zones")
    [[ -n $zone ]] || die "DNS zone _acme-challenge.$fqdn not found in project $project – create it in mStudio first"
    printf '%s\n' "$zone"
}

dns_check() {
    mittwald_challenge_zone "$1" >/dev/null
}

dns_set_txt() {
    local zone body
    zone=$(mittwald_challenge_zone "$1") || return 1
    body=$(jq -n --arg v "$2" '{entries: [$v], settings: {ttl: {auto: true}}}')
    mittwald_api PUT "/dns-zones/$zone/record-sets/txt" -d "$body" >/dev/null
}

dns_clear_txt() {
    local zone
    zone=$(mittwald_challenge_zone "$1") || return 1
    mittwald_api PUT "/dns-zones/$zone/record-sets/txt" -d '{}' >/dev/null
}
