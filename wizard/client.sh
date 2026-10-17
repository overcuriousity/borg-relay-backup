# shellcheck shell=bash
# Client role wizard.
CLIENT_KEY=/root/.ssh/borg-relay_ed25519
DUMP_DIR_DEFAULT=/var/lib/borg-relay/dumps

_client_repo() { REPO="ssh://${RELAY_USER}@${RELAY_HOST}:${RELAY_PORT}/./${BACKUP_NAME}"; }

_client_deps() { wiz_apt borgbackup openssh-client curl python3; }

_client_identity() {
    local kh
    BACKUP_NAME=${BACKUP_NAME:-$(hostname -s)}
    ask BACKUP_NAME "Name of this client's repository"
    valid_name "$BACKUP_NAME" || { ui_fail "use lowercase letters, digits and dashes"; return 1; }
    ask RELAY_HOST "Relay address (IP or hostname)"
    ask RELAY_PORT "Relay SSH port" 22
    ask RELAY_USER "Relay user" borgrelay
    install -d -m 700 /root/.ssh
    [[ -f $CLIENT_KEY ]] || ssh-keygen -q -t ed25519 -N '' -C "borg-relay:$BACKUP_NAME" -f "$CLIENT_KEY"
    kh=$(mktemp)
    ssh-keyscan -p "$RELAY_PORT" "$RELAY_HOST" >"$kh" 2>/dev/null || true
    [[ -s $kh ]] || { ui_fail "no SSH answer from $RELAY_HOST:$RELAY_PORT"; rm -f "$kh"; return 1; }
    ui_info "Relay host key fingerprints (compare on the relay: ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub):"
    ssh-keygen -lf "$kh" >&2
    ask_yn "Do they match?" y || { rm -f "$kh"; return 1; }
    ssh-keygen -R "[$RELAY_HOST]:$RELAY_PORT" >/dev/null 2>&1 || true
    ssh-keygen -R "$RELAY_HOST" >/dev/null 2>&1 || true
    cat "$kh" >>/root/.ssh/known_hosts
    rm -f "$kh"
    _client_repo
}

_client_authorize() {
    local out
    export BORG_RSH="ssh -F none -i $CLIENT_KEY -o BatchMode=yes -o ConnectTimeout=20"
    ui_info "On the relay, run:   borg-relay add-client $BACKUP_NAME"
    ui_info "and paste this key:"
    printf '\n%s\n\n' "$(cat "$CLIENT_KEY.pub")" >&2
    pause "Done on the relay"
    out=$(BORG_PASSPHRASE=x borg_info "$REPO" 2>&1) && { REPO_EXISTS=yes; return 0; }
    case $(classify_borg_error "$out") in
        exists)    REPO_EXISTS=yes; return 0 ;;
        missing)   REPO_EXISTS=no; return 0 ;;
        denied)    ui_fail "relay rejected the key - was add-client run with the right key?" ;;
        unmounted) ui_fail "relay reports its storage target is not mounted" ;;
        network)   ui_fail "relay not reachable on $RELAY_HOST:$RELAY_PORT" ;;
        *)         ui_fail "unexpected answer: $out" ;;
    esac
    return 1
}

_client_init() {
    export BORG_RSH="ssh -F none -i $CLIENT_KEY -o BatchMode=yes -o ConnectTimeout=20"
    if [[ $REPO_EXISTS == yes ]]; then
        ui_info "Repository '$BACKUP_NAME' already exists on the target."
        ask_secret BORG_PASSPHRASE "Its passphrase"
        export BORG_PASSPHRASE
        borg_info "$REPO" >/dev/null || { ui_fail "passphrase rejected"; return 1; }
    else
        if [[ -z ${BORG_PASSPHRASE:-} ]] && ask_yn "Generate a random 32-character passphrase?" y; then
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
    ui_info "On the relay, run:   borg-relay set-passphrase $BACKUP_NAME"
    ui_info "and paste:           $BORG_PASSPHRASE"
    ask_yn "Did the relay report 'stored and verified'?" y
}

