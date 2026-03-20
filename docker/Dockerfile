# Ollama with Intel GPU support (minimal - no model bundled)
# Supports Intel Arc, Intel Iris Xe, and Intel integrated graphics via Level Zero
# Models are downloaded at runtime via pull-model.sh or the Ollama API

# =============================================================================
# Stage 1 — Fetch the official Ollama binary from Docker Hub.
#
# This avoids the GitHub releases CDN entirely. GitHub CDN returns 404 in
# environments that restrict external downloads, and Ollama's release artifact
# names have changed across versions making direct URL construction fragile.
# Docker Hub is the most universally accessible source.
# =============================================================================
ARG OLLAMA_VERSION=latest
FROM ollama/ollama:${OLLAMA_VERSION} AS ollama-bin

# =============================================================================
# Stage 2 — Ubuntu 22.04 + Intel GPU compute runtime
# =============================================================================
FROM ubuntu:22.04

ARG OLLAMA_VERSION=latest
ENV DEBIAN_FRONTEND=noninteractive \
    OLLAMA_HOST=0.0.0.0:11434 \
    OLLAMA_MODELS=/root/.ollama/models

# Install base tools (wget/gpg needed for Intel repo key)
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    gnupg \
    gpg-agent \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Add Intel GPU repository
RUN wget -qO- https://repositories.intel.com/gpu/intel-graphics.key \
    | gpg --dearmor --output /usr/share/keyrings/intel-graphics.gpg \
  && echo "deb [arch=amd64,i386 signed-by=/usr/share/keyrings/intel-graphics.gpg] https://repositories.intel.com/gpu/ubuntu jammy unified" \
    | tee /etc/apt/sources.list.d/intel-gpu-jammy.list

# Install Intel GPU compute runtime (OpenCL + Level Zero)
# intel-opencl-icd  — OpenCL ICD for all Intel GPU generations (4th gen+)
# libze1            — Level Zero loader (10th-gen+ iGPU, Arc dGPU)
# libze-intel-gpu1  — Level Zero GPU driver
# intel-ocloc       — OpenCL offline compiler; without it Gen 9-12 / Arc GPUs
#                     JIT-compile kernels on every cold start, which can hang
# clinfo            — diagnostic: lists detected OpenCL/Level Zero devices
RUN apt-get update && apt-get install -y --no-install-recommends \
    intel-opencl-icd \
    libze1 \
    libze-intel-gpu1 \
    intel-ocloc \
    clinfo \
    && rm -rf /var/lib/apt/lists/*

# Copy Ollama from the official Docker Hub image.
# The binary location has varied across Ollama versions; we probe both
# /bin/ollama (used in some releases) and /usr/local/bin/ollama and take
# whichever exists. Runner libraries (used for CUDA/ROCm) are also copied
# when present — not required for Intel GPU (drivers come from apt above)
# but included so the image stays compatible with CPU-only fallback.
RUN --mount=type=bind,from=ollama-bin,source=/,target=/ollama-src \
    OLLAMA_BIN=$(find /ollama-src -name ollama -maxdepth 6 \
                      \( -type f -o -type l \) 2>/dev/null | head -1) \
    && if [ -z "${OLLAMA_BIN}" ]; then \
         echo "ERROR: ollama binary not found in official image" >&2; exit 1; \
       fi \
    && cp "${OLLAMA_BIN}" /usr/local/bin/ollama \
    && chmod +x /usr/local/bin/ollama \
    && if [ -d /ollama-src/usr/local/lib/ollama ]; then \
         mkdir -p /usr/local/lib/ollama; \
         cp -r /ollama-src/usr/local/lib/ollama/. /usr/local/lib/ollama/; \
       fi

# Create model storage directory (empty — models pulled at runtime)
RUN mkdir -p /root/.ollama/models

VOLUME ["/root/.ollama"]

EXPOSE 11434

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:11434/api/tags || exit 1

CMD ["ollama", "serve"]
