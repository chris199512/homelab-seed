# shellcheck shell=bash
# Loading, defaults and validation of config.env. Sourced by build-image.sh.
#
# config.example.env is the single source of truth: it defines every supported
# setting and its default value.

CONFIG_EXAMPLE=${CONFIG_EXAMPLE:-/src/config.example.env}

# Settings that are only needed at build time or by the installer. They are not
# copied into the installed system.
BUILD_ONLY_KEYS=(
    RASPIOS_IMAGE_URL RASPIOS_IMAGE_SHA256 LOCALE KEYBOARD_LAYOUT
    ADMIN_PASSWORD ADMIN_AUTHORIZED_KEYS_FILE
    NETWORK_INTERFACE NETWORK_GATEWAY NETWORK_DNS
    WIFI_SSID WIFI_PASSWORD WIFI_COUNTRY NTP_SERVERS
    TARGET_DEVICE INSTALLER_IF_INSTALLED INSTALLER_AFTER_INSTALL HOOKS_DIR
)

BOOL_KEYS=(
    SETUP_SYSTEM_UPGRADE SETUP_REBOOT_WHEN_DONE UNATTENDED_UPGRADES UNATTENDED_UPGRADES_REBOOT
    FIREWALL_ENABLED DOCKER_ENABLED SEMAPHORE_ENABLED SEMAPHORE_TOTP_ENABLED SMTP_SECURE
    PROXY_ENABLED ACME_STAGING BOOTSTRAP_ENABLED
)

config_keys() {
    sed -nE 's/^([A-Z][A-Z0-9_]*)=.*/\1/p' "$CONFIG_EXAMPLE"
}

# certbot DNS plugins whose credentials file holds a single API token, and the
# name of that setting. ACME_DNS_API_TOKEN is written into it.
acme_token_key() {
    case $1 in
        cloudflare) echo dns_cloudflare_api_token ;;
        digitalocean) echo dns_digitalocean_token ;;
        dnsimple) echo dns_dnsimple_token ;;
        linode) echo dns_linode_key ;;
        *) return 1 ;;
    esac
}

# expand_refs <value> <authorized-keys-file>: sets EXPANDED to the value with
# ${NAME} replaced by the setting NAME and ${ADMIN_SSH_KEYS} by all public keys
# joined by ";". Unknown references are added to UNKNOWN_REFS and kept as is.
# (Sets variables instead of printing: it must not run in a subshell.)
UNKNOWN_REFS=()
EXPANDED=""
expand_refs() {
    local rest=$1 keys_file=$2 out="" name known
    known=" $(config_keys | tr '\n' ' ') ADMIN_SSH_KEYS "
    while [[ $rest == *'${'* ]]; do
        out+=${rest%%'${'*}
        rest=${rest#*'${'}
        name=${rest%%\}*}
        if [[ $rest != *\}* || ! $name =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
            out+='${'
            continue
        fi
        rest=${rest#*\}}
        if [[ $known != *" $name "* ]]; then
            UNKNOWN_REFS+=("$name")
            out+="\${$name}"
        elif [[ $name == ADMIN_SSH_KEYS ]]; then
            out+=$(grep -E '^(ssh-|ecdsa-|sk-)' "$keys_file" | paste -sd ';' -)
        else
            out+=${!name}
        fi
    done
    EXPANDED=$out$rest
}

# expand_secrets_file <in> <out> <authorized-keys-file>
expand_secrets_file() {
    local line
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            expand_refs "${line#*=}" "$3"
            printf '%s=%s\n' "${line%%=*}" "$EXPANDED"
        else
            printf '%s\n' "$line"
        fi
    done <"$1" >"$2"
}

is_true() { [[ ${1,,} =~ ^(true|yes|on|1)$ ]]; }
is_bool() { [[ ${1,,} =~ ^(true|yes|on|1|false|no|off|0)$ ]]; }

# load_config <file>: defaults from config.example.env, then the user's file.
load_config() {
    local file=$1 key line known
    known=" $(config_keys | tr '\n' ' ') "

    while IFS= read -r line; do
        if [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)= ]]; then
            key=${BASH_REMATCH[2]}
            [[ $known == *" $key "* ]] || warn "Unknown setting '$key' in config (typo?) – ignored"
        fi
    done <"$file"

    # shellcheck source=config.example.env
    . "$CONFIG_EXAMPLE"
    # shellcheck source=/dev/null
    . "$file"

    if [[ -z $SEMAPHORE_WEB_HOST && -n $SEMAPHORE_FQDN ]] && is_true "$PROXY_ENABLED"; then
        if [[ $TLS_MODE == none ]]; then
            SEMAPHORE_WEB_HOST=http://$SEMAPHORE_FQDN
            [[ $PROXY_HTTP_PORT == 80 ]] || SEMAPHORE_WEB_HOST+=":$PROXY_HTTP_PORT"
        else
            SEMAPHORE_WEB_HOST=https://$SEMAPHORE_FQDN
            [[ $PROXY_HTTPS_PORT == 443 ]] || SEMAPHORE_WEB_HOST+=":$PROXY_HTTPS_PORT"
        fi
    fi
}

