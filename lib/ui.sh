# shellcheck shell=bash
# Interactive helpers for the installer. Input comes from $BR_TTY (default /dev/tty)
# so the wizard works under `bash <(curl …)`.
BR_TTY="${BR_TTY:-/dev/tty}"

ui_header() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*" >&2; }
ui_info()   { printf '   %s\n' "$*" >&2; }
ui_ok()     { printf ' \033[32m✓\033[0m %s\n' "$*" >&2; }
ui_fail()   { printf ' \033[31m✗\033[0m %s\n' "$*" >&2; }

# ask VAR QUESTION [DEFAULT] - the variable's current value wins over DEFAULT;
# answering "-" sets the variable to empty
ask() {
    local -n _ask_v=$1
    local q=$2 def ans
    def=${_ask_v:-${3-}}
    printf ' %s%s: ' "$q" "${def:+ [$def]}" >&2
    IFS= read -r ans <"$BR_TTY" || ans=
    if [[ $ans == - ]]; then _ask_v=''; else _ask_v=${ans:-$def}; fi
}

# ask_list ARRAY QUESTION DEFAULT - Enter keeps the current array as is (also entries
# with spaces), "-" empties it, typed text is split on spaces
ask_list() {
    local -n _al=$1
    local q=$2 def=$3 shown ans
    if (( ${#_al[@]} )); then shown=${_al[*]}; else shown=$def; fi
    printf ' %s (space-separated, - for none)%s: ' "$q" "${shown:+ [$shown]}" >&2
    IFS= read -r ans <"$BR_TTY" || ans=
    if [[ -z $ans ]]; then
        (( ${#_al[@]} )) || read -ra _al <<<"$def"
    elif [[ $ans == - ]]; then
        _al=()
    else
        read -ra _al <<<"$ans"
    fi
}

# ask_secret VAR QUESTION - no echo; empty input keeps an existing value
ask_secret() {
    local -n _sec_v=$1
    local q=$2 ans
    while :; do
        printf ' %s%s: ' "$q" "${_sec_v:+ [keep current]}" >&2
        IFS= read -r -s ans <"$BR_TTY" || ans=
        printf '\n' >&2
        [[ -n $ans ]] && { _sec_v=$ans; return 0; }
        [[ -n ${_sec_v:-} ]] && return 0
        ui_fail "must not be empty"
    done
}

ask_yn() {
    local q=$1 def=$2 ans
    printf ' %s [%s]: ' "$q" "$([[ $def == y ]] && echo Y/n || echo y/N)" >&2
    IFS= read -r ans <"$BR_TTY" || ans=
    ans=${ans:-$def}
    [[ $ans == [Yy]* ]]
}

pause() { printf ' %s - press Enter to continue ' "$1" >&2; read -r _ <"$BR_TTY" || true; }

# step DESC FN - run FN (which asks and verifies); on failure offer a retry
step() {
    local desc=$1 fn=$2
    while :; do
        if "$fn"; then ui_ok "$desc"; return 0; fi
        ui_fail "$desc"
        ask_yn "Retry (you can change your answers)?" y || die "aborted at: $desc"
    done
}

# conf_write FILE MODE OWNER VAR... - VAR=value lines (arrays too), %q-quoted, atomic
conf_write() {
    local file=$1 mode=$2 owner=$3 var tmp
    shift 3
    tmp=$(mktemp "$(dirname "$file")/.conf.XXXXXX")
    {
        printf '# written by the borg-relay installer on %s\n' "$(date -I)"
        for var in "$@"; do
            if [[ $(declare -p "$var" 2>/dev/null) =~ ^declare\ -[A-Za-z]*a ]]; then
                local -n _cw_a=$var
                printf '%s=(' "$var"
                (( ${#_cw_a[@]} )) && printf ' %q' "${_cw_a[@]}"
                printf ' )\n'
                unset -n _cw_a
            else
                printf '%s=%q\n' "$var" "${!var-}"
            fi
        done
    } >"$tmp"
    chmod "$mode" "$tmp"
    chown "$owner" "$tmp"
    mv -f "$tmp" "$file"
}

# is_borg1_version TEXT - output of `<borg> --version`; the program name may carry a
# version suffix (e.g. "borg-1.4 1.4.4" on storage boxes)
is_borg1_version() { [[ $1 =~ ^borg(-[0-9.]+)?\ 1\. ]]; }

gen_passphrase() {
    python3 -c 'import secrets, string; a = string.ascii_letters + string.digits; print("".join(secrets.choice(a) for _ in range(32)))'
}

classify_borg_error() {
    case $1 in
        *"passphrase supplied"*"is incorrect"*) echo exists ;;
        *"does not exist"*)    echo missing ;;
        *"Permission denied"*) echo denied ;;
        *"not mounted"*)       echo unmounted ;;
        *"Connection refused"*|*"timed out"*|*"No route"*|*"Could not resolve"*|*"Name or service not known"*) echo network ;;
        *)                     echo other ;;
    esac
}
