#!/usr/bin/env python3
"""
UDS Proxy — Unix Domain Socket → TCP stream proxy.

Listens on a Unix Domain Socket and forwards every connection to the
Ollama TCP upstream.  Both halves of each connection are piped
concurrently, so long-lived SSE streams work correctly.

Environment:
  SOCKET_PATH    Path for the UDS file  (default: /sockets/ollama.sock)
  UPSTREAM_HOST  TCP host to forward to (default: olama)
  UPSTREAM_PORT  TCP port to forward to (default: 11434)
"""

import asyncio
import logging
import os
import signal
import stat

SOCKET_PATH    = os.environ.get("SOCKET_PATH",    "/sockets/ollama.sock")
UPSTREAM_HOST  = os.environ.get("UPSTREAM_HOST",  "olama")
UPSTREAM_PORT  = int(os.environ.get("UPSTREAM_PORT", "11434"))
CHUNK          = 65536

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  uds-proxy  %(levelname)s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger(__name__)

_connections = 0


async def _pipe(src_r: asyncio.StreamReader, dst_w: asyncio.StreamWriter) -> None:
    """Copy bytes from src_r to dst_w until EOF or a connection error."""
    try:
        while True:
            data = await src_r.read(CHUNK)
            if not data:
                break
            dst_w.write(data)
            await dst_w.drain()
    except (ConnectionResetError, BrokenPipeError, OSError):
        pass
    finally:
        try:
            dst_w.close()
        except Exception:
            pass


async def _handle(client_r: asyncio.StreamReader, client_w: asyncio.StreamWriter) -> None:
    global _connections
    _connections += 1
    peer = client_w.get_extra_info("peername", "?")
    log.debug("connect  #%d  peer=%s", _connections, peer)

    try:
        up_r, up_w = await asyncio.open_connection(UPSTREAM_HOST, UPSTREAM_PORT)
    except OSError as exc:
        log.warning("upstream unreachable: %s", exc)
        client_w.close()
        _connections -= 1
        return

    # Pipe both directions concurrently; when either side closes,
    # the other half's writer is closed, ending the peer side too.
    await asyncio.gather(_pipe(client_r, up_w), _pipe(up_r, client_w))
    _connections -= 1


async def main() -> None:
    # Remove any stale socket left from a previous run.
    try:
        if stat.S_ISSOCK(os.stat(SOCKET_PATH).st_mode):
            os.unlink(SOCKET_PATH)
    except FileNotFoundError:
        pass

    os.makedirs(os.path.dirname(SOCKET_PATH), exist_ok=True)

    server = await asyncio.start_unix_server(_handle, path=SOCKET_PATH)

    # World-writable so any container mounting the volume can connect.
    os.chmod(SOCKET_PATH, 0o666)

    log.info("listening  %s → %s:%d", SOCKET_PATH, UPSTREAM_HOST, UPSTREAM_PORT)

    loop = asyncio.get_running_loop()
    stop: asyncio.Future = loop.create_future()
    loop.add_signal_handler(signal.SIGTERM, stop.set_result, None)
    loop.add_signal_handler(signal.SIGINT,  stop.set_result, None)

    async with server:
        await stop

    log.info("shutting down (%d connection(s) active)", _connections)
    try:
        os.unlink(SOCKET_PATH)
    except FileNotFoundError:
        pass


asyncio.run(main())
