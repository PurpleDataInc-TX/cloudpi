#!/bin/bash
set -e

# =============================================================================
# CloudPi - Azure Key Vault + tmpfs Secrets Setup Script
# =============================================================================
# This script configures a VM to fetch secrets from Azure Key Vault to tmpfs
# (RAM-only storage) for use with Docker Compose.
#
# Prerequisites:
# 1. VM must have a Managed Identity with these Key Vault roles:
#    - Key Vault Secrets User (read secrets)
#    - Key Vault Secrets Officer (write secrets - only needed once for upload)
# 2. Azure CLI must be installed
# 3. Secrets must already exist in Key Vault (or will be uploaded if file exists)
# =============================================================================

# Configuration
# Accept vault name as first argument, then env var, then fail (no default)
if [ -n "$1" ]; then
    VAULT_NAME="$1"
elif [ -n "$VAULT_NAME" ]; then
    VAULT_NAME="$VAULT_NAME"
else
    echo -e "\033[0;31m[ERROR]\033[0m VAULT_NAME must be provided as argument or environment variable"
    echo "Usage: sudo ./setup-keyvault-secrets.sh <vault-name>"
    echo "   OR: sudo VAULT_NAME=my-keyvault ./setup-keyvault-secrets.sh"
    exit 1
fi

SECRET_NAME="${SECRET_NAME:-cloudpi-secrets}"
CLOUDPI_DIR="${CLOUDPI_DIR:-/home/azureadmin/cloudpi}"
TMPFS_DIR="/run/secrets-tmp"
LOG_FILE="/var/log/cloudpi-secrets-fetch.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

log_info "CloudPi Azure Key Vault + tmpfs Setup"
log_info "======================================"
echo ""

# Step 1: Check Azure CLI
log_info "Step 1: Checking Azure CLI installation..."
if ! command -v az &> /dev/null; then
    log_warn "Azure CLI not found. Installing..."
    curl -sL https://aka.ms/InstallAzureCLIDeb | bash
    log_info "✅ Azure CLI installed"
else
    log_info "✅ Azure CLI already installed ($(az version --query '"azure-cli"' -o tsv 2>/dev/null || echo 'version check failed'))"
fi

# Step 2: Login with Managed Identity
log_info ""
log_info "Step 2: Logging in with Managed Identity..."
if su - azureadmin -c "az login --identity" &> /dev/null; then
    log_info "✅ Logged in with Managed Identity"
else
    log_error "Failed to login with Managed Identity"
    log_error "Please ensure the VM has a System-Assigned or User-Assigned Managed Identity enabled"
    exit 1
fi

# Step 3: Verify Managed Identity access to Key Vault
log_info ""
log_info "Step 3: Verifying Managed Identity access to Key Vault..."
# Test access by listing secrets (returns empty array if vault is empty but accessible)
if su - azureadmin -c "az keyvault secret list --vault-name $VAULT_NAME -o json" &> /dev/null; then
    log_info "✅ Managed Identity has access to Key Vault"
else
    log_error "Managed Identity cannot access Key Vault: $VAULT_NAME"
    log_error "Please ensure the VM has a Managed Identity with 'Key Vault Secrets User' role"
    exit 1
fi

# Step 4: Check if secret exists in Key Vault, upload if not
log_info ""
log_info "Step 4: Checking if secret exists in Key Vault..."
if su - azureadmin -c "az keyvault secret show --vault-name $VAULT_NAME --name $SECRET_NAME --query name -o tsv" &> /dev/null; then
    log_info "✅ Secret '$SECRET_NAME' already exists in Key Vault"
else
    log_warn "Secret '$SECRET_NAME' not found in Key Vault"

    # Check if local secrets file exists
    if [ -f "$CLOUDPI_DIR/cloudpi.secrets" ]; then
        log_info "Found local secrets file. Attempting to upload..."
        if su - azureadmin -c "az keyvault secret set --vault-name $VAULT_NAME --name $SECRET_NAME --file $CLOUDPI_DIR/cloudpi.secrets" &> /dev/null; then
            log_info "✅ Secrets uploaded to Key Vault successfully"
        else
            log_error "Failed to upload secrets. Managed Identity may need 'Key Vault Secrets Officer' role"
            log_error "You can upload manually with: az keyvault secret set --vault-name $VAULT_NAME --name $SECRET_NAME --file $CLOUDPI_DIR/cloudpi.secrets"
            exit 1
        fi
    else
        log_error "No secrets file found at $CLOUDPI_DIR/cloudpi.secrets"
        log_error "Please either:"
        log_error "  1. Copy cloudpi.secrets file to $CLOUDPI_DIR/"
        log_error "  2. Manually upload secrets to Key Vault"
        exit 1
    fi
fi

# Step 5: Create fetch-secrets.sh script
log_info ""
log_info "Step 5: Creating fetch-secrets.sh script..."
cat > "$CLOUDPI_DIR/fetch-secrets.sh" << EOF
#!/bin/bash
set -e

# Configuration
VAULT_NAME="$VAULT_NAME"
SECRET_NAME="$SECRET_NAME"
TMPFS_DIR="/run/secrets-tmp"
SECRETS_FILE="\$TMPFS_DIR/cloudpi.secrets"
LOG_FILE="/var/log/cloudpi-secrets-fetch.log"

log() {
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" | tee -a "\$LOG_FILE"
}

