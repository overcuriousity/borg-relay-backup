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
  recovery block to store in your password manager (e.g. KeePassXC).
- systemd timers (`Persistent=true`): missed runs catch up after a reboot.
- Alerts for **failed** runs (systemd `OnFailure=`) and for **missing** runs (daily check
  on the relay), via Gotify and/or UnifiedPush (e.g. NextPush).
- Weekly prune → compact → `borg check --repository-only` on the relay.
- Hooks: Nextcloud (maintenance mode + DB dump), PostgreSQL/MariaDB dump, Paperless-ngx
  export, plus your own drop-ins.

## Quick start

On the **relay** first, then on every **client** (as root, Debian 13):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/overcuriousity/borg-relay-backup/v1.0.1/install.sh)
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
systemctl start borg-relay-backup            # client: back up now
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
