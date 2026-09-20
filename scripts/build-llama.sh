#!/usr/bin/env bash
# Build llama-server for this CPU. Default: native (AVX2/AVX-512/AMX when present).
# Override: LLAMA_SRC, LLAMA_BUILD_DIR, LLAMA_CPU_VARIANT=avx|native
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/_env.sh"

LLAMA_SRC="${LLAMA_SRC:-$HOME/src/llama.cpp}"
LLAMA_BUILD_DIR="${LLAMA_BUILD_DIR:-$LLAMA_SRC/build}"
CPU_VARIANT="${LLAMA_CPU_VARIANT:-native}"
JOBS="${JOBS:-$(nproc)}"

if [[ ! -d "$LLAMA_SRC/.git" ]]; then
  mkdir -p "$(dirname "$LLAMA_SRC")"
  git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "$LLAMA_SRC"
fi

cmake_cpu_args=()
if [[ "$CPU_VARIANT" == "avx" ]]; then
  # Sandy Bridge (i7-2600): no AVX2 / FMA / F16C / BMI2.
  cmake_cpu_args=(
    -DGGML_NATIVE=OFF
    -DGGML_AVX=ON
    -DGGML_AVX2=OFF
    -DGGML_AVX512=OFF
    -DGGML_FMA=OFF
    -DGGML_F16C=OFF
    -DGGML_BMI2=OFF
  )
else
  cmake_cpu_args=(-DGGML_NATIVE=ON)
fi

cmake -S "$LLAMA_SRC" -B "$LLAMA_BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_CUDA=OFF \
  -DLLAMA_BUILD_SERVER=ON \
  -DLLAMA_CURL=ON \
  -DGGML_BLAS=OFF \
  "${cmake_cpu_args[@]}"

cmake --build "$LLAMA_BUILD_DIR" --target llama-server -j "$JOBS"

BIN="$LLAMA_BUILD_DIR/bin/llama-server"
ln -sfn "$BIN" "$ROOT/llama-server"
export LD_LIBRARY_PATH="$(dirname "$BIN")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
echo "Built $BIN"
"$BIN" --version 2>/dev/null | head -5 || true
