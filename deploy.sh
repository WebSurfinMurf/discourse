#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Discourse Deployment Script (Subfolder Configuration)
# ==============================================================================
#
# Description:
#   Deploys Discourse in a subfolder (e.g., /discourse) using Traefik
#   with a StripPrefix middleware.
#
# ==============================================================================


# ── Load secrets ──────────────────────────────────────────────
source "$(dirname "$0")/../secrets/discourse.env"

# ── Infra provisioning ───────────────────────────────────────
NETWORK="traefik-proxy" #
PG_VOLUME="discourse_pg_data"
REDIS_VOLUME="discourse_redis_data"
DISCOURSE_VOLUME="discourse_data"

# ensure network exists
if ! docker network ls --format '{{.Name}}' | grep -qx "${NETWORK}"; then
  echo "Creating network ${NETWORK}…" #
  docker network create "${NETWORK}" #
fi

# ensure volumes exist
for vol in "${PG_VOLUME}" "${REDIS_VOLUME}" "${DISCOURSE_VOLUME}"; do
  if ! docker volume ls --format '{{.Name}}' | grep -qx "${vol}"; then
    echo "Creating volume ${vol}…"
    docker volume create "${vol}"
  fi
done

# ── Docker settings ──────────────────────────────────────────
PG_CONTAINER="discourse-postgres"
REDIS_CONTAINER="discourse-redis"
DISCOURSE_CONTAINER="discourse"
PG_IMAGE="postgres:15"
REDIS_IMAGE="redis:7-alpine"
DISCOURSE_IMAGE="discourse/discourse:latest"


# ── Postgres: only create/start if not already running ────────
if docker ps --format '{{.Names}}' | grep -qx "${PG_CONTAINER}"; then
  echo "Postgres '${PG_CONTAINER}' is already running → skipping"
elif docker ps -a --format '{{.Names}}' | grep -qx "${PG_CONTAINER}"; then
  echo "Postgres '${PG_CONTAINER}' exists but is stopped → starting"
  docker start "${PG_CONTAINER}"
else
  echo "Starting Postgres (${PG_IMAGE})…" #
  docker run -d \
    --name "${PG_CONTAINER}" \
    --network "${NETWORK}" \
    --restart unless-stopped \
    -v "discourse_pg_data":/var/lib/postgresql/data \
    -e POSTGRES_DB="${POSTGRES_DB}" \
    -e POSTGRES_USER="${POSTGRES_USER}" \
    -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
    "${PG_IMAGE}"
fi

# ── Redis: only create/start if not already running ───────────
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
    -v "discourse_redis_data":/data \
    "${REDIS_IMAGE}"
fi

# ── Discourse: always remove & re-deploy ──────────────────────
if docker ps -a --format '{{.Names}}' | grep -qx "${DISCOURSE_CONTAINER}"; then
  echo "Removing existing Discourse container '${DISCOURSE_CONTAINER}'…"
  docker rm -f "${DISCOURSE_CONTAINER}"
fi

echo "Starting Discourse (${DISCOURSE_IMAGE}) in subfolder..."
docker run -d \
  --name "${DISCOURSE_CONTAINER}" \
  --network "${NETWORK}" \
  --restart unless-stopped \
  -v "${DISCOURSE_VOLUME}":/shared/standalone \
  -e DISCOURSE_DB_HOST="discourse-postgres" \
  -e DISCOURSE_DB_NAME="${POSTGRES_DB}" \
  -e DISCOURSE_DB_USERNAME="${POSTGRES_USER}" \
  -e DISCOURSE_DB_PASSWORD="${POSTGRES_PASSWORD}" \
  -e DISCOURSE_REDIS_HOST="discourse-redis" \
  -e DISCOURSE_HOSTNAME="${DISCOURSE_HOSTNAME}" \
  -e DISCOURSE_RELATIVE_URL_ROOT="${DISCOURSE_RELATIVE_URL_ROOT}" \
  -e DISCOURSE_DEVELOPER_EMAILS="${DISCOURSE_DEVELOPER_EMAILS}" \
  -e DISCOURSE_SMTP_ADDRESS="${DISCOURSE_SMTP_ADDRESS}" \
  -e DISCOURSE_SMTP_PORT="${DISCOURSE_SMTP_PORT}" \
  -e DISCOURSE_SMTP_USER_NAME="${DISCOURSE_SMTP_USER_NAME}" \
  -e DISCOURSE_SMTP_PASSWORD="${DISCOURSE_SMTP_PASSWORD}" \
  -e DISCOURSE_SMTP_ENABLE_START_TLS=true \
  --label "traefik.enable=true" \
  --label "traefik.docker.network=traefik-proxy" \
  --label "traefik.http.routers.discourse-secure.rule=Host(\`${DISCOURSE_HOSTNAME}\`)" \
  --label "traefik.http.routers.discourse-secure.entrypoints=websecure" \
  --label "traefik.http.routers.discourse-secure.tls=true" \
  --label "traefik.http.routers.discourse-secure.tls.certresolver=letsencrypt" \
  --label "traefik.http.services.discourse-service.loadbalancer.server.port=3000" \
  "${DISCOURSE_IMAGE}"

echo
echo "✔️ All set! Discourse is being managed by Traefik."
echo "   Access it at: https://${DISCOURSE_HOSTNAME}${DISCOURSE_RELATIVE_URL_ROOT}"
