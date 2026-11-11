# shellcheck shell=bash
# Container definitions, shared by the setup and homelab-seed-update.
#
# Persistent settings live in /etc/homelab-seed/runtime.env, Semaphore's
# environment (incl. secrets) in /etc/homelab-seed/semaphore.env.

RUNTIME_ENV=$SEED_ETC/runtime.env
SEMAPHORE_ENV=$SEED_ETC/semaphore.env
NGINX_CONF_DIR=/etc/nginx/conf.d
NGINX_CERT_DIR=/etc/nginx/certs
ACME_WEBROOT=/var/www/certbot

load_runtime_env() {
    # shellcheck source=/dev/null
    [[ ! -f $RUNTIME_ENV ]] || . "$RUNTIME_ENV"
}

# set_runtime_value <key> <value>
set_runtime_value() {
    local tmp
    tmp=$(mktemp "$RUNTIME_ENV.XXXXXX")
    grep -v "^$1=" "$RUNTIME_ENV" >"$tmp" || true
    printf '%s=%q\n' "$1" "$2" >>"$tmp"
    chmod 644 "$tmp"
    mv "$tmp" "$RUNTIME_ENV"
    printf -v "$1" '%s' "$2"
}

# container_* <service>: name, image and `docker run` arguments of a service.
container_name() {
    case $1 in
        semaphore) echo semaphore ;;
        nginx) echo nginx-proxy ;;
        *) die "Unknown service '$1'" ;;
    esac
}

container_image() {
    case $1 in
        semaphore) echo semaphoreui/semaphore ;;
        nginx) echo nginx ;;
        *) die "Unknown service '$1'" ;;
    esac
}

container_version_key() {
    case $1 in
        semaphore) echo SEMAPHORE_VERSION ;;
        nginx) echo NGINX_VERSION ;;
        *) die "Unknown service '$1'" ;;
    esac
}

# Sets CONTAINER_ARGS for the given service.
container_args() {
    CONTAINER_ARGS=(--network "$DOCKER_NETWORK" --restart unless-stopped)
    case $1 in
        semaphore)
            CONTAINER_ARGS+=(
                --env-file "$SEMAPHORE_ENV"
                -v semaphore_data:/var/lib/semaphore
                -v semaphore_config:/etc/semaphore
                -v semaphore_tmp:/tmp/semaphore
            )
            # Behind the proxy Semaphore is only reachable locally.
            if is_true "$PROXY_ENABLED"; then
                CONTAINER_ARGS+=(-p "127.0.0.1:$SEMAPHORE_PORT:3000")
            else
                CONTAINER_ARGS+=(-p "$SEMAPHORE_PORT:3000")
            fi
            ;;
        nginx)
            install -d -m 755 "$NGINX_CONF_DIR" "$NGINX_CERT_DIR" "$ACME_WEBROOT" /etc/letsencrypt
            CONTAINER_ARGS+=(
                -p "$PROXY_HTTP_PORT:80"
                -v "$NGINX_CONF_DIR:/etc/nginx/conf.d"
                -v "$NGINX_CERT_DIR:/etc/nginx/certs:ro"
                -v "$ACME_WEBROOT:/var/www/certbot:ro"
                -v /etc/letsencrypt:/etc/letsencrypt:ro
            )
            [[ $TLS_MODE == none ]] || CONTAINER_ARGS+=(-p "$PROXY_HTTPS_PORT:443")
            ;;
        *) die "Unknown service '$1'" ;;
    esac
}

ensure_network() {
    docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1 ||
        docker network create "$DOCKER_NETWORK" >/dev/null
}

container_running() {
    [[ $(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null) == true ]]
}

# start_container <name> <image>
start_container() {
    docker rm -f "$1" >/dev/null 2>&1 || true
    docker run -d --name "$1" "${CONTAINER_ARGS[@]}" "$2" >/dev/null || return 1
    # Catch containers that crash right after the start.
    sleep 10
    container_running "$1"
}

# deploy_container <service> <version>: pulls the image first, replaces the
# running container and rolls back to the previous image if the new one fails.
deploy_container() {
    local service=$1 version=$2 name image previous
    name=$(container_name "$service")
    image=$(container_image "$service"):$version
    container_args "$service"
    ensure_network

    log "Pulling $image"
    retry 3 20 docker pull --quiet "$image" >/dev/null || die "Cannot pull $image"
    previous=$(docker inspect -f '{{.Config.Image}}' "$name" 2>/dev/null || true)

    log "Starting $name ($image)"
    if ! start_container "$name" "$image"; then
        docker logs --tail 30 "$name" >&2 || true
        if [[ -n $previous && $previous != "$image" ]]; then
            warn "$image failed to start – rolling back to $previous"
            start_container "$name" "$previous" || warn "Rollback failed as well"
        fi
        die "$name did not start with $image"
    fi
    set_runtime_value "$(container_version_key "$service")" "$version"
}
