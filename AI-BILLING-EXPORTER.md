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

**Start in CloudPi.** CloudPi's AI cost export onboarding screen gives you the values to install with: your org id,
CloudPi's AWS account id and an external id. Install with them, then give CloudPi the stack outputs (bucket, prefix
and read role) on the same screen.

```bash
./setup-ai-exporter.sh install --release ai-exporter-1.0.0 --org-id <org id from CloudPi>   --cloudpi-account-id <CloudPi account id> --cloudpi-external-id <external id from CloudPi>
```

The script:

1. asks for the admin keys with a hidden prompt (or reads `ANTHROPIC_ADMIN_KEY` / `OPENAI_ADMIN_KEY`);
2. downloads the release from GitHub and checks the Lambda zip and the template against their SHA-256s;
3. uploads the zip to a private code bucket (`cloudpi-ai-exporter-code-<account>-<region>`);
4. deploys the CloudFormation stack `cloudpi-ai-exporter`;
5. stores the keys in the stack's secrets (through a private temporary file, never on a command line);
6. shows what the next run will collect (a dry run).

Useful options: `--providers openai` (only one provider), `--backfill-months 6` (earlier months to collect once;
the default 2 gives 3 months with the current one), `--alarm-email you@company.com` (be told when a run fails),
`--region`, `--requester-mode hashed` (hash user ids, names, e-mails and API keys; **CloudPi needs the default `full`**
for its per-user and per-key views, so use `hashed` only if the files are not for CloudPi). Add `--dry-run` to see
every change without making it. `--help` lists everything.

**Checking the download.** The installer checks the zip and the template against the SHA-256s in the release's
manifest, which catches a damaged download. Because the manifest comes from the same release, it does not prove the
release itself is genuine: for that, get both SHA-256s from CloudPi through another channel and pass them with
`--expect-sha256 <zip sha256> --expect-template-sha256 <template sha256>`; the install then stops unless both files
match exactly. Pin both: the template creates the IAM roles, so checking only the zip is not enough.

Each stack has its own small state file next to the script (`.cloudpi-ai-exporter.<stack>.state`, ids only). Use
`--stack <name>` with every command to manage a second install (a second install in another region also needs its
own `--stack` name).

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

Every file is FOCUS 1.5. Besides cost, tokens, model and token type, each row names the Anthropic workspace or OpenAI
project (`SubAccountId` / `SubAccountName`; Anthropic's default workspace is "Default workspace"), the user and API key
(`PrincipalId`, `CredentialId`, `RequesterDetails`), the API key again as the FOCUS resource (`ResourceId`,
`ResourceName`, `ResourceType` = "API Key"), and tags for project rules: `workspace`, `ant_workspace`,
`ant_api_key_id`, `ant_api_key_name`, `ant_actor` (Anthropic) and `project`, `oai_project`, `oai_api_key_name`,
`oai_user` (OpenAI).

Only cost and usage totals are collected, never prompts or responses.

## Cost per team and user through an LLM gateway (optional)

When your apps call OpenAI or Anthropic through a gateway such as LiteLLM, the provider's bill sees only the gateway's
key: every call looks like one user. The exporter can split each bill line by the gateway's own logs, so the FOCUS
file shows which team, user or tag used it. The bill stays the truth: the split shares out the billed cost by each
slice's tokens, and never changes the total.

**1. Let LiteLLM write its logs to S3** (in your account; the exporter only reads them):

```yaml
litellm_settings:
  callbacks: ["s3_v2"]
  turn_off_message_logging: true     # usage only: no prompts or responses in the logs
  s3_callback_params:
    s3_bucket_name: acme-litellm-logs
    s3_region_name: us-east-1
    s3_path: gateway-logs            # the folder: give the same value to --prefix below
```

- Keep the logs at least **38 days** (an S3 lifecycle rule): providers revise last month until the 7th.
- Batched uploads, hour folders and team or key folders are all read.
- Set `LITELLM_LOCAL_MODEL_COST_MAP=True` on the gateway so it does not fetch a price list at start; the exporter
  uses the bill's prices, never the gateway's.
- Who a call belongs to comes from the call itself. Put the employee id in the request's `user`, give keys a team,
  and add tags for anything else: `{"metadata": {"tags": ["cost_center=4410", "app=search"]}}`. Keys used by agents or
  services: create them without a user, so their calls go to the team or key, not to a person.

**2. Tell the exporter where the logs are, and which bill lines they cover** (the scope: the OpenAI projects or
Anthropic workspaces whose traffic goes through the gateway; a bill line is split by one gateway only):

```
./setup-ai-exporter.sh add-gateway-source --name litellm-prod --type litellm \
    --bucket acme-litellm-logs --prefix gateway-logs --openai-projects proj_9xY --anthropic-workspaces wrkspc_01
```

Add `--kms-key-arn <arn>` when the log bucket uses SSE-KMS. The command changes only the gateway settings of the stack,
and gives the Lambda read access to that folder only. If one gateway serves several OpenAI projects or Anthropic
workspaces, say which calls belong to which with `add-account-map --source litellm-prod --provider openai
--account proj_9xY --model-id <LiteLLM deployment id>` (or `--api-base`, `--key-alias`); without it the split is
pooled over the scope.

**What you get.** Each split bill line becomes one row per slice, with the FOCUS allocation columns:
`AllocatedMethodId` = `TOKEN_SHARE`, `AllocatedResourceId` / `AllocatedResourceName` (the slice: team, user, key alias
and tags), `AllocatedTags`, and in `AllocatedMethodDetails` the slice's ratio and tokens. Tokens the gateway did not
see (calls made around it) stay in one more row with no slice, so the rows still add up to the bill line exactly.
The run log's `gateway` block shows the coverage per day, the files read, and any source that could not be read: its
lines are written unsplit in that run, and the month's next run splits them again.

**Why not LiteLLM's own FOCUS export?** It prices calls with LiteLLM's price list, not your bill (no discounts, batch
or cache pricing as billed), so it does not add up to the invoice. The exporter uses only the token counts from the
logs and keeps the cost from the bill.

**Volume.** About 300,000 calls a day per gateway are read in one daily run. A bigger volume, or a gateway's first
month, is read over several runs: until then those days show as not covered (`catching_up` in the run log), and the
cost is never lost or counted twice.

## Day to day

| Task | Command |
|---|---|
| See the stack and the last run | `./setup-ai-exporter.sh status` |
| Run now instead of waiting | `./setup-ai-exporter.sh run-now` |
| New admin key (rotation) | `./setup-ai-exporter.sh set-key anthropic` (or `openai`) |
| Gateway sources | `add-gateway-source`, `set-gateway-source`, `remove-gateway-source --name <name>`, `add-account-map`, `list-gateway-sources` (all take `--dry-run`) |
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
