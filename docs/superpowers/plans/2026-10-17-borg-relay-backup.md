# borg-relay-backup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A public, target-agnostic borg backup system for unprivileged LXC clients behind a single relay, with an interactive one-line installer.

**Architecture:** Clients run `borg create` over SSH to the relay. Each client key on the relay is pinned to the forced command `borg-relay-serve <name>`, which serves exactly one repo append-only, either from a mounted target (`mount`) or by piping to `borg serve` on an SSH target (`ssh-borg`). The relay also runs weekly prune/compact/check with a tamper check and a daily missed-run check. Failures surface via systemd `OnFailure=` → push notification.

**Tech Stack:** bash 5, BorgBackup 1.4, OpenSSH, systemd, curl; tests with bats + shellcheck inside a `debian:trixie` container (podman locally, GitHub Actions in CI).

**Spec:** `docs/superpowers/specs/2026-10-17-borg-relay-backup-design.md`

## Global Constraints

- Target OS: Debian 13 (trixie); BorgBackup 1.4 from Debian. No Borg 2.
- Every borg invocation lives in `lib/borg.sh` (except `borg` calls inside tests).
- Nothing site-specific in the repo: no IPs, hostnames, mail addresses, tokens.
- Clients never learn what the target is; only `relay.conf` knows.
- Client names: `^[a-z0-9][a-z0-9-]{0,62}$`.
- Installed prefix: `/usr/local/lib/borg-relay` (`bin/`, `lib/`, `hooks/`, `systemd/`, `wizard/`); config `/etc/borg-relay`; relay state/home `/var/lib/borg-relay`; relay user `borgrelay`.
- Secrets files must not be accessible by "other" (`load_conf` refuses them).
- Scripts set `LC_ALL=C`; all scripts pass `shellcheck -x`.
- Notification failures never change an exit code.
- Retention default `--keep-within=7d --keep-weekly=4 --keep-monthly=6`; `MAX_AGE_HOURS` default 26; `RETRY_INTERVAL` 60 s, `RETRY_WINDOW` 3600 s; compression `zstd,3`; archive name `<name>-{now:%Y-%m-%dT%H:%M:%S}`.

## Review Focus

1. A client key used with a crafted name or a path to another client's repo must never reach another repo — pinned by `valid_name` tests (Task 1) and the cross-repo integration test (Task 5).
2. The mount dropping out (target not mounted) must stop serving and stop maintenance instead of writing into the bare directory — serve test (Task 5) and maint test (Task 6).
3. A client backup running while the relay's maintenance runs must not make either fail on the repo lock — lock-wait test (Task 6).
4. Post hooks (Nextcloud maintenance mode off, services back on) must run when borg fails or the run is terminated by systemd — failure and SIGTERM tests (Task 7).
5. Passphrases and paths containing quotes, `$`, spaces must survive the installer's config writing and re-sourcing — `conf_write` round-trip test (Task 10).

---

## File Structure

```
install.sh                 bootstrap: fetch tagged tarball, run wizard/main.sh
VERSION                    release version
Makefile                   make test / lint / check (podman)
lib/common.sh              log/die, valid_name, check_private, load_conf
lib/borg.sh                ALL borg invocations
lib/notify.sh              gotify + unifiedpush sending
lib/hooks.sh               hooks.d listing and running
lib/relay.sh               relay pure helpers: authorized line, serve argv, repo location, tamper, age
lib/dbdump.sh              pgsql/mysql dumps for hooks
lib/ui.sh                  wizard prompts, step/retry, conf_write, gen_passphrase, classify_borg_error
bin/borg-relay-serve       forced command on the relay
bin/borg-relay             relay admin: add-client, set-passphrase, list, maint, watch, _verify
bin/borg-relay-backup      client run
bin/borg-relay-notify      OnFailure= handler (both roles)
hooks/10-nextcloud.pre|post, 10-db-dump.pre|post, 10-paperless.pre
systemd/*.service|*.timer
config/*.example
wizard/main.sh, wizard/common.sh, wizard/relay.sh, wizard/client.sh
tests/Containerfile, tests/lint.sh, tests/test_helper.bash, tests/fake-rsh, tests/stubs/curl, tests/*.bats
.github/workflows/ci.yml
README.md SETUP.md RESTORE.md docs/rollout-checklist.md LICENSE
```

---

### Task 1: Scaffold, test harness, `lib/common.sh`

**Files:**
- Create: `Makefile`, `VERSION`, `LICENSE` (MIT, holder "overcuriousity"), `.gitignore`, `tests/Containerfile`, `tests/lint.sh`, `tests/test_helper.bash`, `.github/workflows/ci.yml`, `lib/common.sh`
- Test: `tests/common.bats`

**Interfaces:**
- Produces: `log MSG`, `warn MSG`, `error MSG`, `die MSG` (exit 1), `require_root`, `valid_name NAME` (rc), `check_private FILE` (dies if mode has other-bits), `load_conf FILE [VAR...]` (sources, dies on missing/empty); globals `BR_ETC` (default `/etc/borg-relay`), `BR_STATE` (default `/var/lib/borg-relay`).

- [ ] **Step 1: Harness files**

`tests/Containerfile`:
```dockerfile
FROM docker.io/library/debian:trixie
RUN apt-get update \
 && apt-get install -y --no-install-recommends bats shellcheck borgbackup openssh-client python3 curl ca-certificates util-linux procps \
 && rm -rf /var/lib/apt/lists/*
```

`tests/lint.sh`:
```bash
#!/bin/bash
# Lint every shell file in the repo.
set -euo pipefail
cd "$(dirname "$0")/.."
mapfile -t files < <(ls install.sh bin/* lib/*.sh wizard/*.sh hooks/* tests/fake-rsh tests/stubs/* tests/lint.sh 2>/dev/null)
shellcheck -x -P SCRIPTDIR "${files[@]}"
echo "shellcheck: ${#files[@]} files ok"
```

`Makefile`:
```make
IMAGE := borg-relay-test
RUN   := podman run --rm -v $(CURDIR):/src:Z -w /src $(IMAGE)

.PHONY: image test lint check
image:
	podman build -q -t $(IMAGE) -f tests/Containerfile tests >/dev/null
test: image
	$(RUN) bats tests
lint: image
	$(RUN) tests/lint.sh
check: lint test
```

`.github/workflows/ci.yml`:
```yaml
name: ci
on: [push, pull_request]
jobs:
  check:
    runs-on: ubuntu-latest
    container: debian:trixie
    steps:
      - run: apt-get update && apt-get install -y --no-install-recommends bats shellcheck borgbackup openssh-client python3 curl ca-certificates util-linux procps git
      - uses: actions/checkout@v4
      - run: tests/lint.sh
      - run: bats tests
```

`tests/test_helper.bash`:
```bash
# shellcheck shell=bash
REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
export REPO_ROOT LC_ALL=C

# refute CMD... - fail the test if CMD succeeds (a bare `! cmd` never fails a bats test)
refute() { if "$@"; then return 1; fi; }
```

`VERSION`: `1.0.0`. `.gitignore`: `*.swp`.

- [ ] **Step 2: Write the failing tests** — `tests/common.bats`:
```bash
setup() {
    load test_helper
    source "$REPO_ROOT/lib/common.sh"
    TMP=$(mktemp -d)
}
teardown() { rm -rf "$TMP"; }

@test "valid_name accepts host-like names" {
    valid_name nextcloud
    valid_name cc24-cloud
    valid_name a
}

@test "valid_name rejects traversal, options, case, empty, too long" {
    for bad in ../etc -x Docs "" a/b "a b" "$(printf 'a%.0s' {1..64})"; do
        run valid_name "$bad"
        [ "$status" -ne 0 ]
    done
}

@test "load_conf sources the file and checks required vars" {
    printf 'FOO=bar\nEMPTY=\n' >"$TMP/c"; chmod 600 "$TMP/c"
    load_conf "$TMP/c" FOO
    [ "$FOO" = bar ]
    run load_conf "$TMP/c" EMPTY
    [ "$status" -eq 1 ]
    [[ $output == *"required setting EMPTY is empty"* ]]
}

@test "load_conf accepts group-readable, refuses world-readable" {
    printf 'FOO=bar\n' >"$TMP/c"
    chmod 640 "$TMP/c"; load_conf "$TMP/c" FOO
    chmod 644 "$TMP/c"
    run load_conf "$TMP/c" FOO
    [ "$status" -eq 1 ]
    [[ $output == *"world-accessible"* ]]
}

@test "load_conf fails on a missing file" {
    run load_conf "$TMP/missing"
    [ "$status" -eq 1 ]
    [[ $output == *"not readable"* ]]
}
```

- [ ] **Step 3: Run, expect failure**

Run: `make test`
Expected: FAIL (`lib/common.sh` does not exist).

- [ ] **Step 4: Implement `lib/common.sh`**
```bash
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
```

- [ ] **Step 5: Run tests and lint, expect pass**

Run: `make check`
Expected: lint ok, 5 tests pass.

- [ ] **Step 6: Commit**
```bash
git add -A && git commit -m "feat: scaffold, test harness and common helpers"
```

---

### Task 2: Notifications — `lib/notify.sh`, `bin/borg-relay-notify`

**Files:**
- Create: `lib/notify.sh`, `bin/borg-relay-notify`, `tests/stubs/curl`
- Test: `tests/notify.bats`

**Interfaces:**
- Consumes: `log`, `warn`, `check_private`, `BR_ETC` (Task 1).
- Produces: `notify_priority LEVEL` → 8|5|3; `notify_clip MAX TEXT` → last MAX bytes, prefixed `[…truncated]` when clipped; `notify_load` (sources `$BR_ETC/notify.conf` if present); `notify_send LEVEL TITLE BODY` → returns 0, or non-zero only when `NOTIFY_STRICT=1` and a backend failed. Levels: `success|warning|failure`. Settings: `GOTIFY_URL GOTIFY_TOKEN GOTIFY_INSECURE UP_ENDPOINT UP_MAX_BYTES`.

- [ ] **Step 1: Write the failing tests** — `tests/notify.bats`:
```bash
setup() {
    load test_helper
    source "$REPO_ROOT/lib/common.sh"
    source "$REPO_ROOT/lib/notify.sh"
    TMP=$(mktemp -d)
    unset GOTIFY_URL GOTIFY_TOKEN GOTIFY_INSECURE UP_ENDPOINT UP_MAX_BYTES NOTIFY_STRICT
    # curl stand-in: records args, the contents of -K config files, and stdin bodies
    curl() {
        local a prev=
        for a in "$@"; do
            [[ $prev == -K ]] && cat "$a" >>"$TMP/cfg"
            printf '%s\n' "$a" >>"$TMP/args"
            prev=$a
        done
        [[ " $* " == *" @- "* ]] && cat >"$TMP/body"
        return "${CURL_RC:-0}"
    }
}
teardown() { rm -rf "$TMP"; }

@test "priority per level" {
    [ "$(notify_priority failure)" = 8 ]
    [ "$(notify_priority warning)" = 5 ]
    [ "$(notify_priority success)" = 3 ]
}

@test "clip keeps the tail and marks truncation" {
    [ "$(notify_clip 10 short)" = short ]
    run notify_clip 4 "abcdefgh"
    [ "$output" = $'[…truncated]\nefgh' ]
}

@test "no backend configured: nothing is sent" {
    notify_send failure t b
    [ ! -e "$TMP/args" ]
}

@test "gotify: token in header via config file, not on the command line" {
    GOTIFY_URL=https://g.example/ GOTIFY_TOKEN=s3cret
    notify_send failure "the title" "the body"
    grep -qx 'url = "https://g.example/message"' "$TMP/cfg"
    grep -qx 'header = "X-Gotify-Key: s3cret"' "$TMP/cfg"
    refute grep -q s3cret "$TMP/args"
    grep -qx 'title=the title' "$TMP/args"
    grep -qx 'priority=8' "$TMP/args"
    refute grep -qx -- -k "$TMP/args"
}

@test "gotify insecure adds -k" {
    GOTIFY_URL=https://g GOTIFY_TOKEN=t GOTIFY_INSECURE=yes
    notify_send success t b
    grep -qx -- -k "$TMP/args"
}

@test "unifiedpush: posts title, blank line, clipped body" {
    UP_ENDPOINT=https://up.example/push/abc UP_MAX_BYTES=3
    notify_send warning "T" "xxxyyy"
    grep -qx 'url = "https://up.example/push/abc"' "$TMP/cfg"
    [ "$(cat "$TMP/body")" = $'T\n\n[…truncated]\nyyy' ]
}

@test "backend failure is swallowed unless NOTIFY_STRICT=1" {
    UP_ENDPOINT=https://up CURL_RC=7
    run notify_send failure t b
    [ "$status" -eq 0 ]
    [[ $output == *"unifiedpush notification failed"* ]]
    NOTIFY_STRICT=1
    run notify_send failure t b
    [ "$status" -ne 0 ]
}

@test "notify_load reads notify.conf when present" {
    export BR_ETC=$TMP
    printf 'UP_ENDPOINT=https://x\n' >"$TMP/notify.conf"; chmod 600 "$TMP/notify.conf"
    notify_load
    [ "$UP_ENDPOINT" = https://x ]
}
```

