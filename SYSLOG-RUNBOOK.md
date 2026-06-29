# CloudPi Syslog Mirror — Operator Runbook (Feature 116)

One-page guide to mirror CloudPi's JSON logs into `/var/log/cloudpi/` using the host's **pre-installed** rsyslog. Self-contained — no need to read the PRD.

## What this does

The app writes one JSON-lines file per service into the container's `/var/log/pico/`, bind-mounted to the host (`/var/log/pico:/var/log/pico`). The host rsyslog **tails every `*.log`** with one `imfile` wildcard input and **mirrors each file verbatim** into `/var/log/cloudpi/<same-name>`. No daemon runs in the container; the app opens no socket.

## Prerequisites

- rsyslog **already installed and active**, version **≥ 8.25** (`rsyslogd -v`). This setup never installs rsyslog.
- The **`acl`** package installed (`setfacl`/`getfacl`) so the setup can apply a umask-proof default ACL — `apt-get install -y acl`. Without it the mirror still works, but a service whose log is created *after* setup with a restrictive umask may not mirror (the script warns).
- Phase-1 single-file JSON logging in effect (`/var/log/pico/cloudpi-*.log`).
- Single host (container + rsyslog share the filesystem).
- **The compose mount MUST be the absolute `/var/log/pico:/var/log/pico`** — NOT a relative `./logs/pico`. rsyslog's AppArmor profile only allows reads under `/var/log/**`; a relative mount lands the logs under the bundle dir (`/root/...`) where rsyslog is denied read and the mirror stays empty.

## Procedure

```bash
cd cloudpi

# 1. Pre-create the host log dir so the app (UID 1000) can WRITE and syslog can READ.
#    MUST run BEFORE `compose up`, or the bind mount overrides the image dir as
#    root-owned and the app crashes: PermissionError: /var/log/pico/app.log
sudo mkdir -p /var/log/pico && sudo chown -R 1000:syslog /var/log/pico && sudo chmod 2750 /var/log/pico

docker compose up -d                 # app writes /var/log/pico/cloudpi-*.log
sudo ./setup-syslog.sh               # creates dirs + perms, installs drop-in, validates, restarts
sudo ./verify-syslog.sh              # end-to-end PASS/FAIL
```

`setup-syslog.sh` is idempotent: asserts rsyslog active + ≥ 8.25; creates `/var/log/pico` (`chown 1000:syslog`, `chmod 2750` — app writes, syslog reads) and `/var/log/cloudpi` (group `syslog`, writable so the priv-dropped rsyslog can create the mirror files); copies `host-config/30-cloudpi.conf` to `/etc/rsyslog.d/`; runs `rsyslogd -N1`; and restarts rsyslog only if valid.

## Read the logs

```bash
tail -f /var/log/cloudpi/cloudpi-node.log
grep -rF 'correlation_id":"<trace-id>"' /var/log/cloudpi/   # whole trace across services
grep -rF 'event_name":"<EVENT>"'        /var/log/cloudpi/
```

Files are plain JSON-lines — `less`, `awk`, `jq` all work.

## Key settings

| Setting | Where | Note |
|---|---|---|
| Wildcard tail | `30-cloudpi.conf` `File="/var/log/pico/*.log"` | auto-discovers new files; excludes rotated `*.log.N` |
| Watch mode | `module(load="imfile" mode=...)` | **`polling` (1s) is the default** — safe on the bind mount. Switch to `mode="inotify"` only if `/var/log/pico` is a local FS |
| Source perms (UID-1000) | `setup-syslog.sh` | `chgrp syslog` + `chmod g+r` + setgid on `/var/log/pico` so rsyslog (priv-dropped to `syslog`) can READ |
| Dest perms | `setup-syslog.sh` | `chgrp syslog` + `g+rwx` + setgid on `/var/log/cloudpi` so the priv-dropped rsyslog can WRITE the mirror |
| Exactly-once | (automatic) | no static `StateFile` on the wildcard input; rsyslog auto-manages per-file state across restarts |
| Stay out of syslog | dedicated ruleset + `stop` | CloudPi lines never land in `/var/log/syslog` |
| ≥ 8.25 required | `setup-syslog.sh` asserts | older host: comment the wildcard input, uncomment the per-file fallback in `30-cloudpi.conf` |

## Rotation

The app rotates its own files (Phase 1). Rotated `cloudpi-*.log.1/.2` do **not** match the `*.log` wildcard, so they are never re-ingested; the fresh `*.log` is rediscovered automatically. No copytruncate needed — rsyslog reopens on rename.

## Retention (Ops — required before relying on this)

The mirrored files in `/var/log/cloudpi/` **grow unbounded** — nothing in this feature rotates them. Before production, add a logrotate rule (Ops-owned per spec), e.g. `/etc/logrotate.d/cloudpi`:

```
/var/log/cloudpi/*.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    copytruncate
}
```

Use `copytruncate` (rsyslog holds the file open via the dynamic-file action). The source `/var/log/pico/*.log` is rotated by the app (Phase 1) — do not rotate it here.

## Roll back (reversible, host-side)

```bash
sudo rm /etc/rsyslog.d/30-cloudpi.conf
sudo systemctl restart rsyslog
```

The app keeps writing its files unchanged; nothing tails them. No app change, no rebuild. There is no `SYSLOG_ENABLED` application toggle.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `verify-syslog.sh` → `FAIL readability` | `*.log` not readable by `syslog` (UID 1000) | `sudo ./setup-syslog.sh` (re-applies group + setgid + default ACL) |
| Only SOME `*.log` mirror (e.g. `app.log` yes, `cloudpi-node.log` no) | a service created its log AFTER setup ran, with a restrictive umask → born `g-r`, so syslog can't read it (setgid fixes group, not the read bit) | install `acl` + `sudo ./setup-syslog.sh` (applies a umask-proof **default ACL**). If the script's step-5 readability check still names files, that writer forces mode `0600` — fix that service's log file mode/umask |
| Nothing mirrored, no error | inotify unreliable on the bind mount | set `mode="polling" PollingInterval="1"` in the drop-in, restart rsyslog |
| `setup-syslog.sh` aborts on version | rsyslog < 8.25 | uncomment the per-file fallback block in `30-cloudpi.conf` |
| Lines also in `/var/log/syslog` | drop-in not loaded before defaults | confirm filename is `30-cloudpi.conf` and the ruleset ends with `stop` |
| Duplicate lines after restart | static `StateFile` on the wildcard input | remove it — rsyslog auto-manages wildcard state |
| Rotated history re-appears | glob too broad | use `*.log` (not `*.log*`) |
