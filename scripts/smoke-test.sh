#!/usr/bin/env bash
# End-to-end check against LiteLLM (:4000) or native llama-server (:8001).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/_env.sh"

MASTER="${LITELLM_MASTER_KEY:-sk-localnexus-admin}"
BASE="${LITELLM_URL:-}"
MODE="${SMOKE_MODE:-auto}"

if [[ -z "$BASE" ]]; then
  if [[ "$MODE" != "native" ]] && curl -fsS http://127.0.0.1:4000/health/liveliness >/dev/null 2>&1; then
    BASE="http://127.0.0.1:4000"
    echo "== LiteLLM $BASE =="
  elif curl -fsS http://127.0.0.1:8001/health >/dev/null 2>&1; then
    BASE="http://127.0.0.1:8001"
    MASTER="sk-backend"
    echo "== native llama-server $BASE =="
  else
    BASE="http://127.0.0.1:4000"
    echo "== LiteLLM $BASE =="
  fi
fi

auth=(-H "Authorization: Bearer $MASTER" -H "Content-Type: application/json")
ORIGIN="$BASE"
ORIGIN="${ORIGIN%/}"
[[ "$ORIGIN" == */v1 ]] && ORIGIN="${ORIGIN%/v1}"

echo "== wait for API =="
ready=0
for i in $(seq 1 60); do
  if curl -fsS "$ORIGIN/health" >/dev/null 2>&1 || curl -fsS "$ORIGIN/health/liveliness" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 5
done
if [[ "$ready" -ne 1 ]]; then
  echo "API is not up on $ORIGIN" >&2
  exit 1
fi

echo "== /v1/models =="
curl -fsS "${auth[@]}" "$ORIGIN/v1/models" | python3 -c "import json,sys; d=json.load(sys.stdin); print('\n'.join(m.get('id','') for m in d.get('data',[])))"

echo "== chat =="
chat_json="$(curl -fsS "${auth[@]}" -d '{
  "model":"qwen-chat",
  "max_tokens":32,
  "temperature":0,
  "messages":[{"role":"user","content":"Reply with exactly one word: pong"}]
}' "$ORIGIN/v1/chat/completions")"
echo "$chat_json" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(d["choices"][0]["message"]["content"])
usage=d.get("usage") or {}
print("tokens prompt=%s completion=%s" % (usage.get("prompt_tokens"), usage.get("completion_tokens")))
'

if curl -fsS http://127.0.0.1:8003/health >/dev/null 2>&1 || [[ "$ORIGIN" == *":4000"* ]]; then
  echo "== embeddings =="
  emb_origin="$ORIGIN"
  [[ "$ORIGIN" == *":8001"* ]] && emb_origin="http://127.0.0.1:8003"
  dim="$(curl -fsS "${auth[@]}" -d '{"model":"qwen-embed","input":"localNexus sandbox"}' "$emb_origin/v1/embeddings" \
    | python3 -c "import json,sys; print(len(json.load(sys.stdin)['data'][0]['embedding']))")"
  echo "dim=$dim"
fi

if [[ "$ORIGIN" == *":4000"* ]]; then
  echo "== RAG (LiteLLM + pgvector) =="
  PY="${ROOT}/.venv/bin/python3"
  [[ -x "$PY" ]] || PY=python3
  LITELLM_URL="$ORIGIN/v1" \
  LITELLM_MASTER_KEY="$MASTER" \
  DATABASE_URL="${DATABASE_URL:-postgresql://${POSTGRES_USER:-nexus}:${POSTGRES_PASSWORD:-nexus}@127.0.0.1:5432/${POSTGRES_DB:-nexus}}" \
  "$PY" "$ROOT/scripts/rag_smoke.py"
fi

if curl -fsS http://127.0.0.1:8000/health >/dev/null 2>&1; then
  echo "== whisper (faster-whisper via LiteLLM) =="
  curl -fsS http://127.0.0.1:8000/health
  echo
  WAV="$ROOT/data/logs/smoke-whisper.wav"
  mkdir -p "$ROOT/data/logs"
  if command -v espeak-ng >/dev/null 2>&1; then
    espeak-ng -v en -s 140 -w "$WAV" "pong"
  elif command -v espeak >/dev/null 2>&1; then
    espeak -v en -s 140 -w "$WAV" "pong"
  else
    echo "no espeak-ng; skip transcription fixture"
    WAV=""
  fi
  if [[ -n "${WAV}" && -f "$WAV" ]]; then
    transcribe_url="$ORIGIN/v1/audio/transcriptions"
    [[ "$ORIGIN" == *":8001"* ]] && transcribe_url="http://127.0.0.1:8000/v1/audio/transcriptions"
    curl -fsS -H "Authorization: Bearer $MASTER" \
      -F "file=@${WAV}" -F "model=whisper-1" -F "language=en" \
      "$transcribe_url"
    echo
  fi
fi

echo
echo "API: $ORIGIN/v1"
echo "Chat model alias: qwen-chat"
if [[ "$ORIGIN" == *":4000"* ]]; then
  echo "Admin UI: $ORIGIN/ui  (admin / $MASTER)"
fi
