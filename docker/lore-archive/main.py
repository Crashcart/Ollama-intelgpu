#!/usr/bin/env python3
"""
Lore Archive — immutable long-term memory and entity state tracking
for multi-year tabletop / server campaigns.

Three subsystems:

  1. Chronicle Ledger   — append-only event timeline with semantic search.
                          Every event is vectorised (via Ollama embeddings, or a
                          TF-IDF fallback) so the GM can search "a glowing dagger"
                          and surface a record from years ago without remembering
                          the exact wording.

  2. Entity Tracker     — dynamic status registry for Players, NPCs, Locations,
                          and Items.  Flexible JSON attributes mean any new
                          condition or item type can be stored without schema
                          changes.  The GM Engine checks this before assuming
                          anything about the world state.

  3. Universe Ruleset   — immutable laws of the campaign.  Rules marked "pinned"
                          are returned by GET /api/rules/pinned and must be injected
                          into every prompt sent to the Storyteller API so the AI
                          can never drift from the core rules of your universe.

Routes:
  GET    /api/events                 → list events, newest first (filter: ?entity_id=)
  POST   /api/event                  → create event; embedding queued in background
  GET    /api/events/search?q=...    → semantic similarity search
  DELETE /api/event/{id}             → delete event

  GET    /api/entities               → list all entities (filter: ?type=player|npc|…)
  POST   /api/entity                 → create entity
  GET    /api/entity/{id}            → get entity
  PUT    /api/entity/{id}            → update entity status / location / attributes
  DELETE /api/entity/{id}            → delete entity

  GET    /api/rules                  → list all rules (pinned first)
  GET    /api/rules/pinned           → pinned rules only — for forced context injection
  POST   /api/rule                   → create rule
  GET    /api/rule/{id}              → get rule
  PUT    /api/rule/{id}              → update rule (content, pinned flag, category)
  DELETE /api/rule/{id}              → delete rule

  GET    /                           → static HTML UI
"""

import asyncio
import json
import math
import os
import re
import time
import uuid
from contextlib import asynccontextmanager
from typing import Any, Optional

import aiosqlite
import httpx
from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

DB_PATH     = os.environ.get("DB_PATH", "/data/lore.db")
OLLAMA_URL  = os.environ.get("OLLAMA_BASE_URL", "http://ollama:11434").rstrip("/")
EMBED_MODEL = os.environ.get("EMBED_MODEL", "nomic-embed-text")

# Dimension for the TF-IDF fallback embedding.  512 gives reasonable keyword
# discrimination without being large.
_TFIDF_DIM = 512


# ---------------------------------------------------------------------------
# Embedding helpers
# ---------------------------------------------------------------------------

def _tfidf_embed(text: str) -> list[float]:
    """
    Lightweight bag-of-words fallback for when Ollama's embedding endpoint
    is unavailable (e.g. no embedding model pulled yet).

    Hashes each token to a bucket in a fixed-size vector, then L2-normalises.
    Cosine similarity still works correctly on the output.
    """
    words = re.findall(r"\w+", text.lower())
    vec = [0.0] * _TFIDF_DIM
    for w in words:
        vec[hash(w) % _TFIDF_DIM] += 1.0
    mag = math.sqrt(sum(x * x for x in vec))
    return [x / mag for x in vec] if mag > 0 else vec


async def _ollama_embed(text: str) -> Optional[list[float]]:
    """Call Ollama's /api/embeddings endpoint.  Returns None on any failure."""
    try:
        async with httpx.AsyncClient(base_url=OLLAMA_URL, timeout=20) as client:
            r = await client.post(
                "/api/embeddings",
                json={"model": EMBED_MODEL, "prompt": text},
            )
            r.raise_for_status()
            return r.json().get("embedding")
    except Exception:
        return None


async def embed(text: str) -> list[float]:
    """Return an embedding vector, preferring Ollama, falling back to TF-IDF."""
    vec = await _ollama_embed(text)
    return vec if vec else _tfidf_embed(text)


def cosine_sim(v1: list[float], v2: list[float]) -> float:
    """Cosine similarity between two equal-length vectors (pure Python)."""
    if len(v1) != len(v2):
        return 0.0
    dot  = sum(a * b for a, b in zip(v1, v2))
    mag1 = math.sqrt(sum(a * a for a in v1))
    mag2 = math.sqrt(sum(b * b for b in v2))
    return dot / (mag1 * mag2) if mag1 and mag2 else 0.0


# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

