#!/usr/bin/env python3
"""
Memory Browser — persistent AI memory store.

Stores discrete facts ("memories") the AI has learned about the user or
environment.  Pinned memories are meant to be injected into the system
prompt of every new conversation.  All other services can read pinned
memories via GET /api/memories/pinned.

Routes:
  GET    /api/memories          → all memories (pinned first, then newest)
  GET    /api/memories/pinned   → pinned only (for system-prompt injection)
  GET    /api/memory/{id}       → single memory
  POST   /api/memory            → create  { content }
  PUT    /api/memory/{id}       → update  { content?, pinned? }
  DELETE /api/memory/{id}       → delete
  GET    /                      → static HTML UI
"""

import os
import time
import uuid
from contextlib import asynccontextmanager
from typing import Optional

import aiosqlite
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

DB_PATH = os.environ.get("DB_PATH", "/data/memory.db")


# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

async def init_db() -> None:
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    async with aiosqlite.connect(DB_PATH) as db:
        await db.executescript("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS memories (
                id         TEXT PRIMARY KEY,
                content    TEXT NOT NULL,
                pinned     INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
        """)
        await db.commit()


@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_db()
    yield


# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------

app = FastAPI(title="Memory Browser", docs_url=None, redoc_url=None, lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET", "POST", "PUT", "DELETE"],
    allow_headers=["*"],
)


# ---------------------------------------------------------------------------
# Schemas
# ---------------------------------------------------------------------------

class MemoryCreate(BaseModel):
    content: str


class MemoryUpdate(BaseModel):
    content: Optional[str] = None
    pinned: Optional[bool] = None


# ---------------------------------------------------------------------------
# API
# ---------------------------------------------------------------------------

@app.get("/api/memories")
async def list_memories():
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        cur = await db.execute(
            "SELECT * FROM memories ORDER BY pinned DESC, updated_at DESC"
        )
        rows = await cur.fetchall()
    return {"memories": [dict(r) for r in rows]}


@app.get("/api/memories/pinned")
async def pinned_memories():
    """Return only pinned memories — used by external services for context injection."""
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        cur = await db.execute(
            "SELECT * FROM memories WHERE pinned=1 ORDER BY updated_at DESC"
        )
        rows = await cur.fetchall()
    return {"memories": [dict(r) for r in rows]}


@app.get("/api/memory/{mid}")
async def get_memory(mid: str):
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        cur = await db.execute("SELECT * FROM memories WHERE id=?", (mid,))
        row = await cur.fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Memory not found")
    return dict(row)


@app.post("/api/memory", status_code=201)
async def create_memory(req: MemoryCreate):
    content = req.content.strip()
    if not content:
        raise HTTPException(status_code=422, detail="Content cannot be empty")
    mid = str(uuid.uuid4())
    now = time.time()
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(
            "INSERT INTO memories VALUES (?,?,?,?,?)",
            (mid, content, 0, now, now),
        )
        await db.commit()
    return {"id": mid, "content": content, "pinned": 0, "created_at": now, "updated_at": now}


@app.put("/api/memory/{mid}")
async def update_memory(mid: str, req: MemoryUpdate):
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        cur = await db.execute("SELECT * FROM memories WHERE id=?", (mid,))
        row = await cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Memory not found")
        content = req.content.strip() if req.content is not None else row["content"]
        pinned  = int(req.pinned)     if req.pinned  is not None else row["pinned"]
        if not content:
            raise HTTPException(status_code=422, detail="Content cannot be empty")
        now = time.time()
        await db.execute(
            "UPDATE memories SET content=?, pinned=?, updated_at=? WHERE id=?",
            (content, pinned, now, mid),
        )
        await db.commit()
    return {"id": mid, "content": content, "pinned": bool(pinned), "updated_at": now}


@app.delete("/api/memory/{mid}")
async def delete_memory(mid: str):
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute("DELETE FROM memories WHERE id=?", (mid,))
        await db.commit()
    return {"deleted": True, "id": mid}


# Static UI — mount last
app.mount("/", StaticFiles(directory="static", html=True), name="static")
