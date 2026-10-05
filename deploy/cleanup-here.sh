#!/usr/bin/env bash
set -euo pipefail

backend_dir="${HERE_BACKEND_DIR:-$HOME/here-backend}"
cd "$backend_dir"

docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
  -c "delete from public.posts where expires_at < now() - interval '24 hours';" </dev/null
