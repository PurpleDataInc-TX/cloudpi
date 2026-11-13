# CloudPi

CloudPi is a cloud cost governance and management platform designed for deployment on cloud virtual machines. This repository contains the deployment configuration and setup scripts for running CloudPi using Docker containers.

**Note:** This repository contains the paid, proprietary version of CloudPi. Use is restricted to customers or those with explicit permission from PurpleData Inc.

## Features

- **Containerized Architecture:** Docker application with an app container and two database containers: MySQL and the ClickHouse analytics database
- **Guarded upgrades:** `cp_upgrade.sh` backs up, upgrades, checks migrations and health, and rolls back on failure
- **Optional Pico add-on:** an AI FinOps analyst for Slack, run beside CloudPi (`README-PICO.md`)
- **HTTPS Support:** Optional Automated SSL certificate provisioning via Let's Encrypt (Certbot)
- **Azure Key Vault Integration:** Secure secrets management using Azure Managed Identity and tmpfs (RAM-only storage)
- **Systemd Integration:** Auto-start on boot with systemd service management
- **Health Checks:** Built-in container health monitoring for both app and database services
- **Auto-renewal:** Automated SSL certificate renewal with post-renewal hooks

## Repository Structure

- `docker-compose.yml`: Container orchestration configuration with the app, MySQL (`db`) and ClickHouse services
- `cp_upgrade.sh`: First-time install, upgrades with backup and automatic rollback, snapshots and restores (`./cp_upgrade.sh --help`)
- `clickhouse-setup.sh`, `clickhouse/compose-service.yml`, `clickhouse-first-load.sh`, `clickhouse-tool.sh`: Adding ClickHouse to an install that predates it, and moving its data over; see `README-CLICKHOUSE.md`
- `pico/`: The optional Pico add-on; see `README-PICO.md`
- `.env`: Environment configuration (HOST, HTTPS, SSL paths, client settings)
- `setup-certbot.sh`: Automated SSL certificate setup using Let's Encrypt
- `setup-keyvault-secrets.sh`: Azure Key Vault integration setup with Managed Identity
- `fetch-secrets.sh`: Script to fetch secrets from Azure Key Vault to tmpfs
- `setup-docker-compose-service.sh`: Systemd service creation for auto-start on boot
- `setup-lambda.sh`: Optional, AWS only: moves billing ingestion to an AWS Lambda function in your own account; see `LAMBDA-INGESTION.md`
- `certs/`: Directory for SSL certificates (created by setup-certbot.sh)
- `.gitignore`: Excludes sensitive files (certificates, secrets, fetch-secrets.sh)

## Requirements

- **Operating System:** Linux VM (tested on Ubuntu/Debian)
- **Docker:** Docker Engine with Compose plugin
- **Memory and CPU:** the containers' limits in `docker-compose.yml` are 6 GB / 4 CPUs for the app, 6 GB / 4 CPUs for MySQL and
  4 GB / 2 CPUs for ClickHouse (`CH_MEMORY` / `CH_CPUS` in `.env`); size the VM for what your data needs within them
- **python3** on the VM (used by `clickhouse-setup.sh` when an existing install is upgraded)
- **Cloud Platform:** Azure VM with:
  - System-Assigned or User-Assigned Managed Identity
  - Network Security Group (NSG) with ports 80 and 443 open
  - DNS A record pointing to the VM's public IP
- **Azure Resources:**
  - Azure Key Vault (for secrets storage)
  - Managed Identity with "Key Vault Secrets User" role
- **Domain:** A registered domain or subdomain for SSL certificate

## Deployment Guide

Follow these steps to deploy CloudPi on a new Azure VM:

### 1. Provision Azure Infrastructure

Deploy the VM and related Azure infrastructure using Bicep template code. Ensure the VM has:
- System-Assigned or User-Assigned Managed Identity enabled
- Network Security Group (NSG) configured
- Sufficient resources (recommended: 2+ vCPUs, 8GB+ RAM)

### 2. Clone Repository