async def init_db() -> None:
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    async with aiosqlite.connect(DB_PATH) as db:
        await db.executescript("""
            PRAGMA journal_mode=WAL;

            -- Chronicle Ledger: append-only historical event log.
            -- embedding is populated asynchronously after insert.
            CREATE TABLE IF NOT EXISTS events (
                id            TEXT PRIMARY KEY,
                realworld_ts  REAL NOT NULL,
                ingame_date   TEXT,
                description   TEXT NOT NULL,
                entity_ids    TEXT NOT NULL DEFAULT '[]',
                embedding     TEXT,
                created_at    REAL NOT NULL
            );

            -- Entity Tracker: current physical truth of the world.
            -- attributes is a schema-less JSON object for flexible per-entity data.
            CREATE TABLE IF NOT EXISTS entities (
                id            TEXT PRIMARY KEY,
                entity_type   TEXT NOT NULL,
                name          TEXT NOT NULL,
                status        TEXT NOT NULL DEFAULT 'alive',
                last_location TEXT,
                attributes    TEXT NOT NULL DEFAULT '{}',
                created_at    REAL NOT NULL,
                updated_at    REAL NOT NULL
            );

            -- Universe Ruleset: immutable laws of the campaign.
            -- pinned=1 rows are force-injected into every Storyteller prompt.
            CREATE TABLE IF NOT EXISTS rules (
                id            TEXT PRIMARY KEY,
                title         TEXT NOT NULL,
                content       TEXT NOT NULL,
                category      TEXT,
                pinned        INTEGER NOT NULL DEFAULT 0,
                created_at    REAL NOT NULL,
                updated_at    REAL NOT NULL
            );
        """)
        await db.commit()


# ---------------------------------------------------------------------------
# Background embedding worker
# ---------------------------------------------------------------------------

# Bounded so a slow/unavailable Ollama doesn't cause unbounded memory growth.
_embed_queue: asyncio.Queue = asyncio.Queue(maxsize=500)


async def _embed_worker() -> None:
    """
    Consumes (event_id, text) pairs from the queue and writes the embedding
    vector back to the DB.  Runs as a single background task so that POST
    /api/event returns immediately while the (potentially slow) Ollama call
    happens out-of-band.
    """
    while True:
        event_id, text = await _embed_queue.get()
        try:
            vec = await embed(text)
            async with aiosqlite.connect(DB_PATH) as db:
                await db.execute(
                    "UPDATE events SET embedding=? WHERE id=?",
                    (json.dumps(vec), event_id),
                )
                await db.commit()
        except Exception:
            pass
        finally:
            _embed_queue.task_done()


# ---------------------------------------------------------------------------
# App lifecycle
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_db()
    worker = asyncio.create_task(_embed_worker())
    yield
    worker.cancel()
    try:
        await worker
    except asyncio.CancelledError:
        pass


app = FastAPI(title="Lore Archive", docs_url=None, redoc_url=None, lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET", "POST", "PUT", "DELETE"],
    allow_headers=["*"],
)


# ---------------------------------------------------------------------------
# Pydantic schemas
# ---------------------------------------------------------------------------

class EventCreate(BaseModel):
    ingame_date: Optional[str] = None
    description: str
    entity_ids: list[str] = []


class EntityCreate(BaseModel):
    entity_type: str        # player | npc | location | item
    name: str
    status: str = "alive"
    last_location: Optional[str] = None
    attributes: dict[str, Any] = {}


class EntityUpdate(BaseModel):
    name: Optional[str] = None
    status: Optional[str] = None
    last_location: Optional[str] = None
    attributes: Optional[dict[str, Any]] = None


class RuleCreate(BaseModel):
    title: str
    content: str
    category: Optional[str] = None
    pinned: bool = False


class RuleUpdate(BaseModel):
    title: Optional[str] = None
    content: Optional[str] = None
    category: Optional[str] = None
    pinned: Optional[bool] = None


# ---------------------------------------------------------------------------
# Chronicle Ledger — event routes
# ---------------------------------------------------------------------------

