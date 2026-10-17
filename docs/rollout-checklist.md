# Rollout checklist

Record the date next to each item.

## Relay

- [ ] Relay container created (Debian 13; privileged only for the CIFS `mount` backend)
- [ ] Firewall: relay → target allowed; clients → relay:22 only
- [ ] Installer run as `relay`; backend verified by the wizard
- [ ] **ssh-borg only:** verify that `--restrict-to-repository <name>` resolves relative to
      the target login's home: after the first client's `borg init`, the repo is at
      `<home>/<name>` on the target
- [ ] Notification test message received
- [ ] Relay recovery block stored in the password manager

## Each client

- [ ] Installer run as `client`; `borg-relay add-client` and `borg-relay set-passphrase` done on the relay
- [ ] First backup succeeded (`borg-relay list` on the relay shows 1 archive)
- [ ] Client recovery block stored in the password manager
- [ ] Single-file restore tested (`borg mount` / `borg extract`)

## Alerts and maintenance

- [ ] Failure alert: stop sshd on the relay, run `systemctl start borg-relay-backup` on a client
      with `RETRY_WINDOW=0` temporarily → `[FAILED]` notification arrives; restore settings
- [ ] Missed-run alert: set `MAX_AGE_HOURS=0` in one `repos.d/<name>.conf`, run
      `systemctl start borg-relay-watch` → alert arrives; restore 26
- [ ] `systemctl start borg-relay-maint` → `[OK]` summary arrives
- [ ] Append-only: on a client, `borg delete <repo>::<archive>` then `systemctl start borg-relay-maint`
      → *possible tampering* alert; roll back per RESTORE.md
