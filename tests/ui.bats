setup() {
    load test_helper
    source "$REPO_ROOT/lib/common.sh"
    source "$REPO_ROOT/lib/ui.sh"
    TMP=$(mktemp -d)
    export BR_TTY=$TMP/tty
}
teardown() { rm -rf "$TMP"; }

@test "ask uses the answer, else the current value, else the default" {
    printf 'typed\n' >"$BR_TTY"; X=; ask X "Q" def; [ "$X" = typed ]
    printf '\n' >"$BR_TTY";      X=; ask X "Q" def; [ "$X" = def ]
    printf '\n' >"$BR_TTY";      X=old; ask X "Q" def; [ "$X" = old ]
}

@test "ask_yn honours default and answers" {
    printf '\n' >"$BR_TTY";  ask_yn "Q" y
    printf 'n\n' >"$BR_TTY"; run ask_yn "Q" y; [ "$status" -ne 0 ]
    printf 'Y\n' >"$BR_TTY"; ask_yn "Q" n
}

@test "conf_write round-trips quotes, dollars, spaces and arrays" {
    P='a$b "c" '\''d'\'' e\f'
    PATHS=("/srv/my data" '/x/$y' /etc)
    conf_write "$TMP/c" 600 "$(id -u):$(id -g)" P PATHS
    [ "$(stat -c %a "$TMP/c")" = 600 ]
    unset P PATHS
    source "$TMP/c"
    [ "$P" = 'a$b "c" '\''d'\'' e\f' ]
    [ "${#PATHS[@]}" = 3 ]
    [ "${PATHS[0]}" = "/srv/my data" ]
    [ "${PATHS[1]}" = '/x/$y' ]
}

@test "gen_passphrase gives 32 alphanumerics" {
    p=$(gen_passphrase)
    [[ $p =~ ^[A-Za-z0-9]{32}$ ]]
    [ "$p" != "$(gen_passphrase)" ]
}

@test "classify_borg_error" {
    [ "$(classify_borg_error 'Repository /x does not exist.')" = missing ]
    [ "$(classify_borg_error 'borgrelay@r: Permission denied (publickey).')" = denied ]
    [ "$(classify_borg_error 'Remote: ERROR: storage target is not mounted at /srv')" = unmounted ]
    [ "$(classify_borg_error 'ssh: connect to host r port 22: Connection refused')" = network ]
    [ "$(classify_borg_error 'something else')" = other ]
}

@test "step retries a failing check until it passes" {
    printf 'y\n' >"$BR_TTY"
    n=0; check() { n=$((n+1)); (( n >= 2 )); }
    step "the check" check
    [ "$n" = 2 ]
}

@test "step aborts when the user declines to retry" {
    printf 'n\n' >"$BR_TTY"
    check() { false; }
    run step "the check" check
    [ "$status" -eq 1 ]
    [[ $output == *"aborted at: the check"* ]]
}

@test "ask: '-' means empty even when a default exists" {
    printf -- '-\n' >"$BR_TTY"; X=nginx; ask X "Q" nginx; [ -z "$X" ]
}

@test "ask_list keeps an existing array (with spaces) on Enter" {
    printf '\n' >"$BR_TTY"; L=("/srv/my data" /etc); ask_list L "Paths" "/etc /root"
    [ "${#L[@]}" = 2 ]; [ "${L[0]}" = "/srv/my data" ]
}

@test "ask_list: default when empty, '-' clears, typed text splits" {
    printf '\n' >"$BR_TTY"; L=(); ask_list L "Paths" "/etc /root"
    [ "${L[*]}" = "/etc /root" ]
    printf -- '-\n' >"$BR_TTY"; ask_list L "Paths" "/etc"
    [ "${#L[@]}" = 0 ]
    printf 'a b\n' >"$BR_TTY"; ask_list L "Paths" "/etc"
    [ "${L[*]}" = "a b" ]
}

@test "conf_write writes an empty array as empty" {
    E=()
    conf_write "$TMP/c" 600 "$(id -u):$(id -g)" E
    unset E; source "$TMP/c"
    [ "${#E[@]}" = 0 ]
}

@test "classify_borg_error: wrong passphrase means the repo exists" {
    [ "$(classify_borg_error 'passphrase supplied in BORG_PASSPHRASE ... is incorrect.')" = exists ]
}

@test "is_borg1_version accepts versioned program names (Hetzner: borg-1.4)" {
    is_borg1_version "borg 1.4.0"
    is_borg1_version "borg-1.4 1.4.4"
    run is_borg1_version "borg 2.0.0b14";  [ "$status" -ne 0 ]
    run is_borg1_version "bash: borg: not found"; [ "$status" -ne 0 ]
}
