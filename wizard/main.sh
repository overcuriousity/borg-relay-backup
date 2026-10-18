#!/bin/bash
# Interactive installer entry point (started by install.sh).
set -euo pipefail
export LC_ALL=C
SRC=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
PREFIX=/usr/local/lib/borg-relay
# shellcheck source=../lib/common.sh
source "$SRC/lib/common.sh"
# shellcheck source=../lib/ui.sh
source "$SRC/lib/ui.sh"
# shellcheck source=../lib/borg.sh
source "$SRC/lib/borg.sh"
# shellcheck source=../lib/notify.sh
source "$SRC/lib/notify.sh"
# shellcheck source=../lib/dbdump.sh
source "$SRC/lib/dbdump.sh"
# shellcheck source=common.sh
source "$SRC/wizard/common.sh"

require_root
grep -q '^13' /etc/debian_version 2>/dev/null || ui_info "Note: this installer is tested on Debian 13 only."
ui_header "borg-relay-backup $(cat "$SRC/VERSION") installer"
ui_info "Each step is verified before the next one starts. You can run the installer again at any time;
   your previous answers are offered as defaults."

ROLE=
ask ROLE "Role of this machine ('relay' or 'client')" client
case $ROLE in
    relay)  # shellcheck source=relay.sh
            source "$SRC/wizard/relay.sh";  relay_wizard ;;
    client) # shellcheck source=client.sh
            source "$SRC/wizard/client.sh"; client_wizard ;;
    *)      die "Unknown role '$ROLE'. Please answer 'relay' or 'client'." ;;
esac
