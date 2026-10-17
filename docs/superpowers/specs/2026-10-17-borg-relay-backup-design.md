# borg-relay-backup — Design

Date: 2026-10-17
Status: approved in discussion, pending spec review

## Goal

Incremental, client-side encrypted backups of several Proxmox LXC containers
to a Hetzner Storage Box, with point-in-time restore. Nothing more.

Success means:

- every client produces one archive per day without manual action,
- a failed run **and** a missing run each produce a push alert,
- a compromised client cannot destroy its own backup history,
- repository space is reclaimed according to the retention policy,
- one interactive installer per host yields a working setup plus a
  recovery block for the password manager.

## Constraints

- Clients are **unprivileged** LXC containers (Debian 13). They cannot mount SMB.
- Outbound traffic to the backup target is allowed from **one** relay
  container only (enforced by the Proxmox firewall, outside this repo).
- Target: Hetzner Storage Box. It offers SSH on port 23 and provides
  `borg serve` (versions selected via `--remote-path=borg-1.1|borg-1.2|borg-1.4`).
  No custom software can run there. Sub-accounts exist and support SSH.
- BorgBackup 1.4 (Debian 13 package) on clients and relay.
- The repo is public: no IPs, hostnames, mail addresses or tokens in it.
  All site-specific values are entered at install time.

## Architecture

```
client LXC (unprivileged) --ssh--> relay LXC (unprivileged) --ssh :23--> Storage Box
            ProxyJump                 forwards ONLY to box:23           borg-1.4 serve
```

The relay never touches backup data. The SSH session runs end-to-end from
client to Storage Box; borg data is additionally encrypted client-side.

The SMB relay and its mount scheduling are removed entirely.

### Relay: SSH forwarding

- System user `borgrelay`, shell `/usr/sbin/nologin`.
- Each client public key is added to `~borgrelay/.ssh/authorized_keys` as
  `restrict,port-forwarding,permitopen="<box-host>:23" <key> <client-host>`.
  Result: no shell, no PTY, no agent/X11 forwarding, a single permitted
  destination.
- An sshd drop-in (`/etc/ssh/sshd_config.d/borg-relay.conf`) with a
  `Match User borgrelay` block: `PasswordAuthentication no`,
  `AllowTcpForwarding local`, `PermitTTY no`, `X11Forwarding no`,
  `AllowAgentForwarding no`.

### Storage Box layout

- One sub-account per client host, holding exactly one repo at `./repo`.
- Sub-account `.ssh/authorized_keys` holds two keys:
  - client key, forced:
    `command="borg-1.4 serve --append-only --restrict-to-repository repo",restrict <key>`
  - relay maintenance key, forced:
    `command="borg-1.4 serve --restrict-to-repository repo",restrict <key>`
    (full borg rights, but still no shell).
- Whether `--restrict-to-repository` resolves `repo` relative to the
  sub-account home is verified in the first rollout step; the absolute path
  is used if not.
- The installer **verifies** enforcement by attempting a non-borg command
  with the client key. If it succeeds, the forced command is not honoured:
  the installer warns loudly and the recovery block states "append-only: NOT
  enforced". Nothing claims protection it does not have.

### Client role

Files:

| Path | Purpose |
|---|---|
| `/usr/local/lib/borg-relay/` | library + `borg-relay-backup` entry point |
| `/etc/borg-relay/client.conf` (600) | target, passphrase, paths, excludes, notify settings |
| `/etc/borg-relay/hooks.d/` | executable drop-ins `NN-name.pre` / `NN-name.post`, run in lexical order |
| `/root/.ssh/borg-relay_ed25519` | client key |
| `/root/.ssh/config.d` or `BORG_RSH` | ProxyJump definition (`ssh -J borgrelay@relay -p 23 …`) |
| `borg-relay-backup.service` / `.timer` | daily schedule, `Persistent=true`, `RandomizedDelaySec=10min` |
| `borg-relay-notify@.service` | `OnFailure=` handler, sends failure alert |

Run sequence:

1. `flock` on `/run/borg-relay.lock` (abort if held).
2. Wait for target: `borg info` on the repo; retry every `RETRY_INTERVAL`
   (default 60s) up to `RETRY_WINDOW` (default 60 min). Every failure logs
   the reason (relay unreachable / jump failed / repo error).
3. Run `*.pre` hooks. Any non-zero exit aborts the backup (post hooks still run).
4. `borg create --compression zstd,3 --exclude-caches` with configured paths
   and excludes. Archive name `{hostname}-{now:%Y-%m-%dT%H:%M:%S}`.
5. Run `*.post` hooks always (trap), in lexical order.
6. Notify: success or failure, with full log.

Clients never prune or compact (they cannot: append-only).

Exit status: borg rc 0 → success; rc 1 (warning, e.g. a file changed while
reading) → success, notified with "WARNING" in the title; rc ≥ 2, a failed
pre hook, or an unreachable target → failure (non-zero exit, triggers
`OnFailure=`).

Bundled hooks (opt-in during install):

- **nextcloud**: maintenance mode on (pre), DB dump (pre), maintenance off
  (post). Postgres via `~/.pgpass`-style file, MariaDB via
  `--defaults-extra-file`; credentials file `/etc/borg-relay/db.cnf` (600),
  never on the command line. Dumps under `/var/lib/borg-relay/dumps`
  created with `umask 077`, removed in post. Also writes `dpkg --get-selections`.
