# AgentMemoryMCP Architecture

Codifies the system architecture, SQLite + FTS5 + `sqlite-vec` storage topology, and JSON-RPC 2.0 MCP server protocol for `agent-memory-mcp` so persistent semantic memory operates deterministically on dedicated fast storage, preventing cross-session context loss or database corruption.

## 1. System Topology & Component Overview

Defines the single-file CLI/MCP engine ([bin/agent-memory](../bin/agent-memory)), MCP tool schemas (`mcp/*.json`), and installer ([install.sh](../install.sh)) so agent sessions recall and record semantic memories with sub-millisecond latency, preventing unindexed knowledge sprawl.

1. **Unified CLI & MCP Server ([bin/agent-memory](../bin/agent-memory))**: Implements both the stdio JSON-RPC 2.0 MCP server (`serve`) and the operator CLI (`init`, `status`, `record`, `search`, `recall`, `relate`, `forget`, `gc`, `export`, `import`, `doctor`) backed by SQLite WAL, FTS5 BM25 lexical search, `sqlite-vec` vector similarity, and Reciprocal Rank Fusion (RRF).
2. **Lazy-Loaded MCP Tool Schemas**: Exposes five strict JSON schema contracts in [mcp/memory_record.json](../mcp/memory_record.json), [mcp/memory_search.json](../mcp/memory_search.json), [mcp/memory_recall.json](../mcp/memory_recall.json), [mcp/memory_relate.json](../mcp/memory_relate.json), and [mcp/memory_forget.json](../mcp/memory_forget.json) alongside [mcp/instructions.md](../mcp/instructions.md).
3. **Visual Architecture Map**: Illustrates the hybrid lexical + vector retrieval and knowledge-graph traversal pipeline.

   ```mermaid
   flowchart TD
       Agent["Agent Runtime (MCP Client / CLI)"] --> Server["bin/agent-memory (JSON-RPC 2.0 & CLI)"]
       Server --> Guard["Perimeter & Secret Redaction Guard"]
       Guard --> FTS["SQLite FTS5 (BM25 Lexical Search)"]
       Guard --> Vec["sqlite-vec (Cosine Vector Search)"]
       FTS --> RRF["Reciprocal Rank Fusion & BFS Graph Traversal"]
       Vec --> RRF
   ```

   - *Positive Exemplar*: `Route all memory_record, memory_search, memory_recall, memory_relate, and memory_forget calls through bin/agent-memory on a verified fast storage volume.`
   - *Negative Exemplar*: `Open the SQLite memory database without WAL mode, O_NOFOLLOW regular-file verification, or secret redaction.` (STRICTLY FORBIDDEN)

### Verification & Failure Recovery

Validates storage mount compliance, SQLite schema health, and MCP tool parity before serving requests so memory operations remain reliable, preventing runtime errors.

- Run `agent-memory doctor --json` and `python3 ~/.gemini/config/skills/documentation-management/scripts/doc_manager.py audit --target .` to confirm database and documentation integrity.

---

## 2. Invariants & State Lifecycle

Establishes hardware storage verification, symlink/hardlink rejection, and transactional SQLite mutation invariants so persistent memory records remain clean-room safe and durable, preventing symlink clobbering or secret leakage.

1. **Hardware Mount & Permission Verification**: Verifies dedicated NVMe/Optane mount backing (unless `AGENT_MEMORY_ALLOW_NON_OPTANE=1` is set) and enforces `0700` directory modes and `0600` regular-file modes (`O_NOFOLLOW`, `stat.S_ISREG`, `st_nlink == 1`) on the SQLite database, WAL/SHM companions, and export/log files.
2. **Clean-Room Secret & Persona Scrubbing**: Rejects or redacts raw credentials, API keys, bearer tokens, and conversational persona roleplay before persisting any memory record or entity relation.
3. **Soft-Forget & Garbage Collection**: `memory_forget` transitions records to soft-deleted audit states while `gc` prunes expired or tombstoned records inside bounded `BEGIN IMMEDIATE` transactions.
   - *Positive Exemplar*: `Enforce st_nlink == 1 and O_NOFOLLOW across database opens, export files, and Tri-Stream telemetry outputs.`
   - *Negative Exemplar*: `Persist unmasked API tokens or non-ASCII persona roleplay strings into the semantic memory database.` (STRICTLY FORBIDDEN)

