"""
Tests for docker/ghost-runner/main.py
"""

import asyncio
import json
from pathlib import Path

import pytest
import httpx
from fastapi.testclient import TestClient

from tests.conftest import load_service

SERVICE = str(Path(__file__).resolve().parent.parent / "docker" / "ghost-runner" / "main.py")


# ---------------------------------------------------------------------------
# Async mock helpers
# ---------------------------------------------------------------------------

class _MockStreamResp:
    def __init__(self, lines):
        self._lines = lines
        self.status_code = 200

    def raise_for_status(self):
        pass

    async def aiter_lines(self):
        for line in self._lines:
            yield line

    async def __aenter__(self):
        return self

    async def __aexit__(self, *a):
        pass


class _MockOllamaClient:
    def __init__(self, lines):
        self._lines = lines

    def stream(self, *a, **kw):
        return _MockStreamResp(self._lines)

    async def __aenter__(self):
        return self

    async def __aexit__(self, *a):
        pass


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture()
def mod():
    return load_service(SERVICE, "ghost_runner_main")


@pytest.fixture()
def client(mod, tmp_path, monkeypatch):
    db = str(tmp_path / "ghost.db")
    monkeypatch.setattr(mod, "DB_PATH", db)
    with TestClient(mod.app) as c:
        yield c


def _ollama_factory(lines, mod, monkeypatch):
    monkeypatch.setattr(mod, "_make_ollama_client", lambda **kw: _MockOllamaClient(lines))


# ---------------------------------------------------------------------------
# Task creation
# ---------------------------------------------------------------------------

def test_create_task_returns_201(client):
    r = client.post("/api/task", json={"model": "llama3.2:1b", "prompt": "Hello"})
    assert r.status_code == 201
    body = r.json()
    assert body["status"] == "running"
    assert "task_id" in body


# ---------------------------------------------------------------------------
# List tasks
# ---------------------------------------------------------------------------

def test_list_tasks_empty(client):
    r = client.get("/api/tasks")
    assert r.status_code == 200
    assert r.json()["tasks"] == []


def test_list_tasks_after_create(client):
    client.post("/api/task", json={"model": "m", "prompt": "p"})
    r = client.get("/api/tasks")
    assert len(r.json()["tasks"]) == 1


# ---------------------------------------------------------------------------
# Get task metadata
# ---------------------------------------------------------------------------

def test_get_task_found(client):
    tid = client.post("/api/task", json={"model": "m", "prompt": "p"}).json()["task_id"]
    r = client.get(f"/api/task/{tid}")
    assert r.status_code == 200
    assert r.json()["id"] == tid


def test_get_task_not_found(client):
    r = client.get("/api/task/nonexistent")
    assert r.status_code == 404


# ---------------------------------------------------------------------------
# Delete task
# ---------------------------------------------------------------------------

def test_delete_task(client):
    tid = client.post("/api/task", json={"model": "m", "prompt": "p"}).json()["task_id"]
    r = client.delete(f"/api/task/{tid}")
    assert r.status_code == 200
    assert r.json()["deleted"] is True
    assert client.get(f"/api/task/{tid}").status_code == 404


# ---------------------------------------------------------------------------
# Stream — task not found
# ---------------------------------------------------------------------------

def test_stream_task_not_found(client):
    r = client.get("/api/task/nonexistent/stream")
    assert r.status_code == 404


# ---------------------------------------------------------------------------
# Stream — completed task replays tokens
# ---------------------------------------------------------------------------

async def _seed_completed_task(mod, db_path: str, task_id: str, tokens: list[str]):
    """Directly insert a completed task + tokens into the DB."""
    import aiosqlite, time
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            "INSERT INTO tasks VALUES (?,?,?,?,?,?)",
            (task_id, "m", "p", "complete", time.time(), None),
        )
        for seq, tok in enumerate(tokens):
            await db.execute(
                "INSERT INTO tokens VALUES (?,?,?)", (task_id, seq, tok)
            )
        await db.commit()


def test_stream_completed_task_returns_tokens(mod, tmp_path, monkeypatch):
    import asyncio as _asyncio
    db = str(tmp_path / "ghost2.db")
    monkeypatch.setattr(mod, "DB_PATH", db)

    with TestClient(mod.app) as c:
        # Seed DB with a completed task
        task_id = "test-task-complete"
        _asyncio.run(_seed_completed_task(mod, db, task_id, ["Hello", " world"]))
        r = c.get(f"/api/task/{task_id}/stream")
        assert r.status_code == 200
        content = r.text
        assert "Hello" in content
        assert "world" in content
        assert '"done": true' in content or '"done":true' in content


def test_stream_from_seq_skips_earlier_tokens(mod, tmp_path, monkeypatch):
    import asyncio as _asyncio
    db = str(tmp_path / "ghost3.db")
    monkeypatch.setattr(mod, "DB_PATH", db)

    with TestClient(mod.app) as c:
        task_id = "test-task-seq"
        _asyncio.run(_seed_completed_task(mod, db, task_id, ["A", "B", "C"]))
        r = c.get(f"/api/task/{task_id}/stream?from_seq=2")
        assert r.status_code == 200
        content = r.text
        assert "C" in content
        # seq=0 and seq=1 tokens should not appear
        assert '"seq": 0' not in content and '"seq":0' not in content


# ---------------------------------------------------------------------------
# Stream — error and interrupted states close with done payload
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("status", ["error", "interrupted"])
def test_stream_terminal_states(mod, tmp_path, monkeypatch, status):
    import asyncio as _asyncio, aiosqlite, time
    db = str(tmp_path / f"ghost_{status}.db")
    monkeypatch.setattr(mod, "DB_PATH", db)

    task_id = f"task-{status}"

    async def _seed():
        async with aiosqlite.connect(db) as dbc:
            await dbc.execute(
                "INSERT INTO tasks VALUES (?,?,?,?,?,?)",
                (task_id, "m", "p", status, time.time(), "err" if status == "error" else None),
            )
            await dbc.commit()

    with TestClient(mod.app) as c:
        _asyncio.run(_seed())
        r = c.get(f"/api/task/{task_id}/stream")
        assert r.status_code == 200
        assert status in r.text


# ---------------------------------------------------------------------------
# /api/models proxy
# ---------------------------------------------------------------------------

def test_list_models_success(mod, tmp_path, monkeypatch):
    fake_models = {"models": [{"name": "llama3.2:1b"}]}

    class _Client:
        async def get(self, *a, **kw):
            class R:
                status_code = 200
                def raise_for_status(self): pass
                def json(self): return fake_models
            return R()
        async def __aenter__(self): return self
        async def __aexit__(self, *a): pass

    monkeypatch.setattr(mod, "_make_ollama_client", lambda **kw: _Client())
    db = str(tmp_path / "ghost4.db")
    monkeypatch.setattr(mod, "DB_PATH", db)
    with TestClient(mod.app) as c:
        r = c.get("/api/models")
        assert r.status_code == 200
        assert r.json()["models"][0]["name"] == "llama3.2:1b"


def test_list_models_ollama_down(mod, tmp_path, monkeypatch):
    class _FailClient:
        async def get(self, *a, **kw):
            raise RuntimeError("down")
        async def __aenter__(self): return self
        async def __aexit__(self, *a): pass

    monkeypatch.setattr(mod, "_make_ollama_client", lambda **kw: _FailClient())
    db = str(tmp_path / "ghost5.db")
    monkeypatch.setattr(mod, "DB_PATH", db)
    with TestClient(mod.app) as c:
        r = c.get("/api/models")
        assert r.status_code == 200
        assert r.json() == {"models": []}
