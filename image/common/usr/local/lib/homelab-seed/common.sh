# shellcheck shell=bash
# Shared helpers for the homelab-seed scripts on the Raspberry Pi.

# shellcheck disable=SC2034 # used by the scripts sourcing this file
SEED_ETC=/etc/homelab-seed
# shellcheck disable=SC2034
SEED_LIB=/usr/local/lib/homelab-seed
# shellcheck disable=SC2034
SEED_STATE=/var/lib/homelab-seed

log()    { printf '[homelab-seed] %s\n' "$*" >&2; }
warn()   { printf '[homelab-seed] WARNING: %s\n' "$*" >&2; }
die()    { printf '[homelab-seed] ERROR: %s\n' "$*" >&2; exit 1; }
banner() { printf '\n========== %s ==========\n' "$*" >&2; }

is_true() { [[ ${1,,} =~ ^(true|yes|on|1)$ ]]; }

# wait_until <timeout-seconds> <interval-seconds> <command...>
wait_until() {
    local timeout=$1 interval=$2 start=$SECONDS
    shift 2
    until "$@"; do
        ((SECONDS - start < timeout)) || return 1
        sleep "$interval"
    done
}

# retry <attempts> <delay-seconds> <command...>
retry() {
    local attempts=$1 delay=$2 n=1
    shift 2
    until "$@"; do
        ((n < attempts)) || return 1
        warn "Attempt $n/$attempts failed: $*; retrying in ${delay}s"
        sleep "$delay"
        n=$((n + 1))
    done
}

# part_dev <disk> <n>: /dev/mmcblk0 2 -> /dev/mmcblk0p2, /dev/sda 2 -> /dev/sda2
part_dev() {
    if [[ $1 =~ [0-9]$ ]]; then echo "${1}p$2"; else echo "$1$2"; fi
}
