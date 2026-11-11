# shellcheck shell=bash
# Setup step: Docker Engine.

docker_ready() { docker info >/dev/null 2>&1; }

step_docker() {
    if ! command -v docker >/dev/null; then
        log "Installing Docker"
        retry 3 30 curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh
        rm -f /tmp/get-docker.sh
    fi
    systemctl enable --now docker.service
    wait_until 120 2 docker_ready || die "Docker did not start"
    docker --version >&2
}
