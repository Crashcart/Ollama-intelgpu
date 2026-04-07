"""
Tests for docker/file-catalog/main.py
"""

import os
import shutil
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from tests.conftest import load_service

SERVICE = str(Path(__file__).resolve().parent.parent / "docker" / "file-catalog" / "main.py")


@pytest.fixture()
def dirs(tmp_path):
    """Return (data_dir, drives_dir) with the same real path (no symlinks)."""
    data = tmp_path / "data"
    drives = tmp_path / "drives"
    data.mkdir()
    drives.mkdir()
    return data, drives


@pytest.fixture()
def client(dirs, monkeypatch):
    mod = load_service(SERVICE, "file_catalog_main")
    data, drives = dirs
    monkeypatch.setattr(mod, "DATA_DIR", data)
    monkeypatch.setattr(mod, "DRIVES_DIR", drives)
    monkeypatch.setattr(mod, "MIN_SIZE_B", 0)   # include all files regardless of size
    monkeypatch.setattr(mod, "_SCAN_CACHE", None)
    with TestClient(mod.app) as c:
        yield c, mod, data, drives


# ---------------------------------------------------------------------------
# /api/files
# ---------------------------------------------------------------------------

def test_list_files_empty(client):
    c, mod, data, drives = client
    r = c.get("/api/files")
    assert r.status_code == 200
    assert r.json()["files"] == []


def test_list_files_shows_file(client):
    c, mod, data, drives = client
    (data / "model.gguf").write_bytes(b"x" * 100)
    r = c.get("/api/files")
    assert r.status_code == 200
    files = r.json()["files"]
    assert any(f["path"].endswith("model.gguf") for f in files)


def test_scan_cache_returns_cached_results(client):
    """Second call within TTL should return identical results without re-scanning."""
    c, mod, data, drives = client
    (data / "a.gguf").write_bytes(b"y" * 50)
    r1 = c.get("/api/files")
    # Add a second file — cache should still return old result
    (data / "b.gguf").write_bytes(b"z" * 50)
    r2 = c.get("/api/files")
    assert r1.json() == r2.json()


def test_scan_cache_refreshes_after_ttl(client, monkeypatch):
    c, mod, data, drives = client
    monkeypatch.setattr(mod, "SCAN_TTL", 0)  # expire immediately
    (data / "c.gguf").write_bytes(b"w" * 50)
    r1 = c.get("/api/files")
    (data / "d.gguf").write_bytes(b"v" * 50)
    r2 = c.get("/api/files")
    assert len(r2.json()["files"]) > len(r1.json()["files"])


# ---------------------------------------------------------------------------
# /api/drives
# ---------------------------------------------------------------------------

def test_list_drives_empty_dir(client):
    c, mod, data, drives = client
    r = c.get("/api/drives")
    assert r.status_code == 200
    assert r.json()["drives"] == []


def test_list_drives_shows_mounted_drive(client):
    c, mod, data, drives = client
    (drives / "bigdisk").mkdir()
    r = c.get("/api/drives")
    drive_names = [d["name"] for d in r.json()["drives"]]
    assert "bigdisk" in drive_names


# ---------------------------------------------------------------------------
# /api/file/move — happy path
# ---------------------------------------------------------------------------

def test_move_file_success(client):
    c, mod, data, drives = client
    (data / "weights.gguf").write_bytes(b"data" * 100)
    (drives / "external").mkdir()

    r = c.post("/api/file/move", json={"path": "weights.gguf", "drive": "external"})
    assert r.status_code == 200
    body = r.json()
    assert body["moved"] == "weights.gguf"
    # Original path should now be a symlink
    assert (data / "weights.gguf").is_symlink()
    # File should exist on the drive
    assert (drives / "external" / "weights.gguf").exists()


# ---------------------------------------------------------------------------
# /api/file/move — error cases
# ---------------------------------------------------------------------------

def test_move_file_not_found(client):
    c, mod, data, drives = client
    (drives / "external").mkdir()
    r = c.post("/api/file/move", json={"path": "missing.gguf", "drive": "external"})
    assert r.status_code == 404


def test_move_file_drive_not_found(client):
    c, mod, data, drives = client
    (data / "weights.gguf").write_bytes(b"data")
    r = c.post("/api/file/move", json={"path": "weights.gguf", "drive": "nonexistent"})
    assert r.status_code == 404


def test_move_file_path_traversal_rejected(client):
    c, mod, data, drives = client
    r = c.post("/api/file/move", json={"path": "../etc/passwd", "drive": "external"})
    assert r.status_code == 400


def test_move_file_already_symlink(client):
    c, mod, data, drives = client
    (drives / "external").mkdir()
    real_file = drives / "external" / "real.gguf"
    real_file.write_bytes(b"data")
    link = data / "real.gguf"
    link.symlink_to(real_file)
    r = c.post("/api/file/move", json={"path": "real.gguf", "drive": "external"})
    assert r.status_code == 409


def test_move_file_destination_exists(client):
    c, mod, data, drives = client
    (drives / "external").mkdir()
    (data / "dup.gguf").write_bytes(b"data")
    (drives / "external" / "dup.gguf").write_bytes(b"already there")
    r = c.post("/api/file/move", json={"path": "dup.gguf", "drive": "external"})
    assert r.status_code == 409


# ---------------------------------------------------------------------------
# /api/file/restore — happy path
# ---------------------------------------------------------------------------

def test_restore_file_success(client):
    c, mod, data, drives = client
    (drives / "external").mkdir()
    real_file = drives / "external" / "model.gguf"
    real_file.write_bytes(b"weights" * 10)
    link = data / "model.gguf"
    link.symlink_to(real_file)

    r = c.post("/api/file/restore", json={"path": "model.gguf"})
    assert r.status_code == 200
    # The file should now be a regular file at the original path
    assert (data / "model.gguf").is_file()
    assert not (data / "model.gguf").is_symlink()


# ---------------------------------------------------------------------------
# /api/file/restore — error cases
# ---------------------------------------------------------------------------

def test_restore_not_a_symlink(client):
    c, mod, data, drives = client
    (data / "regular.gguf").write_bytes(b"data")
    r = c.post("/api/file/restore", json={"path": "regular.gguf"})
    assert r.status_code == 409


def test_restore_symlink_outside_drives(client):
    """Symlink pointing outside DRIVES_DIR must be refused."""
    c, mod, data, drives = client
    external_file = data.parent / "elsewhere.gguf"
    external_file.write_bytes(b"data")
    link = data / "sneaky.gguf"
    link.symlink_to(external_file)
    r = c.post("/api/file/restore", json={"path": "sneaky.gguf"})
    assert r.status_code == 409


def test_restore_path_traversal_rejected(client):
    c, mod, data, drives = client
    r = c.post("/api/file/restore", json={"path": "../etc/passwd"})
    assert r.status_code == 400
