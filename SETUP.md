# Setup

## 1. Prerequisites

- Debian 13 on the relay and on every client.
- **Network:** clients may reach only the relay (SSH, port 22). Only the relay may reach the
  storage target. With Proxmox, enforce this in the container firewall.
- **Relay container:** unprivileged is fine for the `ssh-borg` backend. The `mount` backend
  with CIFS/SMB needs a privileged container (kernel CIFS mounts).
- **Names:** each client gets a repository name (`^[a-z0-9][a-z0-9-]{0,62}$`), by default
  its short hostname. It becomes the directory `<target>/<name>`.

## 2. Prepare the storage target

The relay needs one place where it can create one directory per client.

### Example A — SSH host that runs borg (`ssh-borg`)

Any SSH server with borg installed. The repositories live in the login user's home.

Example: a **Hetzner Storage Box** (SSH on port 23, borg provided by the box):

| Wizard question | Answer |
|---|---|
| Storage backend | `ssh-borg` |
| Target SSH host / port / user | `uXXXXX.your-storagebox.de` / `23` / `uXXXXX` (or a sub-account `uXXXXX-subN`) |
| borg command on the target | `borg-1.4` |
| Copy it now with ssh-copy-id? | yes, and *SFTP-only* = yes (uses `ssh-copy-id -s`) |

Enable "SSH support" for the box (or sub-account) in the provider's console first. A
sub-account confines the relay to that sub-account's directory.

### Example B — a mounted share (`mount`)

Any filesystem the relay can mount, e.g. an SMB share (NAS, storage box via SMB):

| Wizard question | Answer |
|---|---|
| Storage backend | `mount` |
| Filesystem type | `cifs` |
| Source | `//server/share` |
| SMB username / password | the share's credentials |
| Extra mount options | `vers=3.0` (add `seal` for SMB encryption if supported) |

The wizard creates a systemd `.mount` + `.automount` unit, verifies that the share is
mounted and writable for the relay user, and the relay refuses to serve or maintain
anything while it is not mounted.

## 3. Install the relay

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/overcuriousity/borg-relay-backup/v1.0.3/install.sh)
```

Choose role `relay`. The wizard:

1. installs packages (borgbackup, openssh-server, curl, python3, cifs-utils for `mount`),
2. creates the system user `borgrelay` (home and state in `/var/lib/borg-relay`),
3. configures and verifies the backend,
4. restricts the `borgrelay` user in `/etc/ssh/sshd_config.d/borg-relay.conf`,
5. sets up notifications and sends a test message,
6. enables `borg-relay-maint.timer` (weekly) and `borg-relay-watch.timer` (daily),
7. prints the relay's recovery block.

## 4. Install each client

Same one-liner, role `client`. Keep a shell on the relay open — the wizard asks you to run:

```bash
borg-relay add-client <name>        # paste the client's public key
borg-relay set-passphrase <name>    # paste the repository passphrase
```

The client wizard verifies the relay's host key, the key authorization, initializes the
repository (`repokey-blake2`, random 32-character passphrase by default), configures paths,
excludes and hooks, notifications, the daily timer (default 21:30), runs the first backup and
prints the client's recovery block.

**Store both recovery blocks (relay and client) in your password manager.**

## 5. Hooks

Hooks are executables in `/etc/borg-relay/hooks.d/` named `NN-name.pre` (before the backup)
and `NN-name.post` (after it, always — also when the backup failed). They run in lexical
order. A failing `.pre` hook aborts the backup; a failing `.post` hook marks the run failed.

Bundled (selected in the wizard): `10-nextcloud`, `10-db-dump`, `10-paperless`. Their settings
are in `client.conf`; database credentials in `/etc/borg-relay/db.pgpass` or `db.cnf` (600).

Site-specific example — pull new container images after each backup:

```bash
cat >/etc/borg-relay/hooks.d/50-update.post <<'EOF2'
#!/bin/bash
set -euo pipefail
cd /opt/myapp
docker compose pull -q
docker compose up -d
EOF2
chmod +x /etc/borg-relay/hooks.d/50-update.post
```

## 6. Changing the storage target

1. On every client: `systemctl stop borg-relay-backup.timer`.
2. On the relay: `systemctl stop borg-relay-maint.timer borg-relay-watch.timer`.
3. Copy the repository tree (`<old target>/<name>` for every client) to the new target,
   e.g. with `rsync -a`.
4. Re-run the installer on the relay and pick the new backend.
5. `borg-relay list` must show every repository with its archives.
6. Start the timers again. Clients need no change.
