#!/usr/bin/env bash
set -euo pipefail

target="${1:-sami@192.168.2.176}"
project_root="$(cd "$(dirname "$0")/.." && pwd)"
secret_file="$project_root/deploy/discord.secret"
ssh_options=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

if [ ! -f "$secret_file" ]; then
  echo "Fehlt: deploy/discord.secret (Vorlage: deploy/discord.secret.example)" >&2
  exit 1
fi

for key in DISCORD_BOT_TOKEN DISCORD_APPLICATION_ID DISCORD_GUILD_ID DISCORD_STAFF_CHANNEL_ID DISCORD_STAFF_ROLE_ID DISCORD_SUPPORT_FORUM_ID; do
  if ! grep -q "^${key}=.." "$secret_file"; then
    echo "Fehlender Wert: $key" >&2
    exit 1
  fi
done

scp "${ssh_options[@]}" "$project_root/supabase/migrations/202609300007_support_chat.sql" "$target:here-backend/202609300007_support_chat.sql"
scp "${ssh_options[@]}" "$project_root/supabase/migrations/202609300008_support_account_cleanup.sql" "$target:here-backend/202609300008_support_account_cleanup.sql"
tar -C "$project_root/backend/discord-moderation" -cf - \
  Dockerfile package.json package-lock.json index.mjs .dockerignore \
  | ssh "${ssh_options[@]}" "$target" 'mkdir -p "$HOME/here-backend/discord-moderation" && tar -xf - -C "$HOME/here-backend/discord-moderation"'
scp "${ssh_options[@]}" "$project_root/backend/discord-moderation/docker-compose.discord.yml" "$target:here-backend/docker-compose.discord.yml"
scp "${ssh_options[@]}" "$secret_file" "$target:here-backend/.env.discord"
ssh "${ssh_options[@]}" "$target" 'bash -s' <<'REMOTE'
set -euo pipefail
cd "$HOME/here-backend"
chmod 600 .env.discord
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
  -c 'create table if not exists public.here_schema_migrations(version text primary key, applied_at timestamptz not null default now())' </dev/null
support_applied="$(docker compose exec -T db psql -At -U postgres -d postgres \
  -c "select count(*) from public.here_schema_migrations where version = '202609300007_support_chat'" </dev/null)"
if [ "$support_applied" != "1" ]; then
  docker compose exec -T db psql -v ON_ERROR_STOP=1 -1 -U postgres -d postgres < 202609300007_support_chat.sql
  docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
    -c "insert into public.here_schema_migrations(version) values ('202609300007_support_chat')" </dev/null
fi
cleanup_applied="$(docker compose exec -T db psql -At -U postgres -d postgres \
  -c "select count(*) from public.here_schema_migrations where version = '202609300008_support_account_cleanup'" </dev/null)"
if [ "$cleanup_applied" != "1" ]; then
  docker compose exec -T db psql -v ON_ERROR_STOP=1 -1 -U postgres -d postgres < 202609300008_support_account_cleanup.sql
  docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
    -c "insert into public.here_schema_migrations(version) values ('202609300008_support_account_cleanup')" </dev/null
fi
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres <<'SQL'
grant usage on type public.support_ticket_status, public.support_sender to here_moderator;
grant select, update, delete on public.support_tickets to here_moderator;
grant select, insert, update on public.support_messages to here_moderator;
SQL
current="$(grep '^COMPOSE_FILE=' .env | cut -d= -f2-)"
case ":$current:" in
  *:docker-compose.discord.yml:*) ;;
  *) sed -i.bak "s|^COMPOSE_FILE=.*$|COMPOSE_FILE=${current}:docker-compose.discord.yml|" .env; rm -f .env.bak ;;
esac
docker compose up -d --build here-discord-moderation
docker compose ps here-discord-moderation
REMOTE