SSH into the VM and clone the CloudPi repository:

```bash
git clone https://github.com/treymorgannichesoft/cloudpi
cd cloudpi
```

### 3. Grant Key Vault Permissions

In Azure Portal, grant the VM's Managed Identity the **Key Vault Secrets Officer** role on your Azure Key Vault:
- Navigate to Key Vault → Access control (IAM)
- Add role assignment → Key Vault Secrets Officer
- Select the VM's Managed Identity

### 4. Upload Secrets to Key Vault

From `Cloudpi_v1.1.074`, `cloudpi.secrets` also holds the app's ClickHouse user. Add these two lines to it before
uploading (the password is any random 32-character string):

```bash
CH_USER=cloudpi_app
CH_PASSWORD=<output of: openssl rand -hex 16>
```

Copy the `cloudpi.secrets` file to the VM's cloudpi folder:

```bash
# From your local machine
scp cloudpi.secrets azureadmin@<vm-ip>:~/cloudpi/
```

### 5. Run Key Vault Setup Script

Execute the Key Vault setup script to upload secrets and configure auto-fetch on boot:

```bash
sudo ./setup-keyvault-secrets.sh <your-keyvault-name>
```

This script will:
- Install Azure CLI
- Authenticate using the VM's Managed Identity
- Upload `cloudpi.secrets` to Azure Key Vault
- Create `fetch-secrets.sh` script
- Set up systemd service to fetch secrets from Key Vault to tmpfs on boot

### 6. Delete Local Secrets File

For security, remove the secrets file from the VM after it's been uploaded to Key Vault:

```bash
rm cloudpi.secrets
```

### 7. Login to Docker Hub

Authenticate with Docker Hub to pull CloudPi container images:

```bash
docker login --username cloudpi1
# Enter password when prompted
```

### 8. Setup Auto-Start Service

Configure systemd to automatically start CloudPi containers on boot:

```bash
sudo ./setup-docker-compose-service.sh
```

This creates a systemd service that:
- Starts containers automatically on boot
- Depends on Docker service and secrets fetch service
- Restarts on failure
- Pulls latest images before starting

### 9. Configure Environment Variables

Edit the `.env` file with your deployment-specific configuration:

```bash
nano .env
```

Required configuration:

```bash
# Set your domain/subdomain
HOST=your-subdomain.yourdomain.com
SUBDOMAIN=your-subdomain.yourdomain.com

# Enable HTTPS
HTTPS=true

# Configure SSL certificate paths (will be created by setup-certbot.sh)
CERT_PATH=/home/certs/certificate.crt
KEY_PATH=/home/certs/private.key
CA_BUNDLE_PATH=/home/certs/ca_bundle.crt

# Client configuration
CLIENT_NAME=Your Client Name
CLIENT_CODE=your-code
CLIENT_DOMAIN=yourdomain.com
CLIENT_EMAIL=contact@yourdomain.com
CLIENT_CONTACT_NAME=Contact Name
CLIENT_CONTACT_NUMBER=+1 234-567-8900
FISCAL_YEAR=JAN-DEC

# Service configuration
WORKERS=4
```

### 10. Open Port 80 in Network Security Group

Before running Certbot, open port 80 in the Azure NSG to allow Let's Encrypt validation:

In Azure Portal:
- Navigate to VM → Networking → Network settings
- Add inbound port rule:
  - Source: Any
  - Source port ranges: *
  - Destination: Any
  - Service: HTTP
  - Destination port ranges: 80
  - Protocol: TCP
  - Action: Allow
  - Priority: (e.g., 1010)
  - Name: AllowHTTP

### 11. Configure DNS

Set up DNS A record in Hostinger (or your DNS provider) to map your subdomain to the VM's public IP:

- Type: A
- Name: your-subdomain (e.g., cloudpit16)
- Value: VM's public IP address
- TTL: Auto or 3600

Wait a few minutes for DNS propagation, then verify:

```bash
nslookup your-subdomain.yourdomain.com
```

