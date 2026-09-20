#!/usr/bin/env bash
# Full Docker stack for GTX 1660 Ti 6GB + 32GB RAM (see env/gpu-1660ti.env).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
chmod +x scripts/*.sh

ENV_FILE="${NEXUS_ENV_FILE:-$ROOT/env/gpu-1660ti.env}"
export NEXUS_ENV_FILE="$ENV_FILE"
if [[ "${1:-}" == "stop" ]]; then
  docker compose --env-file "$ENV_FILE" -f docker-compose.yml -f docker-compose.gpu.yml --profile stt down
  echo "docker stack stopped (volumes kept)"
  exit 0
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "missing $ENV_FILE" >&2
  exit 1
fi

./scripts/gpu-check.sh
# Stop native host engines so :4000 / :8001 / :5432 are free.
if [[ -x ./scripts/start-stack.sh ]]; then
  ./scripts/start-stack.sh stop || true
fi

set -a
[[ -f .env ]] && source <(sed 's/\r$//' .env)
# GPU profile wins for model / ngl / compose.
# shellcheck disable=SC1090
source <(sed 's/\r$//' "$ENV_FILE")
set +a

./scripts/download-models.sh

echo "Starting GPU compose (first CUDA llama.cpp build is 10–20 min) ..."
docker compose --env-file "$ENV_FILE" \
  -f docker-compose.yml -f docker-compose.gpu.yml \
  --profile stt up --build -d

echo
echo "=== docker stack up ==="
echo "API      http://127.0.0.1:4000/v1"
echo "Admin UI http://127.0.0.1:4000/ui"
echo "Logs     docker compose -f docker-compose.yml -f docker-compose.gpu.yml logs -f llm"
echo "Smoke    ./scripts/smoke-test.sh"
echo "Stop     ./scripts/start-docker.sh stop"
