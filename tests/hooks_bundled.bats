setup() {
    load test_helper
    TMP=$(mktemp -d)
    export BR_ETC=$TMP/etc BR_DUMP_DIR=$TMP/dumps CALLS=$TMP/calls
    mkdir -p "$BR_ETC" "$TMP/bin"
    # generic recording stub; pg_dump/mariadb-dump also create their output file
    for c in php runuser systemctl dpkg docker pg_dump mariadb-dump; do
        cat >"$TMP/bin/$c" <<'STUB'
#!/bin/bash
echo "$(basename "$0") $* PGPASSFILE=${PGPASSFILE-}" >>"$CALLS"
prev=
for a in "$@"; do
    [[ $prev == -f ]] && echo dump >"$a"
    [[ $a == --result-file=* ]] && echo dump >"${a#--result-file=}"
    prev=$a
done
[[ $(basename "$0") == systemctl && $1 == start && -n ${FAIL_START-} ]] && exit 1
exit 0
STUB
        chmod +x "$TMP/bin/$c"
    done
    export PATH=$TMP/bin:$PATH
}
teardown() { rm -rf "$TMP"; }

conf() { printf '%s\n' "$@" >"$BR_ETC/client.conf"; chmod 600 "$BR_ETC/client.conf"; }

@test "nextcloud pre: maintenance on, stop service, pgsql dump without password in argv" {
    conf NC_DIR=/var/www/nextcloud NC_STOP_SERVICE=nginx DB_TYPE=pgsql DB_NAME=nc DB_USER=ncu
    printf 'localhost:*:nc:ncu:secretpw\n' >"$BR_ETC/db.pgpass"; chmod 600 "$BR_ETC/db.pgpass"
    run "$REPO_ROOT/hooks/10-nextcloud.pre"
    [ "$status" -eq 0 ]
    grep -q 'maintenance:mode --on' "$CALLS"
    grep -q '^systemctl stop nginx' "$CALLS"
    grep -q "^pg_dump .*PGPASSFILE=$BR_ETC/db.pgpass" "$CALLS"
    refute grep -q secretpw "$CALLS"
    [ "$(stat -c %a "$BR_DUMP_DIR/nc.sql")" = 600 ]
    [ -f "$BR_DUMP_DIR/dpkg-selections.txt" ]
}

@test "nextcloud post: always tries both steps and reports failure" {
    conf NC_DIR=/var/www/nextcloud NC_STOP_SERVICE=nginx DB_TYPE=pgsql DB_NAME=nc DB_USER=ncu
    mkdir -p "$BR_DUMP_DIR"; echo x >"$BR_DUMP_DIR/nc.sql"
    FAIL_START=1 run "$REPO_ROOT/hooks/10-nextcloud.post"
    [ "$status" -eq 1 ]
    grep -q 'maintenance:mode --off' "$CALLS"
    [ ! -e "$BR_DUMP_DIR/nc.sql" ]
}

@test "mysql dump passes credentials only via defaults-extra-file (first option)" {
    conf DB_TYPE=mysql DB_NAME=nc
    printf '[client]\nuser=u\npassword=secretpw\n' >"$BR_ETC/db.cnf"; chmod 600 "$BR_ETC/db.cnf"
    run "$REPO_ROOT/hooks/10-db-dump.pre"
    [ "$status" -eq 0 ]
    grep -q "^mariadb-dump --defaults-extra-file=$BR_ETC/db.cnf " "$CALLS"
    refute grep -q secretpw "$CALLS"
}

@test "world-readable credentials abort the dump" {
    conf DB_TYPE=pgsql DB_NAME=nc DB_USER=u
    printf 'x\n' >"$BR_ETC/db.pgpass"; chmod 644 "$BR_ETC/db.pgpass"
    run "$REPO_ROOT/hooks/10-db-dump.pre"
    [ "$status" -ne 0 ]
    refute grep -q '^pg_dump' "$CALLS"
}

@test "paperless pre: incremental export inside the running container" {
    conf PAPERLESS_DIR=/opt/paperless
    run "$REPO_ROOT/hooks/10-paperless.pre"
    [ "$status" -eq 0 ]
    grep -q '^docker compose --project-directory /opt/paperless exec -T webserver document_exporter /usr/src/paperless/export --delete' "$CALLS"
}
