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
  if [[ "$MODE" == "native" ]] || { [[ "$MODE" == "auto" ]] && curl -fsS http://127.0.0.1:8001/health >/dev/null 2>&1; }; then
    BASE="http://127.0.0.1:8001"
    MASTER="sk-backend"
    echo "== native llama-server $BASE =="
  else
    BASE="http://127.0.0.1:4000"
    echo "== LiteLLM $BASE =="
  fi
fi

auth=(-H "Authorization: Bearer $MASTER" -H "Content-Type: application/json")

echo "== wait for API =="
ready=0
for i in $(seq 1 60); do
  if curl -fsS "$BASE/health" >/dev/null 2>&1 || curl -fsS "$BASE/health/liveliness" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 5
done
if [[ "$ready" -ne 1 ]]; then
  echo "API is not up on $BASE" >&2
  exit 1
fi

echo "== /v1/models =="
curl -fsS "${auth[@]}" "$BASE/v1/models" | python3 -c "import json,sys; d=json.load(sys.stdin); print('\n'.join(m.get('id','') for m in d.get('data',[])))"

echo "== chat =="
chat_json="$(curl -fsS "${auth[@]}" -d '{
  "model":"qwen-chat",
  "max_tokens":32,
  "temperature":0,
  "messages":[{"role":"user","content":"Reply with exactly one word: pong"}]
}' "$BASE/v1/chat/completions")"
echo "$chat_json" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(d["choices"][0]["message"]["content"])
usage=d.get("usage") or {}
print("tokens prompt=%s completion=%s" % (usage.get("prompt_tokens"), usage.get("completion_tokens")))
'

if curl -fsS http://127.0.0.1:8003/health >/dev/null 2>&1 || [[ "$BASE" == *":4000"* ]]; then
  echo "== embeddings =="
  emb_base="$BASE"
  [[ "$BASE" == *":8001"* ]] && emb_base="http://127.0.0.1:8003"
  dim="$(curl -fsS "${auth[@]}" -d '{"model":"qwen-embed","input":"localNexus sandbox"}' "$emb_base/v1/embeddings" \
    | python3 -c "import json,sys; print(len(json.load(sys.stdin)['data'][0]['embedding']))")"
  echo "dim=$dim"
fi

echo
echo "API: $BASE/v1"
echo "Chat model alias: qwen-chat"
