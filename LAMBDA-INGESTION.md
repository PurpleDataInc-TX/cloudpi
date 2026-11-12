# Moving CloudPi's billing ingestion to AWS Lambda

Optional. By default CloudPi collects billing data on the server it runs on. If that load is too heavy for the server, `setup-lambda.sh`
creates a Lambda function **in your own AWS account** and runs the heavy one-off work there: the imports that a user marks **Historical** on the import
page (a back-fill, one month at a time). Regular imports and scheduled collection stay on this server. You can switch back with one command.
Customers who never run it are not affected.

> `setup-lambda.sh` sits next to `cp_upgrade.sh` in this repository, and `cp_upgrade.sh` has the hook that keeps the Lambda on the same release
> as the app. The release files themselves are **not** in git: each CloudPi release has a GitHub Release of this repository, named by the image
> tag, with four files attached (the bundle zip, `lambda-manifest.json`, `lambda-template.yaml` and `lambda-service-role.yaml`). GitHub allows
> 2 GiB per release file; the 100 MB limit is for files in git.

## What you need

1. An AWS account and the AWS CLI on this server, signed in as someone who may create S3 buckets, IAM roles and policies, CloudFormation stacks
   and Lambda functions (an administrator for the first install). For a first try use `--no-service-role`, which deploys with your own permissions.
2. A region where Lambda Managed Instances is available.
3. Two subnets in different Availability Zones and a security group with no inbound rules. The Lambda machines must reach S3, Secrets Manager,
   your cloud's billing data (AWS S3, Azure Blob, GCP BigQuery or Databricks) and your CloudPi database.
4. A Secrets Manager secret whose value is the database URL the function connects with (`mysql+pymysql://user:password@host:3306/db`).
   Give the script the secret's **ARN**, never the URL.
5. Docker with the Compose plugin (already needed to run CloudPi), `curl`, and internet access to github.com: `--release <tag>` downloads the
   release files into `./lambda` and refuses the bundle unless its SHA-256 matches the manifest.
6. Only if your CloudPi also writes to ClickHouse (`DB_DUAL_WRITE`, on by default): two more secrets, one for ClickHouse and one for Redis. See
   **ClickHouse and Redis** below. Without them the function writes MySQL only.

## Your server and your database

