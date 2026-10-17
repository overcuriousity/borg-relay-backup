# shellcheck shell=bash
# Database dumps for hooks. Credentials never appear on a command line.
#   pgsql: $BR_ETC/db.pgpass  (host:port:db:user:password), DB_USER required
#   mysql: $BR_ETC/db.cnf     ([client] user=… password=…)
DUMP_DIR="${BR_DUMP_DIR:-/var/lib/borg-relay/dumps}"

dbdump_run() {
    umask 077
    mkdir -p "$DUMP_DIR"
    local out=$DUMP_DIR/$DB_NAME.sql dump
    case ${DB_TYPE:-} in
        pgsql)
            check_private "$BR_ETC/db.pgpass"
            PGPASSFILE=$BR_ETC/db.pgpass pg_dump --no-password -h "${DB_HOST:-localhost}" \
                -U "$DB_USER" -f "$out.tmp" "$DB_NAME" || return 1
            ;;
        mysql)
            check_private "$BR_ETC/db.cnf"
            dump=$(command -v mariadb-dump || command -v mysqldump) || { error "mariadb-dump not installed"; return 1; }
            "$dump" --defaults-extra-file="$BR_ETC/db.cnf" --single-transaction --routines \
                -h "${DB_HOST:-localhost}" --result-file="$out.tmp" "$DB_NAME" || return 1
            ;;
        *)
            error "DB_TYPE must be 'pgsql' or 'mysql'"
            return 1
            ;;
    esac
    mv "$out.tmp" "$out"
    log "dumped database $DB_NAME ($(du -h "$out" | cut -f1))"
}

# pgpass_line HOST DB USER PASSWORD - ':' and '\\' escaped as libpq requires
pgpass_line() {
    local esc=() f
    for f in "$@"; do f=${f//\\/\\\\}; esc+=("${f//:/\\:}"); done
    printf '%s:*:%s:%s:%s\n' "${esc[0]}" "${esc[1]}" "${esc[2]}" "${esc[3]}"
}

# mycnf_content USER PASSWORD - option-file text; quotes with the quote char the
# password does not contain, backslashes doubled
mycnf_content() {
    local user=$1 pw=${2//\\/\\\\} q='"'
    if [[ $pw == *'"'* ]]; then
        [[ $pw == *"'"* ]] && { error "the database password contains both ' and \" - not supported"; return 1; }
        q="'"
    fi
    printf '[client]\nuser="%s"\npassword=%s%s%s\n' "$user" "$q" "$pw" "$q"
}

dbdump_clean() { rm -rf "${DUMP_DIR:?}"/*; }
