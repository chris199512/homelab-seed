# shellcheck shell=bash
# Setup step: nginx reverse proxy in front of Semaphore.
#
# The proxy starts with plain HTTP. Once a certificate exists (45-certificate.sh)
# the configuration is switched to HTTPS with write_proxy_conf tls.

# Server block contents that forward to Semaphore. Resolving the container at
# request time lets nginx start even while Semaphore is down.
proxy_locations() {
    cat <<'EOF'
    resolver 127.0.0.11 valid=10s;
    set $semaphore http://semaphore:3000;

    location / {
        proxy_pass $semaphore;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_buffering off;
        proxy_request_buffering off;
    }

    location /api/ws {
        proxy_pass $semaphore;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Origin "";
    }
EOF
}

# Paths inside the nginx container.
tls_cert_paths() {
    if [[ $TLS_MODE == selfsigned ]]; then
        TLS_CERT=/etc/nginx/certs/semaphore.crt
        TLS_KEY=/etc/nginx/certs/semaphore.key
    else
        TLS_CERT=/etc/letsencrypt/live/$SEMAPHORE_FQDN/fullchain.pem
        TLS_KEY=/etc/letsencrypt/live/$SEMAPHORE_FQDN/privkey.pem
    fi
}

# write_proxy_conf <http|tls>
write_proxy_conf() {
    local server_name=${SEMAPHORE_FQDN:-_} https_port=""
    [[ $PROXY_HTTPS_PORT == 443 ]] || https_port=":$PROXY_HTTPS_PORT"
    {
        echo "# Managed by homelab-seed"
        echo "server {"
        echo "    listen 80;"
        echo "    server_name $server_name;"
        echo
        echo "    location /.well-known/acme-challenge/ {"
        echo "        root /var/www/certbot;"
        echo "    }"
        if [[ $1 == tls ]]; then
            echo
            echo "    location / {"
            # shellcheck disable=SC2016 # nginx variables
            echo '        return 301 https://$host'"$https_port"'$request_uri;'
            echo "    }"
        else
            echo
            proxy_locations
        fi
        echo "}"
        if [[ $1 == tls ]]; then
            tls_cert_paths
            echo
            echo "server {"
            echo "    listen 443 ssl;"
            echo "    server_name $server_name;"
            echo
            echo "    ssl_certificate $TLS_CERT;"
            echo "    ssl_certificate_key $TLS_KEY;"
            echo
            proxy_locations
            echo "}"
        fi
    } >"$NGINX_CONF_DIR/semaphore.conf"
}

reload_proxy() {
    docker exec nginx-proxy nginx -t >&2 || die "Invalid nginx configuration"
    docker exec nginx-proxy nginx -s reload
}

step_proxy() {
    install -d -m 755 "$NGINX_CONF_DIR" "$NGINX_CERT_DIR" "$ACME_WEBROOT"
    write_proxy_conf http
    deploy_container nginx "$NGINX_VERSION"
}
