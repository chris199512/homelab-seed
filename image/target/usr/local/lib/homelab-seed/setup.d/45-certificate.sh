# shellcheck shell=bash
# Setup step: TLS certificate for the proxy (TLS_MODE) and switch to HTTPS.
# Let's Encrypt certificates are renewed by certbot's systemd timer.

selfsigned_certificate() {
    local cn=${SEMAPHORE_FQDN:-$TARGET_HOSTNAME} san
    san="DNS:$cn,DNS:$TARGET_HOSTNAME,DNS:$TARGET_HOSTNAME.local"
    [[ $NETWORK_IPV4 != static ]] || san+=",IP:${NETWORK_ADDRESS%/*}"
    if [[ -f $NGINX_CERT_DIR/semaphore.crt ]]; then
        log "Self-signed certificate already exists"
        return
    fi
    log "Creating a self-signed certificate for $cn"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -days 3650 -subj "/CN=$cn" -addext "subjectAltName=$san" \
        -keyout "$NGINX_CERT_DIR/semaphore.key" -out "$NGINX_CERT_DIR/semaphore.crt" 2>/dev/null
    chmod 600 "$NGINX_CERT_DIR/semaphore.key"
}

# Arguments for `certbot certonly` depending on the challenge.
certbot_challenge_args() {
    local hook=$SEED_LIB/certbot-dns-hook
    if [[ $TLS_MODE == letsencrypt-http ]]; then
        CERTBOT_ARGS=(--webroot -w "$ACME_WEBROOT")
        return
    fi
    local provider=$ACME_DNS_PROVIDER package credentials=$SEED_ETC/dns-credentials.ini

    # Built-in provider without a certbot plugin: manual hooks.
    if [[ $provider == mittwald ]]; then
        (
            umask 077
            {
                printf 'ACME_DNS_PROVIDER=%q\n' "$provider"
                printf 'ACME_DNS_PROPAGATION_SECONDS=%q\n' "$ACME_DNS_PROPAGATION_SECONDS"
                printf 'MITTWALD_API_TOKEN=%q\n' "$ACME_DNS_API_TOKEN"
            } >"$SEED_ETC/dns.env"
        )
        CERTBOT_ARGS=(--manual --preferred-challenges dns
            --manual-auth-hook "$hook auth" --manual-cleanup-hook "$hook cleanup")
        return
    fi

    # Any certbot DNS plugin: python3-certbot-dns-<provider> with a credentials
    # file (generated at build time for token-only providers). The file stays,
    # certbot needs it for the renewals.
    package=python3-certbot-dns-$provider
    apt-cache show "$package" >/dev/null 2>&1 ||
        die "There is no certbot DNS plugin '$provider' (package $package) – check ACME_DNS_PROVIDER"
    retry 3 30 apt_get install --no-install-recommends "$package"
    install -m 600 "$ACME_DNS_CREDENTIALS_FILE" "$credentials"
    CERTBOT_ARGS=(--authenticator "dns-$provider"
        "--dns-$provider-credentials" "$credentials"
        "--dns-$provider-propagation-seconds" "$ACME_DNS_PROPAGATION_SECONDS")
}

letsencrypt_certificate() {
    local deploy_hook=/etc/letsencrypt/renewal-hooks/deploy/homelab-seed-reload-nginx

    retry 3 30 apt_get install --no-install-recommends certbot
    install -d -m 755 "$(dirname "$deploy_hook")"
    cat >"$deploy_hook" <<'EOF'
#!/bin/sh
# Managed by homelab-seed: load renewed certificates.
docker exec nginx-proxy nginx -s reload 2>/dev/null || true
EOF
    chmod 755 "$deploy_hook"

    if [[ -f /etc/letsencrypt/live/$SEMAPHORE_FQDN/fullchain.pem ]]; then
        log "Certificate for $SEMAPHORE_FQDN already exists"
    else
        certbot_challenge_args
        if is_true "$ACME_STAGING"; then CERTBOT_ARGS+=(--test-cert); fi
        log "Requesting a Let's Encrypt certificate for $SEMAPHORE_FQDN ($TLS_MODE)"
        certbot certonly --non-interactive --agree-tos --email "$ACME_EMAIL" \
            --cert-name "$SEMAPHORE_FQDN" -d "$SEMAPHORE_FQDN" "${CERTBOT_ARGS[@]}"
    fi
    systemctl enable --now certbot.timer
}

step_certificate() {
    case $TLS_MODE in
        selfsigned) selfsigned_certificate ;;
        letsencrypt-http | letsencrypt-dns) letsencrypt_certificate ;;
        *) die "Unsupported TLS_MODE '$TLS_MODE'" ;;
    esac
    log "Switching the proxy to HTTPS"
    write_proxy_conf tls
    reload_proxy
}