- [ ] **Step 2: Run, expect failure** — `make test` → notify tests FAIL (no lib/notify.sh).

- [ ] **Step 3: Implement `lib/notify.sh`**
```bash
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
```

- [ ] **Step 4: `bin/borg-relay-notify`** (OnFailure handler; lint-only)
```bash
#!/bin/bash
# OnFailure= handler: push the failed unit's journal of its last run.
# Usage: borg-relay-notify UNIT   (from borg-relay-notify@%n.service)
set -uo pipefail
export LC_ALL=C
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=../lib/common.sh
source "$here/../lib/common.sh"
# shellcheck source=../lib/notify.sh
source "$here/../lib/notify.sh"

unit=${1:?usage: borg-relay-notify UNIT}
notify_load
inv=$(systemctl show -p InvocationID --value "$unit" 2>/dev/null)
if [[ -n $inv ]]; then
    body=$(journalctl --no-pager -o cat _SYSTEMD_INVOCATION_ID="$inv" | tail -n 200)
else
    body=$(journalctl --no-pager -o cat -u "$unit" -n 200)
fi
notify_send failure "[FAILED] $(hostname -s): $unit" "$body"
```

`tests/stubs/curl` (used by integration tests in Tasks 6–7):
```bash
#!/bin/bash
# Test stand-in for curl: appends args, -K config contents and stdin to $CURL_LOG.
prev=
for a in "$@"; do
    [[ $prev == -K ]] && cat "$a" >>"$CURL_LOG"
    printf 'ARG %s\n' "$a" >>"$CURL_LOG"
    prev=$a
done
if [[ " $* " == *" @- "* ]]; then cat >>"$CURL_LOG"; printf '\n' >>"$CURL_LOG"; fi
exit "${CURL_RC:-0}"
```

- [ ] **Step 5: Run** — `make check` → all pass.

- [ ] **Step 6: Commit** — `git add -A && git commit -m "feat: gotify and unifiedpush notifications"`

---

### Task 3: Hooks — `lib/hooks.sh`

**Files:**
- Create: `lib/hooks.sh`
- Test: `tests/hooks.bats`

**Interfaces:**
- Consumes: `log`, `warn`, `error`.
- Produces: `hooks_list DIR KIND` (prints executable `DIR/*.KIND`, C-sorted); `hooks_run DIR KIND` — `pre`: stops at first failure; `post`: runs all; returns 0 or the first failing exit code. Hooks get stdin `/dev/null`.

- [ ] **Step 1: Failing tests** — `tests/hooks.bats`:
```bash
setup() {
    load test_helper
    source "$REPO_ROOT/lib/common.sh"
    source "$REPO_ROOT/lib/hooks.sh"
    TMP=$(mktemp -d); D=$TMP/hooks.d; mkdir "$D"
    mk() { printf '#!/bin/bash\necho %s >>"%s/order"\n%s\n' "$1" "$TMP" "${2:-exit 0}" >"$D/$1"; chmod +x "$D/$1"; }
}
teardown() { rm -rf "$TMP"; }

@test "lists executable hooks of one kind in lexical order" {
    mk 20-b.pre; mk 10-a.pre; mk 10-a.post
    printf 'x' >"$D/30-c.pre"   # not executable
    run hooks_list "$D" pre
    [ "$output" = "$D/10-a.pre"$'\n'"$D/20-b.pre" ]
}

@test "missing directory is not an error" {
    run hooks_list "$TMP/nope" pre
    [ "$status" -eq 0 ]; [ -z "$output" ]
    run hooks_run "$TMP/nope" pre
    [ "$status" -eq 0 ]
}

@test "pre hooks stop at the first failure and return its code" {
    mk 10-a.pre; mk 20-b.pre "exit 3"; mk 30-c.pre
    run hooks_run "$D" pre
    [ "$status" -eq 3 ]
    [ "$(cat "$TMP/order")" = $'10-a.pre\n20-b.pre' ]
}

@test "post hooks all run; first failure code is returned" {
    mk 10-a.post "exit 4"; mk 20-b.post "exit 5"; mk 30-c.post
    run hooks_run "$D" post
    [ "$status" -eq 4 ]
    [ "$(cat "$TMP/order")" = $'10-a.post\n20-b.post\n30-c.post' ]
}

@test "hooks cannot swallow the hook list via stdin" {
    mk 10-a.pre "cat >/dev/null"; mk 20-b.pre
    run hooks_run "$D" pre
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP/order")" = $'10-a.pre\n20-b.pre' ]
}

@test "non-executable hook files are reported" {
    printf 'x' >"$D/10-a.pre"
    run hooks_run "$D" pre
    [[ $output == *"not executable"* ]]
}
```

- [ ] **Step 2: Run, expect failure** — `make test`.

- [ ] **Step 3: Implement `lib/hooks.sh`**
```bash
# shellcheck shell=bash
# Drop-in hooks: DIR/NN-name.pre runs before, DIR/NN-name.post after borg create.

hooks_list() {
    local dir=$1 kind=$2 f
    [[ -d $dir ]] || return 0
    for f in "$dir"/*."$kind"; do
        [[ -f $f ]] || continue
        if [[ -x $f ]]; then printf '%s\n' "$f"; else warn "hook $(basename "$f") is not executable - skipped"; fi
    done
    return 0
}

hooks_run() {
    local dir=$1 kind=$2 hook hrc rc=0
    while IFS= read -r hook; do
        log "hook: $(basename "$hook")"
        "$hook" </dev/null
        hrc=$?
        if (( hrc != 0 )); then
            error "hook $(basename "$hook") failed (exit $hrc)"
            (( rc == 0 )) && rc=$hrc
            [[ $kind == pre ]] && break
        fi
    done < <(hooks_list "$dir" "$kind")
    return "$rc"
}
```

- [ ] **Step 4: Run** — `make check` → pass.
- [ ] **Step 5: Commit** — `git commit -am "feat: pre/post hook runner"` (use `git add -A` first).

---

### Task 4: `lib/borg.sh` and `lib/relay.sh`

**Files:**
- Create: `lib/borg.sh`, `lib/relay.sh`
- Test: `tests/relay.bats`

**Interfaces:**
- Consumes: Task 1 helpers.
- Produces (`lib/borg.sh`; `BORG_BIN` default `borg`; `BORG_LOCK_WAIT` default 600):
  - `borg_info REPO`, `borg_init REPO`, `borg_key_export REPO` (key to stdout)
  - `borg_create REPO ARCHIVE` — uses globals `BACKUP_PATHS` (array, required), `EXCLUDES` (array, optional), `BORG_COMPRESSION` (default `zstd,3`)
  - `borg_dry_run REPO` — same globals, `--dry-run --list`
  - `borg_archive_names REPO` (one per line), `borg_last_archive_epoch REPO` (epoch seconds or empty)
  - `borg_prune REPO KEEP_ARGS...`, `borg_compact REPO`, `borg_check_repo REPO`
  - `borg_serve_argv NAME` → sets array `BORG_SERVE_ARGV`
  - `borg_serve_cmdline BORGCMD NAME` → prints remote command string
- Produces (`lib/relay.sh`; relay.conf vars `BACKEND MOUNTPOINT MOUNT_REQUIRE_MOUNTPOINT TARGET_HOST TARGET_PORT TARGET_USER TARGET_KEY REMOTE_BORG`; `BR_LIBEXEC` default `/usr/local/lib/borg-relay/bin`):
  - `relay_authorized_line NAME PUBKEY` → authorized_keys line
  - `relay_serve_argv NAME` → sets `RELAY_SERVE_ARGV` (array), `RELAY_SERVE_CWD`
  - `relay_mount_ready` → rc
  - `relay_repo_location NAME` → full-access path/URL
  - `relay_borg_env` → exports `BORG_RSH`, `BORG_REMOTE_PATH` for ssh-borg
  - `tamper_missing PREV_FILE CUR_FILE` → names missing from CUR
  - `archive_age_hours NOW_EPOCH ARCHIVE_EPOCH` → integer hours

- [ ] **Step 1: Failing tests** — `tests/relay.bats`:
```bash
setup() {
    load test_helper
    source "$REPO_ROOT/lib/common.sh"
    source "$REPO_ROOT/lib/borg.sh"
    source "$REPO_ROOT/lib/relay.sh"
    TMP=$(mktemp -d)
    KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMk0nG5Z7rKk+abc/def= root@nc"
}
teardown() { rm -rf "$TMP"; }

@test "authorized line pins the forced command and drops the key comment" {
    run relay_authorized_line nextcloud "$KEY"
    [ "$status" -eq 0 ]
    [ "$output" = 'restrict,command="/usr/local/lib/borg-relay/bin/borg-relay-serve nextcloud" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMk0nG5Z7rKk+abc/def= borg-relay:nextcloud' ]
}

@test "authorized line rejects bad names and non-keys" {
    run relay_authorized_line "../x" "$KEY";              [ "$status" -ne 0 ]
    run relay_authorized_line ok "hello world";          [ "$status" -ne 0 ]
    run relay_authorized_line ok 'ssh-ed25519 AAA" evil'; [ "$status" -ne 0 ]
    run relay_authorized_line ok "";                      [ "$status" -ne 0 ]
}

@test "mount backend serves from the mountpoint, append-only, one repo" {
    BACKEND=mount MOUNTPOINT=/srv/borgtarget
    relay_serve_argv alpha
    [ "$RELAY_SERVE_CWD" = /srv/borgtarget ]
    [ "${RELAY_SERVE_ARGV[*]}" = "borg serve --append-only --restrict-to-repository alpha" ]
}

@test "ssh-borg backend pipes to the remote borg" {
    BACKEND=ssh-borg TARGET_HOST=t.example TARGET_PORT=23 TARGET_USER=u1 TARGET_KEY=/k REMOTE_BORG=borg-1.4
    relay_serve_argv alpha
    [ -z "$RELAY_SERVE_CWD" ]
    [ "${RELAY_SERVE_ARGV[0]}" = ssh ]
    [ "${RELAY_SERVE_ARGV[-2]}" = u1@t.example ]
    [ "${RELAY_SERVE_ARGV[-1]}" = "borg-1.4 serve --append-only --restrict-to-repository alpha" ]
    [[ " ${RELAY_SERVE_ARGV[*]} " == *" -p 23 "* ]]
    [[ " ${RELAY_SERVE_ARGV[*]} " == *" -i /k "* ]]
    [[ " ${RELAY_SERVE_ARGV[*]} " == *" StrictHostKeyChecking=yes "* ]]
}

@test "unknown backend fails" {
    BACKEND=webdav
    run relay_serve_argv alpha
    [ "$status" -ne 0 ]
}

@test "repo location per backend" {
    BACKEND=mount MOUNTPOINT=/srv/t
    [ "$(relay_repo_location alpha)" = /srv/t/alpha ]
    BACKEND=ssh-borg TARGET_HOST=h TARGET_PORT=23 TARGET_USER=u
    [ "$(relay_repo_location alpha)" = "ssh://u@h:23/./alpha" ]
}

@test "relay_borg_env sets remote path only for ssh-borg" {
    unset BORG_RSH BORG_REMOTE_PATH
    BACKEND=mount; relay_borg_env
    [ -z "${BORG_REMOTE_PATH:-}" ]
    BACKEND=ssh-borg TARGET_KEY=/k REMOTE_BORG=borg-1.4; relay_borg_env
    [ "$BORG_REMOTE_PATH" = borg-1.4 ]
    [[ $BORG_RSH == "ssh -i /k "* ]]
}

@test "mount readiness can be relaxed only by config" {
    BACKEND=mount MOUNTPOINT=$TMP MOUNT_REQUIRE_MOUNTPOINT=yes
    run relay_mount_ready; [ "$status" -ne 0 ]
    MOUNT_REQUIRE_MOUNTPOINT=no
    run relay_mount_ready; [ "$status" -eq 0 ]
}

@test "tamper_missing lists archives that disappeared" {
    printf 'a1\na2\na3\n' >"$TMP/prev"
    printf 'a1\na3\na4\n' >"$TMP/cur"
    [ "$(tamper_missing "$TMP/prev" "$TMP/cur")" = a2 ]
    printf 'a1\na2\na3\na4\n' >"$TMP/cur"
    [ -z "$(tamper_missing "$TMP/prev" "$TMP/cur")" ]
}

@test "archive age in whole hours" {
    [ "$(archive_age_hours 100000 100000)" = 0 ]
    [ "$(archive_age_hours 100000 $((100000 - 26*3600 - 5)))" = 26 ]
}

@test "remote serve command quotes the name" {
    [ "$(borg_serve_cmdline borg alpha)" = "borg serve --append-only --restrict-to-repository alpha" ]
}
```

