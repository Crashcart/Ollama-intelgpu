# Ollama with Intel GPU support (minimal - no model bundled)
# Supports Intel Arc, Intel Iris Xe, and Intel integrated graphics via oneAPI/SYCL
# Models are downloaded at runtime via pull-model.sh or the Ollama API

FROM ubuntu:22.04 AS base

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
RUN apt-get update && apt-get install -y --no-install-recommends \
    intel-opencl-icd \
    libze-intel-gpu1 \
    libze1 \
    clinfo \
    && rm -rf /var/lib/apt/lists/*

# Install Ollama (picks up Intel GPU via OpenCL/SYCL at runtime)
RUN if [ "${OLLAMA_VERSION}" = "latest" ]; then \
      curl -fsSL https://ollama.com/install.sh | sh; \
    else \
      curl -fsSL https://ollama.com/install.sh | OLLAMA_VERSION="${OLLAMA_VERSION}" sh; \
    fi

# Create model directory (empty - models pulled at runtime)
RUN mkdir -p /root/.ollama/models

VOLUME ["/root/.ollama"]

EXPOSE 11434

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:11434/api/tags || exit 1

CMD ["ollama", "serve"]
