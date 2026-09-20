# llama.cpp with CUDA for GTX 1660 Ti (Turing, sm_75).
# Build: docker compose -f docker-compose.yml -f docker-compose.gpu.yml build llm
ARG CUDA_VER=12.4.1
FROM nvidia/cuda:${CUDA_VER}-devel-ubuntu22.04 AS build

ARG CUDA_ARCHITECTURES=75

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake ninja-build git ca-certificates curl libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --depth 1 https://github.com/ggml-org/llama.cpp.git .

RUN cmake -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DGGML_CUDA=ON \
        -DGGML_NATIVE=OFF \
        -DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCHITECTURES} \
        -DLLAMA_BUILD_SERVER=ON \
        -DLLAMA_CURL=ON \
    && cmake --build build --config Release -j"$(nproc)" --target llama-server

FROM nvidia/cuda:${CUDA_VER}-runtime-ubuntu22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        libgomp1 libcurl4 ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /src/build/bin/ /opt/llama/
ENV PATH=/opt/llama:$PATH
ENV LD_LIBRARY_PATH=/opt/llama
ENTRYPOINT ["llama-server"]
