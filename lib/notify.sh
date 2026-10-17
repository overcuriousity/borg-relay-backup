# shellcheck shell=bash
# Push notifications. Settings (all optional), from $BR_ETC/notify.conf:
#   GOTIFY_URL GOTIFY_TOKEN GOTIFY_INSECURE=yes|no
#   UP_ENDPOINT (UnifiedPush endpoint, e.g. NextPush)  UP_MAX_BYTES (default 4000)
# Secrets go to curl via a config file (process substitution), never argv.

notify_priority() {
    case $1 in
        failure) echo 8 ;;
        warning) echo 5 ;;
        *)       echo 3 ;;
    esac
}

# notify_clip MAX TEXT - keep the last MAX bytes; the end of a log matters most.
notify_clip() {
    local max=$1 text=$2
    if (( ${#text} > max )); then
        printf '[…truncated]\n%s' "${text: -max}"
    else
        printf '%s' "$text"
    fi
}

notify_load() {
    local f=$BR_ETC/notify.conf
    [[ -r $f ]] || return 0
    check_private "$f"
    # shellcheck disable=SC1090
    source "$f"
}

notify_send() {
    local level=$1 title=$2 body=$3 prio failed=0
    prio=$(notify_priority "$level")
    if [[ -n ${GOTIFY_URL:-} && -n ${GOTIFY_TOKEN:-} ]]; then
        local insecure=()
        [[ ${GOTIFY_INSECURE:-no} == yes ]] && insecure=(-k)
        if ! curl -fsS "${insecure[@]}" --max-time 30 \
            -K <(printf 'url = "%s/message"\nheader = "X-Gotify-Key: %s"\n' "${GOTIFY_URL%/}" "$GOTIFY_TOKEN") \
            --form-string "title=${title}" \
            --form-string "message=${body}" \
            --form-string "priority=${prio}" >/dev/null; then
            warn "gotify notification failed"
            failed=1
        fi
    fi
    if [[ -n ${UP_ENDPOINT:-} ]]; then
        if ! printf '%s\n\n%s' "$title" "$(notify_clip "${UP_MAX_BYTES:-4000}" "$body")" \
            | curl -fsS --max-time 30 -K <(printf 'url = "%s"\n' "$UP_ENDPOINT") \
                --data-binary @- >/dev/null; then
            warn "unifiedpush notification failed"
            failed=1
        fi
    fi
    if [[ ${NOTIFY_STRICT:-0} == 1 ]]; then return "$failed"; fi
    return 0
}