# validate_config <staged-dir>: checks everything and reports all problems at once.
validate_config() {
    local stage=$1 files=$1/files key errors=()
    err() { errors+=("$*"); }
    required() { local k; for k; do [[ -n ${!k} ]] || err "$k must be set"; done; }
    matches() { [[ ${!1} =~ $2 ]] || err "$1='${!1}' is invalid: $3"; }
    port() {
        local k
        for k; do
            if [[ ! ${!k} =~ ^[0-9]+$ ]] || ((${!k} < 1 || ${!k} > 65535)); then
                err "$k must be a port number"
            fi
        done
    }

    local ipv4='([0-9]{1,3}\.){3}[0-9]{1,3}'

    while IFS= read -r key; do
        [[ ${!key} != *$'\n'* && ${!key} != *$'\r'* ]] || err "$key must not contain line breaks"
    done < <(config_keys)
    for key in "${BOOL_KEYS[@]}"; do
        is_bool "${!key}" || err "$key must be true or false"
    done

    # System
    required RASPIOS_IMAGE_URL ADMIN_PASSWORD ADMIN_AUTHORIZED_KEYS_FILE
    [[ -z $RASPIOS_IMAGE_SHA256 ]] || matches RASPIOS_IMAGE_SHA256 '^[0-9a-fA-F]{64}$' "expected a SHA256 hex digest"
    matches TARGET_HOSTNAME '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,40}[a-zA-Z0-9])?$' "use letters, digits and '-' (max. 42 chars)"
    matches ADMIN_USER '^[a-z_][a-z0-9_-]{0,31}$' "use lowercase letters, digits, '_' and '-'"
    [[ $ADMIN_USER != root ]] || err "ADMIN_USER must not be root"
    matches LOCALE '^[A-Za-z_]+\.[A-Za-z0-9-]+(@[a-z]+)?$' "expected e.g. en_US.UTF-8"
    if [[ ! -s $files/authorized_keys ]]; then
        err "ADMIN_AUTHORIZED_KEYS_FILE: file is missing or empty"
    elif ! grep -qE '^(ssh-|ecdsa-|sk-)' "$files/authorized_keys"; then
        err "ADMIN_AUTHORIZED_KEYS_FILE contains no SSH public key"
    fi

    # Network
    matches NETWORK_INTERFACE '^(ethernet|wifi)$' "use ethernet or wifi"
    matches NETWORK_IPV4 '^(dhcp|static)$' "use dhcp or static"
    [[ -z $NETWORK_DNS ]] || matches NETWORK_DNS "^$ipv4( +$ipv4)*$" "expected IPv4 addresses separated by spaces"
    if [[ $NETWORK_IPV4 == static ]]; then
        required NETWORK_ADDRESS NETWORK_GATEWAY NETWORK_DNS
        matches NETWORK_ADDRESS "^$ipv4/[0-9]{1,2}$" "expected address/prefix, e.g. 192.168.1.10/24"
        matches NETWORK_GATEWAY "^$ipv4$" "expected an IPv4 address"
    fi
    if [[ $NETWORK_INTERFACE == wifi ]]; then
        required WIFI_SSID WIFI_COUNTRY
        matches WIFI_COUNTRY '^[A-Z]{2}$' "expected a two-letter country code such as DE"
        [[ -z $WIFI_PASSWORD ]] || ((${#WIFI_PASSWORD} >= 8 && ${#WIFI_PASSWORD} <= 63)) ||
            err "WIFI_PASSWORD must be 8–63 characters (or empty for open networks)"
    fi
    [[ -z $NTP_SERVERS ]] || matches NTP_SERVERS '^[A-Za-z0-9.:-]+( +[A-Za-z0-9.:-]+)*$' "expected host names separated by spaces"

    # Installer
    matches TARGET_DEVICE '^/dev/' "must be a device path such as /dev/mmcblk0"
    matches INSTALLER_IF_INSTALLED '^(skip|overwrite)$' "use skip or overwrite"
    matches INSTALLER_AFTER_INSTALL '^(reboot|poweroff)$' "use reboot or poweroff"

    # Setup, security
    [[ -z $EXTRA_PACKAGES ]] || matches EXTRA_PACKAGES '^[a-z0-9][a-z0-9.+:=~-]*( +[a-z0-9][a-z0-9.+:=~-]*)*$' "expected package names separated by spaces"
    if [[ -n $HOOKS_DIR ]] && ! compgen -G "$stage/hooks/*.sh" >/dev/null; then
        err "HOOKS_DIR contains no *.sh files"
    fi
    matches UNATTENDED_UPGRADES_REBOOT_TIME '^([01][0-9]|2[0-3]):[0-5][0-9]$' "expected HH:MM"
    if [[ $FIREWALL_SSH_FROM != any ]]; then
        matches FIREWALL_SSH_FROM "^$ipv4(/[0-9]{1,2})?( +$ipv4(/[0-9]{1,2})?)*$" "use any or CIDRs separated by spaces"
    fi
    [[ -z $FIREWALL_ALLOW ]] || matches FIREWALL_ALLOW '^[0-9]+(:[0-9]+)?/(tcp|udp)( +[0-9]+(:[0-9]+)?/(tcp|udp))*$' "expected rules like 8080/tcp 53/udp"

    # Docker, Semaphore, proxy
    matches DOCKER_NETWORK '^[a-zA-Z0-9][a-zA-Z0-9_.-]*$' "not a valid Docker network name"
    if is_true "$SEMAPHORE_ENABLED"; then
        is_true "$DOCKER_ENABLED" || err "SEMAPHORE_ENABLED requires DOCKER_ENABLED"
        required SEMAPHORE_VERSION SEMAPHORE_ADMIN_USER SEMAPHORE_ADMIN_NAME SEMAPHORE_ADMIN_EMAIL SEMAPHORE_ADMIN_PASSWORD
        port SEMAPHORE_PORT
        [[ -z $SMTP_HOST ]] || { required SMTP_SENDER; port SMTP_PORT; }
    fi
    if is_true "$PROXY_ENABLED"; then
        is_true "$SEMAPHORE_ENABLED" || err "PROXY_ENABLED requires SEMAPHORE_ENABLED"
        required NGINX_VERSION
        port PROXY_HTTP_PORT PROXY_HTTPS_PORT
        [[ -z $SEMAPHORE_FQDN ]] || matches SEMAPHORE_FQDN '^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$' "not a valid domain name"
    fi

    # TLS
    matches TLS_MODE '^(none|selfsigned|letsencrypt-http|letsencrypt-dns)$' "use none, selfsigned, letsencrypt-http or letsencrypt-dns"
    if [[ $TLS_MODE != none ]]; then
        is_true "$PROXY_ENABLED" || err "TLS_MODE=$TLS_MODE requires PROXY_ENABLED"
    fi
    if [[ $TLS_MODE == letsencrypt-* ]]; then
        required SEMAPHORE_FQDN ACME_EMAIL
    fi
    if [[ $TLS_MODE == letsencrypt-http && $PROXY_HTTP_PORT != 80 ]]; then
        warn "letsencrypt-http: Let's Encrypt connects to port 80 – forward it to PROXY_HTTP_PORT=$PROXY_HTTP_PORT"
    fi
    if [[ $TLS_MODE == letsencrypt-dns ]]; then
        matches ACME_DNS_PROPAGATION_SECONDS '^[0-9]+$' "expected a number of seconds"
        matches ACME_DNS_PROVIDER '^[a-z0-9]+$' "expected the name of a certbot DNS plugin, e.g. cloudflare"
        if [[ $ACME_DNS_PROVIDER == mittwald ]]; then
            required ACME_DNS_API_TOKEN
        elif [[ $ACME_DNS_PROVIDER == route53 ]]; then
            err "ACME_DNS_PROVIDER=route53 is not supported (it reads AWS credentials, not a credentials file)"
        elif [[ -z $ACME_DNS_CREDENTIALS_FILE ]]; then
            if ! acme_token_key "$ACME_DNS_PROVIDER" >/dev/null; then
                err "ACME_DNS_PROVIDER=$ACME_DNS_PROVIDER needs ACME_DNS_CREDENTIALS_FILE (ACME_DNS_API_TOKEN only works for cloudflare, digitalocean, dnsimple, linode, mittwald)"
            else
                required ACME_DNS_API_TOKEN
            fi
        elif ! grep -q '=' "$files/dns-credentials" 2>/dev/null; then
            err "ACME_DNS_CREDENTIALS_FILE contains no 'key = value' settings"
        fi
    fi

    # Bootstrap
    if is_true "$BOOTSTRAP_ENABLED"; then
        is_true "$SEMAPHORE_ENABLED" || err "BOOTSTRAP_ENABLED requires SEMAPHORE_ENABLED"
        required BOOTSTRAP_PROJECT_NAME BOOTSTRAP_REPO_NAME BOOTSTRAP_REPO_URL BOOTSTRAP_REPO_BRANCH \
            BOOTSTRAP_INVENTORY_NAME BOOTSTRAP_INVENTORY_PATH BOOTSTRAP_ENVIRONMENT_NAME
        [[ $BOOTSTRAP_REPO_URL != *github.com/you/* ]] || err "BOOTSTRAP_REPO_URL still points to the example repository"
        matches BOOTSTRAP_TASK_TIMEOUT '^[0-9]+$' "expected a number of seconds"
        [[ -z $BOOTSTRAP_PLAYBOOK ]] || required BOOTSTRAP_TEMPLATE_NAME
        [[ -z $BOOTSTRAP_REPO_TOKEN ]] || required BOOTSTRAP_REPO_KEY_NAME
        [[ -z $BOOTSTRAP_BECOME_PASSWORD ]] || required BOOTSTRAP_BECOME_KEY_NAME
        if [[ -n $BOOTSTRAP_SSH_PRIVATE_KEY_FILE ]]; then
            required BOOTSTRAP_SSH_KEY_NAME BOOTSTRAP_SSH_LOGIN
            grep -q -- '-----BEGIN' "$files/ssh_key" 2>/dev/null ||
                err "BOOTSTRAP_SSH_PRIVATE_KEY_FILE does not contain a private key"
        fi
        if [[ -n $BOOTSTRAP_SECRETS_FILE ]]; then
            local line n=0
            while IFS= read -r line || [[ -n $line ]]; do
                n=$((n + 1))
                [[ -z ${line//[[:space:]]/} || $line =~ ^[[:space:]]*# ]] && continue
                [[ $line =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || err "BOOTSTRAP_SECRETS_FILE line $n is not KEY=VALUE"
            done <"$files/secrets.env"
            UNKNOWN_REFS=()
            expand_secrets_file "$files/secrets.env" /dev/null "$files/authorized_keys"
            if ((${#UNKNOWN_REFS[@]})); then
                err "BOOTSTRAP_SECRETS_FILE references unknown settings: $(printf '${%s} ' "${UNKNOWN_REFS[@]}")"
            fi
        fi
    fi

    if ((${#errors[@]})); then
        printf '  - %s\n' "${errors[@]}" >&2
        die "config.env is invalid (${#errors[@]} problem(s))"
    fi
}

# write_env <file> <key>...: writes the settings so that bash can source them.
write_env() {
    local file=$1 key
    shift
    for key; do
        printf '%s=%q\n' "$key" "${!key}"
    done >"$file"
    chmod 600 "$file"
}

# Keys copied into the installed system.
runtime_keys() {
    local key skip=" ${BUILD_ONLY_KEYS[*]} "
    while IFS= read -r key; do
        [[ $skip == *" $key "* ]] || printf '%s\n' "$key"
    done < <(config_keys)
}