- [ ] **Step 2: Run, expect failure** — `make test`.

- [ ] **Step 3: Implement `lib/borg.sh`**
```bash
# shellcheck shell=bash
# Every borg invocation of borg-relay lives here (one place to touch for a Borg 2 move).
BORG_BIN="${BORG_BIN:-borg}"

_lockwait() { printf -- '--lock-wait=%s' "${BORG_LOCK_WAIT:-600}"; }

borg_info()       { "$BORG_BIN" info "$(_lockwait)" "$1"; }
borg_init()       { "$BORG_BIN" init --encryption=repokey-blake2 "$1"; }
borg_key_export() { "$BORG_BIN" key export "$1"; }

_borg_create_args() {
    BORG_CREATE_ARGS=(--compression "${BORG_COMPRESSION:-zstd,3}" --exclude-caches)
    local p
    for p in "${EXCLUDES[@]+"${EXCLUDES[@]}"}"; do BORG_CREATE_ARGS+=(--exclude "$p"); done
}

# borg_create REPO ARCHIVE - paths from BACKUP_PATHS, excludes from EXCLUDES
borg_create() {
    _borg_create_args
    "$BORG_BIN" create "$(_lockwait)" --stats "${BORG_CREATE_ARGS[@]}" "$1::$2" "${BACKUP_PATHS[@]}"
}

borg_dry_run() {
    _borg_create_args
    "$BORG_BIN" create --dry-run --list "${BORG_CREATE_ARGS[@]}" "$1::dry-run" "${BACKUP_PATHS[@]}"
}

borg_archive_names()      { "$BORG_BIN" list "$(_lockwait)" --short "$1"; }
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
```

- [ ] **Step 4: Implement `lib/relay.sh`**
```bash
# shellcheck shell=bash
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
        export BORG_RSH="ssh -i $(_target_key) -o BatchMode=yes -o StrictHostKeyChecking=yes -o ServerAliveInterval=30"
        export BORG_REMOTE_PATH=${REMOTE_BORG:-borg}
    fi
}

tamper_missing()    { comm -23 <(sort -u "$1") <(sort -u "$2"); }
archive_age_hours() { echo $(( ($1 - $2) / 3600 )); }
```

- [ ] **Step 5: Run** — `make check` → pass.
- [ ] **Step 6: Commit** — `git add -A && git commit -m "feat: borg wrapper and relay helpers"`

---

### Task 5: `bin/borg-relay-serve` + serve integration tests

**Files:**
- Create: `bin/borg-relay-serve`, `tests/fake-rsh`
- Test: `tests/integration_serve.bats`

**Interfaces:**
- Consumes: `load_conf`, `valid_name`, `relay_serve_argv`, `relay_mount_ready`.
- Produces: executable `bin/borg-relay-serve NAME` (exit 1 with a message on stderr when refusing). `tests/fake-rsh NAME` emulates sshd + forced command: use as `BORG_RSH="$REPO_ROOT/tests/fake-rsh NAME"`, repo URL `ssh://relay/./NAME`.

- [ ] **Step 1: `tests/fake-rsh`**
```bash
#!/bin/bash
# Test stand-in for ssh+sshd: runs the relay's forced command for client NAME.
# borg calls: $BORG_RSH [ssh options] host borg serve ... - all of that is ignored,
# exactly as sshd ignores the client's command when a forced command is set.
name=$1
shift
exec env SSH_ORIGINAL_COMMAND="$*" "$(dirname "$0")/../bin/borg-relay-serve" "$name"
```

- [ ] **Step 2: Failing tests** — `tests/integration_serve.bats`:
```bash
setup() {
    load test_helper
    TMP=$(mktemp -d)
    export BR_ETC=$TMP/etc BR_STATE=$TMP/state
    mkdir -p "$BR_ETC" "$TMP/target" "$TMP/src"
    cat >"$BR_ETC/relay.conf" <<EOF
BACKEND=mount
MOUNTPOINT=$TMP/target
MOUNT_REQUIRE_MOUNTPOINT=no
EOF
    chmod 600 "$BR_ETC/relay.conf"
    export BORG_PASSPHRASE=test-pass BORG_BASE_DIR=$TMP/client-home
    export BORG_RSH="$REPO_ROOT/tests/fake-rsh alpha"
    REPO=ssh://relay/./alpha
    echo hello >"$TMP/src/file"
}
teardown() { rm -rf "$TMP"; }

@test "client inits and creates through the relay into <target>/<name>" {
    borg init -e repokey-blake2 "$REPO"
    borg create "$REPO::a1" "$TMP/src"
    [ -f "$TMP/target/alpha/config" ]
    [ "$(borg list --short "$REPO")" = a1 ]
}

@test "the relay serves append-only" {
    borg init -e repokey-blake2 "$REPO"
    borg create "$REPO::a1" "$TMP/src"
    [ -f "$TMP/target/alpha/transactions" ]
}

@test "a client cannot open another client's repo" {
    run borg init -e repokey-blake2 ssh://relay/./beta
    [ "$status" -ne 0 ]
    [[ $output == *"not allowed"* ]]
    [ ! -e "$TMP/target/beta" ]
}

@test "refuses to serve when the target is not mounted" {
    sed -i 's/MOUNT_REQUIRE_MOUNTPOINT=no/MOUNT_REQUIRE_MOUNTPOINT=yes/' "$BR_ETC/relay.conf"
    run borg init -e repokey-blake2 "$REPO"
    [ "$status" -ne 0 ]
    [[ $output == *"not mounted"* ]]
    [ ! -e "$TMP/target/alpha" ]
}

@test "rejects an invalid name in the forced command" {
    run "$REPO_ROOT/bin/borg-relay-serve" "../alpha"
    [ "$status" -eq 1 ]
    [[ $output == *"invalid client name"* ]]
}
```

- [ ] **Step 3: Run, expect failure** — `make test`.

- [ ] **Step 4: Implement `bin/borg-relay-serve`**
```bash
#!/bin/bash
# Forced command for client keys on the relay (see authorized_keys):
#   command=".../borg-relay-serve NAME"
# Serves exactly one repository, append-only. The client's requested command
# (SSH_ORIGINAL_COMMAND) is ignored on purpose.
set -euo pipefail
export LC_ALL=C
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=../lib/common.sh
source "$here/../lib/common.sh"
# shellcheck source=../lib/borg.sh
source "$here/../lib/borg.sh"
# shellcheck source=../lib/relay.sh
source "$here/../lib/relay.sh"

name=${1-}
valid_name "$name" || die "invalid client name in forced command"
load_conf "$BR_ETC/relay.conf" BACKEND
relay_serve_argv "$name"
if [[ $BACKEND == mount ]]; then
    relay_mount_ready || die "storage target is not mounted at $MOUNTPOINT - refusing to serve"
    cd "$RELAY_SERVE_CWD"
fi
exec "${RELAY_SERVE_ARGV[@]}"
```
`chmod +x bin/borg-relay-serve tests/fake-rsh`.

- [ ] **Step 5: Run** — `make check` → pass. If the "not allowed" assertion fails, print `$output` and adapt the match to borg 1.4's exact wording (`Repository path not allowed`).
- [ ] **Step 6: Commit** — `git add -A && git commit -m "feat: append-only forced command for the relay"`

---

### Task 6: `bin/borg-relay` (relay admin, maintenance, watch)

**Files:**
- Create: `bin/borg-relay`
- Test: `tests/integration_relay.bats`

**Interfaces:**
- Consumes: Tasks 1–5. `BR_RELAY_USER` (default `borgrelay`) owns `$BR_STATE/.ssh/authorized_keys`, `$BR_ETC/repos.d/*`, `$BR_STATE/state/*`.
- Produces CLI:
  - `borg-relay add-client NAME` — reads the public key from stdin (prompt when stdin is a TTY), replaces any line tagged `borg-relay:NAME`.
  - `borg-relay set-passphrase NAME` — reads passphrase from stdin, writes `repos.d/NAME.conf` (`BORG_PASSPHRASE KEEP MAX_AGE_HOURS`, keeps existing KEEP/MAX_AGE_HOURS), verifies via `_verify`.
  - `borg-relay list` — name, archive count, age of newest.
  - `borg-relay maint` — exit 1 if any repo failed (tamper, unreachable, borg error); success summary via `notify_send success`.
  - `borg-relay watch` — exit 1 listing stale/unreachable/empty repos.
  - `borg-relay _verify NAME` — internal, `borg info` with full access.
  - repos.d file format: `BORG_PASSPHRASE=…`, `KEEP='--keep-within=7d --keep-weekly=4 --keep-monthly=6'`, `MAX_AGE_HOURS=26`.

- [ ] **Step 1: Failing tests** — `tests/integration_relay.bats`:
```bash
setup() {
    load test_helper
    TMP=$(mktemp -d)
    export BR_ETC=$TMP/etc BR_STATE=$TMP/state BR_RELAY_USER=root
    mkdir -p "$BR_ETC/repos.d" "$TMP/target" "$TMP/src"
    cat >"$BR_ETC/relay.conf" <<EOF
BACKEND=mount
MOUNTPOINT=$TMP/target
MOUNT_REQUIRE_MOUNTPOINT=no
EOF
    chmod 600 "$BR_ETC/relay.conf"
    echo hello >"$TMP/src/file"
    RELAY="$REPO_ROOT/bin/borg-relay"
    REPO=ssh://relay/./alpha
    KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMk0nG5Z7rKk+abc/def= root@nc"
}
teardown() { rm -rf "$TMP"; }

# client-side borg (own base dir, through the forced command)
cborg() { BORG_PASSPHRASE=pw BORG_BASE_DIR=$TMP/client-home BORG_RSH="$REPO_ROOT/tests/fake-rsh alpha" borg "$@"; }
# relay-side command (own base dir)
relay() { BORG_BASE_DIR=$TMP/relay-home "$RELAY" "$@"; }

init_alpha() {
    cborg init -e repokey-blake2 "$REPO"
    echo pw | relay set-passphrase alpha
}

@test "add-client writes a restricted line and replaces it on re-add" {
    echo "$KEY" | relay add-client alpha
    echo "$KEY" | relay add-client alpha
    [ "$(grep -c 'borg-relay:alpha$' "$BR_STATE/.ssh/authorized_keys")" = 1 ]
    grep -q '^restrict,command="' "$BR_STATE/.ssh/authorized_keys"
}

@test "add-client rejects garbage" {
    run bash -c "echo nope | BORG_BASE_DIR=$TMP/rh $RELAY add-client alpha"
    [ "$status" -ne 0 ]
}

@test "set-passphrase writes a private conf and verifies it" {
    init_alpha
    [ "$(stat -c %a "$BR_ETC/repos.d/alpha.conf")" = 600 ]
    run bash -c "echo wrong | BORG_BASE_DIR=$TMP/rh2 $RELAY set-passphrase alpha"
    [ "$status" -ne 0 ]
}

@test "maint prunes, compacts and records the archive list" {
    init_alpha
    sed -i "s/^KEEP=.*/KEEP=--keep-last=1/" "$BR_ETC/repos.d/alpha.conf"
    cborg create "$REPO::a1" "$TMP/src"
    cborg create "$REPO::a2" "$TMP/src"
    relay maint
    [ "$(cat "$BR_STATE/state/alpha.archives")" = a2 ]
}

@test "maint detects archives deleted by a client and skips the repo" {
    init_alpha
    cborg create "$REPO::a1" "$TMP/src"
    cborg create "$REPO::a2" "$TMP/src"
    relay maint
    cborg delete "$REPO::a1"
    run relay maint
    [ "$status" -eq 1 ]
    [[ $output == *"possible tampering"* ]]
    [ "$(cat "$BR_STATE/state/alpha.archives")" = $'a1\na2' ]
}

@test "maint refuses when the target is not mounted" {
    init_alpha
    sed -i 's/MOUNT_REQUIRE_MOUNTPOINT=no/MOUNT_REQUIRE_MOUNTPOINT=yes/' "$BR_ETC/relay.conf"
    run relay maint
    [ "$status" -eq 1 ]
    [[ $output == *"not mounted"* ]]
}

@test "maint waits for a lock held by a running backup" {
    init_alpha
    cborg create "$REPO::a1" "$TMP/src"
    BORG_PASSPHRASE=pw BORG_BASE_DIR=$TMP/relay-home borg with-lock "$TMP/target/alpha" sleep 4 &
    sleep 1
    relay maint
    wait
}

@test "watch passes for a fresh archive and fails when stale or empty" {
    init_alpha
    run relay watch
    [ "$status" -eq 1 ]; [[ $output == *"no archives"* ]]
    cborg create "$REPO::a1" "$TMP/src"
    relay watch
    sed -i "s/^MAX_AGE_HOURS=.*/MAX_AGE_HOURS=0/" "$BR_ETC/repos.d/alpha.conf"
    run relay watch
    [ "$status" -eq 1 ]; [[ $output == *"old (limit 0h)"* ]]
}
```

