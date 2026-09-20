#!/usr/bin/env bash
# LiteLLM proxy on :4000, talking to host llama-server and host Postgres.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/_env.sh"

PORT="${LITELLM_PORT:-4000}"
MASTER="${LITELLM_MASTER_KEY:-sk-localnexus-admin}"
PGUSER="${POSTGRES_USER:-nexus}"
PGPASSWORD_VALUE="${POSTGRES_PASSWORD:-nexus}"
PGDB="${POSTGRES_DB:-nexus}"
DATABASE_URL="${DATABASE_URL:-postgresql://${PGUSER}:${PGPASSWORD_VALUE}@127.0.0.1:5432/${PGDB}}"
CHAT_API_BASE="${CHAT_API_BASE:-http://127.0.0.1:8001/v1}"
EMBED_API_BASE="${EMBED_API_BASE:-http://127.0.0.1:8003/v1}"
WHISPER_API_BASE="${WHISPER_API_BASE:-http://127.0.0.1:8000/v1}"
VENV="${LITELLM_VENV:-$ROOT/.venv}"
LOG="$ROOT/data/logs/litellm.log"
PIDFILE="$ROOT/data/pids/litellm.pid"
mkdir -p "$ROOT/data/logs" "$ROOT/data/pids"

stop_pid() {
  if [[ -f "$PIDFILE" ]]; then
    local pid
    pid="$(cat "$PIDFILE" || true)"
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
    rm -f "$PIDFILE"
  fi
  pkill -f "litellm --config" 2>/dev/null || true
}

if [[ "${1:-}" == "stop" ]]; then
  stop_pid
  echo "litellm stopped"
  exit 0
fi

if ! curl -fsS http://127.0.0.1:8001/health >/dev/null 2>&1; then
  echo "llama chat is not up on :8001 — run ./scripts/start-native.sh first" >&2
  exit 1
fi

if [[ ! -x "$VENV/bin/litellm" ]]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -U pip wheel
  "$VENV/bin/pip" install 'litellm[proxy]' 'psycopg[binary]' prisma
fi

# Prisma Client Python needs generated engines before the proxy can open the DB.
export PATH="$VENV/bin:${HOME}/.nvm/versions/node/current/bin:${HOME}/.nvm/versions/node/v22.22.2/bin:/usr/bin:$PATH"
SCHEMA="$VENV/lib/python3.12/site-packages/litellm/proxy/schema.prisma"
if [[ -f "$SCHEMA" ]]; then
  echo "prisma generate ..."
  DATABASE_URL="${DATABASE_URL:-postgresql://${PGUSER}:${PGPASSWORD_VALUE}@127.0.0.1:5432/${PGDB}}" \
    "$VENV/bin/prisma" generate --schema="$SCHEMA"
fi

# If chat/embed env still point at Docker DNS names, retarget to host llama-server.
if [[ "$CHAT_API_BASE" == *"://llm:"* ]]; then
  CHAT_API_BASE="http://127.0.0.1:8001/v1"
fi
if [[ "$EMBED_API_BASE" == *"://embed:"* ]] || [[ "$EMBED_API_BASE" == *"://tei:"* ]]; then
  EMBED_API_BASE="http://127.0.0.1:8003/v1"
fi
if [[ "$WHISPER_API_BASE" == *"://whisper:"* ]]; then
  WHISPER_API_BASE="http://127.0.0.1:8000/v1"
fi
if [[ "$DATABASE_URL" == *"@db:"* ]]; then
  DATABASE_URL="postgresql://${PGUSER}:${PGPASSWORD_VALUE}@127.0.0.1:5432/${PGDB}"
fi

stop_pid

export LITELLM_MASTER_KEY="$MASTER"
export DATABASE_URL
export CHAT_API_BASE
export EMBED_API_BASE
export WHISPER_API_BASE
export STORE_MODEL_IN_DB=True
export LITELLM_LOG="${LITELLM_LOG:-INFO}"

echo "Starting LiteLLM on :$PORT (chat=$CHAT_API_BASE embed=$EMBED_API_BASE whisper=$WHISPER_API_BASE)"
nohup "$VENV/bin/litellm" --config "$ROOT/litellm/config.yaml" --port "$PORT" --host 0.0.0.0 \
  >"$LOG" 2>&1 &
echo $! >"$PIDFILE"

echo "Waiting for LiteLLM ..."
ready=0
for i in $(seq 1 180); do
  if curl -fsS "http://127.0.0.1:${PORT}/health/liveliness" >/dev/null 2>&1; then
    ready=1
    break
  fi
  # If the process died, fail fast with logs.
  if [[ -f "$PIDFILE" ]] && ! kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "LiteLLM process exited." >&2
    break
  fi
  sleep 2
done
if [[ "$ready" -ne 1 ]]; then
  echo "LiteLLM did not become ready. Last log:" >&2
  tail -n 80 "$LOG" >&2
  exit 1
fi
echo "LiteLLM ready  http://127.0.0.1:${PORT}/v1"
echo "Admin UI       http://127.0.0.1:${PORT}/ui"
echo "login admin / $MASTER"
