#!/usr/bin/env python3
"""
MCP SQL — lightweight Model Context Protocol server for SQLite databases.

Exposes ghost-runner (tasks/tokens) and memory-browser (memories) SQLite
databases via MCP JSON-RPC 2.0 over HTTP, so AI agents in Open WebUI can
query persisted data using natural language tool calls.

Transport : HTTP POST /mcp  (Streamable HTTP, MCP spec 2024-11-05)
Port      : 8080  (internal only — no host port exposed by default)
Access    : Read-only by default; set READ_ONLY=false to allow writes

Tools exposed:
  list_tables    — list all tables in a database
  describe_table — show column names and types for a table
  execute_query  — run a SELECT (or write if READ_ONLY=false) SQL query

Connect in Open WebUI:
  Admin → Tools → Add Tool → endpoint: http://mcp-sql:8080/mcp
  Select a tool-calling model (llama3.2, qwen2.5, mistral, etc.)
"""

import json
import logging
import os
import re

import aiosqlite
import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger(__name__)

GHOST_DB_PATH  = os.environ.get("GHOST_DB_PATH",  "/data/ghost/ghost.db")
MEMORY_DB_PATH = os.environ.get("MEMORY_DB_PATH", "/data/memory/memory.db")
READ_ONLY      = os.environ.get("READ_ONLY", "true").lower() not in ("false", "0", "no")

_DB_PATHS: dict[str, str] = {
    "ghost":  GHOST_DB_PATH,
    "memory": MEMORY_DB_PATH,
}

# ---------------------------------------------------------------------------
# MCP tool schema definitions
# ---------------------------------------------------------------------------

_DATABASE_PARAM = {
    "type": "string",
    "enum": ["ghost", "memory"],
    "description": (
        "Which SQLite database to query. "
        "'ghost' stores background AI task history and streamed tokens. "
        "'memory' stores user-pinnable AI memory snippets."
    ),
}

_TOOLS: list[dict] = [
    {
        "name": "list_tables",
        "description": "List all tables in a SQLite database.",
        "inputSchema": {
            "type": "object",
            "properties": {"database": _DATABASE_PARAM},
            "required": ["database"],
        },
    },
    {
        "name": "describe_table",
        "description": "Return column names, types, and constraints for a table.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "database": _DATABASE_PARAM,
                "table": {
                    "type": "string",
                    "description": "Name of the table to describe.",
                },
            },
            "required": ["database", "table"],
        },
    },
    {
        "name": "execute_query",
        "description": (
            "Execute a SQL query against a SQLite database and return results as JSON. "
            "Only SELECT statements are permitted (read-only mode). "
            "Examples:\n"
            "  SELECT * FROM tasks ORDER BY created_at DESC LIMIT 10\n"
            "  SELECT content FROM memories WHERE pinned=1\n"
            "  SELECT model, COUNT(*) AS runs FROM tasks GROUP BY model"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "database": _DATABASE_PARAM,
                "query": {
                    "type": "string",
                    "description": "SQL SELECT query to execute.",
                },
                "limit": {
                    "type": "integer",
                    "description": "Maximum rows to return (1–1000, default 100).",
                    "default": 100,
                },
            },
            "required": ["database", "query"],
        },
    },
]

# ---------------------------------------------------------------------------
# SQLite helpers
# ---------------------------------------------------------------------------

def _resolve_db(database: str) -> str:
    """Return the filesystem path for the named database or raise ValueError."""
    path = _DB_PATHS.get(database)
    if not path:
        raise ValueError(
            f"Unknown database '{database}'. Valid values: {list(_DB_PATHS)}"
        )
    return path


def _db_uri(path: str) -> str:
    """Build a SQLite URI that opens the file in read-only mode when READ_ONLY=true."""
    if READ_ONLY:
        return f"file:{path}?mode=ro"
    return f"file:{path}"


async def _list_tables(database: str) -> str:
    path = _resolve_db(database)
    async with aiosqlite.connect(_db_uri(path), uri=True) as db:
        async with db.execute(
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
        ) as cur:
            rows = await cur.fetchall()
    tables = [r[0] for r in rows]
    log.info("list_tables database=%s → %d tables", database, len(tables))
    return json.dumps({"database": database, "tables": tables})


async def _describe_table(database: str, table: str) -> str:
    if not re.match(r"^[a-zA-Z_][a-zA-Z0-9_]*$", table):
        raise ValueError(f"Invalid table name: {table!r}")
    path = _resolve_db(database)
    async with aiosqlite.connect(_db_uri(path), uri=True) as db:
        # Verify existence via a parameterised query on the system catalog first.
        # The confirmed name from sqlite_master (not the raw user input) is then
        # used in the PRAGMA call, which does not support bound parameters.
        async with db.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name=?", (table,)
        ) as cur:
            row = await cur.fetchone()
        if not row:
            raise ValueError(f"Table '{table}' not found in the '{database}' database.")
        safe_table = row[0]  # name confirmed to exist — used in PRAGMA (no bind-param support)
        async with db.execute(f"PRAGMA table_info({safe_table})") as cur:
            rows = await cur.fetchall()
    columns = [
        {
            "name":    r[1],
            "type":    r[2],
            "notnull": bool(r[3]),
            "pk":      bool(r[5]),
        }
        for r in rows
    ]
    log.info("describe_table database=%s table=%s → %d columns", database, table, len(columns))
    return json.dumps({"database": database, "table": table, "columns": columns})


