# shellcheck shell=bash
# Relay role wizard.
RUSER=borgrelay
RHOME=/var/lib/borg-relay

_relay_deps() {
    local pkgs=(borgbackup openssh-server curl python3)
    ask BACKEND "Storage backend: 'mount' (SMB/NFS/sshfs/… mounted here) or 'ssh-borg' (SSH host that runs borg)" mount
    [[ $BACKEND == mount || $BACKEND == ssh-borg ]] || { ui_fail "unknown backend"; return 1; }
    [[ $BACKEND == mount ]] && pkgs+=(cifs-utils)
    wiz_apt "${pkgs[@]}"
}

_relay_user() {
    # a real shell is required: sshd runs the forced command via the user's shell;
    # `restrict` in authorized_keys and the sshd drop-in keep clients from using it
    if id "$RUSER" >/dev/null 2>&1; then
        usermod -s /bin/sh "$RUSER" || return 1
    else
        useradd --system --home-dir "$RHOME" --create-home --shell /bin/sh "$RUSER" || return 1
    fi
    install -d -m 750 -o "$RUSER" -g "$RUSER" "$RHOME" "$RHOME/state"
    install -d -m 700 -o "$RUSER" -g "$RUSER" "$RHOME/.ssh"
    install -d -m 750 -o root -g "$RUSER" "$BR_ETC"
    install -d -m 700 -o "$RUSER" -g "$RUSER" "$BR_ETC/repos.d"
}

_relay_mount() {
    local opts unit aunit
    MOUNT_TYPE=${MOUNT_TYPE:-cifs}
    ask MOUNT_TYPE "Filesystem type (cifs, nfs, fuse.sshfs, …)"
    ask MOUNT_SOURCE "Source, e.g. //server/share"
    ask MOUNTPOINT "Mountpoint on this relay" /srv/borgtarget
    if [[ $MOUNT_TYPE == cifs ]]; then
        ask CIFS_USER "SMB username"
        ask_secret CIFS_PASS "SMB password"
        ask MOUNT_OPTIONS "Extra mount options" "vers=3.0"
        ( umask 077; printf 'username=%s\npassword=%s\n' "$CIFS_USER" "$CIFS_PASS" >"$BR_ETC/target.cred" )
        opts="credentials=$BR_ETC/target.cred,uid=$RUSER,gid=$RUSER,file_mode=0600,dir_mode=0700${MOUNT_OPTIONS:+,$MOUNT_OPTIONS}"
    else
        ask MOUNT_OPTIONS "Mount options (user '$RUSER' must be able to write)"
        opts=$MOUNT_OPTIONS
    fi
    mkdir -p "$MOUNTPOINT"
    unit=$(systemd-escape -p --suffix=mount "$MOUNTPOINT")
    aunit=${unit%.mount}.automount
    cat >"/etc/systemd/system/$unit" <<UNIT
[Unit]
Description=borg-relay storage target
Wants=network-online.target
After=network-online.target

[Mount]
What=$MOUNT_SOURCE
Where=$MOUNTPOINT
Type=$MOUNT_TYPE
Options=$opts
UNIT
    cat >"/etc/systemd/system/$aunit" <<UNIT
[Unit]
Description=borg-relay storage target (automount)

[Automount]
Where=$MOUNTPOINT
TimeoutIdleSec=600

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now "$aunit" >/dev/null
    # shellcheck disable=SC2016  # the inner script expands its own $1/$t
    if ! runuser -u "$RUSER" -- sh -c 't="$1/.borg-relay-write-test"; ls "$1" >/dev/null && touch "$t" && rm "$t"' _ "$MOUNTPOINT" \
        || ! mountpoint -q "$MOUNTPOINT"; then
        ui_fail "target not mounted or not writable for $RUSER (see: journalctl -u $unit)"
        return 1
    fi
}