- [ ] **Step 2: Run, expect failure** — `make test`.

- [ ] **Step 3: Implement `bin/borg-relay`**
```bash
#!/bin/bash
# borg-relay - relay administration and maintenance.
#   add-client NAME        authorize a client key (read from stdin)
#   set-passphrase NAME    store the repo passphrase for maintenance (stdin)
#   list                   repos with archive count and age
#   maint                  tamper check, prune, compact, check (weekly timer)
#   watch                  alert on missing/stale backups (daily timer)
set -uo pipefail
export LC_ALL=C
here=$(dirname "$(readlink -f "$0")")
self=$(readlink -f "$0")
# shellcheck source=../lib/common.sh
source "$here/../lib/common.sh"
# shellcheck source=../lib/borg.sh
source "$here/../lib/borg.sh"
# shellcheck source=../lib/relay.sh
source "$here/../lib/relay.sh"
# shellcheck source=../lib/notify.sh
source "$here/../lib/notify.sh"

RUSER=${BR_RELAY_USER:-borgrelay}
AUTH_KEYS=$BR_STATE/.ssh/authorized_keys
REPOS_D=$BR_ETC/repos.d
DEFAULT_KEEP="--keep-within=7d --keep-weekly=4 --keep-monthly=6"

usage() { sed -n '2,7s/^# \{0,1\}//p' "$self"; exit 2; }

as_relay_user() {
    if [[ $(id -un) == "$RUSER" ]]; then "$@"; else runuser -u "$RUSER" -- "$@"; fi
}

read_input() {   # read_input PROMPT SECRET(0|1) -> REPLY
    if [[ -t 0 ]]; then
        if [[ $2 == 1 ]]; then read -r -s -p "$1" REPLY; echo >&2; else read -r -p "$1" REPLY; fi
    else
        IFS= read -r REPLY || REPLY=
    fi
}

need_name() { valid_name "${1-}" || die "NAME must match ^[a-z0-9][a-z0-9-]{0,62}\$"; }

relay_conf() {
    load_conf "$BR_ETC/relay.conf" BACKEND
    if [[ $BACKEND == mount ]]; then
        relay_mount_ready || die "storage target is not mounted at $MOUNTPOINT"
    fi
}

repo_env() {   # in a subshell: load repos.d/NAME.conf, export borg env, set REPO
    load_conf "$REPOS_D/$1.conf" BORG_PASSPHRASE
    export BORG_PASSPHRASE
    relay_borg_env
    REPO=$(relay_repo_location "$1")
}

repo_names() {
    local f
    for f in "$REPOS_D"/*.conf; do [[ -e $f ]] && basename "$f" .conf; done
    return 0
}

cmd_add_client() {
    require_root
    need_name "${1-}"
    local name=$1 line tmp
    read_input "Public key of client '$name': " 0
    line=$(relay_authorized_line "$name" "$REPLY") || exit 1
    install -d -m 700 -o "$RUSER" -g "$RUSER" "$BR_STATE/.ssh"
    tmp=$(mktemp)
    [[ -f $AUTH_KEYS ]] && grep -v " borg-relay:${name}\$" "$AUTH_KEYS" >"$tmp"
    printf '%s\n' "$line" >>"$tmp"
    install -m 600 -o "$RUSER" -g "$RUSER" "$tmp" "$AUTH_KEYS"
    rm -f "$tmp"
    log "client '$name' authorized (append-only, repo '$name' only)"
}

cmd_set_passphrase() {
    require_root
    need_name "${1-}"
    local name=$1 f=$REPOS_D/$1.conf keep=$DEFAULT_KEEP max=26 tmp
    read_input "Passphrase of repo '$name': " 1
    [[ -n $REPLY ]] || die "empty passphrase"
    if [[ -r $f ]]; then
        # shellcheck disable=SC1090
        keep=$(source "$f"; printf '%s' "${KEEP:-$DEFAULT_KEEP}")
        # shellcheck disable=SC1090
        max=$(source "$f"; printf '%s' "${MAX_AGE_HOURS:-26}")
    fi
    install -d -m 700 -o "$RUSER" -g "$RUSER" "$REPOS_D"
    tmp=$(mktemp)
    printf 'BORG_PASSPHRASE=%q\nKEEP=%q\nMAX_AGE_HOURS=%q\n' "$REPLY" "$keep" "$max" >"$tmp"
    install -m 600 -o "$RUSER" -g "$RUSER" "$tmp" "$f"
    rm -f "$tmp"
    if as_relay_user "$self" _verify "$name"; then
        log "passphrase for '$name' stored and verified"
    else
        die "verification failed - wrong passphrase or repo not initialized yet"
    fi
}

cmd_verify() { need_name "${1-}"; relay_conf; ( repo_env "$1"; borg_info "$REPO" >/dev/null ); }

cmd_list() {
    relay_conf
    local name
    while IFS= read -r name; do
        (
            repo_env "$name"
            count=$(borg_archive_names "$REPO" | wc -l)
            last=$(borg_last_archive_epoch "$REPO")
            age=-; [[ -n $last ]] && age="$(archive_age_hours "$(date +%s)" "$last")h"
            printf '%-24s archives=%-5s newest=%s\n' "$name" "$count" "$age"
        ) || printf '%-24s UNREACHABLE\n' "$name"
    done < <(repo_names)
}

maint_one() (
    name=$1
    repo_env "$name"
    state=$BR_STATE/state/$name.archives
    cur=$(mktemp)
    trap 'rm -f "$cur"' EXIT
    borg_archive_names "$REPO" >"$cur" || { error "$name: cannot list archives"; exit 1; }
    if [[ -f $state ]]; then
        missing=$(tamper_missing "$state" "$cur")
        if [[ -n $missing ]]; then
            error "$name: archives deleted outside maintenance (possible tampering): $(tr '\n' ' ' <<<"$missing")"
            error "$name: prune/compact skipped - see RESTORE.md, 'Rolling back an append-only repository'"
            exit 1
        fi
    fi
    read -ra keep <<<"${KEEP:-$DEFAULT_KEEP}"
    borg_prune "$REPO" "${keep[@]}" || { error "$name: prune failed"; exit 1; }
    borg_compact "$REPO"           || { error "$name: compact failed"; exit 1; }
    borg_check_repo "$REPO"        || { error "$name: repository check failed"; exit 1; }
    install -d -m 700 "$BR_STATE/state"
    borg_archive_names "$REPO" >"$state.new" && mv "$state.new" "$state"
    log "$name: maintenance ok ($(wc -l <"$state") archives)"
)

cmd_maint() {
    relay_conf
    notify_load
    local name failed=() summary=
    while IFS= read -r name; do
        if maint_one "$name"; then summary+="$name: ok"$'\n'; else failed+=("$name"); fi
    done < <(repo_names)
    if (( ${#failed[@]} )); then die "maintenance failed for: ${failed[*]}"; fi
    notify_send success "[OK] $(hostname -s): weekly maintenance" "$summary"
}

watch_one() (
    repo_env "$1"
    last=$(borg_last_archive_epoch "$REPO" 2>&1) || { echo "repository unreachable: $last"; exit 1; }
    [[ -n $last ]] || { echo "no archives yet"; exit 1; }
    age=$(archive_age_hours "$(date +%s)" "$last")
    max=${MAX_AGE_HOURS:-26}
    (( age < max )) || { echo "newest archive is ${age}h old (limit ${max}h)"; exit 1; }
)

cmd_watch() {
    relay_conf
    local name out problems=0
    while IFS= read -r name; do
        if out=$(watch_one "$name"); then log "$name: fresh"; else error "$name: $out"; problems=1; fi
    done < <(repo_names)
    (( problems == 0 )) || die "backups missing or stale"
}

case ${1-} in
    add-client)     shift; cmd_add_client "$@" ;;
    set-passphrase) shift; cmd_set_passphrase "$@" ;;
    list)           cmd_list ;;
    maint)          cmd_maint ;;
    watch)          cmd_watch ;;
    _verify)        shift; cmd_verify "$@" ;;
    *)              usage ;;
esac
```

- [ ] **Step 4: Run** — `make check` → pass. If `{time:%s}` yields a non-integer, fix `borg_last_archive_epoch` to `--json` + `python3 -c` parsing of `start` and re-run.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: relay admin, maintenance with tamper check, missed-run watch"`

---

### Task 7: `bin/borg-relay-backup` (client run)

**Files:**
- Create: `bin/borg-relay-backup`
- Test: `tests/integration_client.bats`

**Interfaces:**
- Consumes: Tasks 1–4; `tests/fake-rsh`, `tests/stubs/curl`.
- Produces: `borg-relay-backup` reading `$BR_ETC/client.conf`: `RELAY_HOST` (req), `RELAY_PORT`=22, `RELAY_USER`=borgrelay, `BACKUP_NAME`=`hostname -s`, `CLIENT_KEY`=/root/.ssh/borg-relay_ed25519, `BORG_PASSPHRASE` (req), `BACKUP_PATHS` (req, array), `EXCLUDES` (array), `RETRY_INTERVAL`=60, `RETRY_WINDOW`=3600, `LOG_KEEP_DAYS`=30. Env overrides for tests: `BR_LOG_DIR`, `BR_LOCK`, `BORG_RSH`. Exit 0 = success or warning (notified), 1 = failure (not notified here; `OnFailure=` does it).

- [ ] **Step 1: Failing tests** — `tests/integration_client.bats`:
```bash
setup() {
    load test_helper
    TMP=$(mktemp -d)
    export BR_ETC=$TMP/etc BR_STATE=$TMP/state BR_LOG_DIR=$TMP/log BR_LOCK=$TMP/lock
    mkdir -p "$BR_ETC/hooks.d" "$TMP/target" "$TMP/src" "$TMP/bin"
    cat >"$BR_ETC/relay.conf" <<EOF
BACKEND=mount
MOUNTPOINT=$TMP/target
MOUNT_REQUIRE_MOUNTPOINT=no
EOF
    cat >"$BR_ETC/client.conf" <<EOF
RELAY_HOST=relay
BACKUP_NAME=alpha
BORG_PASSPHRASE='p\$w "x"'
BACKUP_PATHS=($TMP/src)
RETRY_INTERVAL=1
RETRY_WINDOW=0
EOF
    printf 'UP_ENDPOINT=https://up.invalid/x\n' >"$BR_ETC/notify.conf"
    chmod 600 "$BR_ETC"/*.conf
    ln -s "$REPO_ROOT/tests/stubs/curl" "$TMP/bin/curl"
    export PATH=$TMP/bin:$PATH CURL_LOG=$TMP/curl.log
    export BORG_RSH="$REPO_ROOT/tests/fake-rsh alpha" BORG_BASE_DIR=$TMP/client-home
    echo hello >"$TMP/src/file"
    BORG_PASSPHRASE='p$w "x"' borg init -e repokey-blake2 ssh://relay/./alpha
    RUN="$REPO_ROOT/bin/borg-relay-backup"
}
teardown() { rm -rf "$TMP"; }

hook() { printf '#!/bin/bash\necho %s >>"%s/order"\n%s\n' "$1" "$TMP" "${2:-exit 0}" >"$BR_ETC/hooks.d/$1"; chmod +x "$BR_ETC/hooks.d/$1"; }
archives() { BORG_PASSPHRASE='p$w "x"' borg list --short ssh://relay/./alpha; }

@test "success: hooks around the archive, log written, OK notification" {
    hook 10-x.pre; hook 10-x.post
    run "$RUN"
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP/order")" = $'10-x.pre\n10-x.post' ]
    [[ $(archives) == alpha-* ]]
    ls "$BR_LOG_DIR"/*.log
    grep -q '^\[OK\] alpha: backup completed' "$CURL_LOG"
}

@test "pre hook failure: no archive, post hooks still run, exit 1" {
    hook 10-x.pre "exit 1"; hook 10-x.post
    run "$RUN"
    [ "$status" -eq 1 ]
    [ "$(cat "$TMP/order")" = $'10-x.pre\n10-x.post' ]
    [ -z "$(archives)" ]
}

@test "borg failure: post hooks run, exit 1" {
    hook 10-x.post
    echo 'BORG_COMPRESSION=bogus' >>"$BR_ETC/client.conf"   # borg create rejects it (rc 2)
    run "$RUN"
    [ "$status" -eq 1 ]
    [ "$(cat "$TMP/order")" = 10-x.post ]
}

@test "post hook failure fails the run even though the archive exists" {
    hook 10-x.post "exit 2"
    run "$RUN"
    [ "$status" -eq 1 ]
    [[ $output == *"post hook failed"* ]]
    [[ $(archives) == alpha-* ]]
}

@test "warning (vanished path) still succeeds and is notified as WARNING" {
    sed -i "s|^BACKUP_PATHS=.*|BACKUP_PATHS=($TMP/src $TMP/missing)|" "$BR_ETC/client.conf"
    run "$RUN"
    [ "$status" -eq 0 ]
    grep -q '^\[WARNING\] alpha' "$CURL_LOG"
}

@test "unreachable repository: exit 1, no hooks" {
    hook 10-x.pre
    sed -i 's/MOUNT_REQUIRE_MOUNTPOINT=no/MOUNT_REQUIRE_MOUNTPOINT=yes/' "$BR_ETC/relay.conf"
    run "$RUN"
    [ "$status" -eq 1 ]
    [[ $output == *"not reachable"* ]]
    [ ! -e "$TMP/order" ]
}

@test "a second concurrent run is refused" {
    exec 8>"$BR_LOCK"; flock 8
    run "$RUN"
    [ "$status" -eq 1 ]
    [[ $output == *"in progress"* ]]
}

@test "notification failure does not fail the backup" {
    export CURL_RC=7
    run "$RUN"
    [ "$status" -eq 0 ]
}

@test "SIGTERM during the run still runs post hooks" {
    hook 10-x.pre "sleep 2"; hook 10-x.post
    "$RUN" & pid=$!
    for _ in {1..100}; do [[ -s $TMP/order ]] && break; sleep 0.1; done
    kill -TERM "$pid"
    run wait "$pid"
    [ "$status" -ne 0 ]
    grep -qx 10-x.post "$TMP/order"
}
```

