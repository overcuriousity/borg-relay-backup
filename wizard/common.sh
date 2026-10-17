# shellcheck shell=bash
# Shared wizard steps. Expects SRC, PREFIX and the libs from wizard/main.sh.

wiz_preload() {   # wiz_preload FILE - earlier answers become defaults
    # shellcheck disable=SC1090
    [[ -r $1 ]] && source "$1"
    return 0
}

wiz_apt() {   # wiz_apt PKG... - install what is missing, then require borg 1.4
    local p missing=()
    for p in "$@"; do
        dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing+=("$p")
    done
    if (( ${#missing[@]} )); then
        ui_info "Installing packages: ${missing[*]}"
        apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null || return 1
    fi
    borg --version | grep -q '^borg 1\.4' || { ui_fail "BorgBackup 1.4 required, found: $(borg --version)"; return 1; }
}

wiz_install_files() {
    rm -rf "$PREFIX.new"
    mkdir -p "$PREFIX.new"
    cp -r "$SRC"/{bin,lib,hooks,systemd,wizard,config,VERSION} "$PREFIX.new/"
    chown -R root:root "$PREFIX.new"       # these scripts run as root
    chmod -R go-w "$PREFIX.new"
    rm -rf "$PREFIX"
    mv "$PREFIX.new" "$PREFIX"
    ln -sf "$PREFIX/bin/borg-relay" /usr/local/bin/borg-relay
    ln -sf "$PREFIX/bin/borg-relay-backup" /usr/local/bin/borg-relay-backup
}

wiz_units() {   # wiz_units UNIT... - install unit files and reload
    local u
    for u in "$@"; do install -m 644 "$PREFIX/systemd/$u" "/etc/systemd/system/$u"; done
    systemctl daemon-reload
}

# Notification settings; NOTIFY_OWNER (e.g. root:root or root:borgrelay) and NOTIFY_MODE set by caller.
_wiz_notify_check() {
    GOTIFY_URL=${GOTIFY_URL-} GOTIFY_TOKEN=${GOTIFY_TOKEN-} GOTIFY_INSECURE=${GOTIFY_INSECURE:-no} UP_ENDPOINT=${UP_ENDPOINT-}
    if ask_yn "Send notifications to Gotify?" "$([[ -n $GOTIFY_URL ]] && echo y || echo n)"; then
        ask GOTIFY_URL "Gotify URL (e.g. https://gotify.lan)"
        ask_secret GOTIFY_TOKEN "Gotify application token"
        ask GOTIFY_INSECURE "Accept a self-signed certificate (yes/no)" no
    else
        GOTIFY_URL='' GOTIFY_TOKEN=''
    fi
    if ask_yn "Send notifications to a UnifiedPush endpoint (e.g. NextPush)?" "$([[ -n $UP_ENDPOINT ]] && echo y || echo n)"; then
        ask UP_ENDPOINT "UnifiedPush endpoint URL"
    else
        UP_ENDPOINT=
    fi
    UP_MAX_BYTES=${UP_MAX_BYTES:-4000}
    conf_write "$BR_ETC/notify.conf" "$NOTIFY_MODE" "$NOTIFY_OWNER" GOTIFY_URL GOTIFY_TOKEN GOTIFY_INSECURE UP_ENDPOINT UP_MAX_BYTES
    [[ -z $GOTIFY_URL && -z $UP_ENDPOINT ]] && { ui_info "No notifications configured - you will not hear about failures."; return 0; }
    NOTIFY_STRICT=1 notify_send success "borg-relay test from $(hostname -s)" "If you can read this, notifications work." || return 1
    ask_yn "Did the test message arrive?" y
}
wiz_notify() { step "notifications" _wiz_notify_check; }
