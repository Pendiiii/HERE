#!/usr/bin/env bash
set -euo pipefail

target="${1:-sami@192.168.2.176}"
project_root="$(cd "$(dirname "$0")/.." && pwd)"
secret_file="$project_root/deploy/ai.secret"
if [ ! -f "$secret_file" ]; then
  echo "Fehlt: deploy/ai.secret (Vorlage: deploy/ai.secret.example)" >&2
  exit 1
fi
if ! grep -Eq '^GEMINI_API_KEY=.+$' "$secret_file"; then
  echo "GEMINI_API_KEY fehlt in deploy/ai.secret" >&2
  exit 1
fi

ssh_options=(-o BatchMode=yes -o ConnectTimeout=10)
ssh "${ssh_options[@]}" "$target" 'mkdir -p "$HOME/here-deploy" "$HOME/here-backend/ai-bots"'
scp "${ssh_options[@]}" "$project_root/supabase/migrations/202609300004_ai_bots.sql" "$target:here-deploy/202609300004_ai_bots.sql"
scp "${ssh_options[@]}" "$project_root/supabase/migrations/202609300005_ai_consent.sql" "$target:here-deploy/202609300005_ai_consent.sql"
scp "${ssh_options[@]}" "$project_root/supabase/migrations/202609300006_global_ai_seeds.sql" "$target:here-deploy/202609300006_global_ai_seeds.sql"
tar -C "$project_root/backend/ai-bots" -cf - Dockerfile package.json package-lock.json index.mjs .dockerignore \
  | ssh "${ssh_options[@]}" "$target" 'tar -xf - -C "$HOME/here-backend/ai-bots"'
scp "${ssh_options[@]}" "$project_root/backend/ai-bots/docker-compose.ai.yml" "$target:here-backend/docker-compose.ai.yml"
scp "${ssh_options[@]}" "$secret_file" "$target:here-backend/.env.ai"

ssh "${ssh_options[@]}" "$target" 'bash -s' <<'REMOTE'
set -euo pipefail
cd "$HOME/here-backend"
chmod 600 .env.ai

applied="$(docker compose exec -T db psql -At -U postgres -d postgres \
  -c "select count(*) from public.here_schema_migrations where version = '202609300004_ai_bots'" </dev/null)"
if [ "$applied" != "1" ]; then
  docker compose exec -T db psql -v ON_ERROR_STOP=1 -1 -U postgres -d postgres < "$HOME/here-deploy/202609300004_ai_bots.sql"
  docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
    -c "insert into public.here_schema_migrations(version) values ('202609300004_ai_bots')" </dev/null
fi
consent_applied="$(docker compose exec -T db psql -At -U postgres -d postgres \
  -c "select count(*) from public.here_schema_migrations where version = '202609300005_ai_consent'" </dev/null)"
if [ "$consent_applied" != "1" ]; then
  docker compose exec -T db psql -v ON_ERROR_STOP=1 -1 -U postgres -d postgres < "$HOME/here-deploy/202609300005_ai_consent.sql"
  docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
    -c "insert into public.here_schema_migrations(version) values ('202609300005_ai_consent')" </dev/null
fi
seeds_applied="$(docker compose exec -T db psql -At -U postgres -d postgres \
  -c "select count(*) from public.here_schema_migrations where version = '202609300006_global_ai_seeds'" </dev/null)"
if [ "$seeds_applied" != "1" ]; then
  docker compose exec -T db psql -v ON_ERROR_STOP=1 -1 -U postgres -d postgres < "$HOME/here-deploy/202609300006_global_ai_seeds.sql"
  docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
    -c "insert into public.here_schema_migrations(version) values ('202609300006_global_ai_seeds')" </dev/null
fi

bot_password="$(grep '^HERE_AI_BOT_DB_PASSWORD=' .env | cut -d= -f2- || true)"
if [ -z "$bot_password" ]; then
  bot_password="$(openssl rand -hex 32)"
  printf '\nHERE_AI_BOT_DB_PASSWORD=%s\n' "$bot_password" >> .env
fi
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres <<SQL
do \$\$
begin
  if not exists (select 1 from pg_roles where rolname = 'here_ai_bot') then
    create role here_ai_bot login password '$bot_password';
  else
    alter role here_ai_bot password '$bot_password';
  end if;
end \$\$;
alter role here_ai_bot bypassrls;
grant connect on database postgres to here_ai_bot;
grant usage on schema public, extensions to here_ai_bot;
grant usage on type public.post_category, public.report_target, public.report_status to here_ai_bot;
grant select(id, author_id, body, category, created_at, expires_at, deleted_at, allow_ai_reply) on public.posts to here_ai_bot;
grant select(id, post_id, author_id, created_at, deleted_at) on public.replies to here_ai_bot;
grant select(id, display_name, is_bot) on public.profiles to here_ai_bot;
grant select(target_type, target_id, status) on public.reports to here_ai_bot;
grant select(user_id, kind, expires_at, revoked_at) on public.sanctions to here_ai_bot;
grant usage on type public.sanction_kind to here_ai_bot;
grant select, insert on public.ai_bot_replies, public.ai_bot_seeds, public.ai_bot_skips to here_ai_bot;
grant insert(author_id, body, category, location, expires_at) on public.posts to here_ai_bot;
grant insert(post_id, author_id, body) on public.replies to here_ai_bot;
SQL

service_key="$(grep '^SERVICE_ROLE_KEY=' .env | cut -d= -f2-)"
if [ -z "$service_key" ]; then echo 'SERVICE_ROLE_KEY fehlt auf dem Server' >&2; exit 1; fi

provision_bot() {
  local email="$1" name="$2" id response payload password
  id="$(docker compose exec -T db psql -At -U postgres -d postgres -c "select id from auth.users where email = '$email'" </dev/null)"
  if [ -z "$id" ]; then
    password="$(openssl rand -hex 32)"
    payload="$(jq -nc --arg email "$email" --arg password "$password" '{email:$email,password:$password,email_confirm:true}')"
    response="$(curl -fsS -X POST 'http://127.0.0.1:8000/auth/v1/admin/users' \
      -H "apikey: $service_key" -H "Authorization: Bearer $service_key" -H 'Content-Type: application/json' -d "$payload")"
    id="$(printf '%s' "$response" | jq -r '.id // .user.id // empty')"
  fi
  if ! [[ "$id" =~ ^[0-9a-fA-F-]{36}$ ]]; then echo "Bot-Konto konnte nicht angelegt werden: $email" >&2; exit 1; fi
  docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
    -c "insert into public.profiles(id,display_name,is_bot) values ('$id','$name',true) on conflict (id) do update set display_name=excluded.display_name,is_bot=true" </dev/null >/dev/null
}

provision_bot 'here-ai-fragen@here.invalid' 'HERE Fragen'
provision_bot 'here-ai-tipps@here.invalid' 'HERE Tipps'
provision_bot 'here-ai-austausch@here.invalid' 'HERE Austausch'
unset service_key

current_compose="$(grep '^COMPOSE_FILE=' .env | cut -d= -f2-)"
case ":$current_compose:" in
  *:docker-compose.ai.yml:*) ;;
  *) sed -i.bak "s|^COMPOSE_FILE=.*$|COMPOSE_FILE=${current_compose}:docker-compose.ai.yml|" .env; rm -f .env.bak ;;
esac
docker compose up -d --build here-ai-bots
docker compose ps here-ai-bots
REMOTE
