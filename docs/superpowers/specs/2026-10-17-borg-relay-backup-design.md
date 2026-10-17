# borg-relay-backup — Design

Date: 2026-10-17
Status: approved (rev. 2 — target-agnostic relay)

## Goal

Incremental, client-side encrypted backups of several Proxmox LXC containers
to an exchangeable storage target, with point-in-time restore. Nothing more.

Success means:

- every client produces one archive per day without manual action,
- a failed run **and** a missing run each produce a push alert,
- a compromised client cannot destroy its own backup history,
- repository space is reclaimed according to the retention policy,
- the storage target can be swapped by reconfiguring the relay only —
  clients are unaware of the target,
- one interactive installer per host yields a working setup plus a
  recovery block for the password manager.

## Constraints

- Clients are **unprivileged** LXC containers (Debian 13). They cannot mount SMB.
- Exactly **one** relay container may reach the storage target (enforced by
  the Proxmox firewall, outside this repo). Clients reach only the relay.
- **Target-agnostic.** No component other than the relay's backend config
  knows what the target is. Nothing may depend on a specific provider.
- BorgBackup 1.4 (Debian 13 package) on clients and relay. Borg 2 is out of
  scope; all borg invocations live in one library file to ease a later move.
- The repo is public: no IPs, hostnames, mail addresses or tokens in it.
  All site-specific values are entered at install time.

## Architecture

```
client ──ssh──> relay: forced command `borg-relay-serve <host>`
                      │
                      ├─ backend "mount":    borg serve on the relay against a mounted
                      │                      target (SMB, sshfs, rclone mount, …)
                      └─ backend "ssh-borg": pipe to `borg serve` on any SSH host that
                                             provides borg (configurable remote path)
```

The relay is the single trusted component: it enforces append-only, holds
target credentials, the maintenance access and the repo passphrases. It never
sees plaintext backup data (borg encrypts client-side).

### Repository layout (both backends)

One repo per client at `<target-base>/<host>`. Clients always request the
**relative** path `<host>`:

- client repo URL: `ssh://borgrelay@<relay>/./<host>`
- `mount`: `borg-relay-serve` does `cd <mountpoint>` before `borg serve`, so
  `<host>` resolves to `<mountpoint>/<host>`.
- `ssh-borg`: the remote `borg serve` runs in the remote account's home, so
  `<host>` resolves to `<home>/<host>`. A subdirectory is chosen by using an
  account whose home is that directory (e.g. a storage sub-account).

Because the layout is identical, moving to another target is: copy the directory tree
(e.g. rsync), change the relay backend config.

### Relay: client access

- System user `borgrelay`, shell `/usr/sbin/nologin`.
- Each client key in `~borgrelay/.ssh/authorized_keys`:
  `restrict,command="/usr/local/lib/borg-relay/borg-relay-serve <host>" <key> borg-relay:<host>`
- sshd drop-in `/etc/ssh/sshd_config.d/borg-relay.conf`, `Match User borgrelay`:
  `PasswordAuthentication no`, `AllowTcpForwarding no`, `PermitTTY no`,
  `X11Forwarding no`, `AllowAgentForwarding no`.
- `<host>` must match `^[a-z0-9][a-z0-9-]{0,62}$`; `borg-relay-serve` rejects
  anything else (no path traversal).
- `borg-relay-serve <host>` ignores `SSH_ORIGINAL_COMMAND` (standard borg
  forced-command practice) and always serves **append-only**, restricted to
  that one repo:
  - `mount`: verify `mountpoint -q <mountpoint>` (after touching it to
    trigger the automount); if not mounted, exit with an error so borg never
    writes into the bare directory. Then
    `cd <mountpoint> && exec borg serve --append-only --restrict-to-repository <host>`.
  - `ssh-borg`: `exec ssh -i <target-key> -p <port> -o BatchMode=yes <user>@<target-host> "<remote-borg> serve --append-only --restrict-to-repository <host>"`.
  The new repo is created by the client's `borg init` through this path
  (append-only permits init of the restricted path).

### Relay: target backends

Config `/etc/borg-relay/relay.conf` (600), `BACKEND=mount|ssh-borg`.

