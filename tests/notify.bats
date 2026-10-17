setup() {
    load test_helper
    source "$REPO_ROOT/lib/common.sh"
    source "$REPO_ROOT/lib/notify.sh"
    TMP=$(mktemp -d)
    unset GOTIFY_URL GOTIFY_TOKEN GOTIFY_INSECURE UP_ENDPOINT UP_MAX_BYTES NOTIFY_STRICT
    # curl stand-in: records args, the contents of -K config files, and stdin bodies
    curl() {
        local a prev=
        for a in "$@"; do
            [[ $prev == -K ]] && cat "$a" >>"$TMP/cfg"
            printf '%s\n' "$a" >>"$TMP/args"
            prev=$a
        done
        [[ " $* " == *" @- "* ]] && cat >"$TMP/body"
        return "${CURL_RC:-0}"
    }
}
teardown() { rm -rf "$TMP"; }

@test "priority per level" {
    [ "$(notify_priority failure)" = 8 ]
    [ "$(notify_priority warning)" = 5 ]
    [ "$(notify_priority success)" = 3 ]
}

@test "clip keeps the tail and marks truncation" {
    [ "$(notify_clip 10 short)" = short ]
    run notify_clip 4 "abcdefgh"
    [ "$output" = $'[…truncated]\nefgh' ]
}

@test "no backend configured: nothing is sent" {
    notify_send failure t b
    [ ! -e "$TMP/args" ]
}

@test "gotify: token in header via config file, not on the command line" {
    GOTIFY_URL=https://g.example/ GOTIFY_TOKEN=s3cret
    notify_send failure "the title" "the body"
    grep -qx 'url = "https://g.example/message"' "$TMP/cfg"
    grep -qx 'header = "X-Gotify-Key: s3cret"' "$TMP/cfg"
    refute grep -q s3cret "$TMP/args"
    grep -qx 'title=the title' "$TMP/args"
    grep -qx 'priority=8' "$TMP/args"
    refute grep -qx -- -k "$TMP/args"
}

@test "gotify insecure adds -k" {
    GOTIFY_URL=https://g GOTIFY_TOKEN=t GOTIFY_INSECURE=yes
    notify_send success t b
    grep -qx -- -k "$TMP/args"
}

@test "unifiedpush: posts title, blank line, clipped body" {
    UP_ENDPOINT=https://up.example/push/abc UP_MAX_BYTES=3
    notify_send warning "T" "xxxyyy"
    grep -qx 'url = "https://up.example/push/abc"' "$TMP/cfg"
    [ "$(cat "$TMP/body")" = $'T\n\n[…truncated]\nyyy' ]
}

@test "backend failure is swallowed unless NOTIFY_STRICT=1" {
    UP_ENDPOINT=https://up CURL_RC=7
    run notify_send failure t b
    [ "$status" -eq 0 ]
    [[ $output == *"unifiedpush notification failed"* ]]
    NOTIFY_STRICT=1
    run notify_send failure t b
    [ "$status" -ne 0 ]
}

@test "notify_load reads notify.conf when present" {
    export BR_ETC=$TMP
    printf 'UP_ENDPOINT=https://x\n' >"$TMP/notify.conf"; chmod 600 "$TMP/notify.conf"
    notify_load
    [ "$UP_ENDPOINT" = https://x ]
}