- [ ] **Step 2: Run, expect failure** — `make test`.

- [ ] **Step 3: Implement `bin/borg-relay-backup`**
```bash
#!/bin/bash
# Client backup run: wait for the repo, pre hooks, borg create, post hooks, notify.
# Failures exit 1; systemd OnFailure= sends the alert with the journal.
set -uo pipefail
export LC_ALL=C
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=../lib/common.sh
source "$here/../lib/common.sh"
# shellcheck source=../lib/borg.sh
source "$here/../lib/borg.sh"
# shellcheck source=../lib/hooks.sh
source "$here/../lib/hooks.sh"
# shellcheck source=../lib/notify.sh
source "$here/../lib/notify.sh"

LOG_DIR=${BR_LOG_DIR:-/var/log/borg-relay}
LOCK=${BR_LOCK:-/run/borg-relay.lock}
HOOKS_DIR=$BR_ETC/hooks.d
POST_STATE=none     # none -> pending (pre hooks started) -> done
BORG_PID=

run_post() {
    [[ $POST_STATE == pending ]] || return 0
    POST_STATE=done
    if [[ -n $BORG_PID ]] && kill -0 "$BORG_PID" 2>/dev/null; then
        kill -TERM "$BORG_PID"; wait "$BORG_PID"
    fi
    hooks_run "$HOOKS_DIR" post
}

on_exit() { run_post || error "post hook failed"; }

wait_for_repo() {
    local deadline out
    deadline=$(( $(date +%s) + ${RETRY_WINDOW:-3600} ))
    while :; do
        out=$(borg_info "$REPO" 2>&1 >/dev/null) && return 0
        warn "repository not reachable: ${out//$'\n'/ | }"
        (( $(date +%s) + ${RETRY_INTERVAL:-60} <= deadline )) || return 1
        sleep "${RETRY_INTERVAL:-60}"
    done
}

main() {
    load_conf "$BR_ETC/client.conf" RELAY_HOST BORG_PASSPHRASE BACKUP_PATHS
    NAME=${BACKUP_NAME:-$(hostname -s)}
    valid_name "$NAME" || die "BACKUP_NAME '$NAME' is not a valid name"
    REPO="ssh://${RELAY_USER:-borgrelay}@${RELAY_HOST}:${RELAY_PORT:-22}/./${NAME}"
    export BORG_PASSPHRASE BR_ETC
    export BORG_RSH="${BORG_RSH:-ssh -i ${CLIENT_KEY:-/root/.ssh/borg-relay_ed25519} -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=30}"

    exec 9>"$LOCK"
    flock -n 9 || die "another backup run is in progress"

    mkdir -p "$LOG_DIR"
    find "$LOG_DIR" -name '*.log' -mtime +"${LOG_KEEP_DAYS:-30}" -delete
    LOG_FILE=$LOG_DIR/$(date +%Y%m%d-%H%M%S).log
    exec > >(tee -a "$LOG_FILE") 2>&1
    notify_load
    log "backup of '$NAME' to $REPO"
    trap on_exit EXIT
    trap 'exit 143' TERM INT

    wait_for_repo || die "repository not reachable within ${RETRY_WINDOW:-3600}s"

    POST_STATE=pending
    hooks_run "$HOOKS_DIR" pre || die "pre hook failed - no backup taken"

    local rc=0
    borg_create "$REPO" "${NAME}-{now:%Y-%m-%dT%H:%M:%S}" &
    BORG_PID=$!
    wait "$BORG_PID" || rc=$?
    BORG_PID=

    local post_rc=0
    run_post || post_rc=$?
    (( rc < 2 ))       || die "borg create failed (exit $rc)"
    (( post_rc == 0 )) || die "post hook failed - check the services on '$NAME'"

    if (( rc == 1 )); then
        log "backup completed with warnings"
        notify_send warning "[WARNING] $NAME: backup completed with warnings" "$(cat "$LOG_FILE")"
    else
        log "backup completed"
        notify_send success "[OK] $NAME: backup completed" "$(cat "$LOG_FILE")"
    fi
}

main "$@"
```

- [ ] **Step 4: Run** — `make check` → pass. If the "warning" test fails because borg 1.4 returns rc 2 (not 1) for a missing input path, replace `$TMP/missing` with a FIFO (`mkfifo "$TMP/src/fifo"` and back up `$TMP/src` with `--read-special` absent — borg skips FIFOs with a warning, rc 1) and re-run.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: client backup run with hooks, retries and notifications"`

---

### Task 8: Bundled hooks and `lib/dbdump.sh`

**Files:**
- Create: `lib/dbdump.sh`, `hooks/10-nextcloud.pre`, `hooks/10-nextcloud.post`, `hooks/10-db-dump.pre`, `hooks/10-db-dump.post`, `hooks/10-paperless.pre`
- Test: `tests/hooks_bundled.bats`

**Interfaces:**
- Consumes: `load_conf`, `check_private`, `log`, `error`.
- Produces: `dbdump_run` (writes `$DUMP_DIR/$DB_NAME.sql`, mode 600), `dbdump_clean`; `DUMP_DIR` = `${BR_DUMP_DIR:-/var/lib/borg-relay/dumps}`. client.conf keys: `DB_TYPE` (pgsql|mysql) `DB_NAME` `DB_HOST`=localhost `DB_USER` (pgsql), `NC_DIR` `NC_WEB_USER`=www-data `NC_STOP_SERVICE` (empty = none), `PAPERLESS_DIR` `PAPERLESS_SERVICE`=webserver `PAPERLESS_EXPORT_IN_CONTAINER`=/usr/src/paperless/export. Credentials: `$BR_ETC/db.pgpass` or `$BR_ETC/db.cnf`.

- [ ] **Step 1: Failing tests** — `tests/hooks_bundled.bats`:
```bash
setup() {
    load test_helper
    TMP=$(mktemp -d)
    export BR_ETC=$TMP/etc BR_DUMP_DIR=$TMP/dumps CALLS=$TMP/calls
    mkdir -p "$BR_ETC" "$TMP/bin"
    # generic recording stub; pg_dump/mysqldump also create their output file
    for c in php runuser systemctl dpkg docker pg_dump mariadb-dump; do
        cat >"$TMP/bin/$c" <<'EOF'
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
EOF
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
```

- [ ] **Step 2: Run, expect failure** — `make test`.

- [ ] **Step 3: Implement `lib/dbdump.sh`**
```bash
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

dbdump_clean() { rm -rf "${DUMP_DIR:?}"/*; }
```

- [ ] **Step 4: Hooks.** Each starts with the same header:
```bash
#!/bin/bash
set -euo pipefail
export LC_ALL=C
lib=$(dirname "$(readlink -f "$0")")/../lib
# shellcheck source=../lib/common.sh
source "$lib/common.sh"
# shellcheck source=../lib/dbdump.sh
source "$lib/dbdump.sh"
```

`hooks/10-nextcloud.pre` (header, then):
```bash
# Nextcloud: maintenance mode on, optional service stop, DB dump, package list.
load_conf "$BR_ETC/client.conf" NC_DIR DB_TYPE DB_NAME
log "nextcloud: maintenance mode on"
runuser -u "${NC_WEB_USER:-www-data}" -- php "$NC_DIR/occ" maintenance:mode --on
if [[ -n ${NC_STOP_SERVICE:-} ]]; then
    log "nextcloud: stopping $NC_STOP_SERVICE"
    systemctl stop "$NC_STOP_SERVICE"
fi
dbdump_run
dpkg --get-selections >"$DUMP_DIR/dpkg-selections.txt"
```

`hooks/10-nextcloud.post` (header but `set -uo pipefail` instead of `-euo`, then):
```bash
# Nextcloud: bring everything back; try every step even if one fails.
load_conf "$BR_ETC/client.conf" NC_DIR
rc=0
if [[ -n ${NC_STOP_SERVICE:-} ]]; then
    log "nextcloud: starting $NC_STOP_SERVICE"
    systemctl start "$NC_STOP_SERVICE" || { error "could not start $NC_STOP_SERVICE"; rc=1; }
fi
log "nextcloud: maintenance mode off"
runuser -u "${NC_WEB_USER:-www-data}" -- php "$NC_DIR/occ" maintenance:mode --off \
    || { error "could not leave maintenance mode"; rc=1; }
dbdump_clean
exit "$rc"
```

`hooks/10-db-dump.pre` (header, then):
```bash
# Standalone database dump (PostgreSQL / MariaDB).
load_conf "$BR_ETC/client.conf" DB_TYPE DB_NAME
dbdump_run
```

`hooks/10-db-dump.post` (header, then):
```bash
dbdump_clean
```

`hooks/10-paperless.pre` (header without the dbdump source line, then):
```bash
# Paperless-ngx: incremental document export from the running container.
# The export directory is kept between runs so unchanged files are skipped.
load_conf "$BR_ETC/client.conf" PAPERLESS_DIR
log "paperless: exporting documents"
docker compose --project-directory "$PAPERLESS_DIR" exec -T "${PAPERLESS_SERVICE:-webserver}" \
    document_exporter "${PAPERLESS_EXPORT_IN_CONTAINER:-/usr/src/paperless/export}" --delete
```
`chmod +x hooks/*`.

- [ ] **Step 5: Run** — `make check` → pass.
- [ ] **Step 6: Commit** — `git add -A && git commit -m "feat: nextcloud, db-dump and paperless hooks"`

---

### Task 9: systemd units and config examples

**Files:**
- Create: `systemd/borg-relay-backup.service`, `systemd/borg-relay-backup.timer`, `systemd/borg-relay-notify@.service`, `systemd/borg-relay-maint.service`, `systemd/borg-relay-maint.timer`, `systemd/borg-relay-watch.service`, `systemd/borg-relay-watch.timer`, `config/client.conf.example`, `config/relay.conf.example`, `config/notify.conf.example`, `config/repo.conf.example`
- Test: `tests/units.bats`

**Interfaces:**
- Produces: unit names used by the wizards (Task 10). `ExecStart` paths under `/usr/local/lib/borg-relay/bin/`.

- [ ] **Step 1: Failing test** — `tests/units.bats`:
```bash
setup() { load test_helper; }

@test "every ExecStart points at a script in bin/" {
    for u in "$REPO_ROOT"/systemd/*.service; do
        exe=$(sed -n 's|^ExecStart=/usr/local/lib/borg-relay/\([^ ]*\).*|\1|p' "$u")
        [ -n "$exe" ]
        [ -x "$REPO_ROOT/$exe" ]
    done
}

@test "failing services alert via OnFailure" {
    for u in backup maint watch; do
        grep -qx 'OnFailure=borg-relay-notify@%n.service' "$REPO_ROOT/systemd/borg-relay-$u.service"
    done
}

@test "timers are persistent" {
    for t in "$REPO_ROOT"/systemd/*.timer; do grep -qx 'Persistent=true' "$t"; done
}

@test "config examples are valid bash" {
    for c in "$REPO_ROOT"/config/*.example; do bash -n "$c"; done
}
```