@app.get("/api/events")
async def list_events(
    entity_id: Optional[str] = None,
    limit: int = 200,
):
    """Return events newest-first.  Filter by entity_id to get one entity's history."""
    # Exclude the embedding column — it can be ~6 KB per row and is not needed by the UI.
    _COLS = "id, realworld_ts, ingame_date, description, entity_ids, created_at"
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        if entity_id:
            cur = await db.execute(
                f"SELECT {_COLS} FROM events WHERE entity_ids LIKE ? "
                "ORDER BY realworld_ts DESC LIMIT ?",
                (f'%"{entity_id}"%', limit),
            )
        else:
            cur = await db.execute(
                f"SELECT {_COLS} FROM events ORDER BY realworld_ts DESC LIMIT ?",
                (limit,),
            )
        rows = await cur.fetchall()

    result = []
    for r in rows:
        d = dict(r)
        d["entity_ids"] = json.loads(d["entity_ids"])
        result.append(d)
    return {"events": result}


@app.post("/api/event", status_code=201)
async def create_event(req: EventCreate):
    desc = req.description.strip()
    if not desc:
        raise HTTPException(status_code=422, detail="Description cannot be empty")
    eid = str(uuid.uuid4())
    now = time.time()
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(
            "INSERT INTO events VALUES (?,?,?,?,?,?,?)",
            (eid, now, req.ingame_date, desc, json.dumps(req.entity_ids), None, now),
        )
        await db.commit()
    # Queue embedding computation in background — POST returns immediately.
    await _embed_queue.put((eid, desc))
    return {
        "id": eid,
        "realworld_ts": now,
        "ingame_date": req.ingame_date,
        "description": desc,
        "entity_ids": req.entity_ids,
    }


@app.get("/api/events/search")
async def search_events(
    q: str = Query(..., min_length=1),
    top_k: int = 10,
):
    """
    Semantic similarity search across all events that have been embedded.

    Embeds the query using the same method as the stored events (Ollama when
    available, TF-IDF fallback), then ranks events by cosine similarity.
    Events recorded before their embedding was computed are excluded.
    """
    query_vec = await embed(q)

    # Cap at 10 000 most-recent embedded events. Fetching everything into RAM
    # for cosine ranking becomes prohibitive (60+ MB) on large archives.
    _SEARCH_CAP = 10_000
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        cur = await db.execute(
            "SELECT * FROM events WHERE embedding IS NOT NULL "
            "ORDER BY realworld_ts DESC LIMIT ?",
            (_SEARCH_CAP,),
        )
        rows = await cur.fetchall()

    query_dim = len(query_vec)
    scored = []
    skipped = 0
    for r in rows:
        d = dict(r)
        vec = json.loads(d.pop("embedding"))
        if len(vec) != query_dim:
            # Dimension mismatch: event was embedded by a different model/method.
            # Skip rather than return a misleading 0.0 similarity.
            skipped += 1
            continue
        sim = cosine_sim(query_vec, vec)
        d["entity_ids"] = json.loads(d["entity_ids"])
        d["score"] = round(sim, 4)
        scored.append(d)

    scored.sort(key=lambda x: x["score"], reverse=True)
    return {"results": scored[:top_k], "query": q, "skipped_dim_mismatch": skipped}


@app.delete("/api/event/{eid}")
async def delete_event(eid: str):
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute("DELETE FROM events WHERE id=?", (eid,))
        await db.commit()
    return {"deleted": True, "id": eid}


# ---------------------------------------------------------------------------
# Entity Tracker — entity routes
# ---------------------------------------------------------------------------

@app.get("/api/entities")
async def list_entities(entity_type: Optional[str] = None):
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        if entity_type:
            cur = await db.execute(
                "SELECT * FROM entities WHERE entity_type=? ORDER BY name ASC",
                (entity_type,),
            )
        else:
            cur = await db.execute(
                "SELECT * FROM entities ORDER BY entity_type ASC, name ASC"
            )
        rows = await cur.fetchall()

    result = []
    for r in rows:
        d = dict(r)
        d["attributes"] = json.loads(d["attributes"])
        result.append(d)
    return {"entities": result}


@app.post("/api/entity", status_code=201)
async def create_entity(req: EntityCreate):
    name = req.name.strip()
    if not name:
        raise HTTPException(status_code=422, detail="Name cannot be empty")
    eid = str(uuid.uuid4())
    now = time.time()
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(
            "INSERT INTO entities VALUES (?,?,?,?,?,?,?,?)",
            (eid, req.entity_type, name, req.status,
             req.last_location, json.dumps(req.attributes), now, now),
        )
        await db.commit()
    return {
        "id": eid,
        "entity_type": req.entity_type,
        "name": name,
        "status": req.status,
        "last_location": req.last_location,
        "attributes": req.attributes,
        "created_at": now,
        "updated_at": now,
    }


