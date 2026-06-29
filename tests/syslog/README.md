# Syslog file-tail mirror — tests

Integration tests for the rsyslog wildcard file-tail mirror (Feature 116). They run against a **real, user-space rsyslog** via `harness.sh` (no root, no systemctl): the harness copies the shipped `host-config/30-cloudpi.conf`, rewrites its paths to temp dirs, and runs `rsyslogd` in the foreground pointed at them.

## Prerequisite baseline (already in the bundle — verified, no change)

`docker-compose.yml` (app service):

- `LOGS_BASE_DIR: /var/log/pico`
- `- /var/log/pico:/var/log/pico`  (absolute bind mount — required: rsyslog's AppArmor profile only reads under `/var/log/**`)

So the container's `/var/log/pico/*.log` are visible on the host at `/var/log/pico/`, which is what the host rsyslog tails. The host dir must be `chown 1000:syslog` + `chmod 2750` (app writes, syslog reads).

## Run

```bash
cd cloudpi/tests/syslog
./run-all.sh           # runs every test_*.sh via harness.sh
# or individually:
./test_us2_mirror.sh
```

Requires `rsyslogd` >= 8.25 on PATH (wildcard `imfile`). Tested against 8.2312.
