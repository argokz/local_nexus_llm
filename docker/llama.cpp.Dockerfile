# AVX-only llama.cpp for Sandy Bridge (i7-2600): no AVX2 / FMA / F16C / BMI2.
FROM debian:bookworm-slim AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake git ca-certificates curl libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --depth 1 https://github.com/ggml-org/llama.cpp.git .

RUN cmake -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DGGML_NATIVE=OFF \
        -DGGML_AVX=ON \
        -DGGML_AVX2=OFF \
        -DGGML_AVX512=OFF \
        -DGGML_FMA=OFF \
        -DGGML_F16C=OFF \
        -DGGML_BMI2=OFF \
        -DGGML_CUDA=OFF \
        -DLLAMA_BUILD_SERVER=ON \
        -DLLAMA_CURL=ON \
    && cmake --build build --config Release -j2 --target llama-server

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        libgomp1 libcurl4 ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /src/build/bin/ /opt/llama/
ENV PATH=/opt/llama:$PATH
ENV LD_LIBRARY_PATH=/opt/llama
ENTRYPOINT ["llama-server"]