- [ ] **Step 2: Run, expect failure.**

- [ ] **Step 3: Units**

`systemd/borg-relay-backup.service`:
```ini
[Unit]
Description=borg-relay backup
Wants=network-online.target
After=network-online.target
OnFailure=borg-relay-notify@%n.service

[Service]
Type=oneshot
ExecStart=/usr/local/lib/borg-relay/bin/borg-relay-backup
TimeoutStartSec=12h
KillMode=mixed
TimeoutStopSec=5min
Nice=10
IOSchedulingClass=idle
```

`systemd/borg-relay-backup.timer` (the wizard adds a drop-in with the chosen `OnCalendar`):
```ini
[Unit]
Description=Daily borg-relay backup

[Timer]
OnCalendar=*-*-* 21:30:00
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
```

`systemd/borg-relay-notify@.service`:
```ini
[Unit]
Description=borg-relay failure alert for %i

[Service]
Type=oneshot
ExecStart=/usr/local/lib/borg-relay/bin/borg-relay-notify %i
```

`systemd/borg-relay-maint.service`:
```ini
[Unit]
Description=borg-relay weekly maintenance (tamper check, prune, compact, check)
Wants=network-online.target
After=network-online.target
OnFailure=borg-relay-notify@%n.service

[Service]
Type=oneshot
User=borgrelay
ExecStart=/usr/local/lib/borg-relay/bin/borg-relay maint
TimeoutStartSec=24h
Nice=10
IOSchedulingClass=idle
```

`systemd/borg-relay-maint.timer`:
```ini
[Unit]
Description=Weekly borg-relay maintenance

[Timer]
OnCalendar=Sun *-*-* 04:00:00
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
```

`systemd/borg-relay-watch.service`:
```ini
[Unit]
Description=borg-relay missed-backup check
Wants=network-online.target
After=network-online.target
OnFailure=borg-relay-notify@%n.service

[Service]
Type=oneshot
User=borgrelay
ExecStart=/usr/local/lib/borg-relay/bin/borg-relay watch
TimeoutStartSec=2h
```

`systemd/borg-relay-watch.timer`:
```ini
[Unit]
Description=Daily borg-relay missed-backup check

[Timer]
OnCalendar=*-*-* 09:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

- [ ] **Step 4: Config examples** (documented, values are placeholders like `relay.example.lan`):

`config/client.conf.example`:
```bash
# /etc/borg-relay/client.conf (mode 600) - written by the installer.
RELAY_HOST=relay.example.lan
RELAY_PORT=22
RELAY_USER=borgrelay
BACKUP_NAME=myhost                 # repo name on the target; default: short hostname
CLIENT_KEY=/root/.ssh/borg-relay_ed25519
BORG_PASSPHRASE='change-me'
BACKUP_PATHS=(/etc /root /home)
EXCLUDES=('*/.cache/*')
RETRY_INTERVAL=60                  # seconds between reachability checks
RETRY_WINDOW=3600                  # give up after this many seconds
LOG_KEEP_DAYS=30
# Hook settings (only for enabled hooks):
# NC_DIR=/var/www/nextcloud NC_WEB_USER=www-data NC_STOP_SERVICE=nginx
# DB_TYPE=pgsql DB_NAME=nextcloud DB_HOST=localhost DB_USER=nextcloud
# PAPERLESS_DIR=/opt/paperless PAPERLESS_SERVICE=webserver
# PAPERLESS_EXPORT_IN_CONTAINER=/usr/src/paperless/export
```

`config/relay.conf.example`:
```bash
# /etc/borg-relay/relay.conf (mode 640 root:borgrelay) - written by the installer.
BACKEND=mount                      # mount | ssh-borg
# mount backend
MOUNTPOINT=/srv/borgtarget
MOUNT_REQUIRE_MOUNTPOINT=yes       # never set to "no" outside tests
# ssh-borg backend
# TARGET_HOST=backup.example.net
# TARGET_PORT=22
# TARGET_USER=backup
# TARGET_KEY=/var/lib/borg-relay/.ssh/target_ed25519
# REMOTE_BORG=borg                 # e.g. borg-1.4 on providers offering several versions
```

`config/notify.conf.example`:
```bash
# /etc/borg-relay/notify.conf (client: 600 root; relay: 640 root:borgrelay)
GOTIFY_URL=https://gotify.example.lan
GOTIFY_TOKEN=change-me
GOTIFY_INSECURE=no                 # yes = accept a self-signed certificate
UP_ENDPOINT=                       # UnifiedPush endpoint URL (e.g. NextPush)
UP_MAX_BYTES=4000
```

`config/repo.conf.example`:
```bash
# /etc/borg-relay/repos.d/<name>.conf (mode 600 borgrelay) - written by borg-relay set-passphrase.
BORG_PASSPHRASE='change-me'
KEEP='--keep-within=7d --keep-weekly=4 --keep-monthly=6'
MAX_AGE_HOURS=26
```

- [ ] **Step 5: Run** — `make check` → pass.
- [ ] **Step 6: Commit** — `git add -A && git commit -m "feat: systemd units and config examples"`

---

### Task 10: Installer — `lib/ui.sh`, wizards, `install.sh`

**Files:**
- Create: `lib/ui.sh`, `wizard/main.sh`, `wizard/common.sh`, `wizard/relay.sh`, `wizard/client.sh`, `install.sh`
- Test: `tests/ui.bats`

**Interfaces:**
- Consumes: everything above.
- Produces (`lib/ui.sh`): `ui_header`, `ui_info`, `ui_ok`, `ui_fail` (stderr); `ask VAR QUESTION [DEFAULT]` (existing value wins); `ask_secret VAR QUESTION` (existing kept on empty input); `ask_yn QUESTION y|n` → rc; `pause MSG`; `step DESC FN` (runs FN; on failure offers retry, FN re-asks with current values as defaults; abort → `die`); `conf_write FILE MODE OWNER:GROUP VAR...` (scalars and arrays, `%q`-quoted, atomic); `gen_passphrase` (32 alnum chars); `classify_borg_error TEXT` → `missing|denied|unmounted|network|other`. All reads from `BR_TTY` (default `/dev/tty`).
- Wizard installs to `/usr/local/lib/borg-relay` and symlinks `/usr/local/bin/borg-relay` and `/usr/local/bin/borg-relay-backup`.

- [ ] **Step 1: Failing tests** — `tests/ui.bats`:
```bash
setup() {
    load test_helper
    source "$REPO_ROOT/lib/common.sh"
    source "$REPO_ROOT/lib/ui.sh"
    TMP=$(mktemp -d)
    export BR_TTY=$TMP/tty
}
teardown() { rm -rf "$TMP"; }

@test "ask uses the answer, else the current value, else the default" {
    printf 'typed\n' >"$BR_TTY"; X=; ask X "Q" def; [ "$X" = typed ]
    printf '\n' >"$BR_TTY";      X=; ask X "Q" def; [ "$X" = def ]
    printf '\n' >"$BR_TTY";      X=old; ask X "Q" def; [ "$X" = old ]
}

@test "ask_yn honours default and answers" {
    printf '\n' >"$BR_TTY";  ask_yn "Q" y
    printf 'n\n' >"$BR_TTY"; run ask_yn "Q" y; [ "$status" -ne 0 ]
    printf 'Y\n' >"$BR_TTY"; ask_yn "Q" n
}

@test "conf_write round-trips quotes, dollars, spaces and arrays" {
    P='a$b "c" '\''d'\'' e\f'
    PATHS=("/srv/my data" '/x/$y' /etc)
    conf_write "$TMP/c" 600 "$(id -u):$(id -g)" P PATHS
    [ "$(stat -c %a "$TMP/c")" = 600 ]
    unset P PATHS
    source "$TMP/c"
    [ "$P" = 'a$b "c" '\''d'\'' e\f' ]
    [ "${#PATHS[@]}" = 3 ]
    [ "${PATHS[0]}" = "/srv/my data" ]
    [ "${PATHS[1]}" = '/x/$y' ]
}

@test "gen_passphrase gives 32 alphanumerics" {
    p=$(gen_passphrase)
    [[ $p =~ ^[A-Za-z0-9]{32}$ ]]
    [ "$p" != "$(gen_passphrase)" ]
}

@test "classify_borg_error" {
    [ "$(classify_borg_error 'Repository /x does not exist.')" = missing ]
    [ "$(classify_borg_error 'borgrelay@r: Permission denied (publickey).')" = denied ]
    [ "$(classify_borg_error 'Remote: ERROR: storage target is not mounted at /srv')" = unmounted ]
    [ "$(classify_borg_error 'ssh: connect to host r port 22: Connection refused')" = network ]
    [ "$(classify_borg_error 'something else')" = other ]
}

@test "step retries a failing check until it passes" {
    printf 'y\n' >"$BR_TTY"
    n=0; check() { n=$((n+1)); (( n >= 2 )); }
    step "the check" check
    [ "$n" = 2 ]
}

@test "step aborts when the user declines to retry" {
    printf 'n\n' >"$BR_TTY"
    check() { false; }
    run step "the check" check
    [ "$status" -eq 1 ]
    [[ $output == *"aborted at: the check"* ]]
}
```

- [ ] **Step 2: Run, expect failure.**

- [ ] **Step 3: Implement `lib/ui.sh`**
```bash
# shellcheck shell=bash
# Interactive helpers for the installer. Input comes from $BR_TTY (default /dev/tty)
# so the wizard works under `bash <(curl …)`.
BR_TTY="${BR_TTY:-/dev/tty}"

ui_header() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*" >&2; }
ui_info()   { printf '   %s\n' "$*" >&2; }
ui_ok()     { printf ' \033[32m✓\033[0m %s\n' "$*" >&2; }
ui_fail()   { printf ' \033[31m✗\033[0m %s\n' "$*" >&2; }

ask() {
    local -n _ask_v=$1
    local q=$2 def ans
    def=${_ask_v:-${3-}}
    printf ' %s%s: ' "$q" "${def:+ [$def]}" >&2
    IFS= read -r ans <"$BR_TTY" || ans=
    _ask_v=${ans:-$def}
}

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

step() {
    local desc=$1 fn=$2
    while :; do
        if "$fn"; then ui_ok "$desc"; return 0; fi
        ui_fail "$desc"
        ask_yn "Retry (you can change your answers)?" y || die "aborted at: $desc"
    done
}

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
                printf ' %q' "${_cw_a[@]}"
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

gen_passphrase() {
    python3 -c 'import secrets, string; a = string.ascii_letters + string.digits; print("".join(secrets.choice(a) for _ in range(32)))'
}

classify_borg_error() {
    case $1 in
        *"does not exist"*)                 echo missing ;;
        *"Permission denied"*)              echo denied ;;
        *"not mounted"*)                    echo unmounted ;;
        *"Connection refused"*|*"timed out"*|*"No route"*|*"Could not resolve"*|*"Name or service not known"*) echo network ;;
        *)                                  echo other ;;
    esac
}
```

- [ ] **Step 4: Implement `install.sh`**
```bash
#!/bin/bash
# borg-relay installer bootstrap.
#   bash <(curl -fsSL https://raw.githubusercontent.com/overcuriousity/borg-relay-backup/v1.0.0/install.sh)
# Downloads the tagged release and starts the interactive wizard.
set -euo pipefail
REPO_SLUG=overcuriousity/borg-relay-backup
REF=${BR_REF:-v1.0.0}

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
```

- [ ] **Step 5: Implement `wizard/main.sh`**
```bash
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
# shellcheck source=common.sh
source "$SRC/wizard/common.sh"

require_root
grep -q '^13' /etc/debian_version 2>/dev/null || ui_info "Note: tested on Debian 13 only."
ui_header "borg-relay-backup $(cat "$SRC/VERSION") installer"
ui_info "Every step is checked before the next one. Re-running is safe; your previous answers become the defaults."

ROLE=
ask ROLE "Role of this machine: 'relay' or 'client'" client
case $ROLE in
    relay)  # shellcheck source=relay.sh
            source "$SRC/wizard/relay.sh";  relay_wizard ;;
    client) # shellcheck source=client.sh
            source "$SRC/wizard/client.sh"; client_wizard ;;
    *)      die "unknown role '$ROLE'" ;;
esac
```

- [ ] **Step 6: Implement `wizard/common.sh`**
```bash
# shellcheck shell=bash
# Shared wizard steps. Expects SRC, PREFIX and the libs from wizard/main.sh.

