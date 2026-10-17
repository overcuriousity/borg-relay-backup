# shellcheck shell=bash disable=SC2034  # some functions return results in globals
# Every borg invocation of borg-relay lives here (one place to touch for a Borg 2 move).
BORG_BIN="${BORG_BIN:-borg}"

# Backups and relay maintenance take the same repository lock: wait long for each other.
_lockwait() { printf -- '--lock-wait=%s' "${BORG_LOCK_WAIT:-21600}"; }

borg_info()       { "$BORG_BIN" info "$(_lockwait)" "$1"; }
borg_init()       { "$BORG_BIN" init --encryption=repokey-blake2 "$1"; }
borg_key_export() { "$BORG_BIN" key export "$1"; }

_borg_create_args() {
    BORG_CREATE_ARGS=(--compression "${BORG_COMPRESSION:-zstd,3}" --exclude-caches)
    local p
    for p in "${EXCLUDES[@]+"${EXCLUDES[@]}"}"; do BORG_CREATE_ARGS+=(--exclude "$p"); done
}

# borg_create_bg REPO ARCHIVE - start borg create in the background, its pid in BORG_PID
# (borg itself, not a subshell, so it can be stopped). Paths from BACKUP_PATHS, excludes from EXCLUDES.
borg_create_bg() {
    _borg_create_args
    "$BORG_BIN" create "$(_lockwait)" --stats "${BORG_CREATE_ARGS[@]}" "$1::$2" "${BACKUP_PATHS[@]}" &
    BORG_PID=$!
}

borg_dry_run() {
    _borg_create_args
    "$BORG_BIN" create --dry-run --list "${BORG_CREATE_ARGS[@]}" "$1::dry-run" "${BACKUP_PATHS[@]}"
}

borg_archive_names()      { "$BORG_BIN" list "$(_lockwait)" --short "$1"; }
# borg_archive_index REPO - "<id> <epoch> <name>" per archive (tamper check)
borg_archive_index()      { "$BORG_BIN" list "$(_lockwait)" --format '{id} {time:%s} {archive}{NL}' "$1"; }
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
