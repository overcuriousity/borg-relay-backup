# Restore

Everything below needs only the recovery blocks from your password manager.

## Restore with the relay

On the client (or a fresh machine set up with the same client key):

```bash
export BORG_PASSPHRASE='<passphrase from the client block>'
export BORG_RSH='ssh -i /root/.ssh/borg-relay_ed25519'
REPO='ssh://borgrelay@<relay>:22/./<name>'

borg list "$REPO"
mkdir -p /mnt/restore
borg mount "$REPO::<archive>" /mnt/restore   # browse and copy files
borg umount /mnt/restore
borg extract "$REPO::<archive>" etc/nginx    # paths inside the archive have no leading /
```

Restores through the relay are read operations; append-only does not get in the way.

## Restore without the relay

**`ssh-borg` backend** — from any machine with borg 1.4, using the target account's password
or key:

```bash
export BORG_PASSPHRASE='<client passphrase>' BORG_REMOTE_PATH='<remote borg, e.g. borg-1.4>'
borg list 'ssh://<user>@<target-host>:<port>/./<name>'
```

**`mount` backend** — mount the share anywhere, then:

```bash
export BORG_PASSPHRASE='<client passphrase>'
borg list /mnt/share/<name>
```

If borg reports a damaged key, import the exported key from the client block:
`borg key import <repo> keyfile.txt` (paste the key text into `keyfile.txt`).

## Full host rebuild

1. Reinstall Debian 13 and your application.
2. Run the installer as `client` **with the same name**. The wizard detects the existing
   repository and asks for its passphrase instead of creating a new one.
3. `borg extract` the paths you need (stop the application first).

## Nextcloud

```bash
sudo -u www-data php /var/www/nextcloud/occ maintenance:mode --on
borg extract "$REPO::<archive>" var/www/nextcloud <data dir without leading />
borg extract "$REPO::<archive>" var/lib/borg-relay/dumps
# PostgreSQL
sudo -u postgres dropdb nextcloud && sudo -u postgres createdb -O nextcloud nextcloud
sudo -u postgres psql nextcloud </var/lib/borg-relay/dumps/nextcloud.sql
# MariaDB
mariadb -e 'DROP DATABASE nextcloud; CREATE DATABASE nextcloud'
mariadb nextcloud </var/lib/borg-relay/dumps/nextcloud.sql
sudo -u www-data php /var/www/nextcloud/occ maintenance:mode --off
sudo -u www-data php /var/www/nextcloud/occ maintenance:data-fingerprint
```

## Paperless-ngx

```bash
borg extract "$REPO::<archive>" <export dir without leading />
docker compose exec -T webserver document_importer /usr/src/paperless/export
```

Import into a fresh, empty Paperless instance.

## Rolling back an append-only repository

When the relay reports *possible tampering*, a client marked archives as deleted. Because the
client was append-only, the old data is still there until a full-access client writes. Do
**not** run `borg-relay maint` or any write operation on that repository before the rollback.

Follow the borg documentation, section "append-only mode"
(<https://borgbackup.readthedocs.io/en/1.4-maint/usage/notes.html#append-only-mode-forbid-compaction>).
In short, on the target (or the relay's mount):

1. Investigate first: which client, which key, since when? Assume that client is compromised.
2. In the repository directory, read `transactions`: it lists every transaction with its time
   and the segment it ended in. Find the last transaction **before** the deletion.
3. Delete all segment files under `data/` with a higher number than that transaction's segment.
4. Delete `index.*`, `hints.*` and `integrity.*` in the repository directory.
5. Run `borg check --repair <repo>` from the relay, then `borg list <repo>`: the deleted
   archives are back.
6. Remove `/var/lib/borg-relay/state/<name>.archives` so the next maintenance records a
   fresh baseline, then run `borg-relay maint`.
