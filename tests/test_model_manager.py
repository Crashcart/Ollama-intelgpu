"""
Tests for docker/model-manager/main.py
"""

import json
from pathlib import Path

import pytest
import httpx
from fastapi.testclient import TestClient

from tests.conftest import load_service

SERVICE = str(Path(__file__).resolve().parent.parent / "docker" / "model-manager" / "main.py")


# ---------------------------------------------------------------------------
# Minimal async context-manager helpers to mock httpx clients
# ---------------------------------------------------------------------------

class _MockResponse:
    def __init__(self, data=None, status_code=200, lines=None):
        self._data = data or {}
        self.status_code = status_code
        self._lines = lines or []

    def raise_for_status(self):
        if self.status_code >= 400:
            raise httpx.HTTPStatusError("error", request=None, response=self)

    def json(self):
        return self._data

    async def aiter_lines(self):
        for line in self._lines:
            yield line

    async def __aenter__(self):
        return self

    async def __aexit__(self, *a):
        pass


class _MockClient:
    def __init__(self, response):
        self._response = response

    async def get(self, *a, **kw):
        return self._response

    async def post(self, *a, **kw):
        return self._response

    async def delete(self, *a, **kw):
        return self._response

    def stream(self, *a, **kw):
        return self._response

    async def __aenter__(self):
        return self

    async def __aexit__(self, *a):
        pass


@pytest.fixture()
def mod():
    return load_service(SERVICE, "model_manager_main")


@pytest.fixture()
def client(mod):
    with TestClient(mod.app) as c:
        yield c


# ---------------------------------------------------------------------------
# /api/config
# ---------------------------------------------------------------------------

def test_config_returns_webui_port(client, mod, monkeypatch):
    monkeypatch.setattr(mod, "WEBUI_PORT", "12345")
    r = client.get("/api/config")
    assert r.status_code == 200
    assert r.json()["webui_port"] == "12345"


# ---------------------------------------------------------------------------
# /api/catalog
# ---------------------------------------------------------------------------

def test_catalog_returns_models(client, mod):
    r = client.get("/api/catalog")
    assert r.status_code == 200
    body = r.json()
    assert "models" in body
    assert isinstance(body["models"], list)
    assert len(body["models"]) > 0


# ---------------------------------------------------------------------------
# /api/local
# ---------------------------------------------------------------------------

def test_local_models_success(client, mod, monkeypatch):
    fake_resp = _MockResponse({"models": [{"name": "llama3.2:1b"}]})
    monkeypatch.setattr(mod, "_make_ollama_client", lambda **kw: _MockClient(fake_resp))
    r = client.get("/api/local")
    assert r.status_code == 200
    assert r.json()["models"][0]["name"] == "llama3.2:1b"


def test_local_models_ollama_unreachable(client, mod, monkeypatch):
    class _FailClient:
        async def get(self, *a, **kw):
            raise httpx.ConnectError("refused")
        async def __aenter__(self): return self
        async def __aexit__(self, *a): pass

    monkeypatch.setattr(mod, "_make_ollama_client", lambda **kw: _FailClient())
    r = client.get("/api/local")
    assert r.status_code == 503


# ---------------------------------------------------------------------------
# /api/pull/{model}
# ---------------------------------------------------------------------------

def test_pull_model_streams_sse(client, mod, monkeypatch):
    lines = ['{"status":"pulling manifest"}', '{"status":"done"}']
    fake_resp = _MockResponse(lines=lines)
    monkeypatch.setattr(mod, "_make_ollama_client", lambda **kw: _MockClient(fake_resp))
    r = client.post("/api/pull/llama3.2:1b")
    assert r.status_code == 200
    assert "text/event-stream" in r.headers["content-type"]
    assert b"pulling manifest" in r.content


# ---------------------------------------------------------------------------
# /api/search
# ---------------------------------------------------------------------------

def test_search_registry_success(client, mod, monkeypatch):
    payload = {"models": [{"name": "llama3.2"}]}

    class _SearchClient:
        async def get(self, *a, **kw):
            return _MockResponse(payload)
        async def __aenter__(self): return self
        async def __aexit__(self, *a): pass

    import httpx as _httpx
    monkeypatch.setattr(_httpx, "AsyncClient", lambda **kw: _SearchClient())
    r = client.get("/api/search?q=llama")
    assert r.status_code == 200
    assert "models" in r.json()


def test_search_registry_timeout(client, mod, monkeypatch):
    class _TimeoutClient:
        async def get(self, *a, **kw):
            raise httpx.TimeoutException("timed out")
        async def __aenter__(self): return self
        async def __aexit__(self, *a): pass

    import httpx as _httpx
    monkeypatch.setattr(_httpx, "AsyncClient", lambda **kw: _TimeoutClient())
    r = client.get("/api/search?q=llama")
    assert r.status_code == 504


# ---------------------------------------------------------------------------
# /api/model/{model}  DELETE
# ---------------------------------------------------------------------------

def test_delete_model_success(client, mod, monkeypatch):
    fake_resp = _MockResponse({"status": "deleted"})
    monkeypatch.setattr(mod, "_make_ollama_client", lambda **kw: _MockClient(fake_resp))
    r = client.delete("/api/model/llama3.2:1b")
    assert r.status_code == 200
    assert r.json()["status"] == "deleted"


def test_delete_model_error(client, mod, monkeypatch):
    class _ErrClient:
        async def delete(self, *a, **kw):
            raise RuntimeError("boom")
        async def __aenter__(self): return self
        async def __aexit__(self, *a): pass

    monkeypatch.setattr(mod, "_make_ollama_client", lambda **kw: _ErrClient())
    r = client.delete("/api/model/bad-model")
    assert r.status_code == 500


# ---------------------------------------------------------------------------
# /api/health
# ---------------------------------------------------------------------------

def test_health_check_returns_services(client, mod, monkeypatch):
    ok_resp = _MockResponse({"version": "0.6.5"}, status_code=200)

    class _HealthClient:
        async def get(self, *a, **kw):
            return ok_resp
        async def __aenter__(self): return self
        async def __aexit__(self, *a): pass

    import httpx as _httpx
    monkeypatch.setattr(_httpx, "AsyncClient", lambda **kw: _HealthClient())
    r = client.get("/api/health")
    assert r.status_code == 200
    body = r.json()
    assert "ollama" in body
    assert "searxng" in body
    assert "pipelines" in body
