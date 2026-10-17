# shellcheck shell=bash disable=SC2034  # some functions return results in globals
# Every borg invocation of borg-relay lives here (one place to touch for a Borg 2 move).
BORG_BIN="${BORG_BIN:-borg}"

_lockwait() { printf -- '--lock-wait=%s' "${BORG_LOCK_WAIT:-600}"; }

borg_info()       { "$BORG_BIN" info "$(_lockwait)" "$1"; }
borg_init()       { "$BORG_BIN" init --encryption=repokey-blake2 "$1"; }
borg_key_export() { "$BORG_BIN" key export "$1"; }

_borg_create_args() {
    BORG_CREATE_ARGS=(--compression "${BORG_COMPRESSION:-zstd,3}" --exclude-caches)
    local p
    for p in "${EXCLUDES[@]+"${EXCLUDES[@]}"}"; do BORG_CREATE_ARGS+=(--exclude "$p"); done
}

# borg_create REPO ARCHIVE - paths from BACKUP_PATHS, excludes from EXCLUDES
borg_create() {
    _borg_create_args
    "$BORG_BIN" create "$(_lockwait)" --stats "${BORG_CREATE_ARGS[@]}" "$1::$2" "${BACKUP_PATHS[@]}"
}

borg_dry_run() {
    _borg_create_args
    "$BORG_BIN" create --dry-run --list "${BORG_CREATE_ARGS[@]}" "$1::dry-run" "${BACKUP_PATHS[@]}"
}

borg_archive_names()      { "$BORG_BIN" list "$(_lockwait)" --short "$1"; }
borg_last_archive_epoch() { "$BORG_BIN" list "$(_lockwait)" --last 1 --format '{time:%s}{NL}' "$1"; }

borg_prune()      { local repo=$1; shift; "$BORG_BIN" prune "$(_lockwait)" --list --stats "$@" "$repo"; }
borg_compact()    { "$BORG_BIN" compact "$(_lockwait)" "$1"; }
borg_check_repo() { "$BORG_BIN" check "$(_lockwait)" --repository-only "$1"; }

borg_serve_argv() {
    BORG_SERVE_ARGV=("$BORG_BIN" serve --append-only --restrict-to-repository "$1")
}

borg_serve_cmdline() {
    printf '%s serve --append-only --restrict-to-repository %q' "$1" "$2"
}
