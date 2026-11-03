# AgentMemoryMCP Architecture

Codifies the system architecture, SQLite WAL + FTS5 storage topology, and stdio JSON-RPC 2.0 MCP server protocol for `agent-memory-mcp` so persistent semantic memory operates deterministically on dedicated fast storage, preventing cross-session context loss or database corruption.

## 1. System Topology & Component Overview

Defines the single-file stdlib-only CLI/MCP engine ([bin/agent-memory](../bin/agent-memory)), MCP tool schemas (`mcp/*.json`), and installer ([install.sh](../install.sh)) so agent sessions recall and record semantic memories with sub-millisecond latency, preventing unindexed knowledge sprawl.

1. **Unified CLI & MCP Server ([bin/agent-memory](../bin/agent-memory))**: Implements both the stdio JSON-RPC 2.0 MCP server (`serve-mcp` and `--mcp`) and the operator CLI (`init`, `record`, `relate`, `search`, `recall`, `forget`, `doctor`, `backup`, `restore`, `benchmark`, and `--version` / `-v`) backed by Python 3.10+ standard-library `sqlite3` in WAL mode, FTS5 BM25 lexical search (`bm25(observations_fts, 5.0, 2.0, 1.0)`), and 1-hop entity relation queries (`relations`).
2. **Lazy-Loaded MCP Tool Schemas**: Exposes five strict JSON schema contracts in [mcp/memory_record.json](../mcp/memory_record.json), [mcp/memory_search.json](../mcp/memory_search.json), [mcp/memory_recall.json](../mcp/memory_recall.json), [mcp/memory_relate.json](../mcp/memory_relate.json), and [mcp/memory_forget.json](../mcp/memory_forget.json) alongside [mcp/instructions.md](../mcp/instructions.md).
3. **Visual Architecture Map**: Illustrates the lexical FTS5 retrieval and 1-hop knowledge-graph relation pipeline.

   ```mermaid
   flowchart TD
       Agent["Agent Runtime (MCP Client / CLI)"] --> Server["bin/agent-memory (JSON-RPC 2.0 & CLI)"]
       Server --> Guard["Perimeter, Hardware & Secret Guard"]
       Guard --> FTS["SQLite FTS5 (BM25 Lexical Search)"]
       Guard --> Rel["SQLite Relations Table (1-Hop Entity Graph)"]
       FTS --> Out["Bounded JSON Response Envelope"]
       Rel --> Out
   ```

   - *Positive Exemplar*: `Route all memory_record, memory_search, memory_recall, memory_relate, and memory_forget calls through bin/agent-memory on a verified fast storage volume.`
   - *Negative Exemplar*: `Open the SQLite memory database without WAL mode, O_NOFOLLOW regular-file verification, or secret screening.` (STRICTLY FORBIDDEN)

### Verification & Failure Recovery

Validates storage mount compliance, SQLite schema health, and MCP tool parity before serving requests so memory operations remain reliable, preventing runtime errors.

- Run `./bin/agent-memory doctor` and `python3 ~/.gemini/config/skills/documentation-management/scripts/doc_manager.py audit --target .` to confirm database and documentation integrity.

---

## 2. Invariants & State Lifecycle

Establishes hardware storage verification, symlink/hardlink rejection, and transactional SQLite mutation invariants so persistent memory records remain clean-room safe and durable, preventing symlink clobbering or secret leakage.

1. **Hardware Mount & Permission Verification**: Verifies dedicated Intel Optane NVMe backing via sysfs model markers and PCI IDs while excluding hybrid QLC devices (`HBRPE`, `HBRPL`, `H10`, `H20`) unless `ALLOW_NON_OPTANE=1` is set, and enforces `0700` directory modes and `0600` regular-file modes (`O_NOFOLLOW`, `stat.S_ISREG`, `st_nlink == 1`) on the SQLite database, WAL/SHM companions, and backup/log files.
2. **Clean-Room Secret & Persona Screening**: Rejects raw credentials, API keys, bearer tokens, high-entropy secrets, and conversational persona roleplay before persisting any observation, entity summary, attribute, tag, or relation metadata.
3. **Immediate Hard Deletion & Storage Scrubbing**: `memory_forget` (`forget`) executes immediate hard `DELETE` statements inside a `BEGIN IMMEDIATE` transaction and invokes `_scrub_deleted()` (`PRAGMA incremental_vacuum`, `PRAGMA wal_checkpoint`, or `VACUUM`) to purge deleted content from SQLite pages and WAL sidecars.
   - *Positive Exemplar*: `Enforce st_nlink == 1 and O_NOFOLLOW across database opens, online backups, and Tri-Stream telemetry outputs.`
   - *Negative Exemplar*: `Persist unmasked API tokens or non-ASCII persona roleplay strings into the semantic memory database.` (STRICTLY FORBIDDEN)

