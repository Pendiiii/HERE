#!/usr/bin/env bash
set -euo pipefail

target="${1:-sami@192.168.2.176}"
project_root="$(cd "$(dirname "$0")/.." && pwd)"
migration="$project_root/supabase/migrations/202610010009_city_clans.sql"
levels_migration="$project_root/supabase/migrations/202610010010_clan_levels.sql"
fix_migration="$project_root/supabase/migrations/202610010011_fix_clan_join.sql"
memberships_migration="$project_root/supabase/migrations/202610010012_clan_memberships_per_level.sql"
fix_multi_migration="$project_root/supabase/migrations/202610010013_fix_multi_level_clan_join.sql"
ssh_options=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

scp "${ssh_options[@]}" "$migration" "$target:here-backend/202610010009_city_clans.sql"
scp "${ssh_options[@]}" "$levels_migration" "$target:here-backend/202610010010_clan_levels.sql"
scp "${ssh_options[@]}" "$fix_migration" "$target:here-backend/202610010011_fix_clan_join.sql"
scp "${ssh_options[@]}" "$memberships_migration" "$target:here-backend/202610010012_clan_memberships_per_level.sql"
scp "${ssh_options[@]}" "$fix_multi_migration" "$target:here-backend/202610010013_fix_multi_level_clan_join.sql"
ssh "${ssh_options[@]}" "$target" 'bash -s' <<'REMOTE'
set -euo pipefail
cd "$HOME/here-backend"
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
  -c 'create table if not exists public.here_schema_migrations(version text primary key, applied_at timestamptz not null default now())' </dev/null
applied="$(docker compose exec -T db psql -At -U postgres -d postgres \
  -c "select count(*) from public.here_schema_migrations where version = '202610010009_city_clans'" </dev/null)"
if [ "$applied" != "1" ]; then
  docker compose exec -T db psql -v ON_ERROR_STOP=1 -1 -U postgres -d postgres < 202610010009_city_clans.sql
  docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
    -c "insert into public.here_schema_migrations(version) values ('202610010009_city_clans')" </dev/null
fi
levels_applied="$(docker compose exec -T db psql -At -U postgres -d postgres \
  -c "select count(*) from public.here_schema_migrations where version = '202610010010_clan_levels'" </dev/null)"
if [ "$levels_applied" != "1" ]; then
  docker compose exec -T db psql -v ON_ERROR_STOP=1 -1 -U postgres -d postgres < 202610010010_clan_levels.sql
  docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
    -c "insert into public.here_schema_migrations(version) values ('202610010010_clan_levels')" </dev/null
fi
fix_applied="$(docker compose exec -T db psql -At -U postgres -d postgres \
  -c "select count(*) from public.here_schema_migrations where version = '202610010011_fix_clan_join'" </dev/null)"
if [ "$fix_applied" != "1" ]; then
  docker compose exec -T db psql -v ON_ERROR_STOP=1 -1 -U postgres -d postgres < 202610010011_fix_clan_join.sql
  docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
    -c "insert into public.here_schema_migrations(version) values ('202610010011_fix_clan_join')" </dev/null
fi
memberships_applied="$(docker compose exec -T db psql -At -U postgres -d postgres \
  -c "select count(*) from public.here_schema_migrations where version = '202610010012_clan_memberships_per_level'" </dev/null)"
if [ "$memberships_applied" != "1" ]; then
  docker compose exec -T db psql -v ON_ERROR_STOP=1 -1 -U postgres -d postgres < 202610010012_clan_memberships_per_level.sql
  docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
    -c "insert into public.here_schema_migrations(version) values ('202610010012_clan_memberships_per_level')" </dev/null
fi
fix_multi_applied="$(docker compose exec -T db psql -At -U postgres -d postgres \
  -c "select count(*) from public.here_schema_migrations where version = '202610010013_fix_multi_level_clan_join'" </dev/null)"
if [ "$fix_multi_applied" != "1" ]; then
  docker compose exec -T db psql -v ON_ERROR_STOP=1 -1 -U postgres -d postgres < 202610010013_fix_multi_level_clan_join.sql
  docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
    -c "insert into public.here_schema_migrations(version) values ('202610010013_fix_multi_level_clan_join')" </dev/null
fi
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
  -c "notify pgrst, 'reload schema'" </dev/null
REMOTE

echo "HERE Clans mit Ebenen sind auf dem Backend eingerichtet."
