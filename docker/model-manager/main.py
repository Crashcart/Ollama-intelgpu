#!/usr/bin/env python3
"""
Ollama Model Manager — API proxy + built-in model catalog.

Routes:
  GET  /api/config           → runtime config (URLs for links)
  GET  /api/catalog          → curated model list
  GET  /api/local            → models installed in Ollama
  POST /api/pull/{model}     → pull model, SSE progress stream
  DELETE /api/model/{model}  → delete model
  GET  /                     → static HTML UI
"""

import json
import os
from pathlib import Path
from typing import AsyncGenerator

import httpx
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from fastapi.staticfiles import StaticFiles

app = FastAPI(title="Ollama Model Manager", docs_url=None, redoc_url=None)

# The portal (port 45200) fetches /api/health and /api/local cross-origin.
# Without these headers the browser blocks the response body even though the
# server is reachable (no-cors opaque fetches succeed but JSON reads don't).
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET", "POST", "DELETE"],
    allow_headers=["*"],
)

OLLAMA_URL    = os.environ.get("OLLAMA_BASE_URL", "http://ollama:11434").rstrip("/")
OLLAMA_SOCKET = os.environ.get("OLLAMA_SOCKET", "")
WEBUI_PORT    = os.environ.get("WEBUI_PORT", "45213")


def _make_ollama_client(**kwargs) -> httpx.AsyncClient:
    """
    Return an httpx.AsyncClient pointed at Ollama.

    Connects via Unix Domain Socket when OLLAMA_SOCKET is set and the
    socket file is present; falls back to TCP otherwise.
    """
    if OLLAMA_SOCKET and os.path.exists(OLLAMA_SOCKET):
        return httpx.AsyncClient(
            transport=httpx.AsyncHTTPTransport(uds=OLLAMA_SOCKET),
            base_url="http://ollama",
            **kwargs,
        )
    return httpx.AsyncClient(base_url=OLLAMA_URL, **kwargs)

# ---------------------------------------------------------------------------
# Model catalog — loaded from models.json at startup.
# To add or update models, edit models.json — no Python knowledge or image
# rebuild required.  The file is located next to this script.
# ---------------------------------------------------------------------------
_CATALOG_PATH = Path(__file__).parent / "models.json"
CATALOG: list[dict] = json.loads(_CATALOG_PATH.read_text())


# ---------------------------------------------------------------------------
# API endpoints
# ---------------------------------------------------------------------------

@app.get("/api/config")
async def get_config():
    return {"webui_port": WEBUI_PORT}


@app.get("/api/health")
async def health_check():
    """Connectivity diagnostics for all internal stack services (Ollama, SearXNG, Pipelines)."""
    import asyncio, time
    from urllib.parse import urlparse

    # Probe timeout: must be well under the portal's 12 s browser fetch timeout.
    # All 3 probes run concurrently, so worst-case response time ≈ PROBE_TIMEOUT.
    PROBE_TIMEOUT = 4  # seconds

    # Internal services: (probe_url, include_version_field)
    INTERNAL = {
        "ollama":    (f"{OLLAMA_URL}/api/version", True),
        "searxng":   ("http://searxng:8080/",       False),
        "pipelines": ("http://pipelines:9099/",     False),
    }

    async def probe(key: str, url: str, want_version: bool) -> tuple[str, dict]:
        parsed = urlparse(url)
        base = f"{parsed.scheme}://{parsed.netloc}"
        entry: dict = {"url": base, "ok": False, "latency_ms": None,
                       "error": None, "error_type": None}
        t0 = time.monotonic()
        try:
            async with httpx.AsyncClient(timeout=PROBE_TIMEOUT) as client:
                resp = await client.get(url)
                entry["latency_ms"] = round((time.monotonic() - t0) * 1000)
                resp.raise_for_status()
                entry["ok"] = True
                if want_version:
                    try:
                        entry["version"] = resp.json().get("version")
                    except Exception:
                        pass
        except httpx.ConnectError as exc:
            entry["latency_ms"] = round((time.monotonic() - t0) * 1000)
            entry["error"] = str(exc)
            entry["error_type"] = "ConnectError"
        except httpx.TimeoutException:
            entry["latency_ms"] = round((time.monotonic() - t0) * 1000)
            entry["error"] = f"Connection timed out after {PROBE_TIMEOUT} s"
            entry["error_type"] = "Timeout"
        except Exception as exc:
            entry["latency_ms"] = round((time.monotonic() - t0) * 1000)
            entry["error"] = str(exc)
            entry["error_type"] = type(exc).__name__
        return key, entry

    pairs = await asyncio.gather(
        *(probe(k, url, ver) for k, (url, ver) in INTERNAL.items())
    )
    return dict(pairs)


@app.get("/api/catalog")
async def catalog():
    return {"models": CATALOG}


@app.get("/api/local")
async def local_models():
    """Return models currently installed in Ollama."""
    try:
        async with _make_ollama_client(timeout=10) as client:
            resp = await client.get("/api/tags")
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
        async with _make_ollama_client(timeout=None) as client:
            async with client.stream(
                "POST",
                "/api/pull",
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


@app.get("/api/search")
async def search_registry(q: str = "", p: int = 1):
    """Proxy search to the Ollama model registry at ollama.com."""
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            resp = await client.get(
                "https://ollama.com/api/models",
                params={"q": q, "p": p, "sort": "popular"},
                headers={"Accept": "application/json"},
            )
            resp.raise_for_status()
            return resp.json()
    except httpx.TimeoutException:
        raise HTTPException(status_code=504, detail="ollama.com search timed out")
    except Exception as exc:
        raise HTTPException(status_code=503, detail=f"Registry search unavailable: {exc}")


@app.delete("/api/model/{model:path}")
async def delete_model(model: str):
    """Delete a locally installed model."""
    try:
        async with _make_ollama_client(timeout=30) as client:
            resp = await client.delete("/api/delete", json={"name": model})
            resp.raise_for_status()
            return {"status": "deleted", "model": model}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


# Serve static UI — must be registered last
app.mount("/", StaticFiles(directory="static", html=True), name="static")
