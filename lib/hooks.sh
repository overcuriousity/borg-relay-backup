# shellcheck shell=bash
# Drop-in hooks: DIR/NN-name.pre runs before, DIR/NN-name.post after borg create.

hooks_list() {
    local dir=$1 kind=$2 f
    [[ -d $dir ]] || return 0
    for f in "$dir"/*."$kind"; do
        [[ -f $f ]] || continue
        if [[ -x $f ]]; then printf '%s\n' "$f"; else warn "hook $(basename "$f") is not executable - skipped"; fi
    done
    return 0
}

hooks_run() {
    local dir=$1 kind=$2 hook hrc rc=0
    while IFS= read -r hook; do
        log "hook: $(basename "$hook")"
        "$hook" </dev/null
        hrc=$?
        if (( hrc != 0 )); then
            error "hook $(basename "$hook") failed (exit $hrc)"
            (( rc == 0 )) && rc=$hrc
            [[ $kind == pre ]] && break
        fi
    done < <(hooks_list "$dir" "$kind")
    return "$rc"
}
