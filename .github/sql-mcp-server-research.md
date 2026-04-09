# SQL MCP Server — Research & Integration Planning

> **Origin:** [Introducing SQL MCP Server — Azure SQL Dev Corner](https://devblogs.microsoft.com/azure-sql/introducing-sql-mcp-server/)
>
> **Question:** Would a SQL MCP Server be a better fit for this stack than our current SQLite approach? If so, how should we integrate it?

---

## What Is the Model Context Protocol (MCP)?

The **Model Context Protocol (MCP)** is an open standard (originated by Anthropic, adopted broadly including by Microsoft) that defines how AI models and agents securely discover and interact with external systems — databases, files, APIs — using a standardised JSON-RPC interface.

### Core Concepts

| Term | Role |
|------|------|
| **MCP Host** | The AI application (chat UI, agent, IDE extension) that orchestrates the interaction |
| **MCP Client** | Manages connections between the host and one or more MCP servers |
| **MCP Server** | Exposes **tools** (callable functions), **resources** (data), and **prompts** (templates) to the AI via a standardised schema |
| **Ollama** | Provides local LLM inference; models that support tool-calling (Llama 3, Qwen, Mistral) can consume MCP tool schemas |

### Data Flow

```
User Prompt
    ↓
MCP Host (Open WebUI / Chat UI)
    ↓  tool discovery
MCP Client ←→ MCP Server (SQL MCP)
                    ↓
             SQL Database (SQLite / SQL Server / Azure SQL)
                    ↑
             Parameterised query result
    ↓
Ollama LLM processes result + generates response
    ↓
User
```

### Transport Options

| Transport | When to Use |
|-----------|-------------|
| **STDIO** | Local / same-host deployment (lower latency, simpler) |
| **HTTP (SSE)** | Remote or container-to-container deployment |

---

## What Is SQL MCP Server?

Microsoft's **SQL MCP Server** is a production-ready MCP server implementation built on top of [Data API Builder (DAB)](https://learn.microsoft.com/en-us/azure/data-api-builder/overview-to-data-api-builder). It exposes controlled SQL operations to AI agents:

- **Schema introspection** — list tables, columns, data types
- **Read queries** — parameterised SELECT execution
- **Write operations** — INSERT/UPDATE/DELETE (toggled per environment for safety)
- **RBAC** — fine-grained access control per entity/operation
- **Audit trail** — structured logging of every AI-driven query

### Supported Backends

| Backend | Notes |
|---------|-------|
| Azure SQL / SQL Server | Primary target; full feature set |
| PostgreSQL | Community support via DAB |
| MySQL / MariaDB | Community support via DAB |
| **SQLite** | Supported via DAB with minor configuration |
| CosmosDB | Azure-native support |

---

## Current Stack: How We Handle Data Today

This repository already uses SQLite in two microservices:

| Service | DB File | What's Stored |
|---------|---------|---------------|
| `ghost-runner` | `/data/ghost.db` | Async inference tasks + streaming tokens |
| `memory-browser` | `/data/memories.db` | User-pinnable memory snippets |

Both use `aiosqlite` for async SQLite access. There is **no MCP layer** — data is only accessible via the service's own REST endpoints, not by any AI agent.

---

## The Improvement: What SQL MCP Server Adds

### Problem with the Current Approach

AI models in this stack (via Open WebUI or ghost-runner) **cannot query their own persistent data**. They have no way to:

- Ask "what tasks have I run recently?" 
- Retrieve a saved memory without being explicitly told to call the REST endpoint
- Perform cross-service analysis (e.g. correlate tasks with memories)
- Let a user say "summarise my last 10 prompts" without custom code

### What SQL MCP Server Enables

With an MCP server in front of our SQLite (or upgraded SQL Server) databases, an AI agent could:

1. **Introspect schema** — understand table structure automatically
2. **Query data** — "show me all failed tasks from the last 24 hours"
3. **Natural language to SQL** — the LLM converts user intent to a safe parameterised query
4. **Write memories** — agent can persist important context without manual UI interaction
5. **Cross-service queries** — unified MCP endpoint over multiple databases

---

## Integration Options Considered

### Option A — Lightweight: SQLite + MCP Shim (Recommended for MVP)

Deploy a single MCP server container that proxies both existing SQLite databases using DAB or a community SQLite MCP adapter.

**Pros:**
- Minimal change to existing services (no DB migration)
- Fully local / air-gapped — no cloud dependency
- Works with existing `aiosqlite` schema

**Cons:**
- SQLite concurrency limits under heavy write load (mitigated by WAL mode, which is already enabled)
- Schema changes require MCP server restart

**Candidate images:**
- `ghcr.io/microsoft/data-api-builder` (official DAB, supports SQLite)
- `mcp/sqlite` from the official `modelcontextprotocol/servers` registry (Node.js, minimal footprint)

---

### Option B — Full Upgrade: SQL Server 2025 + MCP Server

Replace SQLite with Microsoft SQL Server 2025 (available as a Docker image), which has native vector search and embedding support.

**Pros:**
- Production-grade database with full ACID guarantees
- Native vector search for semantic memory/RAG workflows
- SQL Server 2025 ships native Ollama integration endpoints

**Cons:**
- SQL Server container is ~1.5 GB (vs. ~0 MB for SQLite)
- Requires additional port (1433) and credential management
- Overkill for the current data volume
- Adds operational complexity on Intel GPU hardware

---

### Option C — Hybrid: Keep SQLite, Add MCP for Reads Only

Keep SQLite for writes (existing microservices unchanged), add a read-only MCP server so agents can query data but not modify it.

**Pros:**
- Zero risk to existing write path
- Safe: agents cannot accidentally corrupt data

**Cons:**
- Agents cannot persist new memories or update task state autonomously

---

## Recommendation

> **Start with Option A** (SQLite + MCP Shim) as an MVP, with a clear upgrade path to Option B if vector search or multi-tenant workloads become needed.

### Rationale

| Factor | Option A | Option B | Option C |
|--------|----------|----------|----------|
| Complexity | Low | High | Low |
| VRAM impact | None | None | None |
| Disk overhead | ~10 MB | ~1.5 GB | ~10 MB |
| AI query capability | Full | Full + vector | Read-only |
| Data migration risk | None | High | None |
| Time to implement | Hours | Days | Hours |

---

## Proposed Architecture (Option A)

```
┌─────────────────────────────────────────────────────────────┐
│  Docker Compose Stack                                        │
│                                                              │
│  ┌──────────────┐   REST    ┌─────────────────────────────┐ │
│  │  ghost-runner│ ────────► │  ghost.db  (aiosqlite/WAL)  │ │
│  │  :45215      │           └──────────────┬──────────────┘ │
│  └──────────────┘                          │ volume mount    │
│                                            ▼                 │
│  ┌──────────────┐   REST    ┌─────────────────────────────┐ │
│  │memory-browser│ ────────► │  memories.db               │ │
│  │  :45216      │           └──────────────┬──────────────┘ │
│  └──────────────┘                          │                 │
│                                            ▼                 │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  ollama-mcp-sql   (NEW)                               │   │
│  │  MCP Server — SQLite adapter over ghost.db +          │   │
│  │  memories.db                                          │   │
│  │  Transport: HTTP SSE  Port: 45218 (internal)          │   │
│  └──────────────────────────────────────────────────────┘   │
│               ▲                                              │
│               │ MCP JSON-RPC                                 │
│  ┌────────────┴───────────┐                                 │
│  │  Open WebUI / Pipelines│  (tool-calling model required)  │
│  │  Ollama engine         │                                 │
│  └────────────────────────┘                                 │
└─────────────────────────────────────────────────────────────┘
```

### New Service: `ollama-mcp-sql`

| Property | Value |
|----------|-------|
| Image | `mcp/sqlite` or DAB container |
| Port | `45218` (internal only, no host exposure needed) |
| Volumes | Mount same `/data` volume as ghost-runner and memory-browser |
| Environment | `READ_ONLY=true` (flip to `false` for write access) |
| Depends on | `ghost-runner`, `memory-browser` (to ensure DBs are initialised) |

---

## Model Requirements

Not all Ollama models support tool-calling. For MCP integration to work, the active model **must** support function/tool calling.

| Model | Tool Calling | Notes |
|-------|-------------|-------|
| `llama3.2:1b` | ✅ | Current default; lightweight |
| `llama3.1:8b` | ✅ | Better reasoning for complex queries |
| `qwen2.5:7b` | ✅ | Strong tool-calling performance |
| `mistral:7b` | ✅ | Good general tool use |
| `phi3:mini` | ⚠️ | Limited tool support |
| `gemma2:2b` | ❌ | No tool calling |

**Recommendation:** Keep `llama3.2:1b` as the default but document that SQL MCP features require a tool-calling model.

---

## Open WebUI MCP Integration

Open WebUI (v0.5+) has native MCP support via **Pipelines** or direct tool configuration:

1. In Open WebUI Admin → **Tools** → Add Tool
2. Set endpoint to `http://ollama-mcp-sql:45218/mcp`
3. Select tool-capable model
4. Users can now ask natural language questions against the database

---

## Security Considerations

- **Read-only by default** — only allow SELECT queries unless explicitly enabled
- **No credentials exposed** — SQLite files are volume-mounted, not over the network
- **Query timeout** — cap execution time to prevent LLM-generated runaway queries
- **Audit log** — log all agent-generated SQL to a separate log file
- **Container isolation** — MCP server has no internet access (internal Docker network only)

---

## Performance Impact

- MCP server adds **< 5 ms** overhead per tool invocation (local SQLite, no network hop)
- No impact on Ollama inference speed or VRAM usage
- WAL mode (already enabled) ensures no read/write contention between existing services and MCP server

---

## Implementation Phases

### Phase 1 — Research & Documentation (this document ✅)
- Evaluate SQL MCP Server suitability
- Document architecture options
- Identify model requirements

### Phase 2 — MVP Integration (future PR)
- Add `ollama-mcp-sql` service to `docker-compose.yml`
- Configure SQLite adapter for `ghost.db` and `memories.db`
- Document in `README.md`

### Phase 3 — Open WebUI Tooling (future PR)
- Register MCP endpoint in Open WebUI Tools
- Test natural language queries against both databases
- Add example prompts to `README.md`

### Phase 4 — Optional SQL Server Upgrade (future PR, if needed)
- Migrate SQLite → SQL Server 2025 for vector search
- Enable embedding storage for semantic memory search
- Benchmark VRAM and latency impact

---

## References

- [Introducing SQL MCP Server — Azure SQL Dev Corner](https://devblogs.microsoft.com/azure-sql/introducing-sql-mcp-server/)
- [SQL MCP Server Documentation — Microsoft Learn](https://learn.microsoft.com/en-us/sql/mcp/)
- [SQL MCP Server Overview — Data API Builder](https://learn.microsoft.com/en-us/azure/data-api-builder/mcp/overview)
- [Model Context Protocol — Architecture Overview](https://modelcontextprotocol.io/docs/learn/architecture)
- [Official MCP Servers Registry](https://github.com/modelcontextprotocol/servers)
- [Microsoft MCP Catalog](https://github.com/microsoft/mcp)
- [Running MCP with Local LLMs via Ollama](https://vizemotion.com/running-model-context-protocol-mcp-with-local-llms-via-ollama/)
- [Getting Started with Vector Search in SQL Server 2025 Using Ollama](https://www.nocentino.com/posts/2025-05-19-ollama-sql-faststart/)
- [Building a Local AI Agent with Ollama + MCP](https://dev.to/rajeev_3ce9f280cbae73b234/building-a-local-ai-agent-with-ollama-mcp-docker-37a)
- [Local AI Models for SQL Server — Complete Guide](https://blog.sqlauthority.com/2025/11/03/local-ai-models-for-sql-server-a-complete-guide/)
