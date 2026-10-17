setup() {
    load test_helper
    TMP=$(mktemp -d)
    export BR_ETC=$TMP/etc BR_STATE=$TMP/state BR_RELAY_USER=root
    mkdir -p "$BR_ETC/repos.d" "$TMP/target" "$TMP/src"
    cat >"$BR_ETC/relay.conf" <<CONF
BACKEND=mount
MOUNTPOINT=$TMP/target
MOUNT_REQUIRE_MOUNTPOINT=no
CONF
    chmod 600 "$BR_ETC/relay.conf"
    echo hello >"$TMP/src/file"
    RELAY="$REPO_ROOT/bin/borg-relay"
    REPO=ssh://relay/./alpha
    KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMk0nG5Z7rKk+abc/def= root@nc"
}
teardown() { rm -rf "$TMP"; }

# client-side borg (own base dir, through the forced command)
cborg() { BORG_PASSPHRASE=pw BORG_BASE_DIR=$TMP/client-home BORG_RSH="$REPO_ROOT/tests/fake-rsh alpha" borg "$@"; }
# relay-side command (own base dir)
relay() { BORG_BASE_DIR=$TMP/relay-home "$RELAY" "$@"; }

init_alpha() {
    cborg init -e repokey-blake2 "$REPO"
    echo pw | relay set-passphrase alpha
}

@test "add-client writes a restricted line and replaces it on re-add" {
    echo "$KEY" | relay add-client alpha
    echo "$KEY" | relay add-client alpha
    [ "$(grep -c 'borg-relay:alpha$' "$BR_STATE/.ssh/authorized_keys")" = 1 ]
    grep -q '^restrict,command="' "$BR_STATE/.ssh/authorized_keys"
}

@test "add-client rejects garbage" {
    run bash -c "echo nope | BORG_BASE_DIR=$TMP/rh $RELAY add-client alpha"
    [ "$status" -ne 0 ]
}

@test "set-passphrase writes a private conf and verifies it" {
    init_alpha
    [ "$(stat -c %a "$BR_ETC/repos.d/alpha.conf")" = 600 ]
    run bash -c "echo wrong | BORG_BASE_DIR=$TMP/rh2 $RELAY set-passphrase alpha"
    [ "$status" -ne 0 ]
}

@test "maint prunes, compacts and records the archive list" {
    init_alpha
    sed -i "s/^KEEP=.*/KEEP=--keep-last=1/" "$BR_ETC/repos.d/alpha.conf"
    cborg create "$REPO::a1" "$TMP/src"
    cborg create "$REPO::a2" "$TMP/src"
    relay maint
    [ "$(cat "$BR_STATE/state/alpha.archives")" = a2 ]
}

@test "maint detects archives deleted by a client and skips the repo" {
    init_alpha
    cborg create "$REPO::a1" "$TMP/src"
    cborg create "$REPO::a2" "$TMP/src"
    relay maint
    cborg delete "$REPO::a1"
    run relay maint
    [ "$status" -eq 1 ]
    [[ $output == *"possible tampering"* ]]
    [ "$(cat "$BR_STATE/state/alpha.archives")" = $'a1\na2' ]
}

@test "maint refuses when the target is not mounted" {
    init_alpha
    sed -i 's/MOUNT_REQUIRE_MOUNTPOINT=no/MOUNT_REQUIRE_MOUNTPOINT=yes/' "$BR_ETC/relay.conf"
    run relay maint
    [ "$status" -eq 1 ]
    [[ $output == *"not mounted"* ]]
}

@test "maint waits for a lock held by a running backup" {
    init_alpha
    cborg create "$REPO::a1" "$TMP/src"
    BORG_PASSPHRASE=pw BORG_BASE_DIR=$TMP/relay-home borg with-lock "$TMP/target/alpha" sleep 4 &
    sleep 1
    relay maint
    wait
}

@test "watch passes for a fresh archive and fails when stale or empty" {
    init_alpha
    run relay watch
    [ "$status" -eq 1 ]; [[ $output == *"no archives"* ]]
    cborg create "$REPO::a1" "$TMP/src"
    relay watch
    sed -i "s/^MAX_AGE_HOURS=.*/MAX_AGE_HOURS=0/" "$BR_ETC/repos.d/alpha.conf"
    run relay watch
    [ "$status" -eq 1 ]; [[ $output == *"old (limit 0h)"* ]]
}