wiz_preload() {   # wiz_preload FILE - earlier answers become defaults
    # shellcheck disable=SC1090
    [[ -r $1 ]] && source "$1"
    return 0
}

wiz_apt() {
    ui_info "Installing packages: $*"
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null || return 1
    borg --version | grep -q '^borg 1\.4' || { ui_fail "BorgBackup 1.4 required, found: $(borg --version)"; return 1; }
}

wiz_install_files() {
    rm -rf "$PREFIX.new"
    mkdir -p "$PREFIX.new"
    cp -a "$SRC"/{bin,lib,hooks,systemd,wizard,config,VERSION} "$PREFIX.new/"
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
        GOTIFY_URL= GOTIFY_TOKEN=
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
```

- [ ] **Step 7: Implement `wizard/relay.sh`**
```bash
# shellcheck shell=bash
# Relay role wizard.
RUSER=borgrelay
RHOME=/var/lib/borg-relay

_relay_deps() {
    local pkgs=(borgbackup openssh-server curl python3)
    ask BACKEND "Storage backend: 'mount' (SMB/NFS/sshfs/… mounted here) or 'ssh-borg' (SSH host that runs borg)" mount
    [[ $BACKEND == mount || $BACKEND == ssh-borg ]] || { ui_fail "unknown backend"; return 1; }
    [[ $BACKEND == mount ]] && pkgs+=(cifs-utils)
    wiz_apt "${pkgs[@]}"
}

_relay_user() {
    id "$RUSER" >/dev/null 2>&1 || useradd --system --home-dir "$RHOME" --create-home --shell /usr/sbin/nologin "$RUSER"
    install -d -m 750 -o "$RUSER" -g "$RUSER" "$RHOME" "$RHOME/state"
    install -d -m 700 -o "$RUSER" -g "$RUSER" "$RHOME/.ssh"
    install -d -m 750 -o root -g "$RUSER" "$BR_ETC"
    install -d -m 700 -o "$RUSER" -g "$RUSER" "$BR_ETC/repos.d"
}

_relay_mount() {
    local opts unit aunit
    MOUNT_TYPE=${MOUNT_TYPE:-cifs}
    ask MOUNT_TYPE "Filesystem type (cifs, nfs, fuse.sshfs, …)"
    ask MOUNT_SOURCE "Source, e.g. //server/share"
    ask MOUNTPOINT "Mountpoint on this relay" /srv/borgtarget
    if [[ $MOUNT_TYPE == cifs ]]; then
        ask CIFS_USER "SMB username"
        ask_secret CIFS_PASS "SMB password"
        ask MOUNT_OPTIONS "Extra mount options" "vers=3.0"
        ( umask 077; printf 'username=%s\npassword=%s\n' "$CIFS_USER" "$CIFS_PASS" >"$BR_ETC/target.cred" )
        opts="credentials=$BR_ETC/target.cred,uid=$RUSER,gid=$RUSER,file_mode=0600,dir_mode=0700${MOUNT_OPTIONS:+,$MOUNT_OPTIONS}"
    else
        ask MOUNT_OPTIONS "Mount options (user '$RUSER' must be able to write)"
        opts=$MOUNT_OPTIONS
    fi
    mkdir -p "$MOUNTPOINT"
    unit=$(systemd-escape -p --suffix=mount "$MOUNTPOINT")
    aunit=${unit%.mount}.automount
    cat >"/etc/systemd/system/$unit" <<EOF
[Unit]
Description=borg-relay storage target
Wants=network-online.target
After=network-online.target

[Mount]
What=$MOUNT_SOURCE
Where=$MOUNTPOINT
Type=$MOUNT_TYPE
Options=$opts
EOF
    cat >"/etc/systemd/system/$aunit" <<EOF
[Unit]
Description=borg-relay storage target (automount)

[Automount]
Where=$MOUNTPOINT
TimeoutIdleSec=600

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$aunit" >/dev/null
    runuser -u "$RUSER" -- sh -c 't="$1/.borg-relay-write-test"; ls "$1" >/dev/null && touch "$t" && rm "$t"' _ "$MOUNTPOINT" \
        && mountpoint -q "$MOUNTPOINT" \
        || { ui_fail "target not mounted or not writable for $RUSER (see: journalctl -u $unit)"; return 1; }
}

_relay_ssh_target() {
    local kh
    ask TARGET_HOST "Target SSH host"
    ask TARGET_PORT "Target SSH port" 22
    ask TARGET_USER "Target SSH user"
    ask REMOTE_BORG "borg command on the target (e.g. borg-1.4 where the provider offers several)" borg
    TARGET_KEY=$RHOME/.ssh/target_ed25519
    [[ -f $TARGET_KEY ]] || runuser -u "$RUSER" -- ssh-keygen -q -t ed25519 -N '' -C "borg-relay@$(hostname -s)" -f "$TARGET_KEY"
    kh=$(mktemp)
    ssh-keyscan -p "$TARGET_PORT" "$TARGET_HOST" >"$kh" 2>/dev/null || true
    [[ -s $kh ]] || { ui_fail "no SSH answer from $TARGET_HOST:$TARGET_PORT"; return 1; }
    ui_info "Host key fingerprints of the target:"; ssh-keygen -lf "$kh" >&2
    ask_yn "Do these match the fingerprints published by your target?" y || return 1
    install -m 600 -o "$RUSER" -g "$RUSER" "$kh" "$RHOME/.ssh/known_hosts"; rm -f "$kh"
    ui_info "Relay public key (must be authorized on the target):"
    printf '\n%s\n\n' "$(cat "$TARGET_KEY.pub")" >&2
    if ask_yn "Copy it now with ssh-copy-id (asks for the target password)?" y; then
        local sftp=()
        ask_yn "Is the target SFTP-only without a shell (e.g. a storage box)?" n && sftp=(-s)
        runuser -u "$RUSER" -- ssh-copy-id "${sftp[@]}" -i "$TARGET_KEY.pub" -p "$TARGET_PORT" "$TARGET_USER@$TARGET_HOST" <"$BR_TTY" || return 1
    else
        pause "Authorize the key on the target"
    fi
    runuser -u "$RUSER" -- ssh -i "$TARGET_KEY" -p "$TARGET_PORT" -o BatchMode=yes "$TARGET_USER@$TARGET_HOST" "$REMOTE_BORG --version" \
        | grep -q '^borg 1\.' || { ui_fail "'$REMOTE_BORG --version' did not run on the target"; return 1; }
}

_relay_backend() {
    if [[ $BACKEND == mount ]]; then
        _relay_mount || return 1
        MOUNT_REQUIRE_MOUNTPOINT=yes
        conf_write "$BR_ETC/relay.conf" 640 "root:$RUSER" BACKEND MOUNTPOINT MOUNT_REQUIRE_MOUNTPOINT MOUNT_TYPE MOUNT_SOURCE MOUNT_OPTIONS CIFS_USER
    else
        _relay_ssh_target || return 1
        conf_write "$BR_ETC/relay.conf" 640 "root:$RUSER" BACKEND TARGET_HOST TARGET_PORT TARGET_USER TARGET_KEY REMOTE_BORG
    fi
}

_relay_sshd() {
    cat >/etc/ssh/sshd_config.d/borg-relay.conf <<EOF
# managed by borg-relay - clients may only run their forced borg command
Match User $RUSER
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AllowTcpForwarding no
    AllowStreamLocalForwarding no
    PermitTunnel no
    PermitTTY no
    X11Forwarding no
    AllowAgentForwarding no
Match all
EOF
    sshd -t && systemctl reload ssh
}

_relay_timers() {
    wiz_units borg-relay-maint.service borg-relay-maint.timer borg-relay-watch.service borg-relay-watch.timer borg-relay-notify@.service
    systemctl enable --now borg-relay-maint.timer borg-relay-watch.timer >/dev/null
}

_relay_recovery() {
    ui_header "Recovery entry for KeePassXC - RELAY $(hostname -s)"
    {
        echo "===== borg-relay RELAY $(hostname -s) ($(date -I)) ====="
        echo "Backend: $BACKEND"
        if [[ $BACKEND == mount ]]; then
            echo "Target:  $MOUNT_TYPE $MOUNT_SOURCE (options: ${MOUNT_OPTIONS:-none})"
            [[ $MOUNT_TYPE == cifs ]] && echo "SMB user: $CIFS_USER   SMB password: $CIFS_PASS"
            echo "Repos:   <share>/<client-name>"
            echo "Without the relay: mount the share anywhere, then"
            echo "  BORG_PASSPHRASE=<client passphrase> borg list /mnt/share/<client-name>"
        else
            echo "Target:  ssh://$TARGET_USER@$TARGET_HOST:$TARGET_PORT  remote borg: $REMOTE_BORG"
            echo "Repos:   <target home>/<client-name>"
            echo "Without the relay (target password or any authorized key):"
            echo "  BORG_REMOTE_PATH=$REMOTE_BORG BORG_PASSPHRASE=<client passphrase> borg list ssh://$TARGET_USER@$TARGET_HOST:$TARGET_PORT/./<client-name>"
        fi
        echo "Add a client:  borg-relay add-client <name>   then   borg-relay set-passphrase <name>"
        echo "====="
    } >&2
    pause "Copy this block into KeePassXC now"
}

relay_wizard() {
    wiz_preload "$BR_ETC/relay.conf"
    wiz_preload "$BR_ETC/notify.conf"
    step "packages" _relay_deps
    wiz_install_files
    step "relay user and directories" _relay_user
    step "storage backend" _relay_backend
    step "sshd restrictions" _relay_sshd
    NOTIFY_MODE=640 NOTIFY_OWNER="root:$RUSER" wiz_notify
    step "maintenance and watch timers" _relay_timers
    _relay_recovery
    ui_ok "Relay ready. Next: run the installer on each client."
}
```

- [ ] **Step 8: Implement `wizard/client.sh`**
```bash
# shellcheck shell=bash
# Client role wizard.
CLIENT_KEY=/root/.ssh/borg-relay_ed25519
DUMP_DIR_DEFAULT=/var/lib/borg-relay/dumps

_client_repo() { REPO="ssh://${RELAY_USER}@${RELAY_HOST}:${RELAY_PORT}/./${BACKUP_NAME}"; }

_client_deps() { wiz_apt borgbackup openssh-client curl python3; }

_client_identity() {
    local kh
    BACKUP_NAME=${BACKUP_NAME:-$(hostname -s)}
    ask BACKUP_NAME "Name of this client's repository"
    valid_name "$BACKUP_NAME" || { ui_fail "use lowercase letters, digits and dashes"; return 1; }
    ask RELAY_HOST "Relay address (IP or hostname)"
    ask RELAY_PORT "Relay SSH port" 22
    ask RELAY_USER "Relay user" borgrelay
    install -d -m 700 /root/.ssh
    [[ -f $CLIENT_KEY ]] || ssh-keygen -q -t ed25519 -N '' -C "borg-relay:$BACKUP_NAME" -f "$CLIENT_KEY"
    kh=$(mktemp)
    ssh-keyscan -p "$RELAY_PORT" "$RELAY_HOST" >"$kh" 2>/dev/null || true
    [[ -s $kh ]] || { ui_fail "no SSH answer from $RELAY_HOST:$RELAY_PORT"; rm -f "$kh"; return 1; }
    ui_info "Relay host key fingerprints (compare on the relay: ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub):"
    ssh-keygen -lf "$kh" >&2
    ask_yn "Do they match?" y || { rm -f "$kh"; return 1; }
    ssh-keygen -R "[$RELAY_HOST]:$RELAY_PORT" >/dev/null 2>&1 || true
    ssh-keygen -R "$RELAY_HOST" >/dev/null 2>&1 || true
    cat "$kh" >>/root/.ssh/known_hosts; rm -f "$kh"
    _client_repo
}

_client_authorize() {
    local out
    export BORG_RSH="ssh -i $CLIENT_KEY -o BatchMode=yes -o ConnectTimeout=20"
    ui_info "On the relay, run:   borg-relay add-client $BACKUP_NAME"
    ui_info "and paste this key:"
    printf '\n%s\n\n' "$(cat "$CLIENT_KEY.pub")" >&2
    pause "Done on the relay"
    out=$(BORG_PASSPHRASE=x borg_info "$REPO" 2>&1) && { REPO_EXISTS=yes; return 0; }
    case $(classify_borg_error "$out") in
        missing)   REPO_EXISTS=no; return 0 ;;
        denied)    ui_fail "relay rejected the key - was add-client run with the right key?" ;;
        unmounted) ui_fail "relay reports its storage target is not mounted" ;;
        network)   ui_fail "relay not reachable on $RELAY_HOST:$RELAY_PORT" ;;
        *)         ui_fail "unexpected answer: $out" ;;
    esac
    return 1
}