_relay_ssh_target() {
    local kh
    ask TARGET_HOST "Target SSH host"
    ask TARGET_PORT "Target SSH port" 22
    ask TARGET_USER "Target SSH user"
    ask REMOTE_BORG "borg command on the target (e.g. borg-1.4 where the provider offers several)" borg
    TARGET_KEY=$RHOME/.ssh/target_ed25519
    [[ -f $TARGET_KEY ]] || runuser -u "$RUSER" -- ssh-keygen -q -t ed25519 -N '' -C "borg-relay@$(hostname -s)" -f "$TARGET_KEY"
    kh=$(mktemp)
    ssh-keyscan -p "$TARGET_PORT" "$TARGET_HOST" >"$kh" 2>/dev/null || true
    [[ -s $kh ]] || { ui_fail "no SSH answer from $TARGET_HOST:$TARGET_PORT"; rm -f "$kh"; return 1; }
    ui_info "Host key fingerprints of the target:"
    ssh-keygen -lf "$kh" >&2
    ask_yn "Do these match the fingerprints published by your target?" y || { rm -f "$kh"; return 1; }
    install -m 600 -o "$RUSER" -g "$RUSER" "$kh" "$RHOME/.ssh/known_hosts"
    rm -f "$kh"
    ui_info "Relay public key (must be authorized on the target):"
    printf '\n%s\n\n' "$(cat "$TARGET_KEY.pub")" >&2
    if ask_yn "Copy it now with ssh-copy-id (asks for the target password)?" y; then
        local sftp=()
        ask_yn "Is the target SFTP-only without a shell (e.g. a storage box)?" n && sftp=(-s)
        runuser -u "$RUSER" -- ssh-copy-id -F none "${sftp[@]}" -i "$TARGET_KEY.pub" -p "$TARGET_PORT" "$TARGET_USER@$TARGET_HOST" <"$BR_TTY" || return 1
    else
        pause "Authorize the key on the target"
    fi
    runuser -u "$RUSER" -- ssh -F none -i "$TARGET_KEY" -p "$TARGET_PORT" -o BatchMode=yes "$TARGET_USER@$TARGET_HOST" "$REMOTE_BORG --version" \
        | grep -q '^borg 1\.' || { ui_fail "'$REMOTE_BORG --version' did not run on the target"; return 1; }
}

_relay_backend() {
    if [[ $BACKEND == mount ]]; then
        _relay_mount || return 1
        # shellcheck disable=SC2034  # written by conf_write
        MOUNT_REQUIRE_MOUNTPOINT=yes
        conf_write "$BR_ETC/relay.conf" 640 "root:$RUSER" BACKEND MOUNTPOINT MOUNT_REQUIRE_MOUNTPOINT MOUNT_TYPE MOUNT_SOURCE MOUNT_OPTIONS CIFS_USER
    else
        _relay_ssh_target || return 1
        conf_write "$BR_ETC/relay.conf" 640 "root:$RUSER" BACKEND TARGET_HOST TARGET_PORT TARGET_USER TARGET_KEY REMOTE_BORG
    fi
}

_relay_sshd() {
    cat >/etc/ssh/sshd_config.d/borg-relay.conf <<CONF
# managed by borg-relay - clients may only run their forced borg command
Match User $RUSER
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AllowTcpForwarding no
    AllowStreamLocalForwarding no
    PermitTunnel no
    PermitTTY no
    X11Forwarding no
    AllowAgentForwarding no
Match all
CONF
    sshd -t && systemctl reload ssh
}

_relay_timers() {
    wiz_units borg-relay-maint.service borg-relay-maint.timer borg-relay-watch.service borg-relay-watch.timer borg-relay-notify@.service
    systemctl enable --now borg-relay-maint.timer borg-relay-watch.timer >/dev/null
}

_relay_recovery() {
    ui_header "Recovery entry for KeePassXC - RELAY $(hostname -s)"
    {
        echo "===== borg-relay RELAY $(hostname -s) ($(date -I)) ====="
        echo "Backend: $BACKEND"
        if [[ $BACKEND == mount ]]; then
            echo "Target:  $MOUNT_TYPE $MOUNT_SOURCE (options: ${MOUNT_OPTIONS:-none})"
            [[ $MOUNT_TYPE == cifs ]] && echo "SMB user: $CIFS_USER   SMB password: $CIFS_PASS"
            echo "Repos:   <share>/<client-name>"
            echo "Without the relay: mount the share anywhere, then"
            echo "  BORG_PASSPHRASE=<client passphrase> borg list /mnt/share/<client-name>"
        else
            echo "Target:  ssh://$TARGET_USER@$TARGET_HOST:$TARGET_PORT  remote borg: $REMOTE_BORG"
            echo "Repos:   <target home>/<client-name>"
            echo "Without the relay (target password or any authorized key):"
            echo "  BORG_REMOTE_PATH=$REMOTE_BORG BORG_PASSPHRASE=<client passphrase> borg list ssh://$TARGET_USER@$TARGET_HOST:$TARGET_PORT/./<client-name>"
        fi
        echo "Add a client:  borg-relay add-client <name>   then   borg-relay set-passphrase <name>"
        echo "====="
    } >&2
    pause "Copy this block into KeePassXC now"
}

relay_wizard() {
    wiz_preload "$BR_ETC/relay.conf"
    wiz_preload "$BR_ETC/notify.conf"
    step "packages" _relay_deps
    wiz_install_files
    step "relay user and directories" _relay_user
    step "storage backend" _relay_backend
    step "sshd restrictions" _relay_sshd
    NOTIFY_MODE=640 NOTIFY_OWNER="root:$RUSER" wiz_notify
    step "maintenance and watch timers" _relay_timers
    _relay_recovery
    ui_ok "Relay ready. Next: run the installer on each client."
}
