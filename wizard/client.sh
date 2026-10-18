# shellcheck shell=bash
# Client role wizard.
CLIENT_KEY=/root/.ssh/borg-relay_ed25519
DUMP_DIR_DEFAULT=/var/lib/borg-relay/dumps

_client_repo() { REPO="ssh://${RELAY_USER}@${RELAY_HOST}:${RELAY_PORT}/./${BACKUP_NAME}"; }

_client_deps() { wiz_apt borgbackup openssh-client curl python3; }

_client_identity() {
    local kh
    BACKUP_NAME=${BACKUP_NAME:-$(hostname -s)}
    ask BACKUP_NAME "Repository name for this client"
    valid_name "$BACKUP_NAME" || { ui_fail "Use lowercase letters, digits and dashes only (max. 63 characters)."; return 1; }
    ask RELAY_HOST "Relay address (IP address or hostname)"
    ask RELAY_PORT "Relay SSH port" 22
    ask RELAY_USER "User on the relay" borgrelay
    install -d -m 700 /root/.ssh
    [[ -f $CLIENT_KEY ]] || ssh-keygen -q -t ed25519 -N '' -C "borg-relay:$BACKUP_NAME" -f "$CLIENT_KEY"
    kh=$(mktemp)
    ssh-keyscan -p "$RELAY_PORT" "$RELAY_HOST" >"$kh" 2>/dev/null || true
    [[ -s $kh ]] || { ui_fail "No SSH response from $RELAY_HOST:$RELAY_PORT. Check the address and the firewall."; rm -f "$kh"; return 1; }
    ui_info "Host key fingerprints reported by the relay (on the relay: ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub):"
    ssh-keygen -lf "$kh" >&2
    ask_yn "Do they match the relay's fingerprint?" y || { rm -f "$kh"; return 1; }
    ssh-keygen -R "[$RELAY_HOST]:$RELAY_PORT" >/dev/null 2>&1 || true
    ssh-keygen -R "$RELAY_HOST" >/dev/null 2>&1 || true
    cat "$kh" >>/root/.ssh/known_hosts
    rm -f "$kh"
    _client_repo
}

_client_authorize() {
    local out
    export BORG_RSH="ssh -F none -i $CLIENT_KEY -o BatchMode=yes -o ConnectTimeout=20"
    ui_info "Action required on the relay (as root): borg-relay add-client $BACKUP_NAME"
    ui_info "When prompted, paste this public key:"
    printf '\n%s\n\n' "$(cat "$CLIENT_KEY.pub")" >&2
    pause "Once the relay has confirmed the client"
    out=$(BORG_PASSPHRASE=x borg_info "$REPO" 2>&1) && { REPO_EXISTS=yes; return 0; }
    case $(classify_borg_error "$out") in
        exists)    REPO_EXISTS=yes; return 0 ;;
        missing)   REPO_EXISTS=no; return 0 ;;
        denied)    ui_fail "The relay rejected this client. Check that add-client was run with the key shown above." ;;
        unmounted) ui_fail "The relay reports that its storage is not mounted." ;;
        network)   ui_fail "The relay is not reachable at $RELAY_HOST:$RELAY_PORT." ;;
        *)         ui_fail "Unexpected response from the relay: $out" ;;
    esac
    return 1
}

_client_init() {
    export BORG_RSH="ssh -F none -i $CLIENT_KEY -o BatchMode=yes -o ConnectTimeout=20"
    if [[ $REPO_EXISTS == yes ]]; then
        ui_info "The repository '$BACKUP_NAME' already exists."
        ask_secret BORG_PASSPHRASE "Passphrase of the existing repository"
        export BORG_PASSPHRASE
        borg_info "$REPO" >/dev/null || { ui_fail "The passphrase was rejected."; return 1; }
    else
        if [[ -z ${BORG_PASSPHRASE:-} ]] && ask_yn "Generate a random passphrase (32 characters)?" y; then
            BORG_PASSPHRASE=$(gen_passphrase)
        else
            ask_secret BORG_PASSPHRASE "Passphrase for the new repository"
        fi
        export BORG_PASSPHRASE
        borg_init "$REPO" || return 1
    fi
    # persist at once: the passphrase must never exist only on screen
    conf_write "$BR_ETC/client.conf" 600 root:root RELAY_HOST RELAY_PORT RELAY_USER BACKUP_NAME CLIENT_KEY BORG_PASSPHRASE
    KEY_EXPORT=$(borg_key_export "$REPO") || return 1
}

