setup() {
    load test_helper
    TMP=$(mktemp -d)
    export BR_ETC=$TMP/etc BR_STATE=$TMP/state
    mkdir -p "$BR_ETC" "$TMP/target" "$TMP/src"
    cat >"$BR_ETC/relay.conf" <<CONF
BACKEND=mount
MOUNTPOINT=$TMP/target
MOUNT_REQUIRE_MOUNTPOINT=no
CONF
    chmod 600 "$BR_ETC/relay.conf"
    export BORG_PASSPHRASE=test-pass BORG_BASE_DIR=$TMP/client-home
    export BORG_RSH="$REPO_ROOT/tests/fake-rsh alpha"
    REPO=ssh://relay/./alpha
    echo hello >"$TMP/src/file"
}
teardown() { rm -rf "$TMP"; }

@test "client inits and creates through the relay into <target>/<name>" {
    borg init -e repokey-blake2 "$REPO"
    borg create "$REPO::a1" "$TMP/src"
    [ -f "$TMP/target/alpha/config" ]
    [ "$(borg list --short "$REPO")" = a1 ]
}

@test "the relay serves append-only" {
    borg init -e repokey-blake2 "$REPO"
    borg create "$REPO::a1" "$TMP/src"
    [ -f "$TMP/target/alpha/transactions" ]
}

@test "a client cannot open another client's repo" {
    run borg init -e repokey-blake2 ssh://relay/./beta
    [ "$status" -ne 0 ]
    [[ $output == *"not allowed"* ]]
    [ ! -e "$TMP/target/beta" ]
}

@test "refuses to serve when the target is not mounted" {
    sed -i 's/MOUNT_REQUIRE_MOUNTPOINT=no/MOUNT_REQUIRE_MOUNTPOINT=yes/' "$BR_ETC/relay.conf"
    run borg init -e repokey-blake2 "$REPO"
    [ "$status" -ne 0 ]
    [[ $output == *"not mounted"* ]]
    [ ! -e "$TMP/target/alpha" ]
}

@test "rejects an invalid name in the forced command" {
    run "$REPO_ROOT/bin/borg-relay-serve" "../alpha"
    [ "$status" -eq 1 ]
    [[ $output == *"invalid client name"* ]]
}

@test "a wrong passphrase on an existing repo is classified as 'exists'" {
    source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/ui.sh"
    borg init -e repokey-blake2 "$REPO"
    out=$(BORG_PASSPHRASE=wrong borg info "$REPO" 2>&1) || true
    [ "$(classify_borg_error "$out")" = exists ]
}

@test "the not-mounted message reliably reaches the client" {
    sed -i 's/MOUNT_REQUIRE_MOUNTPOINT=no/MOUNT_REQUIRE_MOUNTPOINT=yes/' "$BR_ETC/relay.conf"
    for _ in 1 2 3 4 5 6; do
        run borg info "$REPO"
        [[ $output == *"not mounted"* ]]
    done
}