**If your CloudPi server was created with `cloud-template.yaml`**, update that stack with `EnableLambdaIngestion=true` (the option is in this
repository's `cloud-template.yaml`). Nothing changes while it is `false`: everything it adds is behind that switch. With `true` it:

- gives the server an IAM role (no permissions yet; `--instance-role` below attaches the one policy CloudPi needs) and lets the containers reach
  it (metadata hop limit 2, IMDSv2 required). Without the hop limit the containers cannot see the role;
- creates the security group the function runs in (no inbound rules) and opens MySQL (3306) on the server **to that group only**;
- outputs the values `setup-lambda.sh` asks for: `LambdaSubnetIds` (`--subnets`), `LambdaSecurityGroupId` (`--security-group`),
  `InstanceRoleName` (`--instance-role`) and `DatabaseHost` (the server's private address for the database URL).

Note that `cloud-template.yaml` also opens ports 3306 (MySQL) and 6379 (Redis) to the whole internet (`0.0.0.0/0`). The option does not change
that, so existing customers are not surprised; restrict both rules to your own addresses.

**The database must be in the same VPC as the function** (or one you have peered with it). The function reaches it through its security group,
never through an address range and never across the internet:

| Your database | What to do |
|---|---|
| MySQL on the CloudPi server created by `cloud-template.yaml` | Nothing more: the option above already lets the function's group in. Use `DatabaseHost` in the URL. |
| RDS, or any other MySQL host in the same VPC | Pass `--database-security-group <its security group>`. `install` opens port 3306 on that group to the function's group (the rule stays if you delete the stack: remove it with `aws ec2 revoke-security-group-ingress`). |
| The CloudPi database **container** | It publishes no port today. Publish it (`ports: ["3306:3306"]` under `db` in `docker-compose.yml`; this restarts the database container) and treat the server like the first row. |
| A database in another VPC or account | Not covered: set up peering or a transit gateway first. |

**The database URL.** Put `mysql+pymysql://user:password@<host>:3306/<database>` in a Secrets Manager secret and give `install` its ARN.

**The database user's permissions.** Besides full access to the CloudPi schema, the user in the URL needs
`GRANT SELECT ON performance_schema.metadata_locks TO '<user>'@'%'`: before it reorganises a table's partitions the import checks that no other
session holds the table, and without this grant every month fails with `MySQL 1142 ... SELECT command denied ... metadata_locks`. If the function's database is a MySQL server with binary logging on, creating the stored routines also
needs `log_bin_trust_function_creators=1` (or a user with SUPER).

**The connection to the database is not encrypted.** The function talks to your database in plain text, as CloudPi itself does, so keep the
database inside the private network the function runs in (the security-group rules above are what limit who can reach it).

## Install

```
cd cloudpi
./setup-lambda.sh install --dry-run --release 1.5.0 --subnets subnet-0a1,subnet-0b2 --security-group sg-0123abcd \
    --database-secret-arn arn:aws:secretsmanager:us-east-1:111122223333:secret:cloudpi-db-AbCd      # shows what would happen, changes nothing
./setup-lambda.sh install --release 1.5.0 --subnets subnet-0a1,subnet-0b2 --security-group sg-0123abcd \
    --database-secret-arn arn:aws:secretsmanager:us-east-1:111122223333:secret:cloudpi-db-AbCd \
    --instance-role <the AWS role of this server>
```

There is no list of orgs to give: every org may use the Lambda (the script writes `INGEST_LAMBDA_ORGS=all` into the `.env` block). Only **historical
imports** go to it: the import page offers **Regular** (any months, as before) or **Historical** (a back-fill, one month at a time), and the
files a user imports as Historical run on the Lambda, one month at a time, oldest first. Regular imports, scheduled collection,
and every month that is already collected keep running on this server. If a long import cannot finish within one collection's time, the months
that did not start stay pending and the next collection continues them. To send everything back to this server, run `./setup-lambda.sh local`.

It does, in order: checks the release files and your AWS identity, verifies the bundle's SHA-256, creates a private encrypted bucket (job files
expire after 7 days) and uploads the bundle, creates a CloudFormation role and the policy CloudPi needs (stack `cloudpi-lambda-deployer`),
deploys the function (stack `cloudpi-lambda`), switches the function off so no machine runs idle, writes a marked block into `.env`
(your old `.env` is kept as `.env.bak-lambda-<time>`), and restarts the CloudPi app container.

**Restarting the app interrupts a collection that is running right now.** Run it when none is, or answer `N` at the prompt and restart later.

If you did not pass `--instance-role`, attach the policy named `AppPolicyArn` in the `cloudpi-lambda-deployer` stack outputs to the AWS role of
this server. Without it CloudPi cannot invoke the function.

## ClickHouse and Redis (optional)

When CloudPi writes every change to ClickHouse as well as MySQL (`DB_DUAL_WRITE`, on by default), the function has to write both too, or the
months it loads would be missing in ClickHouse. Give `install` two more secrets (ARNs, never the values):

```
./setup-lambda.sh install ... \
    --clickhouse-secret-arn arn:aws:secretsmanager:us-east-1:111122223333:secret:cloudpi-clickhouse-AbCd \
    --redis-secret-arn arn:aws:secretsmanager:us-east-1:111122223333:secret:cloudpi-redis-AbCd \
    --read-source clickhouse         # optional: mysql | compare | clickhouse
```

- **The ClickHouse secret** is JSON: `{"host": "...", "port": 8443, "user": "...", "password": "...", "database": "...", "secure": true, "ca_cert": "..."}`.
  `ca_cert` is the **text** of the CA certificate (PEM), needed only when the server's certificate is not signed by a public CA. The function
  writes it to a file itself.
- **The Redis secret** is JSON: `{"host": "...", "port": 6379, "password": "..."}` (`username` is optional). It must be the Redis CloudPi itself
  uses: it numbers the rows that both databases hold. ClickHouse without Redis is refused.
- **`--read-source`** is where the function reads from: `clickhouse` (the default, as in the app), `compare` (serve MySQL and read ClickHouse beside
  it, logging a mismatch) or `mysql` (read MySQL; it still writes both). It is only valid together with the ClickHouse secret.
- **Network.** The function's security group must be allowed on the ClickHouse and Redis ports. The installer opens port 3306 for the database
  (`--database-security-group`) and nothing for ClickHouse or Redis: allow the function's group on them yourself.
- **The ClickHouse user** needs the access CloudPi's own user has: the function creates and drops its own stage tables, inserts, and deletes the
  rows of the months it replaces.
- **Certificates.** The function runs Python 3.13, which refuses a CA certificate without the key usage extension. If the connection fails with
  `CA cert does not include key usage extension`, issue the CA with `keyUsage = keyCertSign, cRLSign`.
- **Leaving the secrets out** is allowed, and the function then writes MySQL only (dual write off, reads from MySQL). Do not do that when your
  CloudPi reads from ClickHouse: the months the function loads would be missing there.

Running `install` again without these flags **keeps** the ClickHouse and Redis settings of the last install (and `--read-source` can be changed on
its own). To take ClickHouse out of the function on purpose, run `./setup-lambda.sh install ... --no-clickhouse`. `status` says whether ClickHouse is
on and where the function reads from; `upgrade` and `follow` keep the settings.

## Day to day

```
./setup-lambda.sh status    # mode, orgs, stack state, whether ClickHouse is on
./setup-lambda.sh local     # collect on this server again; the Lambda stays in your account, switched off
./setup-lambda.sh lambda    # collect on Lambda again, for the same orgs
```

`local` and `lambda` only change `.env` and restart the app; they do not touch AWS.

## Upgrading and rolling back

The release is the CloudPi image tag, and the Lambda must be on the same release as the app (a job and its result carry a schema number; a
mismatch fails the month with a message that says to deploy the matching function).

- **With `cp_upgrade.sh`** (the hook is already in it): nothing more to do. After the app is
  healthy on the new tag, `cp_upgrade.sh` runs `./setup-lambda.sh follow <tag>`. It does nothing if you never installed the Lambda. It runs only
  after a successful upgrade, so an upgrade that failed and was rolled back automatically never touches the Lambda. A manual `--rollback` or
  `--restore` moves the Lambda back to the tag the app returns to. If moving the Lambda fails, the app upgrade still counts as done and the
  script tells you how to retry, or to run `./setup-lambda.sh local` so collections use this server meanwhile.
- **By hand:** `./setup-lambda.sh upgrade <tag>` (also the way to roll back: give it the older tag).

`upgrade` downloads and verifies the release, **refuses while a collection is running on the function** (a job with a recent heartbeat and no result
yet; `--force` overrides), uploads the bundle, redeploys the same stack with the same settings, and switches the function off again. It does not
touch `.env` or restart the app. It keeps the ClickHouse and Redis settings of the install. Between the app becoming healthy and the Lambda
finishing, a collection on Lambda can fail with a schema message and is retried.

## What is not covered yet

- Removing everything (`aws cloudformation delete-stack` for both stacks, then the bucket): not scripted.
- Detecting a running collection: the script asks; it cannot see one.
- The permissions of the CloudFormation role are the least that were needed on paper. The first install on a real account may name one that is
  missing; add only what the message names.