### Verification & Failure Recovery

Tests transactional mutations, hard deletion scrubbing, and hardlink/symlink rejection against the test suite before deployment so state transitions are deterministic, preventing partial commits.

- Run `pytest tests/test_agent_memory.py` to verify all hermetic test cases pass.

---

## 3. Data Flow & Boundary Communication

Documents the newline-delimited stdio JSON-RPC 2.0 transport and Tri-Stream CLI telemetry contracts so MCP hosts and CLI callers communicate without framing errors, preventing protocol deadlocks.

1. **Newline-Delimited JSON-RPC 2.0 Server**: Reads line-delimited JSON-RPC 2.0 requests and batches over stdio via `sys.stdin.readline(MAX_PAYLOAD_SIZE + 1)` while enforcing `MAX_PAYLOAD_SIZE` (`16 MiB`) and `MAX_BATCH_SIZE` (`128`) bounds.
2. **Tri-Stream Installer & Benchmark Telemetry**: [install.sh](../install.sh) and [benchmark/benchmark_comparison.py](../benchmark/benchmark_comparison.py) support `--validate-args`, `--dry-run`, `--json`, `--version` (`-v`), and `--log-dir`, emitting bounded `results.json` (`<= 64 KiB`, `0600`) and `debug.log` (`0600`) under `--log-dir`.
3. **Deterministic Exit Codes & Strict Flag Parsing**: Disables prefix flag abbreviations (`allow_abbrev=False`) across [bin/agent-memory](../bin/agent-memory) and [benchmark/benchmark_comparison.py](../benchmark/benchmark_comparison.py), returning `0` on success, `1` on runtime/storage errors, `2` on CLI usage or path validation errors, `130` on `SIGINT`, and `143` on `SIGTERM`.
   - *Positive Exemplar*: `Validate installer and benchmark arguments with --validate-args and enforce --log-dir collision checks against the active SQLite database path.`
   - *Negative Exemplar*: `Point --log-dir at or inside the active database directory or allow abbreviated CLI flags.` (STRICTLY FORBIDDEN)

### Verification & Failure Recovery

Monitors JSON-RPC framing and Tri-Stream telemetry outputs during pre-flight verification so protocol mismatches are caught immediately, preventing broken MCP handshakes.

- Run `./bin/agent-memory --version`, `python3 benchmark/benchmark_comparison.py --validate-args --json`, and `bash install.sh --validate-args --dry-run --json` to confirm exit code `0`.

---

## 4. Cross-System Dependencies & Memory Invariants

Binds `agent-memory-mcp` to the `agent-baseline` catalog reference stub and benchmark harness so skill instructions and performance metrics stay synchronized, preventing deployment drift.

1. **Baseline Catalog Integration**: Deployed to `~/.local/bin/agent-memory`, `~/.gemini/antigravity-cli/mcp/agent-memory/`, and `~/.gemini/config/skills/agent-memory/` via [install.sh](../install.sh) and linked from `agent-baseline` via `agent-memory/reference.md`.
2. **Comparative Benchmark Suite**: [benchmark/benchmark_comparison.py](../benchmark/benchmark_comparison.py) benchmarks latency, recall accuracy, and token efficiency with full Tri-Stream `--log-dir` and `allow_abbrev=False` support.
3. **Docs-as-Code Synchronization**: Tracks commit watermarks in `docs/.doc_state.json` and cross-links [README.md](../README.md), [LLM_ONBOARDING.md](../LLM_ONBOARDING.md), [skill/SKILL.md](../skill/SKILL.md), and [skill/references/agent-memory-mcp.md](../skill/references/agent-memory-mcp.md) in [INDEX.md](INDEX.md).
   - *Positive Exemplar*: `Run ./install.sh and advance docs/.doc_state.json whenever bin/agent-memory or skill/SKILL.md is updated.`
   - *Negative Exemplar*: `Modify MCP tool schemas in mcp/*.json without updating bin/agent-memory and skill/SKILL.md in the same commit.` (STRICTLY FORBIDDEN)

### Verification & Failure Recovery

Audits deployed binary and skill files against repository sources before handoff so runtime installations match git ground truth, preventing stale MCP schemas.

- Run `pytest`, `ruff check .`, `shellcheck install.sh`, and `python3 ~/.gemini/config/skills/documentation-management/scripts/doc_manager.py audit --target .` to confirm zero defects.
