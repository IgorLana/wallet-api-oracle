#!/usr/bin/env bash
# From the project root: bash db/scripts/migrate.sh
# Do not delete the existing Oracle volume; works after C03 as well.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

if [[ ! -f .env ]]; then
  printf 'Missing .env. Copy .env.example to .env and set passwords.\n' >&2
  exit 1
fi

# .env is a trusted, local shell-compatible file. Keep values alphanumeric + _.
set -a
# shellcheck disable=SC1091
source ./.env
set +a
for variable in ORACLE_PASSWORD WALLET_OWNER_PASSWORD WALLET_APP_PASSWORD WALLET_AUDIT_PASSWORD; do
  if [[ -z "${!variable:-}" || "${!variable}" == CHANGE_ME ]]; then
    printf '%s is missing or still CHANGE_ME in .env\n' "$variable" >&2
    exit 1
  fi
done

printf '\n[1/4] Starting Oracle (preserving data volume)...\n'
docker compose up -d oracle
printf '\n[2/4] Bootstrapping users in FREEPDB1...\n'
# -e without = takes the value from the local exported environment.
docker compose exec -T \
  -e WALLET_OWNER_PASSWORD \
  -e WALLET_APP_PASSWORD \
  -e WALLET_AUDIT_PASSWORD \
  oracle bash -s < db/bootstrap/create-users.sh

COMPOSE_FILES=(-f docker-compose.yml -f docker-compose.migrations.yml)
printf '\n[3/4] Running audit migrations...\n'
docker compose "${COMPOSE_FILES[@]}" run --rm flyway-audit
printf '\n[4/4] Running owner migrations...\n'
docker compose "${COMPOSE_FILES[@]}" run --rm flyway-owner
printf '\nC04 migrations completed. Run: bash db/scripts/verify-c04.sh\n'
