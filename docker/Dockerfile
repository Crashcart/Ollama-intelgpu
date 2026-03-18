# Ollama with Intel GPU support (minimal - no model bundled)
# Supports Intel Arc, Intel Iris Xe, and Intel integrated graphics via oneAPI/SYCL
# Models are downloaded at runtime via pull-model.sh or the Ollama API

FROM ubuntu:22.04

ARG OLLAMA_VERSION=latest
ENV DEBIAN_FRONTEND=noninteractive \
    OLLAMA_HOST=0.0.0.0:11434 \
    OLLAMA_MODELS=/root/.ollama/models

# Install Intel GPU runtime and OpenCL support
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    gnupg \
    gpg-agent \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Add Intel graphics repository for GPU driver support
RUN wget -qO- https://repositories.intel.com/gpu/intel-graphics.key \
    | gpg --dearmor --output /usr/share/keyrings/intel-graphics.gpg \
  && echo "deb [arch=amd64,i386 signed-by=/usr/share/keyrings/intel-graphics.gpg] https://repositories.intel.com/gpu/ubuntu jammy unified" \
    | tee /etc/apt/sources.list.d/intel-gpu-jammy.list

# Install Intel GPU compute runtime (OpenCL + Level Zero)
# intel-opencl-icd  — OpenCL ICD for all Intel GPU generations
# libze1            — Level Zero loader (Arc / Xe / 10th-gen+ iGPU)
# libze-intel-gpu1  — Level Zero GPU driver
# intel-ocloc       — OpenCL offline compiler; required for Gen 9-12 iGPU and Arc
#                     (without it, kernels are JIT-compiled per-run which can hang
#                      or fail on first inference for these GPU generations)
# clinfo            — diagnostic: lists detected OpenCL/Level Zero devices
RUN apt-get update && apt-get install -y --no-install-recommends \
    intel-opencl-icd \
    libze1 \
    libze-intel-gpu1 \
    intel-ocloc \
    clinfo \
    && rm -rf /var/lib/apt/lists/*

# Install Ollama binary from GitHub releases.
# We download the standalone binary (no .tgz) because:
#   • Ollama no longer ships ollama-linux-amd64.tgz in recent releases
#   • Intel GPU acceleration uses Level Zero (installed above via apt),
#     so no bundled CUDA/ROCm GPU libraries from a tarball are needed
RUN if [ "${OLLAMA_VERSION}" = "latest" ]; then \
      OLLAMA_URL="https://github.com/ollama/ollama/releases/latest/download/ollama-linux-amd64"; \
    else \
      OLLAMA_URL="https://github.com/ollama/ollama/releases/download/${OLLAMA_VERSION}/ollama-linux-amd64"; \
    fi \
    && curl -fsSL "${OLLAMA_URL}" -o /usr/local/bin/ollama \
    && chmod +x /usr/local/bin/ollama

# Create model directory (empty - models pulled at runtime)
RUN mkdir -p /root/.ollama/models

VOLUME ["/root/.ollama"]

EXPOSE 11434

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:11434/api/tags || exit 1

CMD ["ollama", "serve"]