_client_init() {
    export BORG_RSH="ssh -i $CLIENT_KEY -o BatchMode=yes -o ConnectTimeout=20"
    if [[ $REPO_EXISTS == yes ]]; then
        ui_info "Repository '$BACKUP_NAME' already exists on the target."
        ask_secret BORG_PASSPHRASE "Its passphrase"
        export BORG_PASSPHRASE
        borg_info "$REPO" >/dev/null || { ui_fail "passphrase rejected"; return 1; }
    else
        if [[ -z ${BORG_PASSPHRASE:-} ]] && ask_yn "Generate a random 32-character passphrase?" y; then
            BORG_PASSPHRASE=$(gen_passphrase)
        else
            ask_secret BORG_PASSPHRASE "Passphrase for the new repository"
        fi
        export BORG_PASSPHRASE
        borg_init "$REPO" || return 1
    fi
    KEY_EXPORT=$(borg_key_export "$REPO") || return 1
}

_client_relay_passphrase() {
    ui_info "On the relay, run:   borg-relay set-passphrase $BACKUP_NAME"
    ui_info "and paste:           $BORG_PASSPHRASE"
    ask_yn "Did the relay report 'stored and verified'?" y
}

_client_hooks() {
    local h
    BACKUP_PATHS=("${BACKUP_PATHS[@]+"${BACKUP_PATHS[@]}"}")
    local paths=${BACKUP_PATHS[*]:-/etc /root /home} excl=${EXCLUDES[*]:-}
    ask paths "Paths to back up (space-separated)"
    read -ra BACKUP_PATHS <<<"$paths"
    ask excl "Exclude patterns (space-separated, empty for none)"
    read -ra EXCLUDES <<<"$excl"
    install -d -m 700 "$BR_ETC/hooks.d"
    for h in "$BR_ETC"/hooks.d/10-{nextcloud,db-dump,paperless}.{pre,post}; do [[ -L $h ]] && rm -f "$h"; done
    CONF_VARS=(RELAY_HOST RELAY_PORT RELAY_USER BACKUP_NAME CLIENT_KEY BORG_PASSPHRASE BACKUP_PATHS EXCLUDES)

    if ask_yn "Nextcloud on this host (maintenance mode + DB dump)?" "$([[ -n ${NC_DIR:-} ]] && echo y || echo n)"; then
        ask NC_DIR "Nextcloud directory" /var/www/nextcloud
        ask NC_WEB_USER "Web server user" www-data
        ask NC_STOP_SERVICE "Service to stop during backup (empty for none)" nginx
        _client_db || return 1
        ln -sf "$PREFIX/hooks/10-nextcloud.pre" "$PREFIX/hooks/10-nextcloud.post" "$BR_ETC/hooks.d/"
        CONF_VARS+=(NC_DIR NC_WEB_USER NC_STOP_SERVICE)
    elif ask_yn "Dump a database before each backup?" "$([[ -n ${DB_TYPE:-} ]] && echo y || echo n)"; then
        _client_db || return 1
        ln -sf "$PREFIX/hooks/10-db-dump.pre" "$PREFIX/hooks/10-db-dump.post" "$BR_ETC/hooks.d/"
    fi
    if ask_yn "Paperless-ngx on this host (document export)?" "$([[ -n ${PAPERLESS_DIR:-} ]] && echo y || echo n)"; then
        ask PAPERLESS_DIR "Paperless docker compose directory"
        ask PAPERLESS_SERVICE "Compose service name" webserver
        ask PAPERLESS_EXPORT_IN_CONTAINER "Export path inside the container" /usr/src/paperless/export
        local host_export=$PAPERLESS_DIR/export
        ask host_export "Same export directory on this host"
        BACKUP_PATHS+=("$host_export")
        ln -sf "$PREFIX/hooks/10-paperless.pre" "$BR_ETC/hooks.d/"
        CONF_VARS+=(PAPERLESS_DIR PAPERLESS_SERVICE PAPERLESS_EXPORT_IN_CONTAINER)
    fi
    ui_info "Site-specific hooks: put executable NN-name.pre / NN-name.post files into $BR_ETC/hooks.d/"
    conf_write "$BR_ETC/client.conf" 600 root:root "${CONF_VARS[@]}"
    ui_info "Preview of the first files:"
    borg_dry_run "$REPO" 2>&1 | head -n 15 >&2 || return 1
}

_client_db() {
    ask DB_TYPE "Database type: pgsql or mysql" pgsql
    [[ $DB_TYPE == pgsql || $DB_TYPE == mysql ]] || { ui_fail "pgsql or mysql"; return 1; }
    ask DB_NAME "Database name" nextcloud
    ask DB_HOST "Database host" localhost
    ask DB_USER "Database user" "$DB_NAME"
    local pw=
    ask_secret pw "Database password"
    if [[ $DB_TYPE == pgsql ]]; then
        ( umask 077; printf '%s:*:%s:%s:%s\n' "$DB_HOST" "$DB_NAME" "$DB_USER" "$pw" >"$BR_ETC/db.pgpass" )
    else
        ( umask 077; printf '[client]\nuser=%s\npassword="%s"\n' "$DB_USER" "$pw" >"$BR_ETC/db.cnf" )
    fi
    BACKUP_PATHS+=("$DUMP_DIR_DEFAULT")
    CONF_VARS+=(DB_TYPE DB_NAME DB_HOST DB_USER)
}

_client_timer() {
    SCHEDULE=${SCHEDULE:-"*-*-* 21:30:00"}
    ask SCHEDULE "Daily start time (systemd OnCalendar)"
    systemd-analyze calendar "$SCHEDULE" >/dev/null 2>&1 || { ui_fail "not a valid OnCalendar expression"; return 1; }
    wiz_units borg-relay-backup.service borg-relay-backup.timer borg-relay-notify@.service
    install -d /etc/systemd/system/borg-relay-backup.timer.d
    printf '[Timer]\nOnCalendar=\nOnCalendar=%s\n' "$SCHEDULE" >/etc/systemd/system/borg-relay-backup.timer.d/schedule.conf
    systemctl daemon-reload
    systemctl enable --now borg-relay-backup.timer >/dev/null
}

_client_first_run() {
    ask_yn "Run the first backup now (can take long for big data)?" y || return 0
    ui_info "Running ... follow it in another shell with: journalctl -fu borg-relay-backup"
    systemctl start borg-relay-backup.service || { journalctl -u borg-relay-backup -n 30 --no-pager >&2; return 1; }
    borg_archive_names "$REPO" >&2
}

_client_recovery() {
    ui_header "Recovery entry for KeePassXC - CLIENT $BACKUP_NAME"
    {
        echo "===== borg-relay CLIENT $BACKUP_NAME ($(date -I)) ====="
        echo "Repository via relay: $REPO"
        echo "Repository on target: <target>/$BACKUP_NAME  (see the RELAY entry)"
        echo "Passphrase: $BORG_PASSPHRASE"
        echo "Repo key (only needed if the key inside the repo is damaged;"
        echo "restore with: borg key import <repo> <file-with-this-text>):"
        echo "$KEY_EXPORT"
        echo "Client SSH key: $CLIENT_KEY (needed only for access via the relay)"
        echo "Restore:"
        echo "  export BORG_PASSPHRASE='…'"
        echo "  borg list <repo>"
        echo "  borg mount <repo>::<archive> /mnt/restore      # browse, then: borg umount /mnt/restore"
        echo "  borg extract <repo>::<archive> path/inside/archive"
        echo "====="
    } >&2
    pause "Copy this block into KeePassXC now"
}

client_wizard() {
    wiz_preload "$BR_ETC/client.conf"
    wiz_preload "$BR_ETC/notify.conf"
    step "packages" _client_deps
    wiz_install_files
    install -d -m 700 "$BR_ETC"
    step "client key and relay host key" _client_identity
    step "relay accepts this client" _client_authorize
    step "repository" _client_init
    step "relay knows the passphrase" _client_relay_passphrase
    step "paths and hooks" _client_hooks
    NOTIFY_MODE=600 NOTIFY_OWNER=root:root wiz_notify
    step "daily timer" _client_timer
    step "first backup" _client_first_run
    _client_recovery
    ui_ok "Client '$BACKUP_NAME' is set up."
}
```

- [ ] **Step 9: Run** — `make check` → pass (ui tests + lint of all wizard files).
- [ ] **Step 10: Smoke test from a checkout** inside the container (no systemd, so only up to the first apt step is meaningful):

Run: `podman run --rm -it -v $PWD:/src:Z borg-relay-test bash -c 'cd /src && printf "nonsense\n" | BR_TTY=/dev/stdin bash install.sh'`
Expected: header printed, then `ERROR: unknown role 'nonsense'`.

- [ ] **Step 11: Commit** — `git add -A && git commit -m "feat: interactive installer with verified steps and recovery blocks"`

---

### Task 11: Documentation

**Files:**
- Create: `README.md`, `SETUP.md`, `RESTORE.md`, `docs/rollout-checklist.md`

No code; each file must contain the listed sections with working commands that match the scripts above.

- [ ] **Step 1: `README.md`** — sections: what it is (one paragraph, goal from spec), architecture diagram (from spec), security model (append-only enforced on the relay, tamper check, relay is the trusted component, client-side encryption, what a compromised client/relay can and cannot do), features, quick start (the one-liner with `v1.0.0`, relay first then clients), operation (`borg-relay list`, `journalctl -u borg-relay-backup`, `systemctl list-timers 'borg-relay*'`), limitations (relay down stops watch; NextPush on Nextcloud caveat; paths with spaces must be entered via `client.conf`, not the wizard prompt), license.
- [ ] **Step 2: `SETUP.md`** — prerequisites (Debian 13 containers; relay privileged only for the `mount` backend with CIFS; Proxmox firewall: clients → relay:22 only, relay → target only), preparing a target with two examples (Hetzner Storage Box via `ssh-borg` with port 23, `REMOTE_BORG=borg-1.4`, SFTP-only `ssh-copy-id -s`, sub-accounts optional; any SMB share via `mount`), relay installation walk-through, client installation walk-through (incl. the two relay commands), adding site-specific hooks (example: a `20-update.post` that pulls container images, marked as an example), changing the target (stop timers, copy the repo tree, rerun relay wizard, `borg-relay list`).
- [ ] **Step 3: `RESTORE.md`** — restore with only KeePassXC (relay up / relay gone, both backends), single files via `borg mount`, full host rebuild (reinstall Debian → installer with the same name, `REPO_EXISTS` path → `borg extract`), Nextcloud restore (files, `psql`/`mariadb` import of the dump, `occ maintenance:mode --off`, `occ maintenance:data-fingerprint`), Paperless restore (`document_importer`), "Rolling back an append-only repository" (summarize borg 1.4 docs: inspect `transactions`, remove segment files newer than the last good transaction, delete `index.*`/`hints.*`/`integrity.*`, `borg check --repair` not needed for pure rollback; link to the borg docs section "append-only mode").
- [ ] **Step 4: `docs/rollout-checklist.md`** — checkbox list for the greenfield rollout: verify `--restrict-to-repository` relative path on the real target; relay wizard; each client wizard; force a failure (stop relay sshd) and confirm alert; confirm watch alert by setting `MAX_AGE_HOURS=0` once; run `borg-relay maint` manually; test a restore of one file per client; record dates.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "docs: readme, setup, restore, rollout checklist"`

---

### Task 12: Publish

- [ ] **Step 1: Final check** — `make check` → all green; `git status` clean; a grep for the site's private IPs, hostnames, account IDs and mail addresses (kept outside the repo) returns nothing.
- [ ] **Step 2: Create the GitHub repo and push**
```bash
gh repo create overcuriousity/borg-relay-backup --public --source . --remote origin \
  --description "Target-agnostic, append-only borg backups for unprivileged containers behind a relay" --push
```
- [ ] **Step 3: CI** — `gh run watch --exit-status` → success.
- [ ] **Step 4: Tag and release**
```bash
git tag -a v1.0.0 -m "v1.0.0" && git push origin v1.0.0
gh release create v1.0.0 --title v1.0.0 --notes "First release. Install: bash <(curl -fsSL https://raw.githubusercontent.com/overcuriousity/borg-relay-backup/v1.0.0/install.sh)"
```
- [ ] **Step 5: Verify the one-liner source** — `curl -fsSL https://raw.githubusercontent.com/overcuriousity/borg-relay-backup/v1.0.0/install.sh | head -3` shows the bootstrap header; `curl -fsSIL https://github.com/overcuriousity/borg-relay-backup/archive/refs/tags/v1.0.0.tar.gz | grep -i '^HTTP.* 200'`.
