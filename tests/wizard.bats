# Wizard step functions, run with stubs (no apt, no systemd, no network).
setup() {
    load test_helper
    TMP=$(mktemp -d)
    export BR_ETC=$TMP/etc BR_TTY=$TMP/tty
    mkdir -p "$BR_ETC"
    SRC=$REPO_ROOT PREFIX=$TMP/prefix
    source "$REPO_ROOT/lib/common.sh"
    source "$REPO_ROOT/lib/ui.sh"
    source "$REPO_ROOT/lib/borg.sh"
    source "$REPO_ROOT/lib/notify.sh"
    source "$REPO_ROOT/lib/dbdump.sh"
    source "$REPO_ROOT/wizard/common.sh"
}
teardown() { rm -rf "$TMP"; }

@test "relay user gets a shell that can run the forced command" {
    source "$REPO_ROOT/wizard/relay.sh"
    id() { return 1; }
    useradd() { echo "useradd $*" >>"$TMP/calls"; }
    usermod() { echo "usermod $*" >>"$TMP/calls"; }
    install() { :; }
    _relay_user
    grep -q -- '--shell /bin/sh' "$TMP/calls"
    id() { return 0; }
    : >"$TMP/calls"
    _relay_user
    grep -q 'usermod -s /bin/sh borgrelay' "$TMP/calls"
}

@test "client wizard detects an existing encrypted repository (host rebuild)" {
    source "$REPO_ROOT/wizard/client.sh"
    CLIENT_KEY=$TMP/key; echo "ssh-ed25519 AAAA x" >"$TMP/key.pub"; REPO=r
    borg_info() { echo "passphrase supplied in BORG_PASSPHRASE, by BORG_PASSCOMMAND or via BORG_PASSPHRASE_FD is incorrect." >&2; return 2; }
    printf '\n' >"$BR_TTY"
    _client_authorize
    [ "$REPO_EXISTS" = yes ]
}

@test "a generated passphrase is saved right after borg init" {
    source "$REPO_ROOT/wizard/client.sh"
    REPO_EXISTS=no BORG_PASSPHRASE= REPO=r
    RELAY_HOST=relay RELAY_PORT=22 RELAY_USER=borgrelay BACKUP_NAME=n
    gen_passphrase() { echo GENERATEDPASS; }
    borg_init() { :; }
    borg_key_export() { echo KEY; }
    printf 'y\n' >"$BR_TTY"
    _client_init
    grep -q GENERATEDPASS "$BR_ETC/client.conf"
    [ "$(stat -c %a "$BR_ETC/client.conf")" = 600 ]
}

@test "installed files are owned by root, not by the checkout's owner" {
    SRC=$TMP/src; mkdir -p "$SRC"
    cp -r "$REPO_ROOT"/{bin,lib,hooks,systemd,wizard,config,VERSION} "$SRC/"
    chown -R nobody "$SRC"
    wiz_install_files
    [ -z "$(find "$PREFIX" ! -user root)" ]
    [ -z "$(find "$PREFIX" -perm /022 ! -type l)" ]
}

@test "sshd step refuses when ssh.socket and ssh.service both own port 22" {
    source "$REPO_ROOT/wizard/relay.sh"
    SSHD_DROPIN=$TMP/borg-relay.conf
    sshd() { return 0; }
    systemctl() { echo "systemctl $*" >>"$TMP/calls"; [[ $1 == is-active ]] && return 0; return 0; }
    run _relay_sshd
    [ "$status" -ne 0 ]
    [[ $output == *"ssh.socket"* ]]
    refute grep -q 'reload' "$TMP/calls"
}

@test "sshd step verifies that sshd still runs after the reload" {
    source "$REPO_ROOT/wizard/relay.sh"
    SSHD_DROPIN=$TMP/borg-relay.conf
    sshd() { return 0; }
    systemctl() {
        case "$1 $2" in
            "is-active --quiet") [[ $3 == ssh.socket ]] && return 1; [[ -e $TMP/reloaded ]] && return 1; return 0 ;;
            "reload ssh") touch "$TMP/reloaded" ;;
        esac
    }
    run _relay_sshd
    [ "$status" -ne 0 ]
    [[ $output == *"not running"* ]]
}

@test "choosing a database dump creates the dump folder" {
    source "$REPO_ROOT/wizard/client.sh"
    DUMP_DIR_DEFAULT=$TMP/dumps BR_ETC=$TMP/etc
    BACKUP_PATHS=(/etc) CONF_VARS=()
    printf 'pgsql\n' >"$BR_TTY"
    DB_TYPE=pgsql DB_NAME=nc DB_HOST=localhost DB_USER=u
    ask_secret() { local -n _v=$1; _v=pw; }
    _client_db
    [ -d "$TMP/dumps" ]
}

@test "preview tolerates borg warnings and shows real errors" {
    source "$REPO_ROOT/wizard/client.sh"
    REPO=r
    borg_dry_run() { echo "- /etc/a"; echo "/x: [Errno 2] No such file or directory" >&2; return 1; }
    run _client_preview
    [ "$status" -eq 0 ]
    [[ $output == *"No such file"* ]]
    borg_dry_run() { echo "Repository /x does not exist" >&2; return 2; }
    run _client_preview
    [ "$status" -ne 0 ]
    [[ $output == *"does not exist"* ]]
    borg_dry_run() { for i in $(seq 100); do echo "- /f$i"; done; return 141; }
    run _client_preview
    [ "$status" -eq 0 ]
}
