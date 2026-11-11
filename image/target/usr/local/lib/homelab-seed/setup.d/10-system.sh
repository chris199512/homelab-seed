# shellcheck shell=bash
# Setup steps: packages, automatic updates and firewall.

apt_get() {
    DEBIAN_FRONTEND=noninteractive apt-get -y \
        -o DPkg::Lock::Timeout=600 \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        "$@"
}

step_system() {
    local packages=(ca-certificates curl jq)
    retry 5 30 apt_get update
    if is_true "$SETUP_SYSTEM_UPGRADE"; then
        retry 3 30 apt_get full-upgrade
    fi
    # shellcheck disable=SC2206 # space-separated list
    [[ -z $EXTRA_PACKAGES ]] || packages+=($EXTRA_PACKAGES)
    retry 3 30 apt_get install --no-install-recommends "${packages[@]}"
    apt_get autoremove --purge
    apt_get clean
}

step_unattended_upgrades() {
    local reboot=false
    if is_true "$UNATTENDED_UPGRADES_REBOOT"; then reboot=true; fi
    retry 3 30 apt_get install --no-install-recommends unattended-upgrades
    cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    cat >/etc/apt/apt.conf.d/52homelab-seed <<EOF
// Managed by homelab-seed
Unattended-Upgrade::Automatic-Reboot "$reboot";
Unattended-Upgrade::Automatic-Reboot-Time "$UNATTENDED_UPGRADES_REBOOT_TIME";
EOF
    systemctl enable --now unattended-upgrades.service
}

# Ports of the services this setup runs.
service_ports() {
    if is_true "$PROXY_ENABLED"; then
        echo "$PROXY_HTTP_PORT/tcp"
        [[ $TLS_MODE == none ]] || echo "$PROXY_HTTPS_PORT/tcp"
    elif is_true "$SEMAPHORE_ENABLED"; then
        echo "$SEMAPHORE_PORT/tcp"
    fi
}

step_firewall() {
    local source rule
    retry 3 30 apt_get install --no-install-recommends ufw
    ufw --force reset >/dev/null
    ufw default deny incoming
    ufw default allow outgoing
    if [[ $FIREWALL_SSH_FROM == any ]]; then
        ufw allow 22/tcp comment ssh
    else
        for source in $FIREWALL_SSH_FROM; do
            ufw allow from "$source" to any port 22 proto tcp comment ssh
        done
    fi
    # shellcheck disable=SC2046 # space-separated lists
    for rule in $(service_ports) $FIREWALL_ALLOW; do
        ufw allow "$rule"
    done
    ufw --force enable
    ufw status verbose >&2
}
