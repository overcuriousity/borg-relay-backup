setup() {
    load test_helper
    TMP=$(mktemp -d)
    export BR_ETC=$TMP/etc BR_STATE=$TMP/state BR_LOG_DIR=$TMP/log BR_LOCK=$TMP/lock
    mkdir -p "$BR_ETC/hooks.d" "$TMP/target" "$TMP/src" "$TMP/bin"
    cat >"$BR_ETC/relay.conf" <<CONF
BACKEND=mount
MOUNTPOINT=$TMP/target
MOUNT_REQUIRE_MOUNTPOINT=no
CONF
    cat >"$BR_ETC/client.conf" <<CONF
RELAY_HOST=relay
BACKUP_NAME=alpha
BORG_PASSPHRASE='p\$w "x"'
BACKUP_PATHS=($TMP/src)
RETRY_INTERVAL=1
RETRY_WINDOW=0
CONF
    printf 'UP_ENDPOINT=https://up.invalid/x\n' >"$BR_ETC/notify.conf"
    chmod 600 "$BR_ETC"/*.conf
    ln -s "$REPO_ROOT/tests/stubs/curl" "$TMP/bin/curl"
    export PATH=$TMP/bin:$PATH CURL_LOG=$TMP/curl.log
    export BORG_RSH="$REPO_ROOT/tests/fake-rsh alpha" BORG_BASE_DIR=$TMP/client-home
    echo hello >"$TMP/src/file"
    BORG_PASSPHRASE='p$w "x"' borg init -e repokey-blake2 ssh://borgrelay@relay:22/./alpha
    RUN="$REPO_ROOT/bin/borg-relay-backup"
}
teardown() { rm -rf "$TMP"; }

hook() { printf '#!/bin/bash\necho %s >>"%s/order"\n%s\n' "$1" "$TMP" "${2:-exit 0}" >"$BR_ETC/hooks.d/$1"; chmod +x "$BR_ETC/hooks.d/$1"; }
archives() { BORG_PASSPHRASE='p$w "x"' borg list --short ssh://borgrelay@relay:22/./alpha; }

@test "success: hooks around the archive, log written, OK notification" {
    hook 10-x.pre; hook 10-x.post
    run "$RUN"
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP/order")" = $'10-x.pre\n10-x.post' ]
    [[ $(archives) == alpha-* ]]
    ls "$BR_LOG_DIR"/*.log
    grep -q '^\[OK\] alpha: backup completed' "$CURL_LOG"
}

@test "pre hook failure: no archive, post hooks still run, exit 1" {
    hook 10-x.pre "exit 1"; hook 10-x.post
    run "$RUN"
    [ "$status" -eq 1 ]
    [ "$(cat "$TMP/order")" = $'10-x.pre\n10-x.post' ]
    [ -z "$(archives)" ]
}

@test "borg failure: post hooks run, exit 1" {
    hook 10-x.post
    echo 'BORG_COMPRESSION=bogus' >>"$BR_ETC/client.conf"   # borg create rejects it (rc 2)
    run "$RUN"
    [ "$status" -eq 1 ]
    [ "$(cat "$TMP/order")" = 10-x.post ]
}

@test "post hook failure fails the run even though the archive exists" {
    hook 10-x.post "exit 2"
    run "$RUN"
    [ "$status" -eq 1 ]
    [[ $output == *"post-backup hook failed"* ]]
    [[ $(archives) == alpha-* ]]
}

@test "warning (vanished path) still succeeds and is notified as WARNING" {
    sed -i "s|^BACKUP_PATHS=.*|BACKUP_PATHS=($TMP/src $TMP/missing)|" "$BR_ETC/client.conf"
    run "$RUN"
    [ "$status" -eq 0 ]
    grep -q '^\[WARNING\] alpha' "$CURL_LOG"
}

@test "unreachable repository: exit 1, no hooks" {
    hook 10-x.pre
    sed -i 's/MOUNT_REQUIRE_MOUNTPOINT=no/MOUNT_REQUIRE_MOUNTPOINT=yes/' "$BR_ETC/relay.conf"
    run "$RUN"
    [ "$status" -eq 1 ]
    [[ $output == *"not reachable"* ]]
    [ ! -e "$TMP/order" ]
}

@test "a second concurrent run is refused" {
    exec 8>"$BR_LOCK"; flock 8
    run "$RUN"
    [ "$status" -eq 1 ]
    [[ $output == *"in progress"* ]]
}

@test "notification failure does not fail the backup" {
    export CURL_RC=7
    run "$RUN"
    [ "$status" -eq 0 ]
}

@test "SIGTERM during the run still runs post hooks" {
    hook 10-x.pre "sleep 2"; hook 10-x.post
    "$RUN" & pid=$!
    for _ in {1..100}; do [[ -s $TMP/order ]] && break; sleep 0.1; done
    kill -TERM "$pid"
    rc=0; wait "$pid" || rc=$?     # not `run wait`: a subshell cannot wait for our job
    [ "$rc" -eq 143 ]
    grep -qx 10-x.post "$TMP/order"
}

@test "SIGTERM during borg create stops borg before post hooks run" {
    hook 10-x.post
    printf '#!/bin/bash\nif [[ $1 == create ]]; then echo $$ >"%s/borgpid"; exec sleep 30; fi\nexec borg "$@"\n' "$TMP" >"$TMP/borgwrap"
    chmod +x "$TMP/borgwrap"
    BORG_BIN=$TMP/borgwrap "$RUN" & pid=$!
    for _ in {1..100}; do [[ -s $TMP/borgpid ]] && break; sleep 0.1; done
    kill -TERM "$pid"
    rc=0; wait "$pid" || rc=$?
    [ "$rc" -eq 143 ]
    grep -qx 10-x.post "$TMP/order"
    refute kill -0 "$(cat "$TMP/borgpid")"
}

@test "SIGTERM while post hooks run does not skip the remaining post hooks" {
    hook 10-a.post "sleep 2"; hook 20-b.post
    "$RUN" & pid=$!
    for _ in {1..300}; do grep -qx 10-a.post "$TMP/order" 2>/dev/null && break; sleep 0.1; done
    kill -TERM "$pid"
    wait "$pid" || true
    grep -qx 20-b.post "$TMP/order"
}

@test "--seed backs up without running any hooks" {
    hook 10-x.pre; hook 10-x.post
    run "$RUN" --seed
    [ "$status" -eq 0 ]
    [ ! -e "$TMP/order" ]
    [[ $(archives) == alpha-* ]]
    grep -q '^\[OK\] alpha: seed backup completed' "$CURL_LOG"
}