- **mount**: the installer writes a systemd `.mount` + `.automount` unit
  for the mountpoint (`/srv/borg-target` default) from user-supplied
  type/source/options; for CIFS a credentials file
  `/etc/borg-relay/target.cred` (600) and `uid=borgrelay,gid=borgrelay`. The
  relay container must be privileged for CIFS (as today).
- **ssh-borg**: target host, port, user, remote borg command (default
  `borg`; e.g. `borg-1.4` where the provider offers versions). Target key
  `~borgrelay/.ssh/target_ed25519`, host key pinned at install in
  `~borgrelay/.ssh/known_hosts`. The relay may be unprivileged.

Library function `relay_repo_location <host>` returns the full-access
location used by maintenance: `<mountpoint>/<host>` (mount) or
`ssh://<user>@<target-host>:<port>/./<host>` plus `--remote-path` (ssh-borg).

### Relay: maintenance

- `/etc/borg-relay/repos.d/<host>.conf` (600): passphrase, retention
  (default `--keep-within=7d --keep-weekly=4 --keep-monthly=6`),
  `MAX_AGE_HOURS` (default 26).
- `borg-relay-maint.timer` weekly, per repo: tamper check → `borg prune` →
  `borg compact` → `borg check --repository-only`. Results notified.
- `borg-relay-watch.timer` daily, per repo: alert if the newest archive is
  older than `MAX_AGE_HOURS`, or the repo/target is unreachable.
- Maintenance runs as `borgrelay`, with full access (no append-only).

Tamper check: in borg 1.x append-only mode a restricted client can still
*mark* archives deleted; the deletion only becomes permanent when a
full-access client next writes (our prune/compact). Since only the relay
ever deletes, it stores the archive list after each maintenance run in
`/var/lib/borg-relay/<host>.archives`. Before the next run, every archive in
that list must still exist. If one is missing, maintenance for that repo is
skipped (no prune, no compact) and a failure alert is sent, so the
tampering can be rolled back per the borg append-only docs.

Known limitation: if the relay itself is down, missed-run detection stops.
The client's own failure alerts still fire (target unreachable).

### Client role

| Path | Purpose |
|---|---|
| `/usr/local/lib/borg-relay/` | library + `borg-relay-backup` entry point |
| `/etc/borg-relay/client.conf` (600) | relay address, passphrase, paths, excludes, notify settings |
| `/etc/borg-relay/hooks.d/` | executable drop-ins `NN-name.pre` / `NN-name.post`, lexical order |
| `/root/.ssh/borg-relay_ed25519` | client key (`BORG_RSH="ssh -i … -o BatchMode=yes"`) |
| `borg-relay-backup.service` / `.timer` | daily, `Persistent=true`, `RandomizedDelaySec=10min` |
| `borg-relay-notify@.service` | `OnFailure=` handler, sends failure alert |

Run sequence:

1. `flock` on `/run/borg-relay.lock` (abort if held).
2. Wait for repo: `borg info` on the repo URL; retry every `RETRY_INTERVAL`
   (default 60s) up to `RETRY_WINDOW` (default 60 min). Each failure logs
   borg's error output.
3. Run `*.pre` hooks. Any non-zero exit aborts the backup (post hooks still run).
4. `borg create --compression zstd,3 --exclude-caches` with configured paths
   and excludes. Archive name `{hostname}-{now:%Y-%m-%dT%H:%M:%S}`.
5. Run `*.post` hooks always (trap), lexical order.
6. Notify success / warning / failure, with full log.

Clients never prune or compact.

Exit status: borg rc 0 → success; rc 1 (warning, e.g. a file changed while
reading) → success, notified with "WARNING" in the title; rc ≥ 2, a failed
pre hook, or an unreachable repo → failure (non-zero exit → `OnFailure=`).

Bundled hooks (opt-in during install):

- **nextcloud**: maintenance mode on (pre), DB dump (pre), maintenance off
  (post). Postgres via a pgpass file, MariaDB via `--defaults-extra-file`;
  credentials in `/etc/borg-relay/db.cnf` (600), never on the command line.
  Dumps under `/var/lib/borg-relay/dumps` with `umask 077`, removed in post.
  Also writes `dpkg --get-selections`.
