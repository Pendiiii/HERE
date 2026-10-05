#!/usr/bin/env bash
set -euo pipefail
umask 077

backend_dir="${HERE_BACKEND_DIR:-$HOME/here-backend}"
backup_dir="${HERE_BACKUP_DIR:-$HOME/here-backups}"
mkdir -p "$backup_dir"
cd "$backend_dir"

backup_file="$backup_dir/here-$(date -u +%Y%m%dT%H%M%SZ).dump"
temporary_file="$(mktemp "$backup_dir/.here-backup-XXXXXXXX")"
trap 'rm -f "$temporary_file"' EXIT

docker compose exec -T db pg_dump -U postgres -d postgres --format=custom --no-owner > "$temporary_file"
test -s "$temporary_file"
mv "$temporary_file" "$backup_file"
trap - EXIT

# Keep two weeks of daily snapshots in this dedicated backup directory.
find "$backup_dir" -maxdepth 1 -type f -name 'here-*.dump' -mtime +14 -delete
printf 'HERE backup saved: %s\n' "$backup_file"
