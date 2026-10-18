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

@test "seed service pauses the daily timer and alerts on failure" {
    u=$REPO_ROOT/systemd/borg-relay-seed.service
    grep -qx 'ExecStart=/usr/local/lib/borg-relay/bin/borg-relay-backup --seed' "$u"
    grep -qx 'ExecStartPre=/usr/bin/systemctl stop borg-relay-backup.timer' "$u"
    grep -qx 'ExecStopPost=/usr/bin/systemctl start borg-relay-backup.timer' "$u"
    grep -qx 'OnFailure=borg-relay-notify@%n.service' "$u"
}
