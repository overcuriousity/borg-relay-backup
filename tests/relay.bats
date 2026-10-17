setup() {
    load test_helper
    source "$REPO_ROOT/lib/common.sh"
    source "$REPO_ROOT/lib/borg.sh"
    source "$REPO_ROOT/lib/relay.sh"
    TMP=$(mktemp -d)
    KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMk0nG5Z7rKk+abc/def= root@nc"
}
teardown() { rm -rf "$TMP"; }

@test "authorized line pins the forced command and drops the key comment" {
    run relay_authorized_line nextcloud "$KEY"
    [ "$status" -eq 0 ]
    [ "$output" = 'restrict,command="/usr/local/lib/borg-relay/bin/borg-relay-serve nextcloud" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMk0nG5Z7rKk+abc/def= borg-relay:nextcloud' ]
}

@test "authorized line rejects bad names and non-keys" {
    run relay_authorized_line "../x" "$KEY";              [ "$status" -ne 0 ]
    run relay_authorized_line ok "hello world";          [ "$status" -ne 0 ]
    run relay_authorized_line ok 'ssh-ed25519 AAA" evil'; [ "$status" -ne 0 ]
    run relay_authorized_line ok "";                      [ "$status" -ne 0 ]
}

@test "mount backend serves from the mountpoint, append-only, one repo" {
    BACKEND=mount MOUNTPOINT=/srv/borgtarget
    relay_serve_argv alpha
    [ "$RELAY_SERVE_CWD" = /srv/borgtarget ]
    [ "${RELAY_SERVE_ARGV[*]}" = "borg serve --append-only --restrict-to-repository alpha" ]
}

@test "ssh-borg backend pipes to the remote borg" {
    BACKEND=ssh-borg TARGET_HOST=t.example TARGET_PORT=23 TARGET_USER=u1 TARGET_KEY=/k REMOTE_BORG=borg-1.4
    relay_serve_argv alpha
    [ -z "$RELAY_SERVE_CWD" ]
    [ "${RELAY_SERVE_ARGV[0]}" = ssh ]
    [ "${RELAY_SERVE_ARGV[-2]}" = u1@t.example ]
    [ "${RELAY_SERVE_ARGV[-1]}" = "borg-1.4 serve --append-only --restrict-to-repository alpha" ]
    [[ " ${RELAY_SERVE_ARGV[*]} " == *" -p 23 "* ]]
    [[ " ${RELAY_SERVE_ARGV[*]} " == *" -i /k "* ]]
    [[ " ${RELAY_SERVE_ARGV[*]} " == *" StrictHostKeyChecking=yes "* ]]
}

@test "unknown backend fails" {
    BACKEND=webdav
    run relay_serve_argv alpha
    [ "$status" -ne 0 ]
}

@test "repo location per backend" {
    BACKEND=mount MOUNTPOINT=/srv/t
    [ "$(relay_repo_location alpha)" = /srv/t/alpha ]
    BACKEND=ssh-borg TARGET_HOST=h TARGET_PORT=23 TARGET_USER=u
    [ "$(relay_repo_location alpha)" = "ssh://u@h:23/./alpha" ]
}

@test "relay_borg_env sets remote path only for ssh-borg" {
    unset BORG_RSH BORG_REMOTE_PATH
    BACKEND=mount; relay_borg_env
    [ -z "${BORG_REMOTE_PATH:-}" ]
    BACKEND=ssh-borg TARGET_KEY=/k REMOTE_BORG=borg-1.4; relay_borg_env
    [ "$BORG_REMOTE_PATH" = borg-1.4 ]
    [[ $BORG_RSH == "ssh -i /k "* ]]
}

@test "mount readiness can be relaxed only by config" {
    BACKEND=mount MOUNTPOINT=$TMP MOUNT_REQUIRE_MOUNTPOINT=yes
    run relay_mount_ready; [ "$status" -ne 0 ]
    MOUNT_REQUIRE_MOUNTPOINT=no
    run relay_mount_ready; [ "$status" -eq 0 ]
}

@test "tamper_missing lists archives that disappeared" {
    printf 'a1\na2\na3\n' >"$TMP/prev"
    printf 'a1\na3\na4\n' >"$TMP/cur"
    [ "$(tamper_missing "$TMP/prev" "$TMP/cur")" = a2 ]
    printf 'a1\na2\na3\na4\n' >"$TMP/cur"
    [ -z "$(tamper_missing "$TMP/prev" "$TMP/cur")" ]
}

@test "archive age in whole hours" {
    [ "$(archive_age_hours 100000 100000)" = 0 ]
    [ "$(archive_age_hours 100000 $((100000 - 26*3600 - 5)))" = 26 ]
}

@test "remote serve command quotes the name" {
    [ "$(borg_serve_cmdline borg alpha)" = "borg serve --append-only --restrict-to-repository alpha" ]
}
