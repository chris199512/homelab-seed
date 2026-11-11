# shellcheck shell=bash
# Setup step: creates a Semaphore project wired to the Ansible repository and
# runs the bootstrap playbook. Every resource is looked up by name first, so
# the step can safely run again.

SEMAPHORE_API=http://127.0.0.1:${SEMAPHORE_PORT:-3000}/api
SEMAPHORE_TOKEN=""

# sem_api <method> <path> [json]
sem_api() {
    local args=(-sS --fail-with-body -X "$1" -H 'Accept: application/json' -H "Authorization: Bearer $SEMAPHORE_TOKEN")
    [[ -z ${3:-} ]] || args+=(-H 'Content-Type: application/json' --data-binary "$3")
    curl "${args[@]}" "$SEMAPHORE_API$2"
}

# Logs in as the admin and creates an API token.
sem_login() {
    local cookies body
    cookies=$(mktemp)
    body=$(U=$SEMAPHORE_ADMIN_USER P=$SEMAPHORE_ADMIN_PASSWORD jq -n '{auth: env.U, password: env.P}')
    curl -sS --fail-with-body -c "$cookies" -H 'Content-Type: application/json' \
        --data-binary "$body" "$SEMAPHORE_API/auth/login" >/dev/null
    SEMAPHORE_TOKEN=$(curl -sS --fail-with-body -b "$cookies" -X POST "$SEMAPHORE_API/user/tokens" | jq -r '.id // empty')
    rm -f "$cookies"
    [[ -n $SEMAPHORE_TOKEN ]] || die "Could not create a Semaphore API token"
}

# find_id <collection-path> <name>
find_id() {
    sem_api GET "$1" | jq -r --arg n "$2" 'first(.[] | select(.name == $n) | .id) // empty'
}

# ensure <collection-path> <name> <json>: prints the id, creates the resource if missing.
ensure() {
    local path=$1 name=$2 body=$3 id
    id=$(find_id "$path" "$name")
    if [[ -n $id ]]; then
        log "'$name' exists (id $id)"
    else
        log "Creating '$name'"
        sem_api POST "$path" "$body" >/dev/null
        id=$(find_id "$path" "$name")
        [[ -n $id ]] || die "Creating '$name' in $path failed"
    fi
    echo "$id"
}

# ensure_key <project> <name> <type> [json-fields]
ensure_key() {
    local body extra=${4:-}
    [[ -n $extra ]] || extra='{}'
    body=$(jq -n --arg n "$2" --arg t "$3" --argjson p "$1" --argjson extra "$extra" \
        '{name: $n, type: $t, project_id: $p} + $extra')
    ensure "/project/$1/keys" "$2" "$body"
}

