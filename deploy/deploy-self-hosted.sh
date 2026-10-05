#!/usr/bin/env bash
set -euo pipefail

target="${1:-sami@192.168.2.176}"
public_url="${2:-http://192.168.2.176:8000}"
project_root="$(cd "$(dirname "$0")/.." && pwd)"
migration="$project_root/supabase/migrations/202609300001_initial_here.sql"
account_migration="$project_root/supabase/migrations/202609300002_delete_account.sql"
profile_migration="$project_root/supabase/migrations/202609300003_profile_name.sql"

ssh_options=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

if ! ssh "${ssh_options[@]}" "$target" 'true'; then
  echo "Server nicht erreichbar: $target" >&2
  exit 1
fi

ssh "${ssh_options[@]}" "$target" 'mkdir -p "$HOME/here-deploy"'
scp "${ssh_options[@]}" "$migration" "$target:here-deploy/here.sql"
scp "${ssh_options[@]}" "$account_migration" "$target:here-deploy/202609300002_delete_account.sql"
scp "${ssh_options[@]}" "$profile_migration" "$target:here-deploy/202609300003_profile_name.sql"
scp "${ssh_options[@]}" "$project_root/deploy/docker-compose.here-hardening.yml" \
  "$target:here-deploy/docker-compose.here-hardening.yml"
scp "${ssh_options[@]}" "$project_root/deploy/backup-here.sh" "$target:here-deploy/backup-here.sh"
scp "${ssh_options[@]}" "$project_root/deploy/cleanup-here.sh" "$target:here-deploy/cleanup-here.sh"

ssh "${ssh_options[@]}" "$target" bash -s -- "$public_url" <<'REMOTE'
set -euo pipefail
public_url="$1"
backend_dir="$HOME/here-backend"

if [ ! -f "$backend_dir/run.sh" ]; then
  installer="$(mktemp)"
  curl -fsSL https://supabase.link/setup.sh -o "$installer"
  # Docker and the required base tools are provisioned separately on the host.
  # Avoid an unnecessary sudo prompt when deploying over non-interactive SSH.
  sh "$installer" -y --skip-deps --project-dir here-backend
  rm -f "$installer"
fi

cd "$backend_dir"
cp "$HOME/here-deploy/docker-compose.here-hardening.yml" docker-compose.here-hardening.yml
current_compose="$(grep '^COMPOSE_FILE=' .env | cut -d= -f2-)"
case ":$current_compose:" in
  *:docker-compose.here-hardening.yml:*) ;;
  *) sed -i.bak "s|^COMPOSE_FILE=.*$|COMPOSE_FILE=${current_compose}:docker-compose.here-hardening.yml|" .env; rm -f .env.bak ;;
esac
sed -i.bak \
  -e "s|^SUPABASE_PUBLIC_URL=.*$|SUPABASE_PUBLIC_URL=$public_url|" \
  -e "s|^API_EXTERNAL_URL=.*$|API_EXTERNAL_URL=$public_url/auth/v1|" \
  -e "s|^SITE_URL=.*$|SITE_URL=$public_url|" \
  -e 's|^ENABLE_ANONYMOUS_USERS=.*$|ENABLE_ANONYMOUS_USERS=true|' \
  .env
rm -f .env.bak
chmod 600 .env
install -m 700 "$HOME/here-deploy/backup-here.sh" "$HOME/here-backend/backup-here.sh"
install -m 700 "$HOME/here-deploy/cleanup-here.sh" "$HOME/here-backend/cleanup-here.sh"

if ! sh run.sh start </dev/null; then
  echo "Supabase meldet während des ersten Starts noch nicht alle Dienste als gesund; warte auf Kern-APIs ..."
fi

api_key="$(grep '^SUPABASE_PUBLISHABLE_KEY=' .env | cut -d= -f2-)"
ready=false
for attempt in $(seq 1 60); do
  if docker compose exec -T db pg_isready -U postgres -d postgres </dev/null >/dev/null 2>&1 \
    && curl -fsS -H "apikey: $api_key" "$public_url/auth/v1/health" >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 2
done
if [ "$ready" != true ]; then
  echo "Supabase Datenbank/Auth wurden nicht rechtzeitig bereit" >&2
  docker compose ps >&2
  exit 1