- **db-dump**: same dump logic standalone (Postgres / MariaDB).
- **paperless**: `docker compose exec -T webserver document_exporter` into a
  persistent export dir (kept between runs so the exporter is incremental).

Site-specific hooks (e.g. pulling new images after a backup) are placed by
the admin in `hooks.d/` and are not part of this repo.

### Relay role

In addition to forwarding:

- `/etc/borg-relay/repos.d/<host>.conf` (600): repo URL, passphrase, retention.
- Maintenance key `/root/.ssh/borg-relay-maint_ed25519` (full borg rights on boxes).
- `borg-relay-maint.timer` weekly: per repo, first a **tamper check**, then `borg prune` (default
  `--keep-within=7d --keep-weekly=4 --keep-monthly=6`), `borg compact`,
  `borg check --repository-only`. Results notified.
- `borg-relay-watch.timer` daily: per repo, alert if the newest archive is
  older than `MAX_AGE_HOURS` (default 26) or the repo is unreachable.

Tamper check: in borg 1.x append-only mode a restricted client can still
*mark* archives deleted; the deletion only becomes permanent when a
full-access client next writes (i.e. our prune/compact). Since only the relay
ever deletes, it stores the archive list after each maintenance run in
`/var/lib/borg-relay/<host>.archives`. Before the next run, every archive in
that list must still exist. If one is missing, maintenance for that repo is
skipped (no prune, no compact) and a failure alert is sent, so the
tampering can be rolled back per the borg append-only docs.

Known limitation: if the relay itself is down, missed-run detection stops.
The client's own failure alerts still fire (target unreachable).

### Notifications

Library `notify.sh`, backends enabled independently per host:

- **gotify**: `POST $GOTIFY_URL/message?token=…`, optional
  `GOTIFY_INSECURE=yes` (`curl -k`) for local self-signed certificates.
- **unifiedpush**: raw `POST` of `title\n\nmessage` to `UP_ENDPOINT`
  (e.g. NextPush). Body truncated to a configurable size (default 4000 B).

Priority: failure 8, warning 5, success 3. Notification failures are logged
but never change the backup's exit code.

Caveat (documented): NextPush runs on Nextcloud; when that Nextcloud is down,
its alerts cannot be delivered. A second backend is recommended.

### Installer

`bash <(curl -fsSL https://raw.githubusercontent.com/overcuriousity/borg-relay-backup/<tag>/install.sh)`

`install.sh` downloads the tagged release tarball, then runs the role
wizard. Every step is verified before the next one; on failure the step can
be retried or the wizard aborted, never silently skipped. Re-running is
idempotent (existing config values become defaults).

Relay wizard:

1. Dependencies (`borgbackup openssh-server curl`).
2. Storage Box host and main account; outbound test to `<box>:23`.
3. Create `borgrelay` user + sshd drop-in; `sshd -t`; reload.
4. Generate maintenance key; print it for the sub-account step.
5. Notification backends; send test message.
6. Install timers.
7. Recovery block.

Adding a client on the relay: `borg-relay add-client` (prompts for the
client public key, host name, sub-account, passphrase) — called by the
client wizard's instructions.

Client wizard:

1. Dependencies (`borgbackup openssh-client curl`).
2. Relay address; generate client key; show the public key and the exact
   `borg-relay add-client` command to run on the relay; test jump:
   `ssh -J borgrelay@relay -p 23 <sub>@<box> ` reaches the box banner.
3. Sub-account name; install client key **and** relay maintenance key into
   the sub-account `authorized_keys` (one-time, sub-account password, via
   the jump); test forced command (see Storage Box layout).
4. Passphrase (generated by default, 32 chars); `borg init -e repokey-blake2`
   through the client's forced command (`borg serve --append-only` permits
   `init` of the restricted path). `borg key export` captured.
5. Paths, excludes, hooks; dry-run `borg create --dry-run --list | head`.
6. Notification backends; test message.
7. Install units; run one real backup; show `borg list`.
8. Recovery block.

Recovery block (printed once, plain text for KeePassXC):

- host, sub-account, repo URL, `--remote-path`
- passphrase
- exported repo key (full text)
- client SSH private key path and the jump command
- append-only status
- restore one-liners (`borg list`, `borg mount`, `borg extract`) that work
  from **any** machine with the sub-account password, without the relay.

### Restore

`RESTORE.md` covers: restore from a fresh machine with only the KeePassXC
entry; single-file restore via `borg mount`; full-host rebuild; Nextcloud
and Paperless application restore steps.

## Testing

- `shellcheck` on all scripts (CI via GitHub Actions).
- `bats` unit tests for pure functions: config parsing/validation, hook
  ordering, archive-age calculation, notification payload building,
  authorized_keys line generation.
- End-to-end validation happens during the greenfield rollout and is
  recorded in `docs/rollout-checklist.md`.

## Out of scope

- Proxmox firewall configuration (documented, not automated).
- Creating Storage Box sub-accounts (manual in Hetzner Console; documented).
- Backing up Proxmox host config or VM images.
- Borg 2.