_client_relay_passphrase() {
    ui_info "Action required on the relay (as root): borg-relay set-passphrase $BACKUP_NAME"
    ui_info "When prompted, enter this passphrase: $BORG_PASSPHRASE"
    ui_info "The relay needs it for weekly maintenance. Backups from this client work without it,"
    ui_info "so you may also do this after the installation."
    pause "When done (or to continue now)"
}

_client_db() {
    ask DB_TYPE "Database type ('pgsql' or 'mysql')" pgsql
    [[ $DB_TYPE == pgsql || $DB_TYPE == mysql ]] || { ui_fail "Please answer 'pgsql' (PostgreSQL) or 'mysql' (MySQL/MariaDB)."; return 1; }
    ask DB_NAME "Database name" nextcloud
    ask DB_HOST "Database host" localhost
    ask DB_USER "Database user" "$DB_NAME"
    local pw=
    ask_secret pw "Database password"
    if [[ $DB_TYPE == pgsql ]]; then
        ( umask 077; pgpass_line "$DB_HOST" "$DB_NAME" "$DB_USER" "$pw" >"$BR_ETC/db.pgpass" )
    else
        local cnf
        cnf=$(mycnf_content "$DB_USER" "$pw") || return 1
        ( umask 077; printf '%s\n' "$cnf" >"$BR_ETC/db.cnf" )
    fi
    install -d -m 700 "$DUMP_DIR_DEFAULT"   # must exist before the first backup / preview
    BACKUP_PATHS+=("$DUMP_DIR_DEFAULT")
    CONF_VARS+=(DB_TYPE DB_NAME DB_HOST DB_USER)
}

_client_dedupe_paths() {
    local p seen=() out=()
    for p in "${BACKUP_PATHS[@]}"; do
        [[ " ${seen[*]} " == *" $p "* ]] && continue
        seen+=("$p"); out+=("$p")
    done
    BACKUP_PATHS=("${out[@]}")
}

_client_hooks() {
    local h
    BACKUP_PATHS=("${BACKUP_PATHS[@]+"${BACKUP_PATHS[@]}"}")
    EXCLUDES=("${EXCLUDES[@]+"${EXCLUDES[@]}"}")
    ask_list BACKUP_PATHS "Paths to back up" "/etc /root /home"
    (( ${#BACKUP_PATHS[@]} )) || { ui_fail "At least one path is required."; return 1; }
    ask_list EXCLUDES "Exclude patterns, e.g. */cache/*" ""
    install -d -m 700 "$BR_ETC/hooks.d"
    for h in "$BR_ETC"/hooks.d/10-{nextcloud,db-dump,paperless}.{pre,post}; do [[ -L $h ]] && rm -f "$h"; done
    CONF_VARS=(RELAY_HOST RELAY_PORT RELAY_USER BACKUP_NAME CLIENT_KEY BORG_PASSPHRASE BACKUP_PATHS EXCLUDES)

    if ask_yn "Is Nextcloud installed on this host? (enables maintenance mode and a database dump during the backup)" "$([[ -n ${NC_DIR:-} ]] && echo y || echo n)"; then
        ask NC_DIR "Nextcloud installation directory" /var/www/nextcloud
        ask NC_WEB_USER "User the web server runs as" www-data
        ask NC_STOP_SERVICE "Service to stop during the backup (\"-\" for none)" nginx
        _client_db || return 1
        ln -sf "$PREFIX/hooks/10-nextcloud.pre" "$PREFIX/hooks/10-nextcloud.post" "$BR_ETC/hooks.d/"
        CONF_VARS+=(NC_DIR NC_WEB_USER NC_STOP_SERVICE)
    elif ask_yn "Dump a database before each backup?" "$([[ -n ${DB_TYPE:-} ]] && echo y || echo n)"; then
        _client_db || return 1
        ln -sf "$PREFIX/hooks/10-db-dump.pre" "$PREFIX/hooks/10-db-dump.post" "$BR_ETC/hooks.d/"
    fi
    if ask_yn "Is Paperless-ngx installed on this host? (exports all documents before the backup)" "$([[ -n ${PAPERLESS_DIR:-} ]] && echo y || echo n)"; then
        ask PAPERLESS_DIR "Directory containing the Paperless docker-compose file"
        ask PAPERLESS_SERVICE "Name of the Paperless service in the compose file" webserver
        ask PAPERLESS_EXPORT_IN_CONTAINER "Export directory inside the container" /usr/src/paperless/export
        local host_export=$PAPERLESS_DIR/export
        ask host_export "The same export directory as seen on this host"
        BACKUP_PATHS+=("$host_export")
        ln -sf "$PREFIX/hooks/10-paperless.pre" "$BR_ETC/hooks.d/"
        CONF_VARS+=(PAPERLESS_DIR PAPERLESS_SERVICE PAPERLESS_EXPORT_IN_CONTAINER)
    fi
    _client_dedupe_paths
    ui_info "Additional actions before/after the backup: place executable NN-name.pre / NN-name.post files in $BR_ETC/hooks.d/"
    conf_write "$BR_ETC/client.conf" 600 root:root "${CONF_VARS[@]}"
    _client_preview
}

# _client_preview - list the first files; borg warnings (rc 1, e.g. a missing path) are
# shown but accepted, a closed pipe from `head` is fine, real errors fail the step
_client_preview() {
    local err rc
    err=$(mktemp)
    ui_info "Preview of the first files to be backed up:"
    borg_dry_run "$REPO" 2>"$err" | head -n 15 >&2
    rc=${PIPESTATUS[0]}
    if [[ -s $err ]]; then
        ui_info "Messages from borg:"
        head -n 10 "$err" >&2
    fi
    if (( rc == 0 || rc == 1 || rc == 141 )) || grep -qi 'broken ?pipe' "$err"; then
        rm -f "$err"; return 0
    fi
    rm -f "$err"
    return 1
}

_client_timer() {
    SCHEDULE=${SCHEDULE:-"*-*-* 21:30:00"}
    ask SCHEDULE "Daily backup time (systemd OnCalendar format)"
    systemd-analyze calendar "$SCHEDULE" >/dev/null 2>&1 || { ui_fail "This is not a valid OnCalendar expression (example: *-*-* 21:30:00)."; return 1; }
    wiz_units borg-relay-backup.service borg-relay-backup.timer borg-relay-seed.service borg-relay-notify@.service
    install -d /etc/systemd/system/borg-relay-backup.timer.d
    printf '[Timer]\nOnCalendar=\nOnCalendar=%s\n' "$SCHEDULE" >/etc/systemd/system/borg-relay-backup.timer.d/schedule.conf
    systemctl daemon-reload
    systemctl enable --now borg-relay-backup.timer >/dev/null
}

_client_first_run() {
    FIRST_RUN=${FIRST_RUN:-now}
    ask FIRST_RUN "Run the first backup: 'now' (and wait), 'background' (recommended for large data: runs without hooks, services stay online), or 'skip'"
    case $FIRST_RUN in
        now)
            ui_info "The first backup is running. Log: journalctl -u borg-relay-backup"
            systemctl start borg-relay-backup.service || { journalctl -u borg-relay-backup -n 30 --no-pager >&2; return 1; }
            borg_archive_names "$REPO" >&2
            ;;
        background)
            systemctl start --no-block borg-relay-seed.service || return 1
            ui_info "The first backup is running in the background; you can log out. You will be notified of the result."
            ui_info "Progress: journalctl -fu borg-relay-seed. The daily schedule resumes automatically afterwards."
            ;;
        skip) ;;
        *) ui_fail "Please answer 'now', 'background' or 'skip'."; return 1 ;;
    esac
}

