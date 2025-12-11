#!/bin/bash
set -e

# =============================================================================
# CloudPi - Docker Compose Systemd Service Setup Script
# =============================================================================
# This script creates a systemd service to automatically start CloudPi
# containers on boot using Docker Compose.
#
# Prerequisites:
# 1. Docker and Docker Compose must be installed
# 2. docker-compose.yml must exist in the CloudPi directory
# 3. cloudpi-fetch-secrets.service should be set up (for secrets)
# 4. .env file must exist in the CloudPi directory
# =============================================================================

# Configuration
CLOUDPI_DIR="${CLOUDPI_DIR:-/home/azureadmin/cloudpi}"
SERVICE_NAME="cloudpi-docker-compose"
SERVICE_USER="${SERVICE_USER:-azureadmin}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

log_info "CloudPi Docker Compose Systemd Service Setup"
log_info "============================================="
echo ""

# Step 1: Verify prerequisites
log_step "Step 1: Verifying prerequisites..."

# Check Docker
if ! command -v docker &> /dev/null; then
    log_error "Docker is not installed"
    exit 1
fi
log_info "✅ Docker installed ($(docker --version | cut -d' ' -f3 | tr -d ','))"

# Check Docker Compose
if ! docker compose version &> /dev/null; then
    log_error "Docker Compose plugin is not installed"
    exit 1
fi
log_info "✅ Docker Compose installed ($(docker compose version --short))"

# Check CloudPi directory
if [ ! -d "$CLOUDPI_DIR" ]; then
    log_error "CloudPi directory not found: $CLOUDPI_DIR"
    log_error "Set CLOUDPI_DIR environment variable or create the directory"
    exit 1
fi
log_info "✅ CloudPi directory exists: $CLOUDPI_DIR"

# Check docker-compose.yml
if [ ! -f "$CLOUDPI_DIR/docker-compose.yml" ]; then
    log_error "docker-compose.yml not found in $CLOUDPI_DIR"
    exit 1
fi
log_info "✅ docker-compose.yml found"

# Check .env file
if [ ! -f "$CLOUDPI_DIR/.env" ]; then
    log_warn ".env file not found in $CLOUDPI_DIR"
    log_warn "Make sure to create it before starting containers"
else
    log_info "✅ .env file found"
fi

# Check if user exists
if ! id "$SERVICE_USER" &> /dev/null; then
    log_error "User '$SERVICE_USER' does not exist"
    exit 1
fi
log_info "✅ Service user exists: $SERVICE_USER"

# Step 2: Create systemd service file
log_step ""
log_step "Step 2: Creating systemd service file..."

cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=CloudPi Docker Compose Application Service
Requires=docker.service
After=docker.service
After=network-online.target
After=cloudpi-fetch-secrets.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=$SERVICE_USER
WorkingDirectory=$CLOUDPI_DIR
ExecStartPre=/usr/bin/docker compose pull --quiet
ExecStart=/usr/bin/docker compose up -d --remove-orphans
ExecStop=/usr/bin/docker compose down
ExecReload=/usr/bin/docker compose pull --quiet
ExecReload=/usr/bin/docker compose up -d --remove-orphans
TimeoutStartSec=300
TimeoutStopSec=60
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

log_info "✅ Systemd service file created: /etc/systemd/system/${SERVICE_NAME}.service"

# Step 3: Reload systemd and enable service
log_step ""
log_step "Step 3: Enabling systemd service..."

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"

log_info "✅ Service enabled to start on boot"

# Step 4: Validate docker-compose.yml
log_step ""
log_step "Step 4: Validating docker-compose.yml configuration..."

if su - "$SERVICE_USER" -c "cd $CLOUDPI_DIR && docker compose config" &> /dev/null; then
    log_info "✅ Docker Compose configuration is valid"
else
    log_error "Docker Compose configuration validation failed"
    log_error "Run: cd $CLOUDPI_DIR && docker compose config"
    exit 1
fi

# Summary and next steps
echo ""
log_info "======================================"
log_info "✅ Setup Complete!"
log_info "======================================"
echo ""
log_info "Systemd Service Information:"
echo "  Service name: ${SERVICE_NAME}.service"
echo "  Working directory: $CLOUDPI_DIR"
echo "  Service user: $SERVICE_USER"
echo ""
log_info "Useful Commands:"
echo "  Start:    sudo systemctl start ${SERVICE_NAME}"
echo "  Stop:     sudo systemctl stop ${SERVICE_NAME}"
echo "  Restart:  sudo systemctl restart ${SERVICE_NAME}"
echo "  Reload:   sudo systemctl reload ${SERVICE_NAME}  (pulls latest images & recreates)"
echo "  Status:   sudo systemctl status ${SERVICE_NAME}"
echo "  Logs:     journalctl -u ${SERVICE_NAME} -f"
echo ""
log_info "Container Commands (as $SERVICE_USER):"
echo "  View logs:     docker compose -f $CLOUDPI_DIR/docker-compose.yml logs -f"
echo "  View status:   docker ps"
echo "  Manual start:  cd $CLOUDPI_DIR && docker compose up -d"
echo "  Manual stop:   cd $CLOUDPI_DIR && docker compose down"
echo ""
log_info "Boot Behavior:"
echo "  ✅ Containers will automatically start on boot"
echo "  ✅ Service will restart on failure"
echo "  ✅ Depends on: docker.service, network, cloudpi-fetch-secrets.service"
echo ""
