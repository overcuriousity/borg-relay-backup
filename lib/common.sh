# shellcheck shell=bash
# Shared helpers for borg-relay. Sourced, never executed.

BR_ETC="${BR_ETC:-/etc/borg-relay}"
BR_STATE="${BR_STATE:-/var/lib/borg-relay}"

log()   { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn()  { log "WARNING: $*" >&2; }
error() { log "ERROR: $*" >&2; }
die()   { error "$*"; exit 1; }

require_root() { [[ ${EUID} -eq 0 ]] || die "must be run as root"; }

# valid_name NAME - client/repo names are used as a path component on the target.
valid_name() { [[ ${1-} =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]; }

# check_private FILE - refuse secrets that "other" may access.
check_private() {
    local mode
    mode=$(stat -c '%a' "$1") || die "cannot stat $1"
    (( (8#$mode & 8#007) == 0 )) || die "$1 is world-accessible (mode $mode); fix with: chmod o-rwx $1"
}

# load_conf FILE [REQUIRED_VAR...]
load_conf() {
    local file=$1 var
    shift
    [[ -r $file ]] || die "config not readable: $file"
    check_private "$file"
    # shellcheck disable=SC1090
    source "$file"
    for var in "$@"; do
        [[ -n ${!var:-} ]] || die "$file: required setting $var is empty"
    done
}