log "Starting secrets fetch process"

# Create tmpfs directory if it doesn't exist
if [ ! -d "\$TMPFS_DIR" ]; then
    log "Creating tmpfs directory: \$TMPFS_DIR"
    mkdir -p "\$TMPFS_DIR"
fi

# Mount tmpfs (RAM-only storage)
if ! mountpoint -q "\$TMPFS_DIR"; then
    log "Mounting tmpfs at \$TMPFS_DIR"
    if mount -t tmpfs -o size=2M,mode=0700 tmpfs "\$TMPFS_DIR"; then
        log "✅ tmpfs mounted successfully (2MB, RAM-only)"
    else
        log "❌ ERROR: Failed to mount tmpfs"
        exit 1
    fi
else
    log "ℹ️  tmpfs already mounted at \$TMPFS_DIR"
fi

# Fetch secret from Azure Key Vault using Managed Identity
# Run as azureadmin user to access managed identity, but redirect output as root
log "Logging in with Managed Identity..."
if ! su - azureadmin -c "az login --identity" > /dev/null 2>&1; then
    log "❌ ERROR: Failed to login with Managed Identity"
    exit 1
fi

log "Fetching secrets from Azure Key Vault: $VAULT_NAME/$SECRET_NAME"

if su - azureadmin -c "az keyvault secret show \
    --vault-name '$VAULT_NAME' \
    --name '$SECRET_NAME' \
    --query value \
    --output tsv" > "\$SECRETS_FILE" 2>/dev/null; then

    # Set secure permissions (only root and azureadmin can read)
    chmod 600 "\$SECRETS_FILE"
    chown azureadmin:azureadmin "\$SECRETS_FILE"

    FILE_SIZE=\$(stat -c%s "\$SECRETS_FILE")
    log "✅ Secrets fetched successfully to tmpfs (\$FILE_SIZE bytes)"
    log "   Location: \$SECRETS_FILE (RAM-only, not persisted to disk)"
else
    log "❌ ERROR: Failed to fetch secrets from Key Vault"
    log "   Vault: $VAULT_NAME"
    log "   Secret: $SECRET_NAME"
    log "   Check managed identity permissions and network connectivity"
    exit 1
fi

log "Secrets fetch completed successfully"
exit 0
EOF

chmod +x "$CLOUDPI_DIR/fetch-secrets.sh"
chown azureadmin:azureadmin "$CLOUDPI_DIR/fetch-secrets.sh"
log_info "✅ fetch-secrets.sh created at $CLOUDPI_DIR/fetch-secrets.sh"

# Step 6: Create systemd service
log_info ""
log_info "Step 6: Creating systemd service..."
cat > /etc/systemd/system/cloudpi-fetch-secrets.service << EOF
[Unit]
Description=Fetch CloudPi Secrets from Azure Key Vault to tmpfs
Before=docker.service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
WorkingDirectory=$CLOUDPI_DIR
ExecStart=$CLOUDPI_DIR/fetch-secrets.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cloudpi-fetch-secrets.service
log_info "✅ Systemd service created and enabled"

# Step 7: Test the setup
log_info ""
log_info "Step 7: Testing the setup..."
if systemctl start cloudpi-fetch-secrets.service; then
    log_info "✅ Service started successfully"

    # Verify tmpfs mount
    if mountpoint -q "$TMPFS_DIR"; then
        log_info "✅ tmpfs mounted at $TMPFS_DIR"
    else
        log_error "tmpfs not mounted"
        exit 1
    fi

    # Verify secrets file
    if [ -f "$TMPFS_DIR/cloudpi.secrets" ]; then
        FILE_SIZE=$(stat -c%s "$TMPFS_DIR/cloudpi.secrets")
        log_info "✅ Secrets file exists in tmpfs ($FILE_SIZE bytes)"
    else
        log_error "Secrets file not found in tmpfs"
        exit 1
    fi
else
    log_error "Service failed to start. Check logs with: journalctl -u cloudpi-fetch-secrets.service"
    exit 1
fi

# Step 8: Summary and next steps
log_info ""
log_info "======================================"
log_info "✅ Setup Complete!"
log_info "======================================"
echo ""
log_info "Next Steps:"
echo ""
echo "1. Copy your docker-compose.yml to $CLOUDPI_DIR/"
echo "   - Make sure it references: file: /run/secrets-tmp/cloudpi.secrets"
echo ""
echo "2. Copy your .env file to $CLOUDPI_DIR/"
echo ""
echo "3. Copy your SSL certificates to $CLOUDPI_DIR/certs/"
echo ""
echo "4. Start your containers:"
echo "   cd $CLOUDPI_DIR"
echo "   docker compose up -d"
echo ""
log_info "Secrets Management:"
echo "  - Secrets are stored in Azure Key Vault: $VAULT_NAME/$SECRET_NAME"
echo "  - On boot: Automatically fetched to tmpfs (RAM-only)"
echo "  - To update secrets:"
echo "    1. Update in Key Vault"
echo "    2. Run: sudo systemctl restart cloudpi-fetch-secrets.service"
echo "    3. Run: docker compose restart"
echo ""
log_info "Logs:"
echo "  - Fetch script: tail -f $LOG_FILE"
echo "  - Systemd service: journalctl -u cloudpi-fetch-secrets.service -f"
echo ""
