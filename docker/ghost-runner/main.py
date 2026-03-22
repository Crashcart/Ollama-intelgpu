#!/usr/bin/env python3
"""
Ghost Runner — background task generation with resume support.

The server streams Ollama responses and persists every token to SQLite.
Tasks survive browser disconnects and server restarts — clients reconnect
and stream from any sequence position to replay the full output.

Routes:
  POST   /api/task              → create task, start background generation
  GET    /api/tasks             → list all tasks (newest first)
  GET    /api/task/{id}         → task metadata
  GET    /api/task/{id}/stream  → SSE token stream; ?from_seq=N to resume
  DELETE /api/task/{id}         → cancel in-flight task and delete all data
  GET    /api/models            → proxy Ollama /api/tags (for model picker)
  GET    /                      → static HTML UI
"""

import asyncio
import json
import os
import time
import uuid
from contextlib import asynccontextmanager
from typing import AsyncGenerator

import aiosqlite
import httpx
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

OLLAMA_URL    = os.environ.get("OLLAMA_BASE_URL", "http://olama:11434").rstrip("/")
OLLAMA_SOCKET = os.environ.get("OLLAMA_SOCKET", "")
DB_PATH       = os.environ.get("DB_PATH", "/data/ghost.db")

# ---------------------------------------------------------------------------
# Ollama client factory — UDS when available, TCP fallback
# ---------------------------------------------------------------------------

def _make_ollama_client(**kwargs) -> httpx.AsyncClient:
    """
    Return an httpx.AsyncClient pointed at Ollama.

    When OLLAMA_SOCKET is set and the socket file exists, connect via
    Unix Domain Socket (zero TCP-stack overhead).  Falls back to TCP
    so the service still works if the uds-proxy container is absent.
    """
    if OLLAMA_SOCKET and os.path.exists(OLLAMA_SOCKET):
        return httpx.AsyncClient(
            transport=httpx.AsyncHTTPTransport(uds=OLLAMA_SOCKET),
            base_url="http://ollama",
            **kwargs,
        )
    return httpx.AsyncClient(base_url=OLLAMA_URL, **kwargs)

# ---------------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------------

