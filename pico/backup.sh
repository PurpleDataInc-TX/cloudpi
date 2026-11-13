#!/bin/bash
# Encrypted backup and restore of Pico's data. Run it on the VM from the folder holding docker-compose.yml.
#   ./backup.sh backup             Stops Pico, saves the data, starts it again, and removes backups past the keep period
#   ./backup.sh restore <file>     Replaces the data with that backup; Pico must be stopped first
# PICO_BACKUP_DIR (./backups), PICO_BACKUP_KEY_FILE (./pico_backup_key) and PICO_BACKUP_KEEP_DAYS (14) change the defaults.
# Keep a copy of the key file away from this VM: a backup can't be read without it.
set -euo pipefail
umask 077
cd "$(dirname "$0")"

BACKUP_DIR="${PICO_BACKUP_DIR:-./backups}"
KEY_FILE="${PICO_BACKUP_KEY_FILE:-./pico_backup_key}"
KEEP_DAYS="${PICO_BACKUP_KEEP_DAYS:-14}"
DATA_DIR=/home/pico/.pico/data
RESTART_PICO=false
PARTIAL_FILE=""

# Runs however the backup ends, so a failure never leaves Pico stopped or a half-written file behind.
finish() {
  if [ -n "$PARTIAL_FILE" ]; then rm -f "$PARTIAL_FILE"; fi
  if [ "$RESTART_PICO" = true ]; then docker compose start pico; fi
}

in_data_volume() {
  docker compose run --rm --no-deps -T --entrypoint sh pico -c "$1"
}

pico_is_running() {
  [ -n "$(docker compose ps --status running --quiet pico)" ]
}

decrypt() {
  openssl enc -d -aes-256-cbc -pbkdf2 -pass "file:$KEY_FILE" -in "$1"
}

backup() {
  local name="$BACKUP_DIR/pico-data-$(date -u +%Y%m%dT%H%M%SZ).tar.gz.enc"
  mkdir -p "$BACKUP_DIR"
  trap finish EXIT

  # Stopped, so the copy is consistent. Notices wait in the Redis stream until Pico is back.
  if pico_is_running; then
    RESTART_PICO=true
    docker compose stop pico
  fi

  PARTIAL_FILE="$name.tmp"
  in_data_volume "tar -C $DATA_DIR -czf - ." \
    | openssl enc -aes-256-cbc -pbkdf2 -salt -pass "file:$KEY_FILE" -out "$name.tmp"
  decrypt "$name.tmp" | tar -tzf - > /dev/null
  mv "$name.tmp" "$name"
  PARTIAL_FILE=""
  find "$BACKUP_DIR" -name 'pico-data-*.tar.gz.enc' -mtime "+$((KEEP_DAYS - 1))" -delete
  echo "Saved $name"
}

restore() {
  local file="$1"
  if pico_is_running; then
    echo "Stop Pico first: docker compose stop pico" >&2
    exit 1
  fi
  decrypt "$file" | tar -tzf - > /dev/null
  decrypt "$file" | in_data_volume "find $DATA_DIR -mindepth 1 -delete && tar -C $DATA_DIR -xzf -"
  echo "Restored $file"
}

[ -r "$KEY_FILE" ] || { echo "Can't read the key file $KEY_FILE" >&2; exit 1; }
case "${1:-}" in
  backup) backup ;;
  restore) [ -n "${2:-}" ] || { echo "Usage: $0 restore <file>" >&2; exit 1; }; restore "$2" ;;
  *) echo "Usage: $0 backup | restore <file>" >&2; exit 1 ;;
esac