- **db-dump**: same dump logic standalone (Postgres / MariaDB).
- **paperless**: `docker compose exec -T webserver document_exporter` into a
  persistent export dir (kept between runs so the exporter is incremental).

Site-specific hooks are placed by the admin in `hooks.d/` and are not part
of this repo.

### Notifications

Library `notify.sh`, backends enabled independently per host (clients and relay):

- **gotify**: `POST $GOTIFY_URL/message?token=…`, optional
  `GOTIFY_INSECURE=yes` (`curl -k`) for local self-signed certificates.
- **unifiedpush**: raw `POST` of `title\n\nmessage` to `UP_ENDPOINT`
  (e.g. NextPush). Body truncated to `UP_MAX_BYTES` (default 4000).

Priority: failure 8, warning 5, success 3. Notification failures are logged
but never change the exit code.

Caveat (documented): NextPush runs on Nextcloud; when that Nextcloud is down,
its alerts cannot be delivered. A second backend is recommended.

### Installer

`bash <(curl -fsSL https://raw.githubusercontent.com/overcuriousity/borg-relay-backup/<tag>/install.sh)`

`install.sh` downloads the tagged release tarball and runs the role wizard
(relay / client). Every step is verified before the next; on failure the
step can be retried or the wizard aborted, never silently skipped.
Re-running is idempotent (existing config values become defaults).

Relay wizard:

1. Dependencies (`borgbackup openssh-server curl`, plus `cifs-utils` for CIFS).
2. Backend choice and its settings.
   - mount: write units, start automount, verify mounted + writable.
   - ssh-borg: generate target key, show public key for the target, pin
     host key, verify `<remote-borg> --version` runs on the target.
3. Create `borgrelay` user, sshd drop-in; `sshd -t`; reload.
4. Notification backends; test message.
5. Install timers.
6. Recovery block (relay part).

`borg-relay add-client <host>` on the relay: prompts for the client public
key, writes the authorized_keys line. `borg-relay set-passphrase <host>`:
prompts for the repo passphrase, writes `repos.d/<host>.conf`, verifies with
`borg info` over the full-access location.

Client wizard:

1. Dependencies (`borgbackup openssh-client curl`).
2. Relay address; generate client key; print the exact
   `borg-relay add-client <host>` command and public key; wait; verify the
   relay answers with borg (`borg info` reports "repository does not exist",
   not an SSH error).
3. Passphrase (generated by default, 32 chars); `borg init -e repokey-blake2`;
   `borg key export` captured. (Append-only enforcement lives in
   `borg-relay-serve` and is proven by the integration test, not by the
   wizard.)
4. Print the `borg-relay set-passphrase <host>` command; wait for
   confirmation.
5. Paths, excludes, hooks; `borg create --dry-run --list` preview.
6. Notification backends; test message.
7. Install units; run one real backup; show `borg list`.
8. Recovery block (client part).

Recovery blocks (plain text for a safe place, e.g. a password manager):

- client: host, relay repo URL, passphrase, full exported repo key,
  client key path, restore one-liners via the relay.
- relay: backend type and settings (no secrets duplicated except target
  credentials), how to reach repos **without** the relay (mount the target
  or ssh to it directly) with `borg list/mount/extract` one-liners.

### Restore

`RESTORE.md`: restore from a fresh machine with only the stored recovery entries
(both with and without a working relay); single-file restore via
`borg mount`; full-host rebuild; Nextcloud and Paperless restore; moving
repos to a new target.

## Testing

- `shellcheck` on all scripts (CI via GitHub Actions).
- `bats` unit tests for pure functions: config validation, host-name
  validation, hook ordering, archive-age calculation, tamper check
  comparison, notification payload building, authorized_keys line generation,
  `borg-relay-serve` command construction per backend.
- Local integration test: `borg-relay-serve` with the mount backend against
  a temp directory, driven by a real `borg` client over a fake `BORG_RSH`
  (proves append-only and repo restriction end to end, no network).
- End-to-end validation happens during the greenfield rollout and is
  recorded in `docs/rollout-checklist.md`.

## Out of scope

- Proxmox firewall configuration (documented, not automated).
- Provider-specific account setup (documented generically; Hetzner as an
  example in the docs only).
- Backing up Proxmox host config or VM images.
- Borg 2.