### Verification & Failure Recovery

Tests transactional mutations, soft-delete recovery, and hardlink/symlink rejection against the test suite before deployment so state transitions are deterministic, preventing partial commits.

- Run `pytest tests/test_agent_memory.py` to verify all 13 test suites pass.

---

## 3. Data Flow & Boundary Communication

Documents the stdio JSON-RPC 2.0 transport (`Content-Length` framed and newline-delimited JSON) and Tri-Stream CLI telemetry contracts so MCP hosts and CLI callers communicate without framing errors, preventing protocol deadlocks.

1. **Dual-Framing JSON-RPC 2.0 Server**: Automatically detects and responds in `Content-Length` header framing or newline-delimited JSON-RPC 2.0 over stdio while enforcing `MAX_HEADER_BYTES` and `MAX_CONTENT_LENGTH` bounds.
2. **Tri-Stream CLI Telemetry**: Emits structured JSON on `stdout` (`--json`), bounded `results.json` (`<= 64 KiB`, `0600`), and `debug.log` (`0600`) under `--log-dir` for both [bin/agent-memory](../bin/agent-memory) and [install.sh](../install.sh).
3. **Deterministic Exit Codes**: Returns `0` on success, `1` on runtime/storage errors, `2` on CLI usage or path validation errors (`allow_abbrev=False`), `130` on `SIGINT`, and `143` on `SIGTERM`.
   - *Positive Exemplar*: `Validate CLI arguments with --validate-args and enforce --log-dir collision checks against the active SQLite database path.`
   - *Negative Exemplar*: `Point --log-dir inside the active database directory or allow abbreviated CLI flags.` (STRICTLY FORBIDDEN)

### Verification & Failure Recovery

Monitors JSON-RPC framing and Tri-Stream telemetry outputs during pre-flight verification so protocol mismatches are caught immediately, preventing broken MCP handshakes.

- Run `./bin/agent-memory --validate-args --json` and `bash install.sh --validate-args --dry-run --json` to confirm exit code `0`.

---

## 4. Cross-System Dependencies & Memory Invariants

Binds `agent-memory-mcp` to the `agent-baseline` catalog reference stub and benchmark harness so skill instructions and performance metrics stay synchronized, preventing deployment drift.

1. **Baseline Catalog Integration**: Deployed to `~/.local/bin/agent-memory`, `~/.gemini/mcp/agent-memory/`, and `~/.gemini/config/skills/agent-memory/` via [install.sh](../install.sh) and linked from `agent-baseline` via `agent-memory/reference.md`.
2. **Comparative Benchmark Suite**: [benchmark/benchmark_comparison.py](../benchmark/benchmark_comparison.py) benchmarks latency, recall accuracy, and token efficiency with full Tri-Stream `--log-dir` and `allow_abbrev=False` support.
3. **Docs-as-Code Synchronization**: Tracks commit watermarks in `docs/.doc_state.json` and cross-links [LLM_ONBOARDING.md](../LLM_ONBOARDING.md), [skill/SKILL.md](../skill/SKILL.md), and [skill/references/agent-memory-mcp.md](../skill/references/agent-memory-mcp.md) in [INDEX.md](INDEX.md).
   - *Positive Exemplar*: `Run ./install.sh and advance docs/.doc_state.json whenever bin/agent-memory or skill/SKILL.md is updated.`
   - *Negative Exemplar*: `Modify MCP tool schemas in mcp/*.json without updating bin/agent-memory and skill/SKILL.md in the same commit.` (STRICTLY FORBIDDEN)

### Verification & Failure Recovery

Audits deployed binary and skill files against repository sources before handoff so runtime installations match git ground truth, preventing stale MCP schemas.

- Run `pytest`, `ruff check .`, `shellcheck install.sh`, and `python3 ~/.gemini/config/skills/documentation-management/scripts/doc_manager.py audit --target .` to confirm zero defects.
