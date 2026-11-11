# shellcheck shell=bash
# Helpers for the image builder. Sourced by build-image.sh (runs as root).

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Mounts and loop devices are tracked so they can be released on any exit.
MOUNTS=()
LOOPS=()

# track_mount <mount args...> <mountpoint>
track_mount() {
    mount "$@"
    MOUNTS+=("${!#}")
}

release_mounts() {
    local i
    for ((i = ${#MOUNTS[@]} - 1; i >= 0; i--)); do
        umount "${MOUNTS[i]}" 2>/dev/null || umount -l "${MOUNTS[i]}" 2>/dev/null ||
            warn "Could not unmount ${MOUNTS[i]}"
    done
    MOUNTS=()
}

release_loops() {
    local dev
    for dev in "${LOOPS[@]}"; do
        losetup -d "$dev" 2>/dev/null || true
    done
    LOOPS=()
}

release_all() {
    release_mounts
    release_loops
}

# Docker containers only get the loop device nodes that existed at start.
ensure_loop_nodes() {
    local i
    [[ -e /dev/loop-control ]] || die "/dev/loop-control missing – is the container privileged?"
    for ((i = 0; i < 64; i++)); do
        [[ -e /dev/loop$i ]] || mknod -m 660 "/dev/loop$i" b 7 "$i"
    done
}

# attach_loop <image> <offset> <size>: sets LOOP_DEV
attach_loop() {
    LOOP_DEV=$(losetup --find --show --offset "$2" --sizelimit "$3" "$1")
    LOOPS+=("$LOOP_DEV")
}

# part_geometry <image> <partition-number>: sets PART_OFFSET and PART_SIZE (bytes)
part_geometry() {
    local json sector index=$(($2 - 1))
    json=$(sfdisk --json "$1")
    sector=$(jq -r '.partitiontable.sectorsize // 512' <<<"$json")
    PART_OFFSET=$(($(jq -r ".partitiontable.partitions[$index].start" <<<"$json") * sector))
    PART_SIZE=$(($(jq -r ".partitiontable.partitions[$index].size" <<<"$json") * sector))
}

# fsck_ext4 <device>: exit codes 0 and 1 (errors corrected) are fine.
fsck_ext4() {
    local rc=0
    e2fsck -fy "$1" >&2 || rc=$?
    ((rc <= 1)) || die "e2fsck failed on $1 (exit code $rc)"
}

# Registers qemu for arm64 binaries unless the host already handles them.
ensure_arm64_emulation() {
    local binfmt=/proc/sys/fs/binfmt_misc
    [[ $(uname -m) != aarch64 ]] || return 0
    if [[ ! -e $binfmt/register ]]; then
        mount -t binfmt_misc binfmt_misc "$binfmt" || die "Cannot mount binfmt_misc"
    fi
    if [[ ! -e $binfmt/qemu-aarch64 ]]; then
        log "Registering qemu-aarch64 for arm64 emulation"
        printf '%s' ':qemu-aarch64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-aarch64-static:F' \
            >"$binfmt/register"
    fi
}

# Without the F flag the kernel looks for the interpreter inside the chroot,
# so it has to be copied there. Sets CHROOT_QEMU to the copied path.
CHROOT_QEMU=""
prepare_chroot_emulation() {
    local root=$1 entry=/proc/sys/fs/binfmt_misc/qemu-aarch64 interpreter flags
    [[ $(uname -m) != aarch64 && -e $entry ]] || return 0
    interpreter=$(awk '$1 == "interpreter" {print $2}' "$entry")
    flags=$(awk '$1 == "flags:" {print $2}' "$entry")
    if [[ $flags != *F* && ! -e $root$interpreter ]]; then
        install -D -m 755 /usr/bin/qemu-aarch64-static "$root$interpreter"
        CHROOT_QEMU=$root$interpreter
    fi
    chroot "$root" /bin/true || die "Cannot execute arm64 binaries in the image (binfmt/qemu setup failed)"
}

cleanup_chroot_emulation() {
    [[ -z $CHROOT_QEMU ]] || rm -f "$CHROOT_QEMU"
    CHROOT_QEMU=""
}
