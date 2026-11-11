#!/bin/bash
# Runs inside the Raspberry Pi OS image (chroot) and applies the base system
# configuration. Usage: customize.sh <installer|target>
set -Eeuo pipefail

role=$1
# shellcheck source=/dev/null
. /tmp/homelab-seed-build.env

log() { printf '  [%s] %s\n' "$role" "$*" >&2; }

set_hostname() {
    local name=$TARGET_HOSTNAME
    [[ $role == target ]] || name=$TARGET_HOSTNAME-installer
    log "Hostname: $name"
    echo "$name" >/etc/hostname
    if grep -q '^127\.0\.1\.1' /etc/hosts; then
        sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$name/" /etc/hosts
    else
        printf '127.0.1.1\t%s\n' "$name" >>/etc/hosts
    fi
}

set_locale() {
    local pattern=${LOCALE//./\\.}
    log "Locale: $LOCALE, keyboard: $KEYBOARD_LAYOUT, timezone: $TIMEZONE"
    if grep -qE "^# *$pattern " /etc/locale.gen; then
        sed -i -E "s/^# *($pattern )/\1/" /etc/locale.gen
    elif ! grep -qE "^$pattern " /etc/locale.gen; then
        echo "$LOCALE ${LOCALE#*.}" >>/etc/locale.gen
    fi
    locale-gen >/dev/null
    update-locale LANG="$LOCALE"

    if [[ -f /etc/default/keyboard ]]; then
        sed -i "s/^XKBLAYOUT=.*/XKBLAYOUT=\"$KEYBOARD_LAYOUT\"/" /etc/default/keyboard
    else
        echo "XKBLAYOUT=\"$KEYBOARD_LAYOUT\"" >/etc/default/keyboard
    fi

    [[ -f /usr/share/zoneinfo/$TIMEZONE ]] || { echo "Unknown TIMEZONE '$TIMEZONE'" >&2; exit 1; }
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    echo "$TIMEZONE" >/etc/timezone
}

# Replaces the image's default first user (and its interactive rename wizard)
# with the configured admin account.
create_admin() {
    local first_user group groups=() home
    first_user=$(getent passwd 1000 | cut -d: -f1 || true)
    if [[ -n $first_user && $first_user != "$ADMIN_USER" ]]; then
        log "Removing default user $first_user"
        userdel -r "$first_user" >/dev/null 2>&1 || true
        if id "$first_user" >/dev/null 2>&1; then
            echo "Could not remove user $first_user" >&2
            exit 1
        fi
    fi
    if ! id "$ADMIN_USER" >/dev/null 2>&1; then
        log "Creating user $ADMIN_USER"
        useradd -m -s /bin/bash "$ADMIN_USER"
    fi
    for group in sudo adm dialout cdrom audio video plugdev users input render netdev gpio i2c spi; do
        if getent group "$group" >/dev/null; then groups+=("$group"); fi
    done
    usermod -aG "$(IFS=,; echo "${groups[*]}")" "$ADMIN_USER"
    printf '%s:%s\n' "$ADMIN_USER" "$ADMIN_PASSWORD" | chpasswd

    home=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
    install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$home/.ssh"
    install -m 600 -o "$ADMIN_USER" -g "$ADMIN_USER" /tmp/homelab-seed-authorized_keys "$home/.ssh/authorized_keys"

    # Raspberry Pi OS first-boot user wizard
    systemctl mask userconfig.service >/dev/null 2>&1 || true
    systemctl enable getty@tty1.service >/dev/null 2>&1 || true
    rm -f /etc/ssh/sshd_config.d/rename_user.conf
    # cloud-init would apply its own user/hostname defaults on first boot.
    [[ ! -d /etc/cloud ]] || touch /etc/cloud/cloud-init.disabled
}

# NetworkManager connection profile for the configured interface.
configure_network() {
    local dir=/etc/NetworkManager/system-connections file ipv4 dns="" server
    [[ -d /etc/NetworkManager ]] || { echo "NetworkManager not found – unsupported Raspberry Pi OS release" >&2; exit 1; }
    mkdir -p "$dir"
    log "Network: $NETWORK_INTERFACE, IPv4 $NETWORK_IPV4${NETWORK_ADDRESS:+ ($NETWORK_ADDRESS)}"

    for server in $NETWORK_DNS; do dns+="$server;"; done
    if [[ $NETWORK_IPV4 == static ]]; then
        ipv4="method=manual"$'\n'"address1=$NETWORK_ADDRESS,$NETWORK_GATEWAY"
    else
        ipv4="method=auto"
        [[ -z $dns ]] || ipv4+=$'\n'"ignore-auto-dns=true"
    fi
    [[ -z $dns ]] || ipv4+=$'\n'"dns=$dns"

    if [[ $NETWORK_INTERFACE == wifi ]]; then
        file=$dir/homelab-seed-wifi.nmconnection
        {
            printf '[connection]\nid=homelab-seed-wifi\ntype=wifi\ninterface-name=wlan0\nautoconnect=true\nautoconnect-priority=100\n\n'
            printf '[wifi]\nmode=infrastructure\nssid=%s\n\n' "$WIFI_SSID"
            [[ -z $WIFI_PASSWORD ]] || printf '[wifi-security]\nkey-mgmt=wpa-psk\npsk=%s\n\n' "$WIFI_PASSWORD"
            printf '[ipv4]\n%s\n\n[ipv6]\nmethod=auto\n' "$ipv4"
        } >"$file"
        set_wifi_country
    else
        file=$dir/homelab-seed-ethernet.nmconnection
        {
            printf '[connection]\nid=homelab-seed-ethernet\ntype=ethernet\ninterface-name=eth0\nautoconnect=true\nautoconnect-priority=100\n\n'
            printf '[ethernet]\n\n[ipv4]\n%s\n\n[ipv6]\nmethod=auto\n' "$ipv4"
        } >"$file"
    fi
    chmod 600 "$file"
}

# Raspberry Pi OS keeps Wi-Fi blocked until a regulatory country is set.
set_wifi_country() {
    local cmdline=/boot/firmware/cmdline.txt state
    [[ -f $cmdline ]] || cmdline=/boot/cmdline.txt
    sed -i -E 's/ ?cfg80211\.ieee80211_regdom=[A-Z]{2}//; s/$/ cfg80211.ieee80211_regdom='"$WIFI_COUNTRY"'/' "$cmdline"
    for state in /var/lib/systemd/rfkill/*:wlan; do
        [[ -e $state ]] && echo 0 >"$state"
    done
    return 0
}

configure_ntp() {
    [[ -n $NTP_SERVERS ]] || return 0
    log "NTP: $NTP_SERVERS"
    mkdir -p /etc/systemd/timesyncd.conf.d
    printf '[Time]\nNTP=%s\n' "$NTP_SERVERS" >/etc/systemd/timesyncd.conf.d/10-homelab-seed.conf
}

configure_ssh() {
    log "SSH: key authentication only"
    mkdir -p /etc/ssh/sshd_config.d
    cat >/etc/ssh/sshd_config.d/10-homelab-seed.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
    systemctl enable ssh.service >/dev/null
}

enable_role_service() {
    case $role in
        installer) systemctl enable homelab-seed-installer.service ;;
        target) systemctl enable homelab-seed-setup.service ;;
        *) echo "Unknown role '$role'" >&2; exit 1 ;;
    esac
}

set_hostname
set_locale
create_admin
configure_network
configure_ntp
configure_ssh
enable_role_service
