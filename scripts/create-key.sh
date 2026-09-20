#!/usr/bin/env bash
# Create a virtual API key via LiteLLM (same as Admin UI -> Virtual Keys).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MASTER="sk-localnexus-admin"
if [[ -f "$ROOT/.env" ]]; then
  # shellcheck disable=SC1091
  set -a && source "$ROOT/.env" && set +a
  MASTER="${LITELLM_MASTER_KEY:-$MASTER}"
fi

ALIAS="${1:-sandbox-dev}"
RESP="$(curl -fsS http://127.0.0.1:4000/key/generate \
  -H "Authorization: Bearer $MASTER" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c "import json,sys; print(json.dumps({
    'key_alias': sys.argv[1],
    'models': ['qwen-chat','qwen-embed'],
    'max_budget': 10,
    'rpm_limit': 4,
    'duration': '30d',
  }))" "$ALIAS")")"

echo "$RESP" | python3 -c '
import json,sys
r=json.load(sys.stdin)
print("alias : %s" % r.get("key_alias"))
print("key   : %s" % r.get("key"))
print("Use as: Authorization: Bearer %s" % r.get("key"))
print("       OpenAI base_url = http://<this-pc>:4000/v1")
print(json.dumps(r, indent=2)[:2000])
'
