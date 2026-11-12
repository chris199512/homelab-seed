#!/bin/bash
# Builds the homelab-seed installer image. Runs as root inside the builder
# container started by build.sh / build.ps1:
#   /src     repository (read-only)
#   /config  directory of the config file (read-only), file name in SEED_CONFIG_NAME
#   /cache   downloaded base images (Docker volume)
#   /work    scratch space (Docker volume)
#   /out     finished image
set -Eeuo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONFIG_DIR=/config
CACHE=/cache
WORK=/work
OUT=/out
MNT=$WORK/mnt
STAGE=$WORK/stage
FILES=$STAGE/files

# shellcheck source=builder/lib.sh
. "$SRC/builder/lib.sh"
# shellcheck source=builder/config.sh
. "$SRC/builder/config.sh"

on_exit() {
    release_all
    rm -rf "$STAGE"
}

# Marks an unpacked config bundle (see write_bundle): it is already staged.
BUNDLE_MARKER=.homelab-seed-bundle

# Copies config.env and every file it references into $STAGE, stripping
# Windows line endings. Referenced paths are relative to the config directory.
stage_config() {
    local config=$CONFIG_DIR/${SEED_CONFIG_NAME:-config.env} hooks hook target
    [[ -f $config ]] || die "Config file ${SEED_CONFIG_NAME:-config.env} not found"
    rm -rf "$STAGE"
    install -d -m 700 "$STAGE" "$FILES"

    if [[ -f $CONFIG_DIR/$BUNDLE_MARKER ]]; then
        log "Using a config bundle"
        cp -a "$CONFIG_DIR/." "$STAGE/"
        load_config "$STAGE/config.env"
        return
    fi

    tr -d '\r' <"$config" >"$STAGE/config.env"

    load_config "$STAGE/config.env"
    stage_file ADMIN_AUTHORIZED_KEYS_FILE authorized_keys
    stage_file BOOTSTRAP_SSH_PRIVATE_KEY_FILE ssh_key
    stage_file BOOTSTRAP_SECRETS_FILE secrets.env

    if [[ -n $HOOKS_DIR ]]; then
        hooks=$(config_path HOOKS_DIR "$HOOKS_DIR") || exit 1
        [[ -d $hooks ]] || die "HOOKS_DIR: directory $HOOKS_DIR not found next to the config"
        install -d -m 700 "$STAGE/hooks"
        for hook in "$hooks"/*.sh; do
            [[ -f $hook ]] || continue
            target=$STAGE/hooks/${hook##*/}
            tr -d '\r' <"$hook" >"$target"
        done
    fi
}

