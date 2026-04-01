#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SECRETS_FILE="/run/secrets-tmp/cloudpi.secrets"

# Read new password from secrets file
if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "ERROR: Secrets file not found at $SECRETS_FILE"
  exit 1
fi

NEW_PASSWORD=$(grep "^DB_PASSWORD=" "$SECRETS_FILE" | cut -d= -f2)

if [[ -z "$NEW_PASSWORD" ]]; then
  echo "ERROR: Could not read DB_PASSWORD from secrets file"
  exit 1
fi

echo "New password loaded from secrets file."

# Confirmation prompt
read -rp "This will change masteradmin password and restart the stack. Continue? [y/N]: " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# Step 1: Alter password
echo "[1/4] Changing masteradmin password..."
docker exec cloudpi-db mysql -u root --skip-password \
  -e "ALTER USER 'masteradmin'@'%' IDENTIFIED BY '${NEW_PASSWORD}';" 2>&1

# Step 2: Verify new password works
echo "[2/4] Verifying new password..."
docker exec cloudpi-db mysql -u masteradmin -h 127.0.0.1 \
  --password="$NEW_PASSWORD" \
  -e "SELECT 1;" > /dev/null 2>&1 || {
  echo "ERROR: New password verification failed. Aborting restart."
  exit 1
}
echo "Password verified OK."

# Step 3: Restart stack
echo "[3/3] Restarting stack..."
docker compose down
docker compose up -d --no-build --pull never

echo "[Done] Stack is back up with updated password."