_client_recovery() {
    ui_header "Recovery information - CLIENT $BACKUP_NAME"
    {
        echo "===== borg-relay CLIENT $BACKUP_NAME ($(date -I)) ====="
        echo "Repository via relay: $REPO"
        echo "Repository on target: <target>/$BACKUP_NAME  (see the RELAY entry)"
        echo "Passphrase: $BORG_PASSPHRASE"
        echo "Repo key (only needed if the key inside the repo is damaged;"
        echo "restore with: borg key import <repo> <file-with-this-text>):"
        echo "$KEY_EXPORT"
        echo "Client SSH key: $CLIENT_KEY (needed only for access via the relay)"
        echo "Restore:"
        echo "  export BORG_PASSPHRASE='…'"
        echo "  borg list <repo>"
        echo "  borg mount <repo>::<archive> /mnt/restore      # browse, then: borg umount /mnt/restore"
        echo "  borg extract <repo>::<archive> path/inside/archive"
        echo "====="
    } >&2
    pause "Store this block in a safe place (e.g. your password manager) now"
}

client_wizard() {
    wiz_preload "$BR_ETC/client.conf"
    wiz_preload "$BR_ETC/notify.conf"
    step "Required packages installed" _client_deps
    wiz_install_files
    install -d -m 700 "$BR_ETC"
    step "Client key created and relay identified" _client_identity
    step "Relay accepts this client" _client_authorize
    step "Repository ready" _client_init
    step "Passphrase handed over to the relay" _client_relay_passphrase
    step "Backup paths and hooks configured" _client_hooks
    NOTIFY_MODE=600 NOTIFY_OWNER=root:root wiz_notify
    step "Daily backup scheduled" _client_timer
    step "First backup" _client_first_run
    _client_recovery
    ui_ok "The client '$BACKUP_NAME' is set up."
}