_client_db() {
    ask DB_TYPE "Database type: pgsql or mysql" pgsql
    [[ $DB_TYPE == pgsql || $DB_TYPE == mysql ]] || { ui_fail "pgsql or mysql"; return 1; }
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
    (( ${#BACKUP_PATHS[@]} )) || { ui_fail "at least one path is needed"; return 1; }
    ask_list EXCLUDES "Exclude patterns" ""
    install -d -m 700 "$BR_ETC/hooks.d"
    for h in "$BR_ETC"/hooks.d/10-{nextcloud,db-dump,paperless}.{pre,post}; do [[ -L $h ]] && rm -f "$h"; done
    CONF_VARS=(RELAY_HOST RELAY_PORT RELAY_USER BACKUP_NAME CLIENT_KEY BORG_PASSPHRASE BACKUP_PATHS EXCLUDES)

    if ask_yn "Nextcloud on this host (maintenance mode + DB dump)?" "$([[ -n ${NC_DIR:-} ]] && echo y || echo n)"; then
        ask NC_DIR "Nextcloud directory" /var/www/nextcloud
        ask NC_WEB_USER "Web server user" www-data
        ask NC_STOP_SERVICE "Service to stop during backup (- for none)" nginx
        _client_db || return 1
        ln -sf "$PREFIX/hooks/10-nextcloud.pre" "$PREFIX/hooks/10-nextcloud.post" "$BR_ETC/hooks.d/"
        CONF_VARS+=(NC_DIR NC_WEB_USER NC_STOP_SERVICE)
    elif ask_yn "Dump a database before each backup?" "$([[ -n ${DB_TYPE:-} ]] && echo y || echo n)"; then
        _client_db || return 1
        ln -sf "$PREFIX/hooks/10-db-dump.pre" "$PREFIX/hooks/10-db-dump.post" "$BR_ETC/hooks.d/"
    fi
    if ask_yn "Paperless-ngx on this host (document export)?" "$([[ -n ${PAPERLESS_DIR:-} ]] && echo y || echo n)"; then
        ask PAPERLESS_DIR "Paperless docker compose directory"
        ask PAPERLESS_SERVICE "Compose service name" webserver
        ask PAPERLESS_EXPORT_IN_CONTAINER "Export path inside the container" /usr/src/paperless/export
        local host_export=$PAPERLESS_DIR/export
        ask host_export "Same export directory on this host"
        BACKUP_PATHS+=("$host_export")
        ln -sf "$PREFIX/hooks/10-paperless.pre" "$BR_ETC/hooks.d/"
        CONF_VARS+=(PAPERLESS_DIR PAPERLESS_SERVICE PAPERLESS_EXPORT_IN_CONTAINER)
    fi
    _client_dedupe_paths
    ui_info "Site-specific hooks: put executable NN-name.pre / NN-name.post files into $BR_ETC/hooks.d/"
    conf_write "$BR_ETC/client.conf" 600 root:root "${CONF_VARS[@]}"
    ui_info "Preview of the first files:"
    borg_dry_run "$REPO" 2>&1 | head -n 15 >&2 || return 1
}

_client_timer() {
    SCHEDULE=${SCHEDULE:-"*-*-* 21:30:00"}
    ask SCHEDULE "Daily start time (systemd OnCalendar)"
    systemd-analyze calendar "$SCHEDULE" >/dev/null 2>&1 || { ui_fail "not a valid OnCalendar expression"; return 1; }
    wiz_units borg-relay-backup.service borg-relay-backup.timer borg-relay-notify@.service
    install -d /etc/systemd/system/borg-relay-backup.timer.d
    printf '[Timer]\nOnCalendar=\nOnCalendar=%s\n' "$SCHEDULE" >/etc/systemd/system/borg-relay-backup.timer.d/schedule.conf
    systemctl daemon-reload
    systemctl enable --now borg-relay-backup.timer >/dev/null
}

_client_first_run() {
    ask_yn "Run the first backup now (can take long for big data)?" y || return 0
    ui_info "Running ... follow it in another shell with: journalctl -fu borg-relay-backup"
    systemctl start borg-relay-backup.service || { journalctl -u borg-relay-backup -n 30 --no-pager >&2; return 1; }
    borg_archive_names "$REPO" >&2
}

_client_recovery() {
    ui_header "Recovery entry for KeePassXC - CLIENT $BACKUP_NAME"
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
    pause "Copy this block into KeePassXC now"
}

client_wizard() {
    wiz_preload "$BR_ETC/client.conf"
    wiz_preload "$BR_ETC/notify.conf"
    step "packages" _client_deps
    wiz_install_files
    install -d -m 700 "$BR_ETC"
    step "client key and relay host key" _client_identity
    step "relay accepts this client" _client_authorize
    step "repository" _client_init
    step "relay knows the passphrase" _client_relay_passphrase
    step "paths and hooks" _client_hooks
    NOTIFY_MODE=600 NOTIFY_OWNER=root:root wiz_notify
    step "daily timer" _client_timer
    step "first backup" _client_first_run
    _client_recovery
    ui_ok "Client '$BACKUP_NAME' is set up."
}
