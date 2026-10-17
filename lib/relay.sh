# shellcheck shell=bash disable=SC2034  # some functions return results in globals
# Relay-side helpers. Needs common.sh + borg.sh; the caller loads relay.conf.
BR_LIBEXEC="${BR_LIBEXEC:-/usr/local/lib/borg-relay/bin}"

relay_authorized_line() {
    local name=$1 key=$2 type blob
    valid_name "$name" || { error "invalid client name: '$name'"; return 1; }
    read -r type blob _ <<<"$key"
    if [[ ! ${type-} =~ ^(ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa|sk-ssh-ed25519@openssh\.com)$ \
          || ! ${blob-} =~ ^[A-Za-z0-9+/]+=*$ ]]; then
        error "not an SSH public key"
        return 1
    fi
    printf 'restrict,command="%s/borg-relay-serve %s" %s %s borg-relay:%s\n' \
        "$BR_LIBEXEC" "$name" "$type" "$blob" "$name"
}

_target_key() { printf '%s' "${TARGET_KEY:-$BR_STATE/.ssh/target_ed25519}"; }

relay_serve_argv() {
    local name=$1
    case ${BACKEND:-} in
        mount)
            RELAY_SERVE_CWD=$MOUNTPOINT
            borg_serve_argv "$name"
            RELAY_SERVE_ARGV=("${BORG_SERVE_ARGV[@]}")
            ;;
        ssh-borg)
            RELAY_SERVE_CWD=
            RELAY_SERVE_ARGV=(ssh -i "$(_target_key)" -p "${TARGET_PORT:-22}"
                -o BatchMode=yes -o StrictHostKeyChecking=yes -o ServerAliveInterval=30
                "${TARGET_USER}@${TARGET_HOST}"
                "$(borg_serve_cmdline "${REMOTE_BORG:-borg}" "$name")")
            ;;
        *)
            error "relay.conf: BACKEND must be 'mount' or 'ssh-borg' (got '${BACKEND:-}')"
            return 1
            ;;
    esac
}

relay_mount_ready() {
    [[ ${MOUNT_REQUIRE_MOUNTPOINT:-yes} == no ]] && return 0
    ls "$MOUNTPOINT" >/dev/null 2>&1   # triggers the automount
    mountpoint -q "$MOUNTPOINT"
}

relay_repo_location() {
    case $BACKEND in
        mount)    printf '%s/%s\n' "$MOUNTPOINT" "$1" ;;
        ssh-borg) printf 'ssh://%s@%s:%s/./%s\n' "$TARGET_USER" "$TARGET_HOST" "${TARGET_PORT:-22}" "$1" ;;
    esac
}

relay_borg_env() {
    if [[ $BACKEND == ssh-borg ]]; then
        BORG_RSH="ssh -i $(_target_key) -o BatchMode=yes -o StrictHostKeyChecking=yes -o ServerAliveInterval=30"
        BORG_REMOTE_PATH=${REMOTE_BORG:-borg}
        export BORG_RSH BORG_REMOTE_PATH
    fi
}

tamper_missing()    { comm -23 <(sort -u "$1") <(sort -u "$2"); }
archive_age_hours() { echo $(( ($1 - $2) / 3600 )); }
