"""
Tests for docker/memory-browser/main.py
"""

import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from tests.conftest import load_service

SERVICE = str(Path(__file__).resolve().parent.parent / "docker" / "memory-browser" / "main.py")


@pytest.fixture()
def client(tmp_path, monkeypatch):
    mod = load_service(SERVICE, "memory_browser_main")
    db = str(tmp_path / "memory.db")
    monkeypatch.setattr(mod, "DB_PATH", db)
    with TestClient(mod.app) as c:
        yield c


# ---------------------------------------------------------------------------
# List memories (empty)
# ---------------------------------------------------------------------------

def test_list_memories_empty(client):
    r = client.get("/api/memories")
    assert r.status_code == 200
    assert r.json() == {"memories": []}


# ---------------------------------------------------------------------------
# Create memory
# ---------------------------------------------------------------------------

def test_create_memory(client):
    r = client.post("/api/memory", json={"content": "Test fact"})
    assert r.status_code == 201
    body = r.json()
    assert body["content"] == "Test fact"
    assert body["pinned"] == 0
    assert "id" in body


def test_create_memory_strips_whitespace(client):
    r = client.post("/api/memory", json={"content": "  trimmed  "})
    assert r.status_code == 201
    assert r.json()["content"] == "trimmed"


def test_create_memory_empty_content_rejected(client):
    r = client.post("/api/memory", json={"content": ""})
    assert r.status_code == 422


def test_create_memory_whitespace_only_rejected(client):
    r = client.post("/api/memory", json={"content": "   "})
    assert r.status_code == 422


# ---------------------------------------------------------------------------
# Get single memory
# ---------------------------------------------------------------------------

def test_get_memory(client):
    created = client.post("/api/memory", json={"content": "Hello"}).json()
    r = client.get(f"/api/memory/{created['id']}")
    assert r.status_code == 200
    assert r.json()["content"] == "Hello"


def test_get_memory_not_found(client):
    r = client.get("/api/memory/nonexistent-id")
    assert r.status_code == 404


# ---------------------------------------------------------------------------
# Update memory
# ---------------------------------------------------------------------------

def test_update_memory_content(client):
    mid = client.post("/api/memory", json={"content": "Old"}).json()["id"]
    r = client.put(f"/api/memory/{mid}", json={"content": "New"})
    assert r.status_code == 200
    assert r.json()["content"] == "New"


def test_update_memory_pin(client):
    mid = client.post("/api/memory", json={"content": "A fact"}).json()["id"]
    r = client.put(f"/api/memory/{mid}", json={"pinned": True})
    assert r.status_code == 200
    assert r.json()["pinned"] is True


def test_update_memory_not_found(client):
    r = client.put("/api/memory/bad-id", json={"content": "x"})
    assert r.status_code == 404


def test_update_memory_empty_content_rejected(client):
    mid = client.post("/api/memory", json={"content": "keep"}).json()["id"]
    r = client.put(f"/api/memory/{mid}", json={"content": ""})
    assert r.status_code == 422


# ---------------------------------------------------------------------------
# Delete memory
# ---------------------------------------------------------------------------

def test_delete_memory(client):
    mid = client.post("/api/memory", json={"content": "to delete"}).json()["id"]
    r = client.delete(f"/api/memory/{mid}")
    assert r.status_code == 200
    assert r.json()["deleted"] is True
    assert client.get(f"/api/memory/{mid}").status_code == 404


# ---------------------------------------------------------------------------
# Pinned memories
# ---------------------------------------------------------------------------

def test_pinned_memories_ordering(client):
    client.post("/api/memory", json={"content": "unpinned"})
    mid = client.post("/api/memory", json={"content": "pinned"}).json()["id"]
    client.put(f"/api/memory/{mid}", json={"pinned": True})

    r = client.get("/api/memories/pinned")
    assert r.status_code == 200
    mems = r.json()["memories"]
    assert len(mems) == 1
    assert mems[0]["content"] == "pinned"


def test_list_memories_pinned_first(client):
    client.post("/api/memory", json={"content": "A"})
    mid = client.post("/api/memory", json={"content": "B"}).json()["id"]
    client.put(f"/api/memory/{mid}", json={"pinned": True})

    mems = client.get("/api/memories").json()["memories"]
    assert mems[0]["pinned"] in (1, True)
