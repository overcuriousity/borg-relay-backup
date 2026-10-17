setup() {
    load test_helper
    source "$REPO_ROOT/lib/common.sh"
    source "$REPO_ROOT/lib/hooks.sh"
    TMP=$(mktemp -d); D=$TMP/hooks.d; mkdir "$D"
    mk() { printf '#!/bin/bash\necho %s >>"%s/order"\n%s\n' "$1" "$TMP" "${2:-exit 0}" >"$D/$1"; chmod +x "$D/$1"; }
}
teardown() { rm -rf "$TMP"; }

@test "lists executable hooks of one kind in lexical order" {
    mk 20-b.pre; mk 10-a.pre; mk 10-a.post
    printf 'x' >"$D/30-c.pre"   # not executable
    bats_require_minimum_version 1.5.0
    run --separate-stderr hooks_list "$D" pre
    [ "$output" = "$D/10-a.pre"$'\n'"$D/20-b.pre" ]
    [[ $stderr == *"30-c.pre is not executable"* ]]
}

@test "missing directory is not an error" {
    run hooks_list "$TMP/nope" pre
    [ "$status" -eq 0 ]; [ -z "$output" ]
    run hooks_run "$TMP/nope" pre
    [ "$status" -eq 0 ]
}

@test "pre hooks stop at the first failure and return its code" {
    mk 10-a.pre; mk 20-b.pre "exit 3"; mk 30-c.pre
    run hooks_run "$D" pre
    [ "$status" -eq 3 ]
    [ "$(cat "$TMP/order")" = $'10-a.pre\n20-b.pre' ]
}

@test "post hooks all run; first failure code is returned" {
    mk 10-a.post "exit 4"; mk 20-b.post "exit 5"; mk 30-c.post
    run hooks_run "$D" post
    [ "$status" -eq 4 ]
    [ "$(cat "$TMP/order")" = $'10-a.post\n20-b.post\n30-c.post' ]
}

@test "hooks cannot swallow the hook list via stdin" {
    mk 10-a.pre "cat >/dev/null"; mk 20-b.pre
    run hooks_run "$D" pre
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP/order")" = $'10-a.pre\n20-b.pre' ]
}

@test "non-executable hook files are reported" {
    printf 'x' >"$D/10-a.pre"
    run hooks_run "$D" pre
    [[ $output == *"not executable"* ]]
}