async def _execute_query(database: str, query: str, limit: int = 100) -> str:
    # Strip only leading/trailing whitespace for the keyword check.
    # The SQLite URI mode=ro (opened below) is the hard write-guard at the
    # driver level; this first-token check exists solely to return a clear
    # error message before hitting the driver.
    first_token = query.strip().split()[0].upper() if query.strip().split() else ""

    # Enforce read-only: the first SQL keyword must be SELECT.
    if READ_ONLY and first_token != "SELECT":
        raise ValueError(
            "Only SELECT queries are allowed (READ_ONLY=true). "
            "Set READ_ONLY=false in docker/.env to enable write access."
        )

    limit = min(max(1, int(limit)), 1000)

    # Work on a normalised copy for LIMIT detection.
    # Use the normalised form for LIMIT injection too — appending to the
    # original could embed LIMIT inside a trailing comment.
    normalised = query.strip()
    if not re.search(r"\bLIMIT\b", normalised, re.IGNORECASE):
        normalised = normalised + f" LIMIT {limit}"

    path = _resolve_db(database)
    # Python's sqlite3/aiosqlite.execute() only ever runs a single statement,
    # so multi-statement injection via ';' is not possible at the driver level.
    # The mode=ro URI ensures the database is opened read-only regardless of
    # what SQL the LLM generates.
    async with aiosqlite.connect(_db_uri(path), uri=True) as db:
        async with db.execute(normalised) as cur:
            rows = await cur.fetchall()
            col_names = [d[0] for d in (cur.description or [])]

    result_rows = [dict(zip(col_names, row)) for row in rows]
    log.info("execute_query database=%s rows=%d query=%.120s", database, len(result_rows), normalised)
    return json.dumps({"database": database, "rows": result_rows, "count": len(result_rows)})

# ---------------------------------------------------------------------------
# MCP dispatcher
# ---------------------------------------------------------------------------

async def _call_tool(name: str, arguments: dict) -> str:
    """Dispatch a tools/call request to the appropriate handler."""
    if name == "list_tables":
        return await _list_tables(arguments["database"])
    if name == "describe_table":
        return await _describe_table(arguments["database"], arguments["table"])
    if name == "execute_query":
        return await _execute_query(
            arguments["database"],
            arguments["query"],
            arguments.get("limit", 100),
        )
    raise ValueError("Unknown tool")


async def _dispatch(method: str, params: dict) -> dict:
    """Map a JSON-RPC method to a result dict."""
    if method == "initialize":
        return {
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": "ollama-mcp-sql", "version": "1.0.0"},
        }

    if method == "tools/list":
        return {"tools": _TOOLS}

    if method == "tools/call":
        tool_name = params.get("name", "")
        arguments = params.get("arguments", {})
        try:
            text = await _call_tool(tool_name, arguments)
            return {"content": [{"type": "text", "text": text}]}
        except ValueError as exc:
            # ValueError messages are written by us and describe user-facing problems
            # (unknown database, invalid table name, non-SELECT query, etc.) — safe to expose.
            return {
                "content": [{"type": "text", "text": str(exc)}],
                "isError": True,
            }
        except Exception:
            log.exception("Unexpected error in tool %s", tool_name)
            return {
                "content": [{"type": "text", "text": "An internal error occurred executing the tool."}],
                "isError": True,
            }

    if method == "notifications/initialized":
        # Client notification — no id, no response required; return empty result
        return {}

    raise ValueError("Method not found")

# ---------------------------------------------------------------------------
# FastAPI application
# ---------------------------------------------------------------------------

app = FastAPI(
    title="ollama-mcp-sql",
    description=(
        "Lightweight MCP server exposing ghost-runner (tasks/tokens) and "
        "memory-browser (memories) SQLite databases to AI agents via JSON-RPC 2.0."
    ),
    docs_url=None,
    redoc_url=None,
)


@app.get("/health")
async def health():
    return {"status": "ok", "read_only": READ_ONLY}


@app.get("/")
async def root():
    return {
        "service": "ollama-mcp-sql",
        "version": "1.0.0",
        "read_only": READ_ONLY,
        "mcp_endpoint": "/mcp",
        "databases": list(_DB_PATHS.keys()),
        "tools": [t["name"] for t in _TOOLS],
        "connect": "Open WebUI → Admin → Tools → Add Tool → http://mcp-sql:8080/mcp",
    }


@app.post("/mcp")
async def mcp_endpoint(request: Request):
    """MCP JSON-RPC 2.0 endpoint (Streamable HTTP transport)."""
    try:
        body = await request.json()
    except Exception:
        return JSONResponse(
            {
                "jsonrpc": "2.0",
                "error": {"code": -32700, "message": "Parse error — body must be valid JSON"},
                "id": None,
            },
            status_code=400,
        )

    rpc_id  = body.get("id")
    method  = body.get("method", "")
    params  = body.get("params") or {}

    try:
        result = await _dispatch(method, params)
    except ValueError as exc:
        # ValueError messages are written by us (unknown method, etc.) — safe to expose.
        err_msg = str(exc)
        return JSONResponse({
            "jsonrpc": "2.0",
            "error": {"code": -32601, "message": err_msg},
            "id": rpc_id,
        })
    except Exception:
        log.exception("Unhandled error in MCP dispatch method=%s", method)
        return JSONResponse({
            "jsonrpc": "2.0",
            "error": {"code": -32603, "message": "Internal server error"},
            "id": rpc_id,
        })

    # Notifications have no id and expect no response body; return 204
    if rpc_id is None and method.startswith("notifications/"):
        return Response(status_code=204)

    return JSONResponse({"jsonrpc": "2.0", "result": result, "id": rpc_id})


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8080, log_level="info")
