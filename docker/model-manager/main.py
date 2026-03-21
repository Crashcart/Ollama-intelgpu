#!/usr/bin/env python3
"""
Olama Model Manager — API proxy + built-in model catalog.

Routes:
  GET  /api/config           → runtime config (URLs for links)
  GET  /api/catalog          → curated model list
  GET  /api/local            → models installed in Ollama
  POST /api/pull/{model}     → pull model, SSE progress stream
  DELETE /api/model/{model}  → delete model
  GET  /                     → static HTML UI
"""

import os
from typing import AsyncGenerator

import httpx
from fastapi import FastAPI, HTTPException
from fastapi.responses import StreamingResponse
from fastapi.staticfiles import StaticFiles

app = FastAPI(title="Olama Model Manager", docs_url=None, redoc_url=None)

OLLAMA_URL = os.environ.get("OLLAMA_BASE_URL", "http://olama:11434").rstrip("/")
WEBUI_URL  = os.environ.get("WEBUI_URL", "http://localhost:45213")

# ---------------------------------------------------------------------------
# Model catalog — curated list of popular Ollama models
# ---------------------------------------------------------------------------
CATALOG = [
    # ── Text / general ───────────────────────────────────────────────────────
    {
        "id": "smollm2:135m",       "name": "SmolLM2 135M",       "size_mb":    91,
        "desc": "Hugging Face's ultra-tiny model. Runs on anything.",
        "tags": ["text", "fast"],
    },
    {
        "id": "qwen2.5:0.5b",       "name": "Qwen 2.5 0.5B",      "size_mb":   395,
        "desc": "Alibaba Qwen 2.5 0.5B — surprisingly capable at this size.",
        "tags": ["text", "fast"],
    },
    {
        "id": "llama3.2:1b",        "name": "Llama 3.2 1B",        "size_mb":   770,
        "desc": "Meta's smallest Llama. Great for simple Q&A and quick replies.",
        "tags": ["text", "fast"],
    },
    {
        "id": "gemma3:1b",          "name": "Gemma 3 1B",          "size_mb":   815,
        "desc": "Google Gemma 3 1B — tiny but well-trained.",
        "tags": ["text", "fast"],
    },
    {
        "id": "llama3.2:3b",        "name": "Llama 3.2 3B",        "size_mb":  2000,
        "desc": "Meta Llama 3.2 3B — solid balance of speed and quality.",
        "tags": ["text"],
    },
    {
        "id": "phi3:mini",          "name": "Phi-3 Mini",          "size_mb":  2300,
        "desc": "Microsoft Phi-3 mini 3.8B — punches above its weight class.",
        "tags": ["text"],
    },
    {
        "id": "phi4-mini",          "name": "Phi-4 Mini",          "size_mb":  3800,
        "desc": "Microsoft Phi-4 mini — latest generation, very capable.",
        "tags": ["text"],
    },
    {
        "id": "gemma3:4b",          "name": "Gemma 3 4B",          "size_mb":  3300,
        "desc": "Google Gemma 3 4B — strong instruction following.",
        "tags": ["text"],
    },
    {
        "id": "mistral",            "name": "Mistral 7B",          "size_mb":  4100,
        "desc": "Well-rounded general model. A great default first choice.",
        "tags": ["text"],
    },
    {
        "id": "llama3.1:8b",        "name": "Llama 3.1 8B",        "size_mb":  4700,
        "desc": "Meta Llama 3.1 8B — high quality for everyday tasks.",
        "tags": ["text"],
    },
    {
        "id": "qwen2.5:7b",         "name": "Qwen 2.5 7B",         "size_mb":  4700,
        "desc": "Alibaba Qwen 2.5 7B — strong multilingual and reasoning.",
        "tags": ["text"],
    },
    {
        "id": "mistral-nemo",       "name": "Mistral Nemo 12B",    "size_mb":  7100,
        "desc": "Mistral Nemo 12B — improved context length and quality.",
        "tags": ["text"],
    },
    {
        "id": "gemma3:12b",         "name": "Gemma 3 12B",         "size_mb":  8100,
        "desc": "Google Gemma 3 12B — high quality, fits on most GPUs.",
        "tags": ["text"],
    },
    {
        "id": "qwen2.5:14b",        "name": "Qwen 2.5 14B",        "size_mb":  9000,
        "desc": "Alibaba Qwen 2.5 14B — excellent reasoning and long context.",
        "tags": ["text"],
    },
    {
        "id": "llama3.1:70b",       "name": "Llama 3.1 70B",       "size_mb": 40000,
        "desc": "Meta Llama 3.1 70B — top tier quality. Needs ~40 GB VRAM.",
        "tags": ["text", "large"],
    },
    # ── Code ─────────────────────────────────────────────────────────────────
    {
        "id": "starcoder2:3b",      "name": "StarCoder2 3B",       "size_mb":  1700,
        "desc": "BigCode StarCoder2 3B — efficient, fast code completions.",
        "tags": ["code", "fast"],
    },
    {
        "id": "codellama:7b",       "name": "CodeLlama 7B",        "size_mb":  3800,
        "desc": "Meta CodeLlama 7B — code generation, completion, explanation.",
        "tags": ["code"],
    },
    {
        "id": "deepseek-coder:6.7b","name": "DeepSeek Coder 6.7B", "size_mb":  3800,
        "desc": "DeepSeek Coder — top-tier code generation at 6.7B.",
        "tags": ["code"],
    },
    {
        "id": "qwen2.5-coder:7b",   "name": "Qwen 2.5 Coder 7B",  "size_mb":  4700,
        "desc": "Alibaba Qwen Coder 7B — excellent code assistant.",
        "tags": ["code"],
    },
    {
        "id": "codellama:13b",      "name": "CodeLlama 13B",       "size_mb":  7400,
        "desc": "Meta CodeLlama 13B — higher quality, larger context.",
        "tags": ["code"],
    },
    # ── Vision ───────────────────────────────────────────────────────────────
    {
        "id": "moondream",          "name": "Moondream",           "size_mb":   829,
        "desc": "Tiny vision model — image Q&A in under 1 GB.",
        "tags": ["vision", "fast"],
    },
    {
        "id": "llava:7b",           "name": "LLaVA 7B",            "size_mb":  4700,
        "desc": "LLaVA 7B — understands and reasons about images.",
        "tags": ["vision"],
    },
    {
        "id": "llava:13b",          "name": "LLaVA 13B",           "size_mb":  8000,
        "desc": "LLaVA 13B — higher quality image understanding.",
        "tags": ["vision"],
    },
    {
        "id": "minicpm-v:8b",       "name": "MiniCPM-V 8B",        "size_mb":  5500,
        "desc": "MiniCPM Vision 8B — strong at charts, documents, screenshots.",
        "tags": ["vision"],
    },
    # ── Embedding (RAG) ──────────────────────────────────────────────────────
    {
        "id": "nomic-embed-text",   "name": "Nomic Embed Text",    "size_mb":   274,
        "desc": "Text embedding model used by Open WebUI's RAG feature.",
        "tags": ["embedding", "fast"],
    },
    {
        "id": "mxbai-embed-large",  "name": "MXBai Embed Large",   "size_mb":   670,
        "desc": "High-quality text embeddings for RAG and semantic search.",
        "tags": ["embedding"],
    },
]


