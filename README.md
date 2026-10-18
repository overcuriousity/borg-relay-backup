# borg-relay-backup

Incremental, client-side encrypted [BorgBackup](https://www.borgbackup.org/) backups for
machines that cannot (or must not) reach the storage target themselves — typically
unprivileged Proxmox LXC containers. A single **relay** sits between the clients and the
storage target and enforces **append-only** access. The storage target is exchangeable:
SMB/NFS/sshfs shares, or any SSH host that runs borg.

```
client ──ssh──> relay: forced command `borg-relay-serve <name>`
                      │
                      ├─ backend "mount":    borg serve on the relay against a mounted
                      │                      target (SMB, NFS, sshfs, rclone mount, …)
                      └─ backend "ssh-borg": pipe to `borg serve` on any SSH host that
                                             provides borg
```

## Security model

- **Client-side encryption.** Each client has its own repository and passphrase
  (`repokey-blake2`). Neither the relay nor the target can read backup contents.
- **Append-only, enforced by the relay.** A client's SSH key on the relay is pinned to
  `borg-relay-serve <name>`: no shell, no forwarding, exactly one repository, always
  `borg serve --append-only`. A compromised client can add archives but cannot destroy
  its history.
- **Tamper check.** In borg 1.x append-only mode a client can still *mark* archives as
  deleted; the deletion only becomes final when a full-access client writes. Only the relay
  ever prunes, and before it does it checks that every archive it saw last time still
  exists (by archive id, so a re-created archive with the same name is caught) and that
  no new archive is backdated (which could push real ones out of retention). If either
  check fails, it skips that repository and alerts you, so the deletion can be rolled
  back (see [RESTORE.md](RESTORE.md)).
- **The relay is the trusted component.** It holds the target credentials and the repo
  passphrases (for prune/compact/check). Protect it accordingly.
- **Clients never learn the target.** Swapping the target only changes the relay.

## Features

- One-line interactive installer; every step is verified before the next one; it ends with a
  recovery block to keep in a safe place (e.g. a password manager).
- systemd timers (`Persistent=true`): missed runs catch up after a reboot.
- Alerts for **failed** runs (systemd `OnFailure=`) and for **missing** runs (daily check
  on the relay), via Gotify and/or UnifiedPush (e.g. NextPush).
- Weekly prune → compact → `borg check --repository-only` on the relay.
- Hooks: Nextcloud (maintenance mode + DB dump), PostgreSQL/MariaDB dump, Paperless-ngx
  export, plus your own drop-ins.

## Quick start

On the **relay** first, then on every **client** (as root, Debian 13):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/overcuriousity/borg-relay-backup/v1.0.4/install.sh)
```

The client wizard tells you which two commands to run on the relay
(`borg-relay add-client <name>`, `borg-relay set-passphrase <name>`).
Details: [SETUP.md](SETUP.md).

## Operation

```bash
borg-relay list                              # relay: repos, archive count, age of newest
systemctl list-timers 'borg-relay*'          # both: schedules
journalctl -u borg-relay-backup              # client: run logs (also /var/log/borg-relay/)
journalctl -u borg-relay-maint -u borg-relay-watch   # relay
```

### Running backups manually

On the **client**, as root:

```bash
# Regular backup now (with hooks). Blocks until done; add --no-block to return at once.
systemctl start borg-relay-backup
journalctl -fu borg-relay-backup             # follow progress

# Seed backup (full upload without hooks, services stay online). Use it for the first
# backup and to re-run a first backup that failed or was interrupted.
systemctl start --no-block borg-relay-seed
journalctl -fu borg-relay-seed               # follow progress
```

A seed run pauses the daily timer and resumes it when it stops, also when it fails. If a
seed run failed, start it again before the next scheduled run; otherwise that run uploads
the rest with hooks (e.g. Nextcloud in maintenance mode for hours). Borg writes a checkpoint
every 30 minutes, so a new run picks up the data that is already uploaded instead of
starting over.

Both units run `/usr/local/lib/borg-relay/bin/borg-relay-backup [--seed]`. Starting them
through systemd keeps the failure alerts (`OnFailure=`) and the timer handling.

### Where things live

Configuration is plain shell `KEY=value` files; changes apply on the next run. Annotated
examples are in [`config/`](config/).

| Path | Host | Contents |
|---|---|---|
| `/etc/borg-relay/client.conf` | client | relay address, repo name, passphrase, backup paths, excludes, retry, hook settings |
| `/etc/borg-relay/hooks.d/` | client | `NN-name.pre` / `NN-name.post` hooks (see [SETUP.md](SETUP.md#5-hooks)) |
| `/etc/borg-relay/db.pgpass`, `db.cnf` | client | database credentials for the dump hooks |
| `/root/.ssh/borg-relay_ed25519` | client | client key for the relay |
| `/etc/borg-relay/relay.conf` | relay | backend (`mount` / `ssh-borg`) and storage target |
| `/etc/borg-relay/repos.d/<name>.conf` | relay | per-client passphrase, retention (`KEEP`), `MAX_AGE_HOURS` |
| `/etc/borg-relay/target.cred` | relay | SMB credentials (`mount` backend) |
| `/var/lib/borg-relay/.ssh/` | relay | `authorized_keys` (client keys), `target_ed25519` (key for the target) |
| `/var/lib/borg-relay/state/` | relay | archive lists for the tamper check |
| `/etc/borg-relay/notify.conf` | both | Gotify / UnifiedPush settings |
| `/var/log/borg-relay/` | client | run logs |
| `/usr/local/lib/borg-relay/` | both | installed scripts (overwritten on update — don't edit) |

To change the schedule, edit the drop-in instead of the unit (the units are overwritten on
update):

```bash
systemctl edit borg-relay-backup.timer       # client; wizard's time is in timer.d/schedule.conf
systemctl edit borg-relay-maint.timer        # relay: weekly prune/compact/check
systemctl edit borg-relay-watch.timer        # relay: daily missed-backup check
```

## Limitations

- If the relay is down, the missed-run check is down too. Clients still alert on their own
  failures (repository unreachable).
- NextPush runs on Nextcloud: alerts about that Nextcloud cannot reach you while it is down.
  Configure a second backend if that matters.
- The wizard reads backup paths space-separated; paths containing spaces go into
  `/etc/borg-relay/client.conf` directly.
- BorgBackup 1.4 only. All borg calls live in `lib/borg.sh` to ease a later move to Borg 2.

## Development

`make check` runs shellcheck and the bats suite in a `debian:trixie` container (podman).

## License

MIT
