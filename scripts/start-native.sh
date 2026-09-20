#!/usr/bin/env bash
# Run llama-server on the host (no Docker). Chat :8001, embeddings :8003.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$ROOT/host.auto.env" ]] && source "$ROOT/host.auto.env"
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

CHAT_GGUF="${CHAT_GGUF:-qwen-chat.gguf}"
EMBED_GGUF="${EMBED_GGUF:-qwen-embed.gguf}"
THREADS="${LLAMA_THREADS:-$(nproc)}"
CTX="${LLAMA_CTX:-4096}"
NGL="${LLAMA_NGL:-0}"
CHAT_PORT="${CHAT_PORT:-8001}"
EMBED_PORT="${EMBED_PORT:-8003}"
HOST_BIND="${HOST_BIND:-0.0.0.0}"
RUN_EMBED="${RUN_EMBED:-1}"

BIN="${LLAMA_SERVER_BIN:-$ROOT/llama-server}"
if [[ ! -x "$BIN" && -x "$HOME/src/llama.cpp/build/bin/llama-server" ]]; then
  BIN="$HOME/src/llama.cpp/build/bin/llama-server"
fi
if [[ ! -x "$BIN" ]]; then
  echo "llama-server not found. Run ./scripts/build-llama.sh first." >&2
  exit 1
fi
BIN_DIR="$(cd "$(dirname "$BIN")" && pwd)"
export LD_LIBRARY_PATH="$BIN_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

CHAT_PATH="$ROOT/models/$CHAT_GGUF"
EMBED_PATH="$ROOT/models/$EMBED_GGUF"
if [[ ! -f "$CHAT_PATH" ]]; then
  echo "Missing $CHAT_PATH — run ./scripts/download-models.sh" >&2
  exit 1
fi

LOG_DIR="$ROOT/data/logs"
PID_DIR="$ROOT/data/pids"
mkdir -p "$LOG_DIR" "$PID_DIR"

stop_pid() {
  local pidfile="$1"
  if [[ -f "$pidfile" ]]; then
    local pid
    pid="$(cat "$pidfile" || true)"
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
    rm -f "$pidfile"
  fi
}

if [[ "${1:-}" == "stop" ]]; then
  stop_pid "$PID_DIR/chat.pid"
  stop_pid "$PID_DIR/embed.pid"
  echo "stopped"
  exit 0
fi

stop_pid "$PID_DIR/chat.pid"
stop_pid "$PID_DIR/embed.pid"

echo "Starting chat $CHAT_PATH on :$CHAT_PORT (threads=$THREADS ctx=$CTX ngl=$NGL)"
nohup "$BIN" \
  -m "$CHAT_PATH" \
  --host "$HOST_BIND" --port "$CHAT_PORT" \
  -c "$CTX" -t "$THREADS" -ngl "$NGL" \
  --alias qwen-chat \
  --jinja --reasoning off \
  >"$LOG_DIR/chat.log" 2>&1 &
echo $! >"$PID_DIR/chat.pid"

if [[ "$RUN_EMBED" == "1" && -f "$EMBED_PATH" ]]; then
  echo "Starting embed $EMBED_PATH on :$EMBED_PORT"
  nohup "$BIN" \
    -m "$EMBED_PATH" \
    --host "$HOST_BIND" --port "$EMBED_PORT" \
    --embedding --pooling last \
    -c 512 -ub 512 -t 2 -ngl 0 \
    --alias qwen-embed \
    >"$LOG_DIR/embed.log" 2>&1 &
  echo $! >"$PID_DIR/embed.pid"
fi

echo "Waiting for health..."
for i in $(seq 1 120); do
  if curl -fsS "http://127.0.0.1:${CHAT_PORT}/health" >/dev/null 2>&1; then
    echo "chat ready on http://127.0.0.1:${CHAT_PORT}/v1"
    break
  fi
  if [[ "$i" -eq 120 ]]; then
    echo "chat did not become healthy. Last log:" >&2
    tail -n 40 "$LOG_DIR/chat.log" >&2
    exit 1
  fi
  sleep 2
done

if [[ -f "$PID_DIR/embed.pid" ]]; then
  for i in $(seq 1 60); do
    if curl -fsS "http://127.0.0.1:${EMBED_PORT}/health" >/dev/null 2>&1; then
      echo "embed ready on http://127.0.0.1:${EMBED_PORT}/v1"
      break
    fi
    sleep 2
  done
fi

echo "pids: chat=$(cat "$PID_DIR/chat.pid") embed=$(cat "$PID_DIR/embed.pid" 2>/dev/null || echo none)"
echo "stop with: $0 stop"
