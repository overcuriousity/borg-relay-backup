#!/bin/bash
# borg-relay installer bootstrap.
#   bash <(curl -fsSL https://raw.githubusercontent.com/overcuriousity/borg-relay-backup/v1.0.3/install.sh)
# Downloads the tagged release and starts the interactive wizard.
set -euo pipefail
REPO_SLUG=overcuriousity/borg-relay-backup
REF=${BR_REF:-v1.0.3}

self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -f $self_dir/wizard/main.sh ]]; then
    exec bash "$self_dir/wizard/main.sh" "$@"      # running from a checkout
fi
[[ ${EUID} -eq 0 ]] || { echo "Please run as root." >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo "Downloading borg-relay-backup $REF ..." >&2
curl -fsSL "https://github.com/$REPO_SLUG/archive/refs/tags/$REF.tar.gz" | tar -xz -C "$tmp" --strip-components=1
bash "$tmp/wizard/main.sh" "$@"
