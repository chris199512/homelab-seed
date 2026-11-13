#!/bin/bash
# Unit tests for the builder and the setup helpers. They need bash, jq, tar
# and base64, but no Docker and no root.
#
#   tests/run-tests.sh
#
# Test code is passed in single quotes and expanded inside the test.
# shellcheck disable=SC2016
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export REPO
export CONFIG_EXAMPLE=$REPO/config.example.env
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASSED=0
FAILED=0
SKIPPED=0
# A test exits with this code if a tool it needs is missing.
export SKIP=77

# Code run before every test.
PRELUDE="set -Eeuo pipefail"
# Git Bash on Windows cannot set permissions on NTFS; that is not what we test.
if [[ $(uname -s) == MINGW* || $(uname -s) == MSYS* ]]; then
    PRELUDE+=$'\n''install() { command install "$@" 2>/dev/null || true; }; chmod() { :; }'
fi

# GitHub Actions annotation, so failures show up on the run and in pull requests.
annotate() { # <title> <message>
    local message=$2
    [[ -n ${GITHUB_ACTIONS:-} ]] || return 0
    message=${message//'%'/'%25'}
    message=${message//$'\r'/'%0D'}
    message=${message//$'\n'/'%0A'}
    printf '::error file=tests/run-tests.sh,title=%s::%s\n' "$1" "$message"
}

# check <name> <bash code>: runs the code in a fresh bash; non-zero exit = failure.
check() {
    local name=$1 code=$2 output rc=0
    output=$(cd "$TMP" && bash -c "$PRELUDE"$'\n'"$code" 2>&1) || rc=$?
    if ((rc == 0)); then
        PASSED=$((PASSED + 1))
        printf '  \033[32mok\033[0m    %s\n' "$name"
    elif ((rc == SKIP)); then
        SKIPPED=$((SKIPPED + 1))
        printf '  \033[33mskip\033[0m  %s (%s)\n' "$name" "$output"
        annotate "Skipped: $name" "$output"
    else
        FAILED=$((FAILED + 1))
        printf '  \033[31mFAIL\033[0m  %s\n' "$name"
        printf '%s\n' "$output" | sed 's/^/        /'
        annotate "Test failed: $name" "$output"
    fi
}

# In CI nothing may be skipped.
finish() {
    echo
    printf '%d passed, %d failed, %d skipped\n' "$PASSED" "$FAILED" "$SKIPPED"
    if [[ -n ${CI:-} ]] && ((SKIPPED)); then
        echo "Tests must not be skipped in CI – install the missing tools."
        exit 1
    fi
    ((FAILED == 0))
}

# Helpers available inside the test code.
cat >"$TMP/helpers.sh" <<'EOF'
assert_contains() { # <haystack> <needle>
    [[ $1 == *"$2"* ]] || { printf 'expected to contain: %s\n--- got:\n%s\n' "$2" "$1"; return 1; }
}
assert_not_contains() {
    [[ $1 != *"$2"* ]] || { printf 'expected NOT to contain: %s\n--- got:\n%s\n' "$2" "$1"; return 1; }
}
assert_eq() {
    [[ $1 == "$2" ]] || { printf 'expected: [%s]\n     got: [%s]\n' "$2" "$1"; return 1; }
}
load_builder() {
    . "$REPO/builder/lib.sh"
    . "$REPO/builder/config.sh"
    . "$REPO/builder/build-image.sh"
}
# new_config <lines...>: config dir with valid minimum settings plus the given lines.
new_config() {
    CONFIG_DIR=$(mktemp -d "$PWD/cfg.XXXX")
    STAGE=$(mktemp -d "$PWD/stage.XXXX")/stage
    FILES=$STAGE/files
    mkdir -p "$CONFIG_DIR/secrets"
    echo "ssh-ed25519 AAAAC3NzaTEST test@example" >"$CONFIG_DIR/secrets/authorized_keys"
    { printf 'ADMIN_PASSWORD=x\nSEMAPHORE_ADMIN_PASSWORD=y\n'; printf '%s\n' "$@"; } >"$CONFIG_DIR/config.env"
}
# validate <lines...>: prints the validation output, fails if invalid.
validate() {
    new_config "$@"
    ( stage_config && validate_config "$STAGE" ) 2>&1
}
# invalid <lines...>: prints the validation output, fails if valid.
invalid() {
    local out
    if out=$(validate "$@"); then printf 'expected the config to be invalid\n%s\n' "$out"; return 1; fi
    printf '%s\n' "$out"
}
load_target() {
    . "$REPO/image/common/usr/local/lib/homelab-seed/common.sh"
    SEED_ETC=$PWD/etc
    mkdir -p "$SEED_ETC"
    . "$REPO/image/target/usr/local/lib/homelab-seed/containers.sh"
    local f
    for f in "$REPO"/image/target/usr/local/lib/homelab-seed/setup.d/*.sh; do . "$f"; done
}
EOF
export HELPERS=$TMP/helpers.sh

echo "Configuration"

check "minimal configuration is valid" '
    . "$HELPERS"; load_builder
    validate'

check "config.example.env only lacks the passwords and the key file" '
    . "$HELPERS"; load_builder
    CONFIG_DIR=$(mktemp -d "$PWD/cfg.XXXX"); STAGE=$PWD/st/stage; FILES=$STAGE/files
    cp "$CONFIG_EXAMPLE" "$CONFIG_DIR/config.env"
    out=$( (stage_config && validate_config "$STAGE") 2>&1 ) && exit 1
    assert_contains "$out" "ADMIN_AUTHORIZED_KEYS_FILE: file ./secrets/authorized_keys not found"'

check "missing passwords are reported" '
    . "$HELPERS"; load_builder
    new_config; printf "ADMIN_PASSWORD=\nSEMAPHORE_ADMIN_PASSWORD=\n" >>"$CONFIG_DIR/config.env"
    out=$( (stage_config && validate_config "$STAGE") 2>&1 ) && exit 1
    assert_contains "$out" "ADMIN_PASSWORD must be set"
    assert_contains "$out" "SEMAPHORE_ADMIN_PASSWORD must be set"'

check "all problems are reported at once" '
    . "$HELPERS"; load_builder
    out=$(invalid TARGET_HOSTNAME=bad_name INSTALLER_IF_INSTALLED=maybe PROXY_ENABLED=jein)
    assert_contains "$out" "TARGET_HOSTNAME"
    assert_contains "$out" "INSTALLER_IF_INSTALLED"
    assert_contains "$out" "PROXY_ENABLED must be true or false"
    assert_contains "$out" "(3 problem(s))"'

check "unknown settings produce a warning" '
    . "$HELPERS"; load_builder
    out=$(validate BOOTSTRAP_RUN_AFTR=typo)
    assert_contains "$out" "Unknown setting '\''BOOTSTRAP_RUN_AFTR'\''"'

check "TLS requires the proxy, Let's Encrypt requires FQDN and e-mail" '
    . "$HELPERS"; load_builder
    out=$(invalid TLS_MODE=letsencrypt-http)
    assert_contains "$out" "requires PROXY_ENABLED"
    assert_contains "$out" "SEMAPHORE_FQDN must be set"
    assert_contains "$out" "ACME_EMAIL must be set"'

check "DNS providers: token, credentials file or not supported" '
    . "$HELPERS"; load_builder
    le="PROXY_ENABLED=true TLS_MODE=letsencrypt-dns SEMAPHORE_FQDN=s.example.org ACME_EMAIL=a@example.org"
    out=$(invalid $le ACME_DNS_PROVIDER=mittwald)
    assert_contains "$out" "ACME_DNS_API_TOKEN must be set"
    validate $le ACME_DNS_PROVIDER=mittwald ACME_DNS_API_TOKEN=t >/dev/null
    validate $le ACME_DNS_PROVIDER=digitalocean ACME_DNS_API_TOKEN=t >/dev/null
    out=$(invalid $le ACME_DNS_PROVIDER=ovh ACME_DNS_API_TOKEN=t)
    assert_contains "$out" "needs ACME_DNS_CREDENTIALS_FILE"
    out=$(invalid $le ACME_DNS_PROVIDER=route53)
    assert_contains "$out" "not supported"
    out=$(invalid $le ACME_DNS_PROVIDER=Cloud-Flare)
    assert_contains "$out" "certbot DNS plugin"'

check "DNS credentials file is staged; token providers get one generated" '
    . "$HELPERS"; load_builder
    le="PROXY_ENABLED=true TLS_MODE=letsencrypt-dns SEMAPHORE_FQDN=s.example.org ACME_EMAIL=a@example.org"
    new_config $le ACME_DNS_PROVIDER=ovh ACME_DNS_CREDENTIALS_FILE=./secrets/ovh.ini
    printf "dns_ovh_endpoint = ovh-eu\r\n" >"$CONFIG_DIR/secrets/ovh.ini"
    stage_config 2>/dev/null; validate_config "$STAGE"
    assert_eq "$(cat "$FILES/dns-credentials")" "dns_ovh_endpoint = ovh-eu"
    assert_eq "$(acme_token_key cloudflare)" "dns_cloudflare_api_token"
    assert_eq "$(acme_token_key linode)" "dns_linode_key"
    ! acme_token_key ovh'

check "secrets file: \${NAME} references are expanded" '
    . "$HELPERS"; load_builder
    new_config "ACME_DNS_API_TOKEN=tok-123" "ADMIN_PASSWORD='\''p\$w \"x'\''"
    stage_config 2>/dev/null
    printf "ssh-ed25519 AAA one\nssh-rsa BBB two\n" >"$FILES/authorized_keys"
    printf "A=\${ACME_DNS_API_TOKEN}\nB=pre-\${ADMIN_PASSWORD}-post\nC=\${ADMIN_SSH_KEYS}\nD=literal \$x \${lower} \${\n# \${ADMIN_PASSWORD} in a comment\n" >in.env
    UNKNOWN_REFS=()
    expand_secrets_file in.env out.env "$FILES/authorized_keys"
    assert_eq "$(sed -n 1p out.env)" "A=tok-123"
    assert_eq "$(sed -n 2p out.env)" "B=pre-p\$w \"x-post"
    assert_eq "$(sed -n 3p out.env)" "C=ssh-ed25519 AAA one;ssh-rsa BBB two"
    assert_eq "$(sed -n 4p out.env)" "D=literal \$x \${lower} \${"
    assert_eq "$(sed -n 5p out.env)" "# \${ADMIN_PASSWORD} in a comment"
    assert_eq "${#UNKNOWN_REFS[@]}" "0"'

check "secrets file: unknown references are reported" '
    . "$HELPERS"; load_builder
    new_config BOOTSTRAP_ENABLED=true BOOTSTRAP_REPO_URL=https://example.org/r.git BOOTSTRAP_SECRETS_FILE=./secrets/s.env
    printf "X=\${NOT_A_SETTING}\nY=\${ADMIN_PASSWORD}\n" >"$CONFIG_DIR/secrets/s.env"
    out=$( (stage_config && validate_config "$STAGE") 2>&1 ) && exit 1
    assert_contains "$out" "unknown settings: \${NOT_A_SETTING}"
    assert_not_contains "$out" "\${ADMIN_PASSWORD}"'

check "SEMAPHORE_WEB_HOST is derived from the proxy settings" '
    . "$HELPERS"; load_builder
    new_config PROXY_ENABLED=true TLS_MODE=selfsigned SEMAPHORE_FQDN=s.example.org PROXY_HTTPS_PORT=8443
    stage_config 2>/dev/null
    assert_eq "$SEMAPHORE_WEB_HOST" "https://s.example.org:8443"
    new_config PROXY_ENABLED=true SEMAPHORE_FQDN=s.example.org
    stage_config 2>/dev/null
    assert_eq "$SEMAPHORE_WEB_HOST" "http://s.example.org"'

check "network: static and Wi-Fi settings are checked" '
    . "$HELPERS"; load_builder
    validate NETWORK_INTERFACE=wifi NETWORK_IPV4=static NETWORK_ADDRESS=192.168.1.10/24 \
        NETWORK_GATEWAY=192.168.1.1 "NETWORK_DNS=\"192.168.1.1 9.9.9.9\"" WIFI_SSID=Home WIFI_PASSWORD=supersecret >/dev/null
    out=$(invalid NETWORK_INTERFACE=wifi NETWORK_IPV4=static NETWORK_ADDRESS=192.168.1.10 WIFI_PASSWORD=short WIFI_COUNTRY=de)
    assert_contains "$out" "NETWORK_GATEWAY must be set"
    assert_contains "$out" "expected address/prefix"
    assert_contains "$out" "WIFI_SSID must be set"
    assert_contains "$out" "WIFI_PASSWORD must be 8"
    assert_contains "$out" "two-letter country code"'

check "component dependencies are enforced" '
    . "$HELPERS"; load_builder
    out=$(invalid DOCKER_ENABLED=false)
    assert_contains "$out" "SEMAPHORE_ENABLED requires DOCKER_ENABLED"
    validate DOCKER_ENABLED=false SEMAPHORE_ENABLED=false >/dev/null'

check "firewall, packages and reboot time are checked" '
    . "$HELPERS"; load_builder
    out=$(invalid "FIREWALL_ALLOW=\"8080 53/udp\"" "EXTRA_PACKAGES=\"htop Vim\"" UNATTENDED_UPGRADES_REBOOT_TIME=25:00 "FIREWALL_SSH_FROM=lan")
    assert_contains "$out" "FIREWALL_ALLOW"
    assert_contains "$out" "EXTRA_PACKAGES"
    assert_contains "$out" "expected HH:MM"
    assert_contains "$out" "FIREWALL_SSH_FROM"'

check "bootstrap rejects the example repository URL" '
    . "$HELPERS"; load_builder
    out=$(invalid BOOTSTRAP_ENABLED=true)
    assert_contains "$out" "still points to the example repository"'

check "values with special characters survive write_env" '
    . "$HELPERS"; load_builder
    # p@ss "w$rd'\''x!{<%]  (\047 is a single quote)
    ADMIN_PASSWORD=$(printf "%s\047%s" "p@ss \"w\$rd" "x!{<%]")
    assert_eq "${#ADMIN_PASSWORD}" "17"
    write_env "$PWD/out.env" ADMIN_PASSWORD
    expected=$ADMIN_PASSWORD; unset ADMIN_PASSWORD
    . "$PWD/out.env"
    assert_eq "$ADMIN_PASSWORD" "$expected"'

check "build-only settings are not copied to the system" '
    . "$HELPERS"; load_builder
    keys=" $(runtime_keys | tr "\n" " ") "
    assert_not_contains "$keys" " ADMIN_PASSWORD "
    assert_not_contains "$keys" " WIFI_PASSWORD "
    assert_not_contains "$keys" " TARGET_DEVICE "
    assert_contains "$keys" " SEMAPHORE_ADMIN_PASSWORD "'

echo "Staging and bundles"

check "referenced files are staged without Windows line endings" '
    . "$HELPERS"; load_builder
    new_config HOOKS_DIR=./hooks
    printf "ssh-ed25519 AAAA x\r\n" >"$CONFIG_DIR/secrets/authorized_keys"
    mkdir "$CONFIG_DIR/hooks"; printf "echo hi\r\n" >"$CONFIG_DIR/hooks/10-a.sh"; echo x >"$CONFIG_DIR/hooks/notes.txt"
    printf "TIMEZONE=UTC\r\n" >>"$CONFIG_DIR/config.env"
    stage_config 2>/dev/null
    ! grep -q $'\''\r'\'' "$FILES/authorized_keys" "$STAGE/config.env" "$STAGE/hooks/10-a.sh"
    [[ -f $STAGE/hooks/10-a.sh && ! -e $STAGE/hooks/notes.txt ]]'

check "paths outside the config directory are rejected" '
    . "$HELPERS"; load_builder
    out=$(new_config ADMIN_AUTHORIZED_KEYS_FILE=../../etc/passwd; (stage_config) 2>&1) && exit 1
    assert_contains "$out" "must point inside the directory"
    out=$(new_config ADMIN_AUTHORIZED_KEYS_FILE=/etc/passwd; (stage_config) 2>&1) && exit 1
    assert_contains "$out" "must be a path relative"'

check "a config bundle round-trips" '
    . "$HELPERS"; load_builder
    new_config HOOKS_DIR=./hooks "ADMIN_PASSWORD='\''a \"b\" \$c'\''"
    mkdir "$CONFIG_DIR/hooks"; echo "echo hi" >"$CONFIG_DIR/hooks/10-a.sh"
    OUT=$PWD/out; mkdir -p "$OUT"
    stage_config 2>/dev/null; validate_config "$STAGE"; write_bundle 2>/dev/null
    mkdir unpacked; base64 -d <"$OUT/config.bundle.b64" | tar -xz -C unpacked
    CONFIG_DIR=$PWD/unpacked; STAGE=$PWD/stage2/stage; FILES=$STAGE/files
    unset ADMIN_PASSWORD
    stage_config 2>/dev/null; validate_config "$STAGE"
    assert_eq "$ADMIN_PASSWORD" "a \"b\" \$c"
    [[ -f $STAGE/hooks/10-a.sh && -f $FILES/authorized_keys ]]'

echo "Setup on the Pi"

check "proxy config: HTTP mode forwards to Semaphore" '
    . "$HELPERS"; load_target
    NGINX_CONF_DIR=$PWD; SEMAPHORE_FQDN=""; PROXY_HTTPS_PORT=443; TLS_MODE=none
    write_proxy_conf http
    conf=$(cat semaphore.conf)
    assert_contains "$conf" "server_name _;"
    assert_contains "$conf" "proxy_pass \$semaphore;"
    assert_not_contains "$conf" "listen 443"'

check "proxy config: TLS mode redirects and uses the right certificate" '
    . "$HELPERS"; load_target
    NGINX_CONF_DIR=$PWD; SEMAPHORE_FQDN=s.example.org; PROXY_HTTPS_PORT=8443; TLS_MODE=letsencrypt-dns
    write_proxy_conf tls
    conf=$(cat semaphore.conf)
    assert_contains "$conf" "return 301 https://\$host:8443\$request_uri;"
    assert_contains "$conf" "ssl_certificate /etc/letsencrypt/live/s.example.org/fullchain.pem;"
    assert_contains "$conf" "location /.well-known/acme-challenge/"
    TLS_MODE=selfsigned; write_proxy_conf tls
    assert_contains "$(cat semaphore.conf)" "ssl_certificate /etc/nginx/certs/semaphore.crt;"'

check "container arguments follow the settings" '
    . "$HELPERS"; load_target
    install() { :; }
    DOCKER_NETWORK=net PROXY_ENABLED=true SEMAPHORE_PORT=3001 PROXY_HTTP_PORT=8080 PROXY_HTTPS_PORT=8443
    TLS_MODE=none; container_args nginx
    assert_contains "${CONTAINER_ARGS[*]}" "-p 8080:80"
    assert_not_contains "${CONTAINER_ARGS[*]}" ":443"
    TLS_MODE=selfsigned; container_args nginx
    assert_contains "${CONTAINER_ARGS[*]}" "-p 8443:443"
    container_args semaphore
    assert_contains "${CONTAINER_ARGS[*]}" "-p 127.0.0.1:3001:3000"
    PROXY_ENABLED=false; container_args semaphore
    assert_contains "${CONTAINER_ARGS[*]}" "-p 3001:3000"'

check "Semaphore secrets keep quotes, backslashes and = in values" '
    command -v jq >/dev/null || { echo "jq missing"; exit $SKIP; }
    . "$HELPERS"; load_target
    SEMAPHORE_TOKEN="tok"
    printf "A=x=y\n# comment\n\nB=say \"hi\" \\\\ there\nLAST=no newline" >secrets.env
    BOOTSTRAP_SECRETS_FILE=$PWD/secrets.env
    json=$(secrets_json)
    assert_eq "$(jq -r ".[0].name" <<<"$json")" "SEMAPHORE_TOKEN"
    assert_eq "$(jq -r ".[1].secret" <<<"$json")" "x=y"
    assert_eq "$(jq -r ".[2].secret" <<<"$json")" "say \"hi\" \\ there"
    assert_eq "$(jq -r ".[3].name" <<<"$json")" "LAST"
    assert_eq "$(jq length <<<"$json")" "4"'

check "mittwald: the longest matching domain wins" '
    command -v jq >/dev/null || { echo "jq missing"; exit $SKIP; }
    . "$HELPERS"; load_target
    . "$REPO/image/target/usr/local/lib/homelab-seed/dns/mittwald.sh"
    domains='\''[{"domain":"example.org","projectId":"p1"},{"domain":"lab.example.org","projectId":"p2"},{"domain":"other.org","projectId":"p3"}]'\''
    assert_eq "$(mittwald_project_for semaphore.lab.example.org "$domains")" "p2"
    assert_eq "$(mittwald_project_for semaphore.example.org "$domains")" "p1"
    assert_eq "$(mittwald_project_for example.org "$domains")" "p1"
    assert_eq "$(mittwald_project_for notexample.org "$domains")" ""'

check "hooks run once each, with the settings in the environment" '
    . "$HELPERS"; load_target
    eval "$(sed -n "/^run_step()/,/^}/p" "$REPO/image/target/usr/local/sbin/homelab-seed-setup")"
    STEP_DIR=$PWD/steps; mkdir -p "$STEP_DIR" "$SEED_ETC/hooks"
    HOOKS_INSTALL_DIR=$SEED_ETC/hooks
    printf "TARGET_HOSTNAME=seed\n" >"$SEED_ETC/config.env"
    echo "echo run >>\"$PWD/runs\"; echo \"\$TARGET_HOSTNAME\" >>\"$PWD/runs\"" >"$SEED_ETC/hooks/10-a b.sh"
    run_hook() { ( set -a; . "$SEED_ETC/config.env"; set +a; exec bash "$1" ); }
    run_hooks 2>/dev/null; run_hooks 2>/dev/null
    assert_eq "$(cat runs)" "run"$'\''\n'\''"seed"'

echo "Workflows"

check "build-image workflow assembles a config from individual secrets" '
    . "$HELPERS"; load_builder
    awk "/name: Restore configuration/{f=1} f&&/run: \\|/{r=1;next} r&&/^      - name:/{exit} r{print}" \
        "$REPO/.github/workflows/build-image.yml" | sed "s/^          //" >restore.sh
    mkdir -p repo/hooks runner; echo "echo hi" >repo/hooks/10-x.sh
    (cd repo && RUNNER_TEMP=$PWD/../runner SEED_CONFIG_BUNDLE="" \
        SEED_CONFIG=$'\''ADMIN_PASSWORD=x\nSEMAPHORE_ADMIN_PASSWORD=y\nADMIN_AUTHORIZED_KEYS_FILE=./secrets/authorized_keys'\'' \
        SEED_AUTHORIZED_KEYS="ssh-ed25519 AAAA k" SEED_SSH_PRIVATE_KEY="" SEED_SECRETS_ENV="A=1" \
        bash -e ../restore.sh >/dev/null)
    CONFIG_DIR=$PWD/runner/seed-config; STAGE=$PWD/st/stage; FILES=$STAGE/files
    stage_config 2>/dev/null; validate_config "$STAGE"
    assert_eq "$ADMIN_AUTHORIZED_KEYS_FILE" "./authorized_keys"
    assert_eq "$BOOTSTRAP_SECRETS_FILE" "./secrets.env"
    [[ -f $STAGE/hooks/10-x.sh ]]'

finish