### 12. Setup SSL Certificates

Run the Certbot setup script to obtain Let's Encrypt SSL certificates:

```bash
sudo ./setup-certbot.sh
```

The script will:
- Auto-detect your VM hostname and public IP
- Prompt for subdomain (default: detected hostname)
- Verify DNS configuration
- Obtain SSL certificates from Let's Encrypt
- Copy certificates to the `certs/` directory with proper permissions
- Set up auto-renewal hooks

### 13. Start CloudPi Containers

Start the containers with the first-time install command. It pulls the images, starts MySQL, ClickHouse and the app,
waits for the database setup and the health checks, and records a first snapshot for later rollbacks:

```bash
./cp_upgrade.sh --init Cloudpi_v1.1.074 Cloudpi_db_v1.1.074
```

The ClickHouse image follows the database image (`Cloudpi_db_v1.1.074` -> `Cloudpi_ch_v1.1.074`). A fresh install writes
to both databases and reads from ClickHouse (`DB_WRITE=dual`, `DB_READ=clickhouse` in `.env`).

### 14. Verify Deployment

Check container status:

```bash
docker ps
docker compose logs -f
```

Access CloudPi:
- **HTTPS:** https://your-subdomain.yourdomain.com
- **HTTP:** http://your-subdomain.yourdomain.com (redirects to HTTPS)

Health check endpoints:
- App: `http://localhost/CPiP/v1/health`
- Monitor: `http://localhost/CPiN/monitor`

Verify from outside the VM:

```bash
curl https://your-subdomain.yourdomain.com/CPiP/v1/health
```

## Container Architecture

### Services

- **cloudpi-app**: Main application container
  - Image: `cloudpi1/cloudpi:Cloudpi_v<version>`
  - Ports: 80 (HTTP), 443 (HTTPS); Redis on `127.0.0.1:6379` only
  - Volumes: Redis data, SSL certificates, app backups, the ClickHouse CA (read-only)
  - Health check: HTTP endpoints

- **cloudpi-db**: MySQL database container
  - Image: `cloudpi1/cloudpi:Cloudpi_db_v<version>`
  - Volumes: MySQL data persistence
  - Health check: mysqladmin ping

- **cloudpi-clickhouse**: ClickHouse analytics database container
  - Image: `cloudpi1/cloudpi:Cloudpi_ch_v<version>` (`CH_IMAGE_TAG` in `.env`)
  - Not published on the host; the app reaches it over TLS on the internal network with the CA the container creates
  - Volumes: `clickhouse_data`, `clickhouse_logs`, `clickhouse_tls`, `clickhouse_ca`
  - Health check: `SELECT 1`

### Volumes

- `mysql_data`: Persistent MySQL database storage
- `redis_data`: Redis cache storage
- `cloudpi`: App backups
- `clickhouse_data`: Persistent ClickHouse database storage (`clickhouse_logs`, `clickhouse_tls`, `clickhouse_ca` beside it)
- `./certs:/home/certs`: SSL certificate mount

### Networks

- `cloudpi-network`: Bridge network (172.28.0.0/16)

## Secrets Management

CloudPi supports two secrets management approaches:

1. **Azure Key Vault + tmpfs (Recommended for Production)**
   - Secrets stored in Azure Key Vault
   - Fetched to tmpfs (RAM-only) on boot
   - No secrets persisted to disk
   - Managed Identity authentication

2. **Local File (Development/Testing)**
   - Secrets file stored locally
   - Mounted directly to containers

Secrets are referenced in `docker-compose.yml`:
```yaml
secrets:
  cloudpi_secrets:
    file: /run/secrets-tmp/cloudpi.secrets
```

## SSL Certificate Management

### Auto-Renewal

Certificates are automatically renewed by Certbot's systemd timer. The renewal hook at `/etc/letsencrypt/renewal-hooks/deploy/cloudpi-cert-copy.sh` will:
1. Copy renewed certificates to `certs/` directory
2. Set proper ownership (UID 1000)
3. Restart CloudPi app container

