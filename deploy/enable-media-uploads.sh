#!/usr/bin/env bash
set -euo pipefail

target="${1:-sami@192.168.2.176}"
project_root="$(cd "$(dirname "$0")/.." && pwd)"
migration="$project_root/supabase/migrations/202610010014_image_uploads.sql"
case_fix_migration="$project_root/supabase/migrations/202610010015_fix_media_path_case.sql"
discord_compose="$project_root/backend/discord-moderation/docker-compose.discord.yml"
bot_source="$project_root/backend/discord-moderation/index.mjs"
ssh_options=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

scp "${ssh_options[@]}" "$migration" "$target:here-backend/202610010014_image_uploads.sql"
scp "${ssh_options[@]}" "$case_fix_migration" "$target:here-backend/202610010015_fix_media_path_case.sql"
scp "${ssh_options[@]}" "$discord_compose" "$target:here-backend/docker-compose.discord.yml"
scp "${ssh_options[@]}" "$bot_source" "$target:here-backend/discord-moderation/index.mjs"
ssh "${ssh_options[@]}" "$target" 'bash -s' <<'REMOTE'
set -euo pipefail
cd "$HOME/here-backend"
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
  -c 'create table if not exists public.here_schema_migrations(version text primary key, applied_at timestamptz not null default now())' </dev/null
applied="$(docker compose exec -T db psql -At -U postgres -d postgres \
  -c "select count(*) from public.here_schema_migrations where version = '202610010014_image_uploads'" </dev/null)"
if [ "$applied" != "1" ]; then
  docker compose exec -T db psql -v ON_ERROR_STOP=1 -1 -U postgres -d postgres < 202610010014_image_uploads.sql
  docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
    -c "insert into public.here_schema_migrations(version) values ('202610010014_image_uploads')" </dev/null
fi
case_fix_applied="$(docker compose exec -T db psql -At -U postgres -d postgres \
  -c "select count(*) from public.here_schema_migrations where version = '202610010015_fix_media_path_case'" </dev/null)"
if [ "$case_fix_applied" != "1" ]; then
  docker compose exec -T db psql -v ON_ERROR_STOP=1 -1 -U postgres -d postgres < 202610010015_fix_media_path_case.sql
  docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
    -c "insert into public.here_schema_migrations(version) values ('202610010015_fix_media_path_case')" </dev/null
fi
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
  -c "notify pgrst, 'reload schema'" </dev/null
docker compose config --quiet
docker compose build here-discord-moderation
docker compose up -d --no-deps here-discord-moderation
REMOTE

echo "HERE Bildspeicher, Medien-APIs und Support-Bildweiterleitung sind aktiviert."
