# shellcheck shell=bash
# Setup steps: user hooks from HOOKS_DIR (installed to /etc/homelab-seed/hooks).
# Each hook runs once, as root, with all settings exported as environment
# variables. A failing hook fails the setup, which is then retried.

HOOKS_INSTALL_DIR=$SEED_ETC/hooks

run_hooks() {
    local hook name
    [[ -d $HOOKS_INSTALL_DIR ]] || return 0
    for hook in "$HOOKS_INSTALL_DIR"/*.sh; do
        [[ -f $hook ]] || continue
        name=$(basename "$hook" .sh)
        run_step "hook_${name//[^a-zA-Z0-9_.-]/_}" run_hook "$hook"
    done
}

run_hook() {
    log "Running hook $(basename "$1")"
    (
        set -a
        # shellcheck source=/dev/null
        . "$SEED_ETC/config.env"
        set +a
        cd /root
        exec bash "$1"
    )
}
