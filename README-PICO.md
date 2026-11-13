# Pico

Pico, CloudPi's AI FinOps analyst, is an optional add-on: one container that runs on its own VM. It posts each workspace's daily digest to Slack and
answers there. It opens no inbound port; it reaches CloudPi through the API and Redis.

## What CloudPi needs

- CloudPi `Cloudpi_v1.1.074` or later. The image to run is `cloudpi1/cloudpi:Cloudpi_pico_<x>` from the same release
  (`Cloudpi_pico_v1.1.074` for `Cloudpi_v1.1.074`).
- `PICO_CLIENT_SECRET` in `cloudpi.secrets`, at least 32 characters (`openssl rand -hex 32`). Restart the app after adding it;
  its log then says `OAuth client pico-app, set from config, is created`. The same value goes into Pico's `pico.secrets`.
- `HTTPS=true` in CloudPi's `.env` if Pico reaches it over anything but a private network. Over HTTP, Pico's client secret
  and tokens cross the network in clear text.
- Redis reachable from the VM. Set `REDIS_PUBLISH_IP` in CloudPi's `.env` to a **private** address of the CloudPi host.
  Left empty, Redis stays on that host, which is right for every install without Pico. A compose file older than this one
  has no Redis port line; add `- "<private ip>:6379:6379"` under the app's `ports`.
- Only the Pico VM allowed to reach that port. Redis has no TLS here, so its password crosses the network in clear text;
  keep this on a private network or VPN. `ufw` alone is not enough: Docker's published ports skip its rules, so restrict
  them in the `DOCKER-USER` iptables chain or the cloud firewall.
- Pico turned on for the workspace: a `PICO_SLACK` integration with `cloudConfiguration.pico.enabled` true and the
  report channel id. A CP admin can turn it on without connecting a Slack app, typing the team id
  (`POST /v1/client/integration/add`, `name: PICO_SLACK`). Pico re-reads the installations every 5 minutes.

## The Slack app

One Slack app per customer org:

- Socket Mode on, with an app-level token (`xapp-`, scope `connections:write`).
- Interactivity on, for the More details and Yes / No buttons; Event Subscriptions on, with the bot event `app_mention`.
- Bot scopes `chat:write`, `channels:read`, `groups:read`, `groups:history`, `metadata.message:read`, `app_mentions:read`,
  `users:read`, `users:read.email`. A missing scope shows in Pico's log as `Slack conversations.info refused:
  missing_scope`; add it and reinstall the app (the bot token may change).
- A **private** report channel with the bot invited (`/invite @<bot>`). Pico posts only there, and refuses a public one.

## Running it

The image carries Pico's `agent.yml` and `analyst.yml` templates; every install value in them is a `${NAME}`. Everything an install has to give Pico, settings and secrets, is
in one file, `pico.secrets`: one `KEY=VALUE` per line, read the way the CloudPi image reads `cloudpi.secrets`. A standard
install needs only two files in one folder on the VM:

| File | Holds |
|---|---|
| `pico.secrets` | `PICO_SITE_URL`, the Pico client id and secret, Redis address and password, the workspace id, the Slack team and channel ids, the two Slack tokens, and the AI model and its key. Start from `pico/pico.secrets.example` |
| `docker-compose.yml` | A copy of `pico/docker-compose.yml` from this repo |

Compose mounts `pico.secrets` as the `pico_secrets` Docker secret, at `/run/secrets/pico_secrets`. To read it from another
place, such as the file a secret manager writes to `/tmp`, set `PICO_SECRETS_FILE` to that path before
`docker compose up -d`. Pico's file holds only Pico's values: never point it at CloudPi's `cloudpi.secrets`, because Pico
refuses to start when it sees a platform secret (`DB_PASSWORD`, `SECRET_KEY`, `HMAC_SECRET_KEY`, `CRYPTO_SECRET`,
`REDIS_PASSWORD`). The Redis password goes in as `PICO_REDIS_PASSWORD`.

A value is taken exactly as written (a `$` in a password stays a `$`), and surrounding quotes are dropped. At start the
entrypoint writes the copies Pico reads into `/tmp`:

| Value | Filled by |
|---|---|
| `analyst.yml` `site_url`, `be_path`, `piflask_path` | the entrypoint, from `PICO_SITE_URL` (required), `PICO_BE_PATH` (default `/CPiN`) and `PICO_PIFLASK_PATH` (default `/CPiP`) |
| `agent.yml` `target` | the entrypoint, from `PICO_LLM_MODEL`; empty means Gemini with `GEMINI_API_KEY` |
| `agent.yml` channel: workspace, team, channel, tokens | Pico itself, from the environment; the tokens never reach a file |
| model keys (`GEMINI_API_KEY`, `DEEPSEEK_API_KEY`, ...) | Pico itself, from the provider's usual variable |

Pico refuses to start with an `ALERT` naming what is missing: no secrets file, no `PICO_CLIENT_SECRET`, no
`PICO_SITE_URL`, a Slack token, or a team or channel id that isn't valid. An install with several Slack apps, or with tuned
settings, mounts its own file at `/etc/pico/agent.yml` or `/etc/pico/analyst.yml` (the two commented lines in the compose
file), starting from the same examples; a mounted file takes the place of the built-in one and is filled the same way.

Set `PICO_SITE_URL` to `https://<your domain>`, without a path. Use the domain, not an IP address, because the certificate
only matches the domain.

The container runs as user 10001, which must be able to read the file:

```bash
sudo chown 10001 pico.secrets
sudo chmod 600 pico.secrets
```

Check first, which posts nothing. Then start it:

```bash
docker compose run --rm pico analyst check --analyst-config /etc/pico/analyst.yml --config /etc/pico/agent.yml
docker compose up -d
docker logs -f cloudpi-pico
```

Pico keeps what it has already posted in its data volume (`pico_data`). A workspace it has no memory of is new to it:
Pico marks the recommendations that already exist as seen and posts nothing about them, so the first digest reports
only what is new from then on. Keep that volume: if it is lost, Pico treats every workspace as new again, so the
recommendations created while it was down are never reported. Restore the last backup instead of starting it empty.

To run another build, set `PICO_IMAGE_TAG` before `docker compose up -d`. `PICO_MEMORY` and `PICO_CPUS` change the limits.
Changing `pico.secrets` needs `docker compose up -d --force-recreate`, not `docker restart`, so the container is made again
and reads the new values.

Pico has no health check yet, so watch its logs for lines starting with `ALERT:`. A working start ends with
`Workspace <id> is in the tenant map` and `Slack app <name>: listening`; `@pico daily digest` in the report channel posts
the digest on demand.

### On a Windows host with Docker Desktop

`docker pull` over SSH fails with `A specified logon session does not exist`: the SSH session can't reach Windows'
credential store. Pull from a scheduled task that runs as the logged-on user (`schtasks /create ... /it`, then
`schtasks /run`), and start with `docker compose up -d --pull never`.

## Backup and restore

The design asks for an encrypted daily backup kept 14 days, on an encrypted disk. Copy `pico/backup.sh` next to
`docker-compose.yml`, create a key and keep a copy of it away from the VM, because a backup can't be read without it:

```bash
openssl rand -hex 32 > pico_backup_key && chmod 600 pico_backup_key
./backup.sh backup                                # stops Pico, saves to ./backups, starts it again
docker compose stop pico
./backup.sh restore backups/pico-data-<time>.tar.gz.enc
docker compose start pico
```

Schedule `backup` once a day with cron. Pico is stopped while it runs; notices wait in the Redis stream until it's back.