# KEY=VALUE lines of BOOTSTRAP_SECRETS_FILE plus SEMAPHORE_TOKEN as JSON array.
secrets_json() {
    local line key json
    json=$(jq -n --arg v "$SEMAPHORE_TOKEN" '[{name: "SEMAPHORE_TOKEN", secret: $v, type: "env", operation: "create"}]')
    if [[ -n $BOOTSTRAP_SECRETS_FILE ]]; then
        while IFS= read -r line || [[ -n $line ]]; do
            [[ -z ${line//[[:space:]]/} || $line =~ ^[[:space:]]*# ]] && continue
            key=${line%%=*}
            json=$(K=$key V=${line#*=} jq -c '. + [{name: env.K, secret: env.V, type: "env", operation: "create"}]' <<<"$json")
        done <"$BOOTSTRAP_SECRETS_FILE"
    fi
    echo "$json"
}

# run_task <project> <template-id> <label>: starts a task and waits for it.
run_task() {
    local project=$1 template=$2 label=$3 task status start=$SECONDS
    log "Running '$label'"
    task=$(sem_api POST "/project/$project/tasks" "$(jq -n --argjson t "$template" '{template_id: $t}')" | jq -r '.id // empty')
    [[ -n $task ]] || { warn "Could not start '$label'"; return 1; }
    while ((SECONDS - start < BOOTSTRAP_TASK_TIMEOUT)); do
        sleep 10
        status=$(sem_api GET "/project/$project/tasks/$task" | jq -r '.status // empty') || continue
        case $status in
            success) log "'$label' finished successfully"; return 0 ;;
            error | stopped | failed | rejected) warn "'$label' ended with status '$status' (task $task)"; return 1 ;;
        esac
    done
    warn "'$label' did not finish within ${BOOTSTRAP_TASK_TIMEOUT}s (task $task)"
    return 1
}

step_semaphore_bootstrap() {
    local project user repo_key ssh_key become_key="" repo inventory environment template name names body

    wait_for_semaphore
    sem_login

    project=$(ensure /projects "$BOOTSTRAP_PROJECT_NAME" \
        "$(jq -n --arg n "$BOOTSTRAP_PROJECT_NAME" '{name: $n, alert: true}')")

    if [[ -n $SMTP_HOST ]]; then
        log "Enabling e-mail alerts for $SEMAPHORE_ADMIN_USER"
        user=$(sem_api GET /user | jq -r '.id')
        body=$(jq -n --arg n "$SEMAPHORE_ADMIN_NAME" --arg u "$SEMAPHORE_ADMIN_USER" --arg e "$SEMAPHORE_ADMIN_EMAIL" \
            '{name: $n, username: $u, email: $e, alert: true, admin: true}')
        sem_api PUT "/users/$user" "$body" >/dev/null || warn "Could not enable alerts"
    fi

    # Keys
    if [[ -n $BOOTSTRAP_REPO_TOKEN ]]; then
        repo_key=$(ensure_key "$project" "$BOOTSTRAP_REPO_KEY_NAME" login_password \
            "$(jq -n --arg l "$BOOTSTRAP_REPO_USER" --arg p "$BOOTSTRAP_REPO_TOKEN" '{login_password: {login: $l, password: $p}}')")
    else
        repo_key=$(ensure_key "$project" None none)
    fi

    if [[ -n $BOOTSTRAP_SSH_PRIVATE_KEY_FILE ]]; then
        ssh_key=$(ensure_key "$project" "$BOOTSTRAP_SSH_KEY_NAME" ssh \
            "$(jq -n --arg l "$BOOTSTRAP_SSH_LOGIN" --arg p "$BOOTSTRAP_SSH_PASSPHRASE" \
                --rawfile k "$BOOTSTRAP_SSH_PRIVATE_KEY_FILE" '{ssh: {login: $l, passphrase: $p, private_key: $k}}')")
    else
        ssh_key=$(ensure_key "$project" None none)
    fi

    if [[ -n $BOOTSTRAP_BECOME_PASSWORD ]]; then
        become_key=$(ensure_key "$project" "$BOOTSTRAP_BECOME_KEY_NAME" login_password \
            "$(jq -n --arg p "$BOOTSTRAP_BECOME_PASSWORD" '{login_password: {login: "", password: $p}}')")
    fi

    # Repository, inventory, environment
    repo=$(ensure "/project/$project/repositories" "$BOOTSTRAP_REPO_NAME" \
        "$(jq -n --arg n "$BOOTSTRAP_REPO_NAME" --arg u "$BOOTSTRAP_REPO_URL" --arg b "$BOOTSTRAP_REPO_BRANCH" \
            --argjson p "$project" --argjson k "$repo_key" \
            '{name: $n, project_id: $p, git_url: $u, git_branch: $b, ssh_key_id: $k}')")

    inventory=$(ensure "/project/$project/inventory" "$BOOTSTRAP_INVENTORY_NAME" \
        "$(jq -n --arg n "$BOOTSTRAP_INVENTORY_NAME" --arg i "$BOOTSTRAP_INVENTORY_PATH" \
            --argjson p "$project" --argjson r "$repo" --argjson k "$ssh_key" --arg b "$become_key" \
            '{name: $n, project_id: $p, type: "file", inventory: $i, repository_id: $r, ssh_key_id: $k,
              become_key_id: (if $b == "" then null else ($b | tonumber) end)}')")

    environment=$(ensure "/project/$project/environment" "$BOOTSTRAP_ENVIRONMENT_NAME" \
        "$(jq -n --arg n "$BOOTSTRAP_ENVIRONMENT_NAME" --argjson p "$project" --argjson s "$(secrets_json)" \
            '{name: $n, project_id: $p, json: "{}", env: "{}", secrets: $s}')")

    # Bootstrap playbook and follow-up templates. Failing tasks do not fail the
    # setup – they can be re-run from the Semaphore UI.
    if [[ -n $BOOTSTRAP_PLAYBOOK ]]; then
        template=$(ensure "/project/$project/templates" "$BOOTSTRAP_TEMPLATE_NAME" \
            "$(jq -n --arg n "$BOOTSTRAP_TEMPLATE_NAME" --arg pb "$BOOTSTRAP_PLAYBOOK" --argjson p "$project" \
                --argjson r "$repo" --argjson i "$inventory" --argjson e "$environment" \
                '{name: $n, project_id: $p, app: "ansible", playbook: $pb,
                  repository_id: $r, inventory_id: $i, environment_id: $e}')")
        run_task "$project" "$template" "$BOOTSTRAP_TEMPLATE_NAME" || true
    fi

    IFS=, read -ra names <<<"$BOOTSTRAP_RUN_AFTER"
    for name in "${names[@]}"; do
        name=${name#"${name%%[![:space:]]*}"}
        name=${name%"${name##*[![:space:]]}"}
        [[ -n $name ]] || continue
        template=$(find_id "/project/$project/templates" "$name")
        if [[ -z $template ]]; then
            warn "Template '$name' not found – skipped"
            continue
        fi
        run_task "$project" "$template" "$name" || true
    done
}
