#!/usr/bin/env bash
# Download GGUF weights into ./models (not committed).
# Uses host.auto.env from detect-hw.sh when present; otherwise the original 4B sandbox files.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODELS="$ROOT/models"
mkdir -p "$MODELS"

if [[ -f "$ROOT/host.auto.env" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT/host.auto.env"
elif [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi

CHAT_HF_REPO="${CHAT_HF_REPO:-unsloth/Qwen3-4B-GGUF}"
CHAT_HF_FILE="${CHAT_HF_FILE:-Qwen3-4B-Q4_K_M.gguf}"
CHAT_GGUF="${CHAT_GGUF:-qwen-chat.gguf}"
EMBED_HF_REPO="${EMBED_HF_REPO:-Qwen/Qwen3-Embedding-0.6B-GGUF}"
EMBED_HF_FILE="${EMBED_HF_FILE:-Qwen3-Embedding-0.6B-Q8_0.gguf}"
EMBED_GGUF="${EMBED_GGUF:-qwen-embed.gguf}"

hf_get() {
  local repo="$1" file="$2" dest_name="$3"
  local dest="$MODELS/$dest_name"
  if [[ -f "$dest" ]] && [[ "$(stat -c%s "$dest")" -gt 1048576 ]]; then
    echo "Already present: $dest_name ($(du -h "$dest" | awk '{print $1}'))"
    return 0
  fi
  local url="https://huggingface.co/${repo}/resolve/main/${file}"
  echo "Downloading $file ..."
  local tmp="$dest.part"
  curl -L --retry 5 --retry-all-errors -C - -o "$tmp" "$url"
  mv -f "$tmp" "$dest"
  echo "Saved $dest ($(du -h "$dest" | awk '{print $1}'))"
}

hf_get "$CHAT_HF_REPO" "$CHAT_HF_FILE" "$CHAT_GGUF"
hf_get "$EMBED_HF_REPO" "$EMBED_HF_FILE" "$EMBED_GGUF"

echo "Models ready in $MODELS"
ls -lh "$MODELS"
