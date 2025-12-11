#!/bin/bash

# CloudPi Certbot Setup Script
# This script installs certbot and generates SSL certificates for CloudPi deployments

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="${SCRIPT_DIR}/certs"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print functions
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

# Check if running as root for certbot
check_sudo() {
    if [[ $EUID -ne 0 ]] && ! sudo -n true 2>/dev/null; then
        print_error "This script requires sudo privileges to install certbot and obtain certificates"
        print_info "You may be prompted for your password"
        echo ""
    fi
}

# Install certbot if not already installed
install_certbot() {
    print_header "Checking Certbot Installation"

    if command -v certbot &> /dev/null; then
        print_success "Certbot is already installed"
        certbot --version
    else
        print_info "Certbot not found. Installing..."
        sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y certbot
        print_success "Certbot installed successfully"
    fi
    echo ""
}

# Validate IP address format
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Validate domain format
validate_domain() {
    local domain=$1
    if [[ $domain =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        return 0
    else
        return 1
    fi
}

# Collect user input
collect_input() {
    print_header "CloudPi Certificate Configuration"

    # Auto-detect VM hostname
    VM_HOSTNAME=$(hostname)
    SUGGESTED_SUBDOMAIN="${VM_HOSTNAME}.nichesoft.ai"

    # Auto-detect public IP
    print_info "Detecting public IP address..."
    PUBLIC_IP=$(curl -s -4 ifconfig.me 2>/dev/null || curl -s -4 icanhazip.com 2>/dev/null || echo "")

    if [[ -n "$PUBLIC_IP" ]]; then
        print_success "Detected public IP: $PUBLIC_IP"
    else
        print_warning "Could not auto-detect public IP"
        PUBLIC_IP=""
    fi
    echo ""

    # Subdomain
    while true; do
        if [[ -n "$SUGGESTED_SUBDOMAIN" ]]; then
            read -p "Enter your subdomain [default: $SUGGESTED_SUBDOMAIN]: " SUBDOMAIN
            SUBDOMAIN=${SUBDOMAIN:-$SUGGESTED_SUBDOMAIN}
        else
            read -p "Enter your subdomain (e.g., cloudpit13.nichesoft.ai): " SUBDOMAIN
        fi

        if validate_domain "$SUBDOMAIN"; then
            break
        else
            print_error "Invalid domain format. Please try again."
        fi
    done

    # IP Address
    while true; do
        if [[ -n "$PUBLIC_IP" ]]; then
            read -p "Enter your server IP address [default: $PUBLIC_IP]: " IP_ADDRESS
            IP_ADDRESS=${IP_ADDRESS:-$PUBLIC_IP}
        else
            read -p "Enter your server IP address (e.g., 68.154.18.201): " IP_ADDRESS
        fi

        if validate_ip "$IP_ADDRESS"; then
            break
        else
            print_error "Invalid IP address format. Please try again."
        fi
    done

    # Email (optional)
    read -p "Enter email for certificate notifications (press Enter to skip): " EMAIL

    echo ""
    print_info "Configuration Summary:"
    echo "  Subdomain:   $SUBDOMAIN"
    echo "  IP Address:  $IP_ADDRESS"
    if [[ -n "$EMAIL" ]]; then
        echo "  Email:       $EMAIL"
    else
        echo "  Email:       (none - no renewal notifications)"
    fi
    echo ""

    read -p "Continue with this configuration? (y/n): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        print_error "Setup cancelled by user"
        exit 1
    fi
}

# Verify DNS configuration
verify_dns() {
    print_header "Verifying DNS Configuration"

    print_info "Checking DNS resolution for $SUBDOMAIN..."
    RESOLVED_IP=$(nslookup "$SUBDOMAIN" | grep -A1 "Name:" | grep "Address:" | awk '{print $2}' | head -1)

    if [[ -z "$RESOLVED_IP" ]]; then
        print_error "DNS lookup failed for $SUBDOMAIN"
        print_warning "Make sure your DNS is configured before continuing"
        read -p "Continue anyway? (y/n): " CONTINUE
        if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    elif [[ "$RESOLVED_IP" != "$IP_ADDRESS" ]]; then
        print_warning "DNS resolves to $RESOLVED_IP but you specified $IP_ADDRESS"
        print_warning "Make sure your DNS is pointing to the correct IP address"
        read -p "Continue anyway? (y/n): " CONTINUE
        if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        print_success "DNS correctly configured: $SUBDOMAIN -> $IP_ADDRESS"
    fi
    echo ""
}

# Check port 80
check_port_80() {
    print_header "Port 80 Verification"

    print_warning "IMPORTANT: Port 80 must be open for Let's Encrypt verification!"
    echo ""
    print_info "Let's Encrypt will connect to your server on port 80 to verify domain ownership."
    print_info "Make sure your firewall/NSG allows inbound traffic on port 80."
    echo ""

    # Check if port 80 is already in use
    if sudo lsof -i :80 &> /dev/null; then
        print_warning "Port 80 is currently in use"
        print_info "Certbot will temporarily need port 80. You may need to stop services using it."

        print_info "Services using port 80:"
        sudo lsof -i :80 | grep LISTEN
        echo ""

        read -p "Stop Docker containers temporarily to free port 80? (y/n): " STOP_DOCKER
        if [[ "$STOP_DOCKER" =~ ^[Yy]$ ]]; then
            print_info "Stopping Docker containers..."
            cd "$SCRIPT_DIR"
            docker compose down
            print_success "Docker containers stopped"
            RESTART_DOCKER=true
        fi
    else
        print_success "Port 80 is available"
        RESTART_DOCKER=false
    fi
    echo ""

    read -p "Have you confirmed port 80 is open in your Azure NSG? (y/n): " PORT_CONFIRMED
    if [[ ! "$PORT_CONFIRMED" =~ ^[Yy]$ ]]; then
        print_error "Please open port 80 in your Azure Network Security Group before continuing"
        print_info "You can do this in the Azure Portal under: VM -> Networking -> Add inbound port rule"
        exit 1
    fi
}

# Obtain certificate
obtain_certificate() {
    print_header "Obtaining SSL Certificate"

    # Build certbot command
    CERTBOT_CMD="sudo certbot certonly --standalone -d $SUBDOMAIN --non-interactive --agree-tos"

    if [[ -n "$EMAIL" ]]; then
        CERTBOT_CMD="$CERTBOT_CMD -m $EMAIL"
    else
        CERTBOT_CMD="$CERTBOT_CMD --register-unsafely-without-email"
    fi

    print_info "Running: $CERTBOT_CMD"
    echo ""

    if $CERTBOT_CMD; then
        print_success "Certificate obtained successfully!"
        echo ""
        sudo certbot certificates -d "$SUBDOMAIN"
    else
        print_error "Failed to obtain certificate"
        print_info "Common issues:"
        print_info "  1. Port 80 not accessible from the internet"
        print_info "  2. DNS not pointing to correct IP"
        print_info "  3. Firewall blocking connections"
        exit 1
    fi
}

# Copy certificates to certs directory
copy_certificates() {
    print_header "Copying Certificates to CloudPi"

    # Create certs directory if it doesn't exist
    mkdir -p "$CERTS_DIR"

    # Copy certificates with CloudPi naming convention
    print_info "Copying certificates to $CERTS_DIR..."

    sudo cp "/etc/letsencrypt/live/$SUBDOMAIN/fullchain.pem" "$CERTS_DIR/fullchain.pem"
    sudo cp "/etc/letsencrypt/live/$SUBDOMAIN/privkey.pem" "$CERTS_DIR/privkey.pem"
    sudo cp "/etc/letsencrypt/live/$SUBDOMAIN/cert.pem" "$CERTS_DIR/cert.pem"
    sudo cp "/etc/letsencrypt/live/$SUBDOMAIN/chain.pem" "$CERTS_DIR/chain.pem"

    # Create CloudPi-specific names
    sudo cp "/etc/letsencrypt/live/$SUBDOMAIN/fullchain.pem" "$CERTS_DIR/certificate.crt"
    sudo cp "/etc/letsencrypt/live/$SUBDOMAIN/privkey.pem" "$CERTS_DIR/private.key"
    sudo cp "/etc/letsencrypt/live/$SUBDOMAIN/chain.pem" "$CERTS_DIR/ca_bundle.crt"

    # Set ownership to UID 1000 (cloudpi container user)
    sudo chown -R 1000:1000 "$CERTS_DIR"

    # Set appropriate permissions
    chmod 755 "$CERTS_DIR"
    chmod 644 "$CERTS_DIR"/*.crt "$CERTS_DIR"/*.pem
    chmod 600 "$CERTS_DIR/private.key" "$CERTS_DIR/privkey.pem"

    print_success "Certificates copied successfully!"
    echo ""

    print_info "Certificate files in $CERTS_DIR:"
    ls -lh "$CERTS_DIR"
}

# Setup auto-renewal hook
setup_renewal_hook() {
    print_header "Setting Up Auto-Renewal Hook"

    HOOK_DIR="/etc/letsencrypt/renewal-hooks/deploy"
    HOOK_FILE="$HOOK_DIR/cloudpi-cert-copy.sh"

    print_info "Creating renewal hook to auto-copy certificates..."

    sudo mkdir -p "$HOOK_DIR"

    sudo tee "$HOOK_FILE" > /dev/null <<EOF
#!/bin/bash
# CloudPi Certificate Renewal Hook
# Automatically copies renewed certificates to CloudPi certs directory

DOMAIN="$SUBDOMAIN"
CERTS_DIR="$CERTS_DIR"

if [[ "\$RENEWED_DOMAINS" == *"\$DOMAIN"* ]]; then
    echo "Copying renewed certificates for \$DOMAIN to \$CERTS_DIR"

    cp "/etc/letsencrypt/live/\$DOMAIN/fullchain.pem" "\$CERTS_DIR/fullchain.pem"
    cp "/etc/letsencrypt/live/\$DOMAIN/privkey.pem" "\$CERTS_DIR/privkey.pem"
    cp "/etc/letsencrypt/live/\$DOMAIN/cert.pem" "\$CERTS_DIR/cert.pem"
    cp "/etc/letsencrypt/live/\$DOMAIN/chain.pem" "\$CERTS_DIR/chain.pem"

    # CloudPi-specific names
    cp "/etc/letsencrypt/live/\$DOMAIN/fullchain.pem" "\$CERTS_DIR/certificate.crt"
    cp "/etc/letsencrypt/live/\$DOMAIN/privkey.pem" "\$CERTS_DIR/private.key"
    cp "/etc/letsencrypt/live/\$DOMAIN/chain.pem" "\$CERTS_DIR/ca_bundle.crt"

    chown -R 1000:1000 "\$CERTS_DIR"
    chmod 755 "\$CERTS_DIR"
    chmod 644 "\$CERTS_DIR"/*.crt "\$CERTS_DIR"/*.pem
    chmod 600 "\$CERTS_DIR/private.key" "\$CERTS_DIR/privkey.pem"

    echo "Restarting CloudPi containers..."
    cd "$SCRIPT_DIR"
    docker compose restart app

    echo "Certificates renewed and CloudPi restarted successfully"
fi
EOF

    sudo chmod +x "$HOOK_FILE"
    print_success "Renewal hook created at $HOOK_FILE"
    print_info "Certificates will be automatically copied when renewed"
}

# Restart Docker if needed
restart_docker() {
    if [[ "$RESTART_DOCKER" == "true" ]]; then
        print_header "Restarting CloudPi Containers"

        print_info "Starting Docker containers..."
        cd "$SCRIPT_DIR"
        docker compose up -d

        print_success "Docker containers started"
        echo ""

        print_info "Waiting for containers to become healthy..."
        sleep 15
        docker ps
    fi
}

# Print final summary
print_summary() {
    print_header "Setup Complete!"

    CERT_EXPIRY=$(sudo certbot certificates -d "$SUBDOMAIN" 2>/dev/null | grep "Expiry Date:" | awk '{print $3, $4, $5}')

    print_success "SSL certificates have been successfully installed for $SUBDOMAIN"
    echo ""
    print_info "Certificate Details:"
    echo "  Domain:         $SUBDOMAIN"
    echo "  Expiry Date:    $CERT_EXPIRY"
    echo "  Location:       $CERTS_DIR"
    echo "  Auto-renewal:   Enabled (via certbot timer)"
    echo ""
    print_info "Your CloudPi application is now accessible at:"
    echo "  HTTPS: https://$SUBDOMAIN"
    echo "  HTTP:  http://$SUBDOMAIN"
    echo ""
    print_info "Certificate Files:"
    echo "  certificate.crt  - SSL certificate (CloudPi format)"
    echo "  private.key      - Private key (CloudPi format)"
    echo "  ca_bundle.crt    - CA bundle (CloudPi format)"
    echo "  fullchain.pem    - Full chain (Let's Encrypt format)"
    echo "  privkey.pem      - Private key (Let's Encrypt format)"
    echo ""
    print_success "Certbot will automatically renew certificates before they expire"
    print_success "Renewed certificates will be automatically copied to the certs directory"
    echo ""
}

# Main execution
main() {
    print_header "CloudPi Certbot Setup"
    echo "This script will install certbot and generate SSL certificates for your CloudPi deployment"
    echo ""

    check_sudo
    install_certbot
    collect_input
    verify_dns
    check_port_80
    obtain_certificate
    copy_certificates
    setup_renewal_hook
    restart_docker
    print_summary
}

# Run main function
main
