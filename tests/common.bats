setup() {
    load test_helper
    source "$REPO_ROOT/lib/common.sh"
    TMP=$(mktemp -d)
}
teardown() { rm -rf "$TMP"; }

@test "valid_name accepts host-like names" {
    valid_name nextcloud
    valid_name cc24-cloud
    valid_name a
}

@test "valid_name rejects traversal, options, case, empty, too long" {
    for bad in ../etc -x Docs "" a/b "a b" "$(printf 'a%.0s' {1..64})"; do
        run valid_name "$bad"
        [ "$status" -ne 0 ]
    done
}

@test "load_conf sources the file and checks required vars" {
    printf 'FOO=bar\nEMPTY=\n' >"$TMP/c"; chmod 600 "$TMP/c"
    load_conf "$TMP/c" FOO
    [ "$FOO" = bar ]
    run load_conf "$TMP/c" EMPTY
    [ "$status" -eq 1 ]
    [[ $output == *"required setting EMPTY is empty"* ]]
}

@test "load_conf accepts group-readable, refuses world-readable" {
    printf 'FOO=bar\n' >"$TMP/c"
    chmod 640 "$TMP/c"; load_conf "$TMP/c" FOO
    chmod 644 "$TMP/c"
    run load_conf "$TMP/c" FOO
    [ "$status" -eq 1 ]
    [[ $output == *"world-accessible"* ]]
}

@test "load_conf fails on a missing file" {
    run load_conf "$TMP/missing"
    [ "$status" -eq 1 ]
    [[ $output == *"not readable"* ]]
}