### Manual Renewal

To manually renew certificates:

```bash
sudo certbot renew
```

## Upgrading

Upgrade with `cp_upgrade.sh`, from the folder that holds `docker-compose.yml`. Pull this repository first so the
script and its ClickHouse files are current; your `docker-compose.yml`, `.env` and secrets are not overwritten.

```bash
./cp_upgrade.sh Cloudpi_v1.1.074   # back up, upgrade, run migrations, check health; rolls back on failure
./cp_upgrade.sh --status           # what is running and what a rollback would return to
./cp_upgrade.sh --rollback         # back to the previous version and its data
```

Each upgrade moves the ClickHouse image with the app (`Cloudpi_v<x>` -> `Cloudpi_ch_v<x>`), backs up the ClickHouse data
volume with the MySQL one, and restores both on rollback.

**Upgrading an install from before `Cloudpi_v1.1.074`** also adds ClickHouse: `cp_upgrade.sh` runs
`clickhouse-setup.sh`, which adds the `clickhouse` service, its volumes and the app settings to `docker-compose.yml`,
adds `CH_IMAGE_TAG`, `DB_WRITE=mysql` and `DB_READ=mysql` to `.env`, and adds the ClickHouse user to the secrets file
(backing each file up as `*.pre-clickhouse.<time>` first). The app keeps running on MySQL alone until you copy your
data over and switch, one stage at a time; see `README-CLICKHOUSE.md`.

With Azure Key Vault, the secrets file in `/run/secrets-tmp` is rebuilt from the vault at every boot, so the
ClickHouse user has to be in the vault first. If it is missing, `cp_upgrade.sh` stops before changing anything and
prints the four commands that add `CH_USER` and `CH_PASSWORD` to the vault secret.

Snapshots from `--backup` and `--history` / `--restore` cover MySQL, Redis and the app volume; the ClickHouse volume is
backed up and restored by upgrades and `--rollback`.

## Systemd Service Management

If you configured the systemd service, use these commands:

```bash
# Start containers
sudo systemctl start cloudpi-docker-compose

# Stop containers
sudo systemctl stop cloudpi-docker-compose

# Restart containers
sudo systemctl restart cloudpi-docker-compose

# Pull the images in docker-compose.yml and recreate containers (to change version, use cp_upgrade.sh)
sudo systemctl reload cloudpi-docker-compose

# View status
sudo systemctl status cloudpi-docker-compose

# View logs
journalctl -u cloudpi-docker-compose -f
```

## Security Features

- **Network Security Groups (NSG):** Firewall rules for Azure VMs
- **No new privileges:** Containers run with `no-new-privileges:true`
- **Capability dropping:** Minimal Linux capabilities (CAP_DROP ALL)
- **Resource limits:** CPU and memory limits enforced
- **Secrets in tmpfs:** RAM-only storage, never written to disk
- **Secure file permissions:** Certificates and secrets have restricted access
- **Managed Identity:** No credentials stored in code or configuration

## Troubleshooting

### Containers won't start

Check logs:
```bash
docker compose logs
journalctl -u cloudpi-docker-compose -f
```

### SSL certificate errors

Verify certificates exist:
```bash
ls -la certs/
```

Re-run Certbot setup:
```bash
sudo ./setup-certbot.sh
```

### Database connection issues

Check database health:
```bash
docker exec cloudpi-db mysqladmin ping -h localhost
```

Check database logs:
```bash
docker compose logs db
```

### Secrets not loading

Check secrets fetch service:
```bash
sudo systemctl status cloudpi-fetch-secrets
journalctl -u cloudpi-fetch-secrets -f
tail -f /var/log/cloudpi-secrets-fetch.log
```

Verify tmpfs mount:
```bash
mountpoint /run/secrets-tmp
ls -la /run/secrets-tmp/
```

## License

This software is proprietary and paid. See [LICENSE](./LICENSE) for details on usage and distribution.

## Support

Maintained by PurpleData Inc.

For support, contact your CloudPi account representative.