fi

docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
  -c 'create table if not exists public.here_schema_migrations(version text primary key, applied_at timestamptz not null default now())' </dev/null
applied="$(docker compose exec -T db psql -At -U postgres -d postgres \
  -c "select count(*) from public.here_schema_migrations where version = '202609300001_initial_here'" </dev/null)"
if [ "$applied" != "1" ]; then
  docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres < "$HOME/here-deploy/here.sql"
  docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
    -c "insert into public.here_schema_migrations(version) values ('202609300001_initial_here')" </dev/null
fi
account_applied="$(docker compose exec -T db psql -At -U postgres -d postgres \
  -c "select count(*) from public.here_schema_migrations where version = '202609300002_delete_account'" </dev/null)"
if [ "$account_applied" != "1" ]; then
  docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres < "$HOME/here-deploy/202609300002_delete_account.sql"
  docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
    -c "insert into public.here_schema_migrations(version) values ('202609300002_delete_account')" </dev/null
fi
profile_applied="$(docker compose exec -T db psql -At -U postgres -d postgres \
  -c "select count(*) from public.here_schema_migrations where version = '202609300003_profile_name'" </dev/null)"
if [ "$profile_applied" != "1" ]; then
  docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres < "$HOME/here-deploy/202609300003_profile_name.sql"
  docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
    -c "insert into public.here_schema_migrations(version) values ('202609300003_profile_name')" </dev/null
fi
# PostgREST starts before the application migration and otherwise keeps its old schema cache.
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
  -c "notify pgrst, 'reload schema'" </dev/null

moderator_password="$(grep '^HERE_MODERATOR_DB_PASSWORD=' .env | cut -d= -f2- || true)"
if [ -z "$moderator_password" ]; then
  moderator_password="$(openssl rand -hex 32)"
  printf '\nHERE_MODERATOR_DB_PASSWORD=%s\n' "$moderator_password" >> .env
fi
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres <<SQL
do \$\$
begin
  if not exists (select 1 from pg_roles where rolname = 'here_moderator') then
    create role here_moderator login password '$moderator_password';
  else
    alter role here_moderator password '$moderator_password';
  end if;
end \$\$;
alter role here_moderator bypassrls;
grant connect on database postgres to here_moderator;
grant usage on schema public to here_moderator;
grant select on public.profiles, public.posts, public.replies, public.reports, public.sanctions to here_moderator;
grant update on public.posts, public.replies, public.reports, public.sanctions to here_moderator;
grant insert on public.sanctions, public.moderation_actions to here_moderator;
SQL

curl -fsS -H "apikey: $api_key" "$public_url/auth/v1/health" >/dev/null
test "$(docker inspect --format '{{.State.Health.Status}}' supabase-rest)" = healthy
REMOTE

tar -C "$project_root/backend/discord-moderation" -cf - \
  Dockerfile package.json package-lock.json index.mjs .dockerignore \
  | ssh "${ssh_options[@]}" "$target" 'mkdir -p "$HOME/here-backend/discord-moderation" && tar -xf - -C "$HOME/here-backend/discord-moderation"'
scp "${ssh_options[@]}" "$project_root/backend/discord-moderation/docker-compose.discord.yml" \
  "$target:here-backend/docker-compose.discord.yml"
scp "${ssh_options[@]}" "$project_root/backend/discord-moderation/.env.discord.example" \
  "$target:here-backend/.env.discord.example"

publishable_key="$(ssh "${ssh_options[@]}" "$target" "grep '^SUPABASE_PUBLISHABLE_KEY=' \"\$HOME/here-backend/.env\" | cut -d= -f2-")"
escaped_url="$(printf '%s' "$public_url" | sed 's#://#:/\$()/#')"

umask 077
printf 'SUPABASE_URL = %s\nSUPABASE_ANON_KEY = %s\n' \
  "$escaped_url" "$publishable_key" > "$project_root/Config.xcconfig"

echo "HERE Backend läuft unter $public_url"
echo "Discord-Bot vorbereitet. Nach dem Befüllen von .env.discord: deploy/enable-discord-bot.sh"
