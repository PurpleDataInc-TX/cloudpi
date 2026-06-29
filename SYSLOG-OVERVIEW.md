# CloudPi Syslog Mirror — Plain-English Overview

*A simple guide to what this feature does, why, and how to check it. For the exact commands, see [SYSLOG-RUNBOOK.md](./SYSLOG-RUNBOOK.md).*

---

## 1. In one sentence

The host's **syslog program (rsyslog)** watches the log files our app writes and **copies every line, unchanged, into one folder `/var/log/cloudpi/`** — so operators can read all CloudPi logs from a single place using normal tools like `tail` and `grep`.

## 2. The problem it solves

Our app (Node + Flask) writes JSON log files **inside the container**. On their own those files are hard to reach, easy to lose if the container restarts, and scattered. We want them in **one stable, host-side location** that the standard logging system manages.

## 3. How it works (the picture)

```
  App (in container, user 1000)              Host rsyslog (the "syslog" service)
  ┌───────────────────────────┐             ┌──────────────────────────────────┐
  │ writes JSON log lines  ──► │  /var/log/  │  reads every *.log (imfile)       │
  │ cloudpi-flask.log         │   pico/      │            │                      │
  │ cloudpi-node.log          │ ◄───────────┤            ▼ copies each line     │
  │ app.log                   │  bind mount  │  writes verbatim to              │
  └───────────────────────────┘             │  /var/log/cloudpi/<same-name>     │
                                             └──────────────────────────────────┘
                                                          │
                                          operators:  tail / grep / less
```

**Three plain steps:**
1. The app writes its logs to `/var/log/pico/` (shared with the host via a Docker bind mount).
2. rsyslog **tails** every `*.log` in that folder (one wildcard rule).
3. rsyslog **mirrors** each file, line-for-line, into `/var/log/cloudpi/` with the same name.

No code in the app sends anything; no log program runs inside the container. The app just writes files; the host's syslog does the rest.

## 4. The pieces (4 files in this bundle)

| File | What it is |
|---|---|
| `host-config/30-cloudpi.conf` | The rsyslog rule: "tail `/var/log/pico/*.log`, copy each into `/var/log/cloudpi/` unchanged." |
| `setup-syslog.sh` | One-time installer (run as root): creates folders, sets permissions, installs the rule, restarts rsyslog. |
| `verify-syslog.sh` | A check that writes a test line and confirms it was mirrored. Prints **PASS/FAIL**. |
| `SYSLOG-RUNBOOK.md` | The detailed command reference. |

## 5. How to set it up (quick version)

**Step 0 — get the files: clone the repo from GitHub.** All four pieces (the rule, the two scripts, the docs) ship inside this repo, so once you clone it you have everything.

```bash
# Clone the bundle (first time) — gives you setup-syslog.sh, verify-syslog.sh,
# host-config/30-cloudpi.conf, SYSLOG-RUNBOOK.md and this overview.
git clone https://github.com/PurpleDataInc-TX/cloudpi.git
cd cloudpi
# Already cloned earlier? Just pull the latest instead:
#   cd cloudpi && git pull origin main
```

Then run this flow:

```bash
# 1. Make the host log folder writable by the app (1000) and readable by rsyslog (syslog)
sudo mkdir -p /var/log/pico && sudo chown -R 1000:syslog /var/log/pico && sudo chmod 2750 /var/log/pico

# 2. Make sure docker-compose.yml uses the ABSOLUTE mount /var/log/pico:/var/log/pico, then:
docker compose up -d

# 3. Install + verify the syslog rule
sudo ./setup-syslog.sh         # creates folders, sets perms, installs the rule, restarts rsyslog
sudo ./verify-syslog.sh        # should end with: PASS
```

That's the whole flow: **clone → run the three commands → done.**

## 6. How to check it's actually working

**Is the mechanism wired up?** — write a test line, see it appear in the mirror:
```bash
echo '{"correlation_id":"test-1","msg":"hi"}' >> /var/log/pico/cloudpi-verify.log
sleep 2
grep test-1 /var/log/cloudpi/cloudpi-verify.log && echo "WORKS"
```

**Is *syslog itself* doing the writing?** — confirm the syslog program holds the file open:
```bash
lsof /var/log/cloudpi/*.log
# rsyslogd ... 16w ... /var/log/cloudpi/cloudpi-verify.log
#          ▲ "w" = open for writing, by the syslog daemon = proof
```

**Are my real app logs in there?** — list the mirror folder:
```bash
ls -l /var/log/cloudpi/
```
- Only `cloudpi-verify.log` → just the test probe so far.
- `app.log` / `cloudpi-node.log` with content → real CloudPi logs are flowing. ✅

## 7. Things that surprised us (and the rules to remember)

These came from the real deployment — they're now baked into the scripts:

| Gotcha | Rule |
|---|---|
| **AppArmor** blocks rsyslog from reading anywhere except `/var/log`. | The host log folder **must** be `/var/log/pico` (absolute), never `./logs/pico` (which lands under `/root`). |
| The container app (user 1000) and rsyslog (user `syslog`) both need the folder. | `chown 1000:syslog` + `chmod 2750`: app **writes**, syslog **reads**. Do it **before** `docker compose up`, or Flask crashes with `PermissionError`. |
| rsyslog can mangle the first character. | The rule uses `%msg%` (raw line), **not** `%msg:2:$%` — otherwise it drops the leading `{` and breaks the JSON. |
| rsyslog only copies **new** lines. | It does **not** back-fill old/empty files. A 0-byte `app.log` mirrors the moment the app writes its next line — not before. |

## 8. Important to know

- **CloudPi logs are NOT in `/var/log/syslog` or `journalctl`** — on purpose. A `stop` rule keeps them only in `/var/log/cloudpi/` so they aren't duplicated into the system's catch-all log. The "syslog folder" for CloudPi **is** `/var/log/cloudpi/`.
- **Node logs need an image rebuild** — the running image doesn't yet write Node logs to `/var/log/pico`. Flask already does.
- **Reversible** — to turn it off completely: `sudo rm /etc/rsyslog.d/30-cloudpi.conf && sudo systemctl restart rsyslog`. The app keeps writing its files exactly as before; nothing else changes.
- **Retention** — the mirror files grow forever unless rotated. Add a `logrotate` rule for `/var/log/cloudpi/*.log` (example in the runbook).

## 9. Quick glossary

| Term | Meaning |
|---|---|
| **syslog** | The standard Linux logging service. On this host it's the program **rsyslog**. |
| **rsyslog** | The running syslog daemon — reads, sorts, and writes log messages. |
| **imfile** | The rsyslog feature that reads (tails) log **files**. |
| **mirror** | Copy each source `*.log` to a same-named file under `/var/log/cloudpi/`, unchanged. |
| **bind mount** | A Docker setting that makes a host folder and a container folder the same place. |
| **verbatim** | Byte-for-byte identical — the mirrored line equals the original exactly. |

---

**Bottom line:** the app writes its logs → the host's syslog reads them → and writes exact copies into `/var/log/cloudpi/`. Confirm with `lsof` (syslog holds the file) and `verify-syslog.sh` (prints PASS). Read your logs anytime with `tail -f /var/log/cloudpi/<file>`.
