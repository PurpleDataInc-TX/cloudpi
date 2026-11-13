# ClickHouse

From `Cloudpi_v1.1.074` CloudPi runs a second database, ClickHouse, next to MySQL. A **fresh install** gets it from
`docker-compose.yml` and writes to both databases, with ClickHouse answering reads; nothing below is needed for it.

This page is for an install that **already runs CloudPi on MySQL**: how ClickHouse is added, filled with the existing
data, and how the app moves onto it one stage at a time. MySQL stays the source of truth until the last stage, and
every stage before that is undone by a setting and a restart.

## What you need

- A CloudPi build with ClickHouse: three images from one build, `Cloudpi_<x>` (app), `Cloudpi_db_<x>` (MySQL) and
  `Cloudpi_ch_<x>` (ClickHouse). The db and ch images come from the same build.
- This repo's files beside the deployment's `docker-compose.yml`: `cp_upgrade.sh`, `clickhouse-setup.sh`,
  `clickhouse/compose-service.yml`, `clickhouse-first-load.sh`, `clickhouse-tool.sh`.
- `python3` on the host (`clickhouse-setup.sh` edits the compose file with it) and Docker Compose v1 or v2.
- Room on the host: about 4 GB more memory for the clickhouse container (`CH_MEMORY`), and disk for its copy of the
  data (compressed, smaller than MySQL's).
- A backup: `./cp_upgrade.sh --backup`.

## The stages

| # | Stage | Downtime | Undo |
|---|---|---|---|
| 1–2 | Upgrade to the ClickHouse build; the clickhouse container is added, the app stays on MySQL alone | as a normal upgrade | `./cp_upgrade.sh --rollback` |
| 3 | First load: copy MySQL into ClickHouse | yes: API, worker and Flask stop | nothing to undo, MySQL is untouched |
| 4 | Write both, compare reads | a restart | `DB_WRITE=mysql DB_READ=mysql`, restart |
| 5 | ClickHouse answers reads | a restart | `DB_READ=compare`, restart |
| 6 | ClickHouse decides writes | a restart | `DB_WRITE=dual`, restart |

Move to the next stage only after the current one has run clean (see "What to watch") for the time the business
chooses; a week across a month-end is a sensible minimum before stage 5.

### 1–2. Upgrade to the ClickHouse build

```bash
./cp_upgrade.sh Cloudpi_v1.1.074
```

The usual upgrade (backup, new images, migrations, automatic rollback on failure), plus ClickHouse: when the compose
file has no `clickhouse` service yet, `cp_upgrade.sh` runs `clickhouse-setup.sh` before it stops anything. That script

- backs up `docker-compose.yml`, `.env` and `cloudpi.secrets` as `*.pre-clickhouse.<time>`;
- adds the `clickhouse` service (from `clickhouse/compose-service.yml`) and its four volumes;
- gives the app what it needs to reach ClickHouse: `depends_on: clickhouse`, `DB_WRITE`, `DB_READ`, `CH_HOST`,
  `CH_PORT`, `CH_SECURE`, `CH_CA_CERT` and the read-only `clickhouse_ca` volume;
- adds to `.env` the keys it lacks: `CH_IMAGE_TAG`, `DB_WRITE=mysql`, `DB_READ=mysql`, `CH_MEMORY`, `CH_CPUS`;
- adds to `cloudpi.secrets` `CH_USER=cloudpi_app` and a generated 32-character `CH_PASSWORD` if they are not set
  (the password is never printed);
- checks the result with `docker compose config` and puts every file back if it does not validate;
- starts the clickhouse container and waits until it is healthy.

With both modes on `mysql` the app then behaves exactly as before; it has the ClickHouse settings but does not use
them. Later upgrades move `CH_IMAGE_TAG` with the app (`Cloudpi_v<x>` -> `Cloudpi_ch_v<x>`) and include ClickHouse in
the backup and the rollback.

To add ClickHouse without upgrading, or to see the changes first:

```bash
./clickhouse-setup.sh --ch-tag Cloudpi_ch_<x> --dry-run   # shows every change, changes nothing
./clickhouse-setup.sh --ch-tag Cloudpi_ch_<x> --start     # makes them, starts and health-checks clickhouse
```

Anything already present is left alone, so it can be run again. A compose file whose `app` service or top-level
`volumes` section it cannot find is refused; add the parts by hand from this repo's `docker-compose.yml`.

### 3. First load

```bash
./clickhouse-first-load.sh           # shows the plan, then asks before stopping anything
```

1. Applies the app's ClickHouse migrations (nothing writes to ClickHouse yet).
2. Shows the plan: how each table is copied, the per-workspace tables (`bronze_workspace_<id>`) it will create on
   ClickHouse, and every column that differs between MySQL and ClickHouse. It stops on any difference: that is an
   install whose MySQL missed migrations (for example one installed from a DB image built before 2026-10-03, missing
   V1_329 and V1_392). Run the missing migrations, then the script again.
3. Asks, then stops the API, worker and Flask so nothing writes during the copy.
4. Copies every table into a staging table, verifies each chunk and table against MySQL, swaps it in.
5. Checks every table on both engines; stops unless all are equal.
6. Starts the processes again, however it ended.

It takes hours on a large install (tens of GB in MySQL); plan a window. If it stops, run it again: the copy
continues where it stopped.

### 4. Write both, compare reads

```bash
# in .env
DB_WRITE=dual
DB_READ=compare
docker compose up -d app
```

Every process in the app container follows these two settings.

Every save goes to MySQL, then the same rows to ClickHouse; if ClickHouse refuses, the save is undone on both. Reads
are answered by MySQL; the same read runs on ClickHouse in the background and any difference is logged.

### 5 and 6. Let ClickHouse take over

`DB_READ=clickhouse`, then later `DB_WRITE=dualClickhouseFirst`, each followed by `docker compose up -d app`. Removing MySQL is a separate change.

## What to watch

JSON lines in the app's `cloudpi-node.log` with `category: "db"`:

| `event_name` | Means | Do |
|---|---|---|
| `db_drift` | A row differs between the engines | `./clickhouse-tool.sh fix-drift --table <t> --ids 1,2,3`, then find the write that caused it |
| `db_replay_refused` | ClickHouse refused a save MySQL accepted | a defect; the save was undone on both. Report it before the next stage |
| `db_undo_failed` | A failed save could not be undone | repair the keys in the line with `fix-drift` |
| `db_health_failed` | ClickHouse did not answer | `docker logs cloudpi-clickhouse`; in stage 6 saves fail until it answers |

`GET /CPiN/monitor` answers `clickhouse: "ok"` or `"unreachable"` once a mode uses ClickHouse.

## The tools

The image has no `npm`; the app's ClickHouse tools run through `./clickhouse-tool.sh`, inside the app container with
the API's own settings:

```bash
./clickhouse-tool.sh copy plan|run|verify|status [--tables a,b]
./clickhouse-tool.sh migrate
./clickhouse-tool.sh fix-drift --table <table> --ids 1,2,3
```

`copy verify` compares every table on both engines without copying; run it with the API and worker stopped for an
exact answer, since the app keeps writing while they run.

## Testing the setup script

```bash
tests/clickhouse-setup-test.sh            # against the deployment files this repo's main branch ships
tests/clickhouse-setup-test.sh <git-ref>  # against another release
```

It runs the dry run and the real run on a scratch copy and checks the compose file validates with every part in
place, that a second run changes nothing, and that no password is printed.