# ---------------------------------------------------------------------------
# API endpoints
# ---------------------------------------------------------------------------

@app.get("/api/config")
async def get_config():
    return {"webui_url": WEBUI_URL}


@app.get("/api/catalog")
async def catalog():
    return {"models": CATALOG}


@app.get("/api/local")
async def local_models():
    """Return models currently installed in Ollama."""
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(f"{OLLAMA_URL}/api/tags")
            resp.raise_for_status()
            return resp.json()
    except httpx.ConnectError:
        raise HTTPException(status_code=503, detail="Ollama is not reachable")
    except Exception as exc:
        raise HTTPException(status_code=503, detail=str(exc))


@app.post("/api/pull/{model:path}")
async def pull_model(model: str):
    """Pull a model from the Ollama registry, streaming SSE progress."""

    async def _stream() -> AsyncGenerator[str, None]:
        async with httpx.AsyncClient(timeout=None) as client:
            async with client.stream(
                "POST",
                f"{OLLAMA_URL}/api/pull",
                json={"name": model},
            ) as resp:
                async for line in resp.aiter_lines():
                    if line:
                        yield f"data: {line}\n\n"
        yield 'data: {"status":"done"}\n\n'

    return StreamingResponse(
        _stream(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.delete("/api/model/{model:path}")
async def delete_model(model: str):
    """Delete a locally installed model."""
    try:
        async with httpx.AsyncClient(timeout=30) as client:
            resp = await client.delete(
                f"{OLLAMA_URL}/api/delete",
                json={"name": model},
            )
            resp.raise_for_status()
            return {"status": "deleted", "model": model}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


# Serve static UI — must be registered last
app.mount("/", StaticFiles(directory="static", html=True), name="static")