# config_path <key> <value>: resolves a path setting inside the config directory.
config_path() {
    local resolved
    [[ $2 != /* && $2 != [A-Za-z]:* ]] ||
        die "$1 must be a path relative to the config file (got '$2')"
    resolved=$(realpath -m "$CONFIG_DIR/$2")
    [[ $resolved == "$CONFIG_DIR"/* ]] ||
        die "$1 must point inside the directory of the config file (got '$2')"
    echo "$resolved"
}

# stage_file <key> <name>
stage_file() {
    local value=${!1} path
    [[ -n $value ]] || return 0
    path=$(config_path "$1" "$value") || exit 1
    [[ -f $path ]] || die "$1: file $value not found next to the config"
    tr -d '\r' <"$path" >"$FILES/$2"
}

check_sources() {
    local crlf
    crlf=$(grep -rlI $'\r' "$SRC/image" "$SRC/builder" || true)
    [[ -z $crlf ]] || die "Files with Windows line endings found (clone with core.autocrlf=false):"$'\n'"$crlf"
}

# Downloads (cached) and verifies the Raspberry Pi OS image. Sets BASE_IMAGE.
fetch_base_image() {
    local url name xz expected actual
    url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$RASPIOS_IMAGE_URL") ||
        die "Cannot reach $RASPIOS_IMAGE_URL"
    name=$(basename "$url")
    [[ $name == *.img.xz ]] || die "Expected an .img.xz download, got $url"
    xz=$CACHE/$name
    log "Base image: $name"

    if [[ ! -f $xz ]]; then
        log "Downloading $url"
        curl -fL --retry 3 --progress-bar -o "$xz.part" "$url"
        mv "$xz.part" "$xz"
    fi

    expected=${RASPIOS_IMAGE_SHA256,,}
    if [[ -z $expected ]]; then
        expected=$(curl -fsSL "$url.sha256" | awk '{print $1}') || true
        [[ -n $expected ]] || warn "No published checksum found, skipping verification"
    fi
    if [[ -n $expected ]]; then
        actual=$(sha256sum "$xz" | awk '{print $1}')
        if [[ $actual != "$expected" ]]; then
            rm -f "$xz"
            die "Checksum mismatch for $name (expected $expected, got $actual). Removed the download – run the build again."
        fi
        log "Checksum verified"
    fi

    BASE_IMAGE=$CACHE/${name%.xz}
    if [[ ! -f $BASE_IMAGE ]]; then
        log "Decompressing"
        xz -dc "$xz" >"$BASE_IMAGE.part"
        mv "$BASE_IMAGE.part" "$BASE_IMAGE"
    fi
}

# Gives the image a new random disk identifier so the installer stick and the
# installed system never share PARTUUIDs. References are fixed in mount_image.
randomize_disk_id() {
    OLD_DISK_ID=$(printf '%08x' "$(sfdisk --disk-id "$1")")
    NEW_DISK_ID=$(od -An -N4 -tx4 /dev/urandom | tr -d ' \n')
    sfdisk --quiet --disk-id "$1" "0x$NEW_DISK_ID" >/dev/null
}

# mount_image <image>: mounts the image at $MNT and prepares it for chroot.
mount_image() {
    part_geometry "$1" 2
    attach_loop "$1" "$PART_OFFSET" "$PART_SIZE"
    ROOT_LOOP=$LOOP_DEV
    part_geometry "$1" 1
    attach_loop "$1" "$PART_OFFSET" "$PART_SIZE"

    mkdir -p "$MNT"
    track_mount "$ROOT_LOOP" "$MNT"
    if [[ -d $MNT/boot/firmware ]]; then BOOT_DIR=$MNT/boot/firmware; else BOOT_DIR=$MNT/boot; fi
    track_mount "$LOOP_DEV" "$BOOT_DIR"
    track_mount -t proc proc "$MNT/proc"
    track_mount -t sysfs sysfs "$MNT/sys"
    track_mount --bind /dev "$MNT/dev"
    track_mount --bind /dev/pts "$MNT/dev/pts"

    sed -i "s/$OLD_DISK_ID/$NEW_DISK_ID/g" "$BOOT_DIR/cmdline.txt" "$MNT/etc/fstab"
    grep -q "PARTUUID=$NEW_DISK_ID-02" "$BOOT_DIR/cmdline.txt" ||
        die "cmdline.txt does not reference the root partition by PARTUUID – unsupported image layout"
}

unmount_image() {
    release_mounts
    fsck_ext4 "$ROOT_LOOP"
    release_loops
}

# Copies an overlay directory into the image. Files starting with a shebang
# become executable, everything else is 0644. All files are owned by root.
apply_overlay() {
    local src=$1 file mode
    while IFS= read -r -d '' file; do
        mode=644
        [[ $(head -c2 "$file") != '#!' ]] || mode=755
        install -D -o root -g root -m "$mode" "$file" "$MNT/${file#"$src"/}"
    done < <(find "$src" -type f -print0)
}

# run_customize <role>: system configuration that has to run inside the image.
run_customize() {
    local env=$MNT/tmp/homelab-seed-build.env
    write_env "$env" TARGET_HOSTNAME TIMEZONE LOCALE KEYBOARD_LAYOUT ADMIN_USER ADMIN_PASSWORD \
        NETWORK_INTERFACE NETWORK_IPV4 NETWORK_ADDRESS NETWORK_GATEWAY NETWORK_DNS \
        WIFI_SSID WIFI_PASSWORD WIFI_COUNTRY NTP_SERVERS
    install -m 600 "$FILES/authorized_keys" "$MNT/tmp/homelab-seed-authorized_keys"
    install -m 755 "$SRC/builder/customize.sh" "$MNT/tmp/homelab-seed-customize.sh"

    prepare_chroot_emulation "$MNT"
    chroot "$MNT" /bin/bash /tmp/homelab-seed-customize.sh "$1"
    cleanup_chroot_emulation

    rm -f "$env" "$MNT/tmp/homelab-seed-authorized_keys" "$MNT/tmp/homelab-seed-customize.sh"
}

write_release() {
    {
        printf 'HOMELAB_SEED_VERSION=%q\n' "${SEED_VERSION:-unknown}"
        printf 'BUILD_DATE=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'BASE_IMAGE=%q\n' "$(basename "$BASE_IMAGE")"
    } >"$1"
}

build_target() {
    local etc=$MNT/etc/homelab-seed
    log "Building the system image"
    cp --sparse=always "$BASE_IMAGE" "$WORK/os.img"
    randomize_disk_id "$WORK/os.img"
    mount_image "$WORK/os.img"

    apply_overlay "$SRC/image/common"
    apply_overlay "$SRC/image/target"

    install -d -m 700 "$etc" "$etc/files"
    # File settings point to their location inside the installed system. The
    # subshell keeps the build-side values for the install commands below.
    (
        # shellcheck disable=SC2030
        [[ -z $BOOTSTRAP_SSH_PRIVATE_KEY_FILE ]] || BOOTSTRAP_SSH_PRIVATE_KEY_FILE=/etc/homelab-seed/files/ssh_key
        # shellcheck disable=SC2030
        [[ -z $BOOTSTRAP_SECRETS_FILE ]] || BOOTSTRAP_SECRETS_FILE=/etc/homelab-seed/files/secrets.env
        mapfile -t keys < <(runtime_keys)
        write_env "$etc/config.env" "${keys[@]}"
    )
    # shellcheck disable=SC2031
    [[ -z $BOOTSTRAP_SSH_PRIVATE_KEY_FILE ]] || install -m 600 "$FILES/ssh_key" "$etc/files/ssh_key"
    # shellcheck disable=SC2031
    [[ -z $BOOTSTRAP_SECRETS_FILE ]] || install -m 600 "$FILES/secrets.env" "$etc/files/secrets.env"
    if [[ -n $HOOKS_DIR ]]; then
        install -d -m 700 "$etc/hooks"
        install -m 700 "$STAGE"/hooks/*.sh "$etc/hooks/"
    fi
    write_release "$etc/release"

    run_customize target
    unmount_image
}

build_installer() {
    local img=$WORK/installer.img os_size grow etc=$MNT/etc/homelab-seed
    log "Building the installer image"
    cp --sparse=always "$BASE_IMAGE" "$img"

    # Make room for the system image plus some headroom.
    os_size=$(stat -c %s "$WORK/os.img")
    grow=$(((os_size / 1048576 + 512) * 1048576))
    truncate -s "+$grow" "$img"
    echo ', +' | sfdisk --quiet --no-reread --no-tell-kernel -N 2 "$img" >/dev/null
    part_geometry "$img" 2
    attach_loop "$img" "$PART_OFFSET" "$PART_SIZE"
    fsck_ext4 "$LOOP_DEV"
    resize2fs "$LOOP_DEV" >&2
    release_loops

    randomize_disk_id "$img"
    mount_image "$img"

    apply_overlay "$SRC/image/common"
    apply_overlay "$SRC/image/installer"

    install -d -m 700 "$etc"
    write_env "$etc/installer.env" TARGET_DEVICE INSTALLER_IF_INSTALLED INSTALLER_AFTER_INSTALL
    write_release "$etc/release"
    install -d -m 700 "$MNT/var/lib/homelab-seed"
    log "Copying the system image into the installer"
    cp --sparse=always "$WORK/os.img" "$MNT/var/lib/homelab-seed/os.img"
    chmod 600 "$MNT/var/lib/homelab-seed/os.img"

    run_customize installer
    unmount_image
}

publish() {
    local name
    name="homelab-seed-$TARGET_HOSTNAME-$(date -u +%Y%m%d-%H%M).img"
    rm -f "$WORK/os.img"
    mv "$WORK/installer.img" "$WORK/$name"
    if is_true "${SEED_XZ:-false}"; then
        log "Compressing"
        xz -T0 -f "$WORK/$name"
        name=$name.xz
    fi
    (cd "$WORK" && sha256sum "$name" >"$name.sha256")
    # The output directory may be a slow host mount (Windows, macOS): copy once at the end.
    log "Copying the image to the output directory"
    cp "$WORK/$name.sha256" "$OUT/"
    cp --sparse=always "$WORK/$name" "$OUT/"
    rm -f "$WORK/$name" "$WORK/$name.sha256"
    [[ -z ${HOST_UID:-} ]] || chown "$HOST_UID:${HOST_GID:-$HOST_UID}" "$OUT/$name" "$OUT/$name.sha256"
    log "Done: $name"
}

# Packs the staged configuration (config.env + referenced files) into a single
# base64 line that fits into a CI secret.
write_bundle() {
    local bundle=$OUT/config.bundle.b64 size
    touch "$STAGE/$BUNDLE_MARKER"
    tar -C "$STAGE" -czf - . | base64 -w0 >"$bundle"
    chmod 600 "$bundle"
    [[ -z ${HOST_UID:-} ]] || chown "$HOST_UID:${HOST_GID:-$HOST_UID}" "$bundle"
    size=$(stat -c %s "$bundle")
    ((size <= 48000)) || warn "The bundle is $size bytes – GitHub secrets are limited to 48 KB"
    log "Config bundle written: config.bundle.b64 ($size bytes). It contains your secrets in plain text – delete it after storing it as a secret."
}

main() {
    trap on_exit EXIT
    trap 'die "Build failed in line $LINENO"' ERR
    check_sources
    stage_config
    validate_config "$STAGE"
    log "Configuration is valid"
    if [[ ${SEED_MODE:-build} == bundle ]]; then
        write_bundle
        return
    fi

    ensure_loop_nodes
    ensure_arm64_emulation
    mkdir -p "$CACHE" "$WORK" "$OUT"
    fetch_base_image
    build_target
    build_installer
    publish
}

# Allow tests to source this file without running the build.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
