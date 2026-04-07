"""
Tests for docker/uds-proxy/proxy.py
"""

import asyncio
import io
import os
from pathlib import Path

import pytest


# ---------------------------------------------------------------------------
# Load proxy module without triggering asyncio.run(main())
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def proxy_mod():
    """
    Import proxy.py safely.  The module ends with `asyncio.run(main())`
    which we suppress by replacing asyncio.run with a no-op for the duration
    of the import.
    """
    import importlib.util, sys, asyncio as _asyncio

    original_run = _asyncio.run

    def _noop_run(coro, **kw):
        # Close the coroutine to avoid ResourceWarning
        coro.close()

    _asyncio.run = _noop_run
    try:
        path = str(Path(__file__).resolve().parent.parent / "docker" / "uds-proxy" / "proxy.py")
        if "uds_proxy_main" in sys.modules:
            return sys.modules["uds_proxy_main"]
        spec = importlib.util.spec_from_file_location("uds_proxy_main", path)
        mod = importlib.util.module_from_spec(spec)
        sys.modules["uds_proxy_main"] = mod
        spec.loader.exec_module(mod)
        return mod
    finally:
        _asyncio.run = original_run


# ---------------------------------------------------------------------------
# _pipe: copies bytes from reader to writer
# ---------------------------------------------------------------------------

class _FakeWriter:
    def __init__(self):
        self.data = b""
        self.closed = False

    def write(self, data):
        self.data += data

    async def drain(self):
        pass

    def close(self):
        self.closed = True


class _FakeReader:
    def __init__(self, chunks):
        self._chunks = list(chunks)

    async def read(self, n):
        if self._chunks:
            return self._chunks.pop(0)
        return b""


@pytest.mark.asyncio
async def test_pipe_copies_data(proxy_mod):
    reader = _FakeReader([b"hello", b" world", b""])
    writer = _FakeWriter()
    await proxy_mod._pipe(reader, writer)
    assert writer.data == b"hello world"
    assert writer.closed


@pytest.mark.asyncio
async def test_pipe_empty_reader(proxy_mod):
    reader = _FakeReader([b""])
    writer = _FakeWriter()
    await proxy_mod._pipe(reader, writer)
    assert writer.data == b""
    assert writer.closed


@pytest.mark.asyncio
async def test_pipe_connection_reset(proxy_mod):
    """_pipe should swallow ConnectionResetError without raising."""

    class _ErrorWriter(_FakeWriter):
        def write(self, data):
            raise ConnectionResetError("reset")

    reader = _FakeReader([b"data"])
    writer = _ErrorWriter()
    # Should not raise
    await proxy_mod._pipe(reader, writer)


@pytest.mark.asyncio
async def test_pipe_multiple_chunks(proxy_mod):
    reader = _FakeReader([b"a", b"b", b"c", b""])
    writer = _FakeWriter()
    await proxy_mod._pipe(reader, writer)
    assert writer.data == b"abc"


# ---------------------------------------------------------------------------
# _handle: opens upstream connection, pipes both ways
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_handle_increments_connections(proxy_mod, monkeypatch):
    """Connection counter increments then decrements after the session ends."""

    async def _fake_open_connection(host, port):
        r = _FakeReader([b""])
        w = _FakeWriter()
        return r, w

    monkeypatch.setattr(asyncio, "open_connection", _fake_open_connection)
    proxy_mod._connections = 0

    client_r = _FakeReader([b""])
    client_w = _FakeWriter()
    client_w.get_extra_info = lambda key, default=None: default

    await proxy_mod._handle(client_r, client_w)
    assert proxy_mod._connections == 0  # decremented after completion


@pytest.mark.asyncio
async def test_handle_upstream_unreachable(proxy_mod, monkeypatch):
    """When the upstream is unreachable, the client writer is closed cleanly."""

    async def _fail_open(host, port):
        raise OSError("refused")

    monkeypatch.setattr(asyncio, "open_connection", _fail_open)
    proxy_mod._connections = 0

    client_r = _FakeReader([b""])
    client_w = _FakeWriter()
    client_w.get_extra_info = lambda key, default=None: default

    await proxy_mod._handle(client_r, client_w)
    assert client_w.closed
    assert proxy_mod._connections == 0