@app.get("/api/entity/{eid}")
async def get_entity(eid: str):
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        cur = await db.execute("SELECT * FROM entities WHERE id=?", (eid,))
        row = await cur.fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Entity not found")
    d = dict(row)
    d["attributes"] = json.loads(d["attributes"])
    return d


@app.put("/api/entity/{eid}")
async def update_entity(eid: str, req: EntityUpdate):
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        cur = await db.execute("SELECT * FROM entities WHERE id=?", (eid,))
        row = await cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Entity not found")
        d    = dict(row)
        name = req.name.strip() if req.name is not None else d["name"]
        if not name:
            raise HTTPException(status_code=422, detail="Name cannot be empty")
        status = req.status        if req.status        is not None else d["status"]
        loc    = req.last_location if req.last_location is not None else d["last_location"]
        attrs  = req.attributes    if req.attributes    is not None else json.loads(d["attributes"])
        now    = time.time()
        await db.execute(
            "UPDATE entities SET name=?, status=?, last_location=?, "
            "attributes=?, updated_at=? WHERE id=?",
            (name, status, loc, json.dumps(attrs), now, eid),
        )
        await db.commit()
    return {
        "id": eid,
        "name": name,
        "status": status,
        "last_location": loc,
        "attributes": attrs,
        "updated_at": now,
    }


@app.delete("/api/entity/{eid}")
async def delete_entity(eid: str):
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute("DELETE FROM entities WHERE id=?", (eid,))
        await db.commit()
    return {"deleted": True, "id": eid}


# ---------------------------------------------------------------------------
# Universe Ruleset — rule routes
# ---------------------------------------------------------------------------

@app.get("/api/rules")
async def list_rules():
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        cur = await db.execute(
            "SELECT * FROM rules ORDER BY pinned DESC, created_at ASC"
        )
        rows = await cur.fetchall()
    return {"rules": [dict(r) for r in rows]}


@app.get("/api/rules/pinned")
async def pinned_rules():
    """
    Return only pinned rules.

    External services (the Context Injector / Storyteller API wrapper) should
    call this endpoint before constructing any prompt to guarantee the core
    universe rules are always present in the model context.
    """
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        cur = await db.execute(
            "SELECT * FROM rules WHERE pinned=1 ORDER BY created_at ASC"
        )
        rows = await cur.fetchall()
    return {"rules": [dict(r) for r in rows]}


@app.post("/api/rule", status_code=201)
async def create_rule(req: RuleCreate):
    title   = req.title.strip()
    content = req.content.strip()
    if not title or not content:
        raise HTTPException(status_code=422, detail="Title and content are required")
    rid = str(uuid.uuid4())
    now = time.time()
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(
            "INSERT INTO rules VALUES (?,?,?,?,?,?,?)",
            (rid, title, content, req.category, int(req.pinned), now, now),
        )
        await db.commit()
    return {
        "id": rid,
        "title": title,
        "content": content,
        "category": req.category,
        "pinned": req.pinned,
        "created_at": now,
        "updated_at": now,
    }


@app.get("/api/rule/{rid}")
async def get_rule(rid: str):
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        cur = await db.execute("SELECT * FROM rules WHERE id=?", (rid,))
        row = await cur.fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Rule not found")
    return dict(row)


@app.put("/api/rule/{rid}")
async def update_rule(rid: str, req: RuleUpdate):
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        cur = await db.execute("SELECT * FROM rules WHERE id=?", (rid,))
        row = await cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Rule not found")
        d       = dict(row)
        title   = req.title.strip()   if req.title   is not None else d["title"]
        content = req.content.strip() if req.content is not None else d["content"]
        if not title or not content:
            raise HTTPException(status_code=422, detail="Title and content are required")
        cat    = req.category if req.category is not None else d["category"]
        pinned = int(req.pinned) if req.pinned is not None else d["pinned"]
        now    = time.time()
        await db.execute(
            "UPDATE rules SET title=?, content=?, category=?, pinned=?, updated_at=? "
            "WHERE id=?",
            (title, content, cat, pinned, now, rid),
        )
        await db.commit()
    return {
        "id": rid,
        "title": title,
        "content": content,
        "category": cat,
        "pinned": bool(pinned),
        "updated_at": now,
    }


@app.delete("/api/rule/{rid}")
async def delete_rule(rid: str):
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute("DELETE FROM rules WHERE id=?", (rid,))
        await db.commit()
    return {"deleted": True, "id": rid}


# Static UI — mount last so API routes take precedence
app.mount("/", StaticFiles(directory="static", html=True), name="static")
