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
        case $ACME_DNS_PROVIDER in
            cloudflare) required CLOUDFLARE_API_TOKEN ;;
            mittwald) required MITTWALD_API_TOKEN MITTWALD_DOMAIN ;;
            *) err "ACME_DNS_PROVIDER='$ACME_DNS_PROVIDER' is not supported (use cloudflare or mittwald)" ;;
        esac
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
