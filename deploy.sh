#!/usr/bin/env bash
set -euo pipefail

# ── Load secrets ────────────────────────────────────────────────────────
#AI: source project-specific env after pipeline.env loads
source "$(dirname "$0")/../secrets/discourse.env"

# ── Infra provisioning ─────────────────────────────────────────────────
NETWORK="discourse-net"
PG_VOLUME="discourse_pg_data"
REDIS_VOLUME="discourse_redis_data"
DC_VOLUME="discourse_data"
PLUGIN_VOLUME="discourse_plugins"

# ensure network exists
if ! docker network ls --format '{{.Name}}' | grep -qx "${NETWORK}"; then
  echo "Creating network ${NETWORK}…"
  docker network create "${NETWORK}"
fi

# ensure volumes exist
for vol in "${PG_VOLUME}" "${REDIS_VOLUME}" "${DC_VOLUME}" "${PLUGIN_VOLUME}"; do
  if ! docker volume ls --format '{{.Name}}' | grep -qx "${vol}"; then
    echo "Creating volume ${vol}…"
    docker volume create "${vol}"
  fi
done

# ── Docker settings ───────────────────────────────────────────────────
PG_CONTAINER="discourse-postgres"
REDIS_CONTAINER="discourse-redis"
DC_CONTAINER="discourse"
PG_IMAGE="postgres:15"
REDIS_IMAGE="redis:6"
DC_IMAGE="discourse/discourse:latest"
HTTP_PORT=3000

# ── Postgres: only create/start if not already running ────────────────
if docker ps --format '{{.Names}}' | grep -qx "${PG_CONTAINER}"; then
  echo "Postgres '${PG_CONTAINER}' is already running → skipping"
elif docker ps -a --format '{{.Names}}' | grep -qx "${PG_CONTAINER}"; then
  echo "Postgres '${PG_CONTAINER}' exists but is stopped → starting"
  docker start "${PG_CONTAINER}"
else
  echo "Starting Postgres (${PG_IMAGE})…"
  docker run -d \
    --name "${PG_CONTAINER}" \
    --network "${NETWORK}" \
    --restart unless-stopped \
    -v "${PG_VOLUME}":/var/lib/postgresql/data \
    -e POSTGRES_DB="${DISCOURSE_DB}" \
    -e POSTGRES_USER="${DISCOURSE_DB_USER}" \
    -e POSTGRES_PASSWORD="${DISCOURSE_DB_PASS}" \
    "${PG_IMAGE}"
fi

# ── Redis: only create/start if not already running ───────────────────
if docker ps --format '{{.Names}}' | grep -qx "${REDIS_CONTAINER}"; then
  echo "Redis '${REDIS_CONTAINER}' is already running → skipping"
elif docker ps -a --format '{{.Names}}' | grep -qx "${REDIS_CONTAINER}"; then
  echo "Redis '${REDIS_CONTAINER}' exists but is stopped → starting"
  docker start "${REDIS_CONTAINER}"
else
  echo "Starting Redis (${REDIS_IMAGE})…"
  docker run -d \
    --name "${REDIS_CONTAINER}" \
    --network "${NETWORK}" \
    --restart unless-stopped \
    -v "${REDIS_VOLUME}":/data \
    "${REDIS_IMAGE}"
fi

# ── Discourse: always remove & re-deploy ───────────────────────────────
if docker ps -a --format '{{.Names}}' | grep -qx "${DC_CONTAINER}"; then
  echo "Removing existing Discourse container '${DC_CONTAINER}'…"
  docker rm -f "${DC_CONTAINER}"
fi

echo "Starting Discourse (${DC_IMAGE})…"
docker run -d \
  --name "${DC_CONTAINER}" \
  --network "${NETWORK}" \
  --restart unless-stopped \
  -p "${HTTP_PORT}:3000" \
  -v "${DC_VOLUME}":/var/www/discourse/public/uploads \
  -v "${PLUGIN_VOLUME}":/var/www/discourse/plugins \
  -e DISCOURSE_DB_HOST="${PG_CONTAINER}" \
  -e DISCOURSE_DB_NAME="${DISCOURSE_DB}" \
  -e DISCOURSE_DB_USERNAME="${DISCOURSE_DB_USER}" \
  -e DISCOURSE_DB_PASSWORD="${DISCOURSE_DB_PASS}" \
  -e DISCOURSE_REDIS_HOST="${REDIS_CONTAINER}" \
  "${DC_IMAGE}"

echo
echo "✔️ All set! Discourse is live on HTTP port ${HTTP_PORT}:"
echo " http://$(hostname -I | awk '{print $1}'):${HTTP_PORT}/"
