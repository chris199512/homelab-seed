# shellcheck shell=bash
# Setup steps: persistent runtime settings and the Semaphore container.

semaphore_ready() {
    curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:$SEMAPHORE_PORT/api/ping"
}

wait_for_semaphore() {
    log "Waiting for Semaphore..."
    wait_until 300 5 semaphore_ready || die "Semaphore did not become ready"
}

step_runtime_config() {
    local key
    install -d -m 700 "$SEED_ETC"
    for key in DOCKER_NETWORK PROXY_ENABLED TLS_MODE SEMAPHORE_PORT PROXY_HTTP_PORT PROXY_HTTPS_PORT \
        SEMAPHORE_FQDN SEMAPHORE_VERSION NGINX_VERSION; do
        printf '%s=%q\n' "$key" "${!key}"
    done >"$RUNTIME_ENV"
    chmod 644 "$RUNTIME_ENV"

    is_true "$SEMAPHORE_ENABLED" || return 0
    # docker --env-file takes every value literally – no quoting.
    (
        umask 077
        {
            echo "SEMAPHORE_DB_DIALECT=bolt"
            echo "SEMAPHORE_ADMIN=$SEMAPHORE_ADMIN_USER"
            echo "SEMAPHORE_ADMIN_PASSWORD=$SEMAPHORE_ADMIN_PASSWORD"
            echo "SEMAPHORE_ADMIN_NAME=$SEMAPHORE_ADMIN_NAME"
            echo "SEMAPHORE_ADMIN_EMAIL=$SEMAPHORE_ADMIN_EMAIL"
            [[ -z $SEMAPHORE_WEB_HOST ]] || echo "SEMAPHORE_WEB_HOST=$SEMAPHORE_WEB_HOST"
            if is_true "$SEMAPHORE_TOTP_ENABLED"; then
                echo "SEMAPHORE_TOTP_ENABLED=True"
                echo "SEMAPHORE_TOTP_ALLOW_RECOVERY=True"
            fi
            if [[ -n $SMTP_HOST ]]; then
                echo "SEMAPHORE_EMAIL_ALERT=True"
                echo "SEMAPHORE_EMAIL_HOST=$SMTP_HOST"
                echo "SEMAPHORE_EMAIL_PORT=$SMTP_PORT"
                echo "SEMAPHORE_EMAIL_SENDER=$SMTP_SENDER"
                echo "SEMAPHORE_EMAIL_USERNAME=$SMTP_USER"
                echo "SEMAPHORE_EMAIL_PASSWORD=$SMTP_PASSWORD"
                if is_true "$SMTP_SECURE"; then echo "SEMAPHORE_EMAIL_SECURE=True"; fi
            fi
        } >"$SEMAPHORE_ENV"
    )
}

step_semaphore() {
    deploy_container semaphore "$SEMAPHORE_VERSION"
    wait_for_semaphore
}
