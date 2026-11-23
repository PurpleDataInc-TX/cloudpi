# AI billing exporter

The AI billing exporter collects your **Anthropic (Claude)** and **OpenAI** cost and usage every day, converts it to
**FOCUS 1.5** (the FinOps standard bill format) and writes it to a new private S3 bucket **in your AWS account**.
It runs as one AWS Lambda; your admin keys stay in your account's Secrets Manager.

## What you need

| For | You need |
|---|---|
| Claude | An **Anthropic Admin API key** (`sk-ant-admin...`): Claude Console → Settings → Admin keys. Only organization admins can create one |
| OpenAI | An **OpenAI Admin key** (`sk-admin-...`): OpenAI platform → Settings → Organization → Admin keys |
| AWS | The AWS CLI signed in to the account that will host the exporter, with rights to create CloudFormation stacks, IAM roles, Lambda, S3, Secrets Manager, SSM and EventBridge resources |
| This machine | `bash`, `curl` and `sha256sum` (or `shasum`) |

You can turn on one provider or both.

## Install

```bash
./setup-ai-exporter.sh install --release ai-exporter-1.0.0 --org-id <your CloudPi org id>
```

The script:

1. asks for the admin keys with a hidden prompt (or reads `ANTHROPIC_ADMIN_KEY` / `OPENAI_ADMIN_KEY`);
2. downloads the release from GitHub and checks the Lambda zip and the template against their SHA-256s;
3. uploads the zip to a private code bucket (`cloudpi-ai-exporter-code-<account>-<region>`);
4. deploys the CloudFormation stack `cloudpi-ai-exporter`;
5. stores the keys in the stack's secrets (through a private temporary file, never on a command line);
6. shows what the next run will collect (a dry run).

Useful options: `--providers openai` (only one provider), `--backfill-months 6` (collect earlier months once),
`--alarm-email you@company.com` (be told when a run fails), `--region`, `--requester-mode hashed`
(hash user ids, names and e-mails), `--cloudpi-account-id` with `--cloudpi-external-id` (create the read-only role
CloudPi uses to read the files). Add `--dry-run` to see every change without making it. `--help` lists everything.

**Checking the download.** The installer checks the zip and the template against the SHA-256s in the release's
manifest, which catches a damaged download. Because the manifest comes from the same release, it does not prove the
release itself is genuine: for that, get the zip's SHA-256 from CloudPi through another channel and pass it with
`--expect-sha256 <sha256>`; the install then stops unless the zip matches exactly.

Each stack has its own small state file next to the script (`.cloudpi-ai-exporter.<stack>.state`, ids only). Use
`--stack <name>` with every command to manage a second install.

## What it creates

| Resource | Purpose |
|---|---|
| S3 bucket `cloudpi-ai-focus-<account>-<region>` | The FOCUS files. Private, encrypted, HTTPS only. **Kept** if you uninstall |
| Lambda `cloudpi-ai-exporter-exporter` | Does the work, once a day at 06:00 UTC (`--schedule` to change) |
| Secrets `cloudpi-ai-exporter/anthropic`, `/openai` | The admin keys |
| SSM parameter `/cloudpi-ai-exporter/config` | The settings |
| CloudWatch alarm (+ e-mail if given) | Fires when a run fails |
| IAM roles | The Lambda's role (only what it needs); optionally CloudPi's read-only role |

## How a run works

Once a day the Lambda works out which months to collect: the current month; the previous month too until the 7th
(providers still revise it); any month that failed in the last 3 months; and the backfill months once. It then
collects them **one after another** (all of Anthropic's, then all of OpenAI's). If one fails, the others still run;
the failed month is retried the next day and the alarm fires.

## What is written where

```
s3://cloudpi-ai-focus-<account>-<region>/ai-billing/
  org=<id>/source=ai_focus/provider=anthropic/year=2026/month=11/
      part-00000.parquet     all FOCUS 1.5 rows of the month
      manifest.json          written last: if it exists, the month is complete
  org=<id>/source=ai_focus/provider=openai/...
  _state/<provider>/months/<YYYY-MM>.json    each month's result
  _runs/<run id>/<provider>-<YYYY-MM>.json   what each run did (kept 90 days)
```

Only cost and usage totals are collected, never prompts or responses.

## Day to day

| Task | Command |
|---|---|
| See the stack and the last run | `./setup-ai-exporter.sh status` |
| Run now instead of waiting | `./setup-ai-exporter.sh run-now` |
| New admin key (rotation) | `./setup-ai-exporter.sh set-key anthropic` (or `openai`) |
| Move to a new release | `./setup-ai-exporter.sh upgrade ai-exporter-1.1.0` (settings and keys stay) |
| Remove | `./setup-ai-exporter.sh uninstall` (add `--delete-data` to also delete the bucket and all its billing files; it refuses a bucket with versioning turned on, since old versions would remain) |

## Troubleshooting

| You see | Do this |
|---|---|
| `credentials rejected for anthropic` / `openai` in a run log | The admin key was revoked or is not an Admin key: `set-key <provider>` |
| `has no value yet; run setup-ai-exporter.sh` | The key was never stored: `set-key <provider>` |
| `HTTP 429 ... after 5 retries` | The provider was busy; the month is retried tomorrow automatically |
| `rows add up to ..., the cost endpoint says ...` | The provider's figures did not reconcile; nothing was written. It is retried tomorrow; if it repeats, contact CloudPi support with the run log |
| `unmatched_rows` above 0 in a run log | Some cost could not be tied to a user or key; it is still in the file (as a project or workspace row) |
| `the Lambda zip is damaged` during install | The download was corrupted: run the install again |