async def init_db() -> None:
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    async with aiosqlite.connect(DB_PATH) as db:
        await db.executescript("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS tasks (
                id         TEXT PRIMARY KEY,
                model      TEXT NOT NULL,
                prompt     TEXT NOT NULL,
                status     TEXT NOT NULL DEFAULT 'running',
                created_at REAL NOT NULL,
                error      TEXT
            );
            CREATE TABLE IF NOT EXISTS tokens (
                task_id TEXT    NOT NULL,
                seq     INTEGER NOT NULL,
                token   TEXT    NOT NULL,
                PRIMARY KEY (task_id, seq),
                FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
            );
        """)
        await db.commit()
    # Any task still marked 'running' when the server starts was interrupted
    # (server crashed or was restarted mid-generation).
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(
            "UPDATE tasks SET status='interrupted' WHERE status='running'"
        )
        await db.commit()


# ---------------------------------------------------------------------------
# Background generation coroutine
# ---------------------------------------------------------------------------

_running: dict[str, asyncio.Task] = {}


async def _generate(task_id: str, model: str, prompt: str) -> None:
    """Stream tokens from Ollama and commit each one to SQLite immediately."""
    try:
        async with aiosqlite.connect(DB_PATH) as db:
            await db.execute("PRAGMA journal_mode=WAL")
            seq = 0
            async with _make_ollama_client(timeout=None) as client:
                async with client.stream(
                    "POST",
                    "/api/generate",
                    json={"model": model, "prompt": prompt},
                ) as resp:
                    resp.raise_for_status()
                    async for line in resp.aiter_lines():
                        if not line:
                            continue
                        chunk = json.loads(line)
                        token = chunk.get("response", "")
                        if token:
                            await db.execute(
                                "INSERT OR IGNORE INTO tokens VALUES (?,?,?)",
                                (task_id, seq, token),
                            )
                            await db.commit()
                            seq += 1
                        if chunk.get("done"):
                            break
            await db.execute(
                "UPDATE tasks SET status='complete' WHERE id=?", (task_id,)
            )
            await db.commit()
    except asyncio.CancelledError:
        pass
    except Exception as exc:
        async with aiosqlite.connect(DB_PATH) as db:
            await db.execute(
                "UPDATE tasks SET status='error', error=? WHERE id=?",
                (str(exc), task_id),
            )
            await db.commit()
    finally:
        _running.pop(task_id, None)


# ---------------------------------------------------------------------------
# App lifecycle
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_db()
    yield
    # Cancel any in-flight tasks on shutdown so they mark themselves done
    for t in list(_running.values()):
        t.cancel()
    if _running:
        await asyncio.gather(*_running.values(), return_exceptions=True)


app = FastAPI(title="Ghost Runner", docs_url=None, redoc_url=None, lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET", "POST", "DELETE"],
    allow_headers=["*"],
)


# ---------------------------------------------------------------------------
# API endpoints
# ---------------------------------------------------------------------------

class TaskRequest(BaseModel):
    model: str
    prompt: str


@app.post("/api/task", status_code=201)
async def create_task(req: TaskRequest):
    task_id = str(uuid.uuid4())
    now = time.time()
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(
            "INSERT INTO tasks VALUES (?,?,?,?,?,?)",
            (task_id, req.model, req.prompt, "running", now, None),
        )
        await db.commit()
    _running[task_id] = asyncio.create_task(
        _generate(task_id, req.model, req.prompt)
    )
    return {"task_id": task_id, "status": "running", "created_at": now}


@app.get("/api/tasks")
async def list_tasks():
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        cur = await db.execute(
            """SELECT t.id, t.model, t.prompt, t.status, t.created_at, t.error,
                      COUNT(tok.seq) AS token_count
               FROM tasks t
               LEFT JOIN tokens tok ON t.id = tok.task_id
               GROUP BY t.id
               ORDER BY t.created_at DESC"""
        )
        rows = await cur.fetchall()
    return {"tasks": [dict(r) for r in rows]}


@app.get("/api/task/{task_id}")
async def get_task(task_id: str):
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        cur = await db.execute("SELECT * FROM tasks WHERE id=?", (task_id,))
        row = await cur.fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Task not found")
    return dict(row)


@app.get("/api/task/{task_id}/stream")
async def stream_task(task_id: str, from_seq: int = 0):
    """
    SSE stream of tokens for a task.  Pass ?from_seq=N to resume mid-stream
    (client stores last received seq in IndexedDB and reconnects with it).
    The stream closes with {"done": true, "status": "..."} when the task ends.
    """
    async with aiosqlite.connect(DB_PATH) as db:
        cur = await db.execute("SELECT id FROM tasks WHERE id=?", (task_id,))
        if not await cur.fetchone():
            raise HTTPException(status_code=404, detail="Task not found")

    async def generate() -> AsyncGenerator[str, None]:
        seq = from_seq
        last_heartbeat = time.monotonic()
        while True:
            async with aiosqlite.connect(DB_PATH) as db:
                cur = await db.execute(
                    "SELECT seq, token FROM tokens "
                    "WHERE task_id=? AND seq>=? ORDER BY seq LIMIT 200",
                    (task_id, seq),
                )
                rows = await cur.fetchall()
                cur2 = await db.execute(
                    "SELECT status FROM tasks WHERE id=?", (task_id,)
                )
                status_row = await cur2.fetchone()

            status = status_row[0] if status_row else "error"

            for row in rows:
                yield f"data: {json.dumps({'seq': row[0], 'token': row[1]})}\n\n"
                seq = row[0] + 1

            if not rows:
                if status in ("complete", "error", "interrupted"):
                    yield f"data: {json.dumps({'done': True, 'status': status})}\n\n"
                    return
                # Still generating — poll every 150 ms.
                # Send an SSE comment (heartbeat) every 15 s so nginx and any
                # intermediate proxies don't close the idle connection.
                now = time.monotonic()
                if now - last_heartbeat > 15:
                    yield ": heartbeat\n\n"
                    last_heartbeat = now
                await asyncio.sleep(0.15)

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.delete("/api/task/{task_id}")
async def delete_task(task_id: str):
    t = _running.pop(task_id, None)
    if t:
        t.cancel()
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute("PRAGMA foreign_keys=ON")
        await db.execute("DELETE FROM tasks WHERE id=?", (task_id,))
        await db.commit()
    return {"deleted": True, "task_id": task_id}


@app.get("/api/models")
async def list_models():
    """Proxy Ollama's model list so the client doesn't need cross-origin access."""
    try:
        async with _make_ollama_client(timeout=5) as client:
            r = await client.get("/api/tags")
            r.raise_for_status()
            return r.json()
    except Exception:
        return {"models": []}


# Static UI — must be mounted last
app.mount("/", StaticFiles(directory="static", html=True), name="static")
