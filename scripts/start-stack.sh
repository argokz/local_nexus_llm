#!/usr/bin/env bash
# Full Linux host stack: llama.cpp + Postgres/pgvector + LiteLLM :4000.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "${1:-}" == "stop" ]]; then
  ./scripts/start-litellm.sh stop || true
  ./scripts/start-native.sh stop || true
  echo "stack stopped (postgres left running)"
  exit 0
fi

chmod +x scripts/*.sh
[[ -f host.auto.env ]] || ./scripts/detect-hw.sh
[[ -f models/qwen-chat.gguf ]] || ./scripts/download-models.sh
if [[ ! -x "$HOME/src/llama.cpp/build/bin/llama-server" && ! -x "$ROOT/llama-server" ]]; then
  ./scripts/build-llama.sh
fi

if ! curl -fsS http://127.0.0.1:8001/health >/dev/null 2>&1; then
  ./scripts/start-native.sh
else
  echo "llama-server already healthy on :8001"
fi

./scripts/start-postgres.sh
./scripts/start-litellm.sh

# First LiteLLM Prisma baseline of a non-empty DB can drop RAG tables. Re-apply.
PGUSER="${POSTGRES_USER:-nexus}"
PGDB="${POSTGRES_DB:-nexus}"
sudo -u postgres psql -d "$PGDB" -v ON_ERROR_STOP=1 -f "$ROOT/sql/01-init.sql"
sudo -u postgres psql -d "$PGDB" -v ON_ERROR_STOP=1 -c "ALTER TABLE IF EXISTS chunks OWNER TO ${PGUSER};"
sudo -u postgres psql -d "$PGDB" -v ON_ERROR_STOP=1 -c "GRANT ALL ON ALL TABLES IN SCHEMA public TO ${PGUSER};"
sudo -u postgres psql -d "$PGDB" -v ON_ERROR_STOP=1 -c "GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO ${PGUSER};"

echo
echo "=== stack up ==="
echo "API      http://127.0.0.1:4000/v1"
echo "Admin UI http://127.0.0.1:4000/ui"
echo "Smoke    ./scripts/smoke-test.sh"
echo "RAG      ./scripts/rag_smoke.py  (via smoke-test.sh)"
echo "Key      ./scripts/create-key.sh dev-ivan"
echo "Stop     ./scripts/start-stack.sh stop"
