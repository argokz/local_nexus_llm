#!/usr/bin/env bash
# Probe NVIDIA GPU + Docker GPU passthrough. Exit 1 if the GPU stack cannot run.
set -euo pipefail

echo "=== CPU / RAM ==="
grep -m1 'model name' /proc/cpuinfo || true
echo "nproc=$(nproc)"
free -h || true

echo
echo "=== NVIDIA driver ==="
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "nvidia-smi: NOT FOUND"
  echo "This machine has no NVIDIA driver. A GTX 1660 Ti will not appear here."
  echo "Run this script on the physical PC (32 GB RAM + 1660 Ti), not on the Cloud Agent VM."
  HAS_NVIDIA=0
else
  nvidia-smi
  HAS_NVIDIA=1
fi

echo
echo "=== device nodes ==="
ls -l /dev/nvidia* /dev/dri 2>/dev/null || echo "no /dev/nvidia* or /dev/dri"

echo
echo "=== Docker ==="
if ! command -v docker >/dev/null 2>&1; then
  echo "docker: NOT FOUND"
  echo "Install Docker Engine + nvidia-container-toolkit (Linux) or Docker Desktop with WSL2 GPU (Windows)."
  exit 1
fi
docker version --format 'server={{.Server.Version}}' || docker version
if docker compose version >/dev/null 2>&1; then
  docker compose version
else
  echo "docker compose plugin: NOT FOUND"
  exit 1
fi

if [[ "$HAS_NVIDIA" -ne 1 ]]; then
  exit 1
fi

echo
echo "=== Docker GPU passthrough ==="
if docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi; then
  echo "GPU is visible inside Docker."
else
  echo "Docker cannot see the GPU. Install nvidia-container-toolkit (Linux)"
  echo "or enable WSL2 GPU in Docker Desktop (Windows)."
  exit 1
fi
