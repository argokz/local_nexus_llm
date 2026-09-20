#!/usr/bin/env bash
# Host faster-whisper (no Docker). OpenAI-compatible API on 127.0.0.1:8000.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/_env.sh"

PORT="${WHISPER_PORT:-8000}"
BIND="${WHISPER_BIND:-127.0.0.1}"
WANTED_MODEL="${WHISPER_MODEL:-medium}"
DEVICE="${WHISPER_DEVICE:-cpu}"
COMPUTE="${WHISPER_COMPUTE_TYPE:-int8}"
THREADS="${WHISPER_CPU_THREADS:-2}"
VENV="${WHISPER_VENV:-$ROOT/.venv-whisper}"
LOG="$ROOT/data/logs/whisper.log"
PIDFILE="$ROOT/data/pids/whisper.pid"
DOWNLOAD_ROOT="${WHISPER_DOWNLOAD_ROOT:-$ROOT/models/whisper}"
mkdir -p "$ROOT/data/logs" "$ROOT/data/pids" "$DOWNLOAD_ROOT"

avail_kb() { awk '/MemAvailable:/ {print $2}' /proc/meminfo; }
has_nvidia() {
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    return 0
  fi
  [[ -e /dev/nvidia0 ]]
}

stop_pid() {
  if [[ -f "$PIDFILE" ]]; then
    local pid
    pid="$(cat "$PIDFILE" || true)"
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      for _ in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
      done
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$PIDFILE"
  fi
}

if [[ "${1:-}" == "stop" ]]; then
  stop_pid
  echo "whisper stopped"
  exit 0
fi

echo "=== GPU / whisper probe ==="
if has_nvidia; then
  echo "NVIDIA: yes"
  nvidia-smi -L || true
  DEVICE="${WHISPER_DEVICE:-cuda}"
  COMPUTE="${WHISPER_COMPUTE_TYPE:-float16}"
else
  echo "NVIDIA: no  (nvidia-smi missing, no /dev/nvidia*)"
  if [[ -e /dev/dri/renderD128 ]]; then
    echo "DRM render node present (iGPU) — faster-whisper CUDA path still unavailable"
  else
    echo "DRM: no /dev/dri — no GPU device nodes in this VM"
  fi
  DEVICE=cpu
  COMPUTE=int8
fi
echo "MemAvailable=$(avail_kb) kB  SwapTotal=$(awk '/SwapTotal:/ {print $2}' /proc/meminfo) kB"

# medium int8 ~1.5 GB weights + ~700 MB workspace. small ~500 MB.
need_kb_medium=2300000
need_kb_small=900000
MODEL="$WANTED_MODEL"
# HuggingFace repo ids stay as-is; size aliases (medium/small) are faster-whisper names.
if [[ "$DEVICE" != "cuda" ]]; then
  avail="$(avail_kb)"
  if [[ "$WANTED_MODEL" == "medium" || "$WANTED_MODEL" == *faster-whisper-medium* ]]; then
    if [[ "$avail" -lt "$need_kb_medium" ]]; then
      echo "medium needs ~2.2 GB free after chat/embed; have $((avail/1024)) MB — falling back to small"
      MODEL=small
    else
      echo "CPU medium: MemAvailable $((avail/1024)) MB is enough for int8"
    fi
  fi
  if [[ "$MODEL" == "small" || "$MODEL" == *faster-whisper-small* ]]; then
    avail="$(avail_kb)"
    if [[ "$avail" -lt "$need_kb_small" ]]; then
      echo "Not enough RAM for whisper ($((avail/1024)) MB available). Chat 9B is already resident." >&2
      echo "Start with a smaller chat GGUF, or add swap, then rerun $0" >&2
      exit 1
    fi
  fi
fi

if [[ ! -x "$VENV/bin/python" ]]; then
  python3 -m venv "$VENV"
fi
"$VENV/bin/pip" install -U pip wheel
"$VENV/bin/pip" install 'faster-whisper' 'fastapi' 'uvicorn' 'python-multipart'

if ! command -v ffmpeg >/dev/null 2>&1; then
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ffmpeg espeak-ng
elif ! command -v espeak-ng >/dev/null 2>&1 && ! command -v espeak >/dev/null 2>&1; then
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq espeak-ng
fi

stop_pid

export WHISPER_MODEL="$MODEL"
export WHISPER_DEVICE="$DEVICE"
export WHISPER_COMPUTE_TYPE="$COMPUTE"
export WHISPER_CPU_THREADS="$THREADS"
export WHISPER_DOWNLOAD_ROOT="$DOWNLOAD_ROOT"
# Hugging Face cache next to the CTranslate2 weights.
export HF_HOME="${HF_HOME:-$DOWNLOAD_ROOT/hf}"

echo "Starting faster-whisper model=$MODEL device=$DEVICE compute=$COMPUTE on ${BIND}:${PORT}"
nohup "$VENV/bin/python" -m uvicorn whisper_server:app \
  --app-dir "$ROOT/scripts" \
  --host "$BIND" --port "$PORT" \
  >"$LOG" 2>&1 &
echo $! >"$PIDFILE"

echo "Waiting for whisper (first run downloads CTranslate2 weights) ..."
ready=0
for i in $(seq 1 180); do
  if curl -fsS "http://${BIND}:${PORT}/health" >/dev/null 2>&1; then
    ready=1
    break
  fi
  if [[ -f "$PIDFILE" ]] && ! kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "whisper process exited." >&2
    break
  fi
  sleep 2
done
if [[ "$ready" -ne 1 ]]; then
  echo "whisper did not become ready. Last log:" >&2
  tail -n 80 "$LOG" >&2
  exit 1
fi
curl -fsS "http://${BIND}:${PORT}/health"
echo
echo "whisper ready  http://${BIND}:${PORT}/v1/audio/transcriptions"
echo "stop with: $0 stop"
