# agent-memory-mcp

Provides a per-user SQLite semantic memory and knowledge graph store (CLI and stdio MCP server) for AI coding agents to persist durable technical context across sessions, preventing flat `MEMORY.md` files from causing O(N) prompt token blowup and concurrent subagent write corruption.

By default, `agent-memory` requires an Intel Optane NVMe SSD to guarantee sub-millisecond durable `fsync` writes without flash wear, while non-Optane storage is supported via an explicit `--allow-non-optane` override flag.

## Quickstart

Walks through runtime prerequisite checks, installation, health verification, and empirical performance benchmarks to deploy a verified local memory server, preventing prerequisite or storage-gate failures.

### 1. Check Prerequisites

Verifies Python 3.10+ and SQLite FTS5/JSON1 extension availability before running the installer to confirm runtime compatibility, preventing missing SQLite extensions from blocking full-text index creation.

```bash
python3 -V                                                   # 3.10+ required
python3 -c $'import sqlite3\nconn = sqlite3.connect(":memory:")\nconn.execute("CREATE VIRTUAL TABLE t USING fts5(x)")\nprint("SQLite", sqlite3.sqlite_version, "with FTS5 and JSON1: OK")'
```

### 2. Install

Deploys the `agent-memory` binary, MCP schemas, and skill definition for the current user to register the memory server, preventing unverified directory ownership or storage flags from breaking client startup.

**On an Intel Optane host** (requires `/mnt/optane/$USER` owned by your user with mode `0700`):
```bash
sudo mkdir -p /mnt/optane/$USER && sudo chown $USER: /mnt/optane/$USER && sudo chmod 700 /mnt/optane/$USER
./install.sh
```

**On standard storage (SATA/NVMe SSD, VM, WSL2)**:
```bash
./install.sh --allow-non-optane
```
Defaults the database path to `~/.local/share/agent-memory/memory.db` (or `/mnt/optane/$USER/agent_memory/memory.db` if present). Pass an explicit path with `--db /path/to/memory.db`.

### 3. Verify Health

Confirms database integrity, permissions, storage gate status, and FTS5 index synchronization to validate the installation, preventing runtime MCP tool errors when `"healthy"` is `false`.

```bash
~/.local/bin/agent-memory doctor
```
Must return `"healthy": true`.

### 4. Benchmarks & Performance

Compares physical write latency, context token scaling, and concurrency safety across storage media to quantify the architectural trade-offs of SQLite WAL + FTS5 versus flat files, preventing unindexed note files from degrading prompt prefill latency and corrupting state under parallel writes.

Measured using `python3 benchmark/benchmark_comparison.py -n 100` across physical test drives:

| Specification | Intel Optane Memory M10 (3D XPoint) | Samsung SSD 840 EVO (Standard NAND Flash) |
|---|---|---|
| **Model Number** | `MEMPEK1J032GA` | `MZ-7TE120BW` |
| **Capacity** | 32 GB | 120 GB |
| **Form Factor & Bus** | M.2 2280-S3-B-M, PCIe 3.0 x2 NVMe | 2.5-inch 7mm, SATA 6 Gb/s (SATA III) |
| **Storage Architecture** | Intel 3D XPoint (Phase-change, byte-addressable) | Samsung 19nm 3-bit MLC (TLC) NAND Flash |
| **Controller & DRAM** | Intel Optane Media Controller, direct cell write | Samsung 3-core MEX (400 MHz), 256MB LPDDR2 |
| **Sequential Read / Write** | 1,350 MB/s / 290 MB/s | 540 MB/s / 410 MB/s (TurboWrite pseudo-SLC buffer) |
| **Random 4KB Read / Write** | 240,000 IOPS / 65,000 IOPS | 94,000 IOPS / 35,000 IOPS |
| **Manufacturer Latency** | Read: 0.007 ms (7 us), Write: 0.018 ms (18 us) (typical) | Not rated for byte-level write (FTL page write) |
| **Endurance Rating** | 182.5 TBW (~100 GB/day for 5 years) | 72 TBW |
| **Write Mechanism** | In-place byte write (no block-erase overhead) | Flash Translation Layer (FTL) block-erase cycles |

**Table 1: Physical Storage Benchmark (Pure Hardware & Disk Latency, 100 Iterations)**

| Implementation / Pattern | Intel Optane M10 | Samsung 840 EVO | Hardware Speedup | Durability Level |
|---|---|---|---|---|
| **agent-memory (`sync=FULL`)** | **0.63 ms** | 5.53 ms | **8.8x faster** | Hardware fsync (power-loss safe) |
| **agent-memory (`sync=NORMAL`)** | **0.26 ms** | 0.46 ms | **1.8x faster** | OS Page Cache (app-crash safe) |
| **Flat Markdown (`MEMORY.md`)** | 0.46 ms | 4.06 ms | 8.8x faster | File append fsync (unsafe concurrency) |
| **JSON Rewrite (`notes.json`)** | 1.09 ms | 6.18 ms | 5.7x faster | Full-file rewrite fsync (unsafe concurrency) |

**Table 2: AI Agent Scaling & Safety Benchmark (Architecture & Context Health, 100 Iterations)**

| Architecture / Pattern | Context Tokens (at 100 notes) | Est. LLM Prefill Delay (TTFT) | Disk Write Amplification | Multi-Agent Concurrency Safety |
|---|---|---|---|---|
| **agent-memory MCP** | **~300 to 1,200 tokens** (bounded O(K)) | **~45 to 90 ms** | O(N) modified 4KB pages | **Safe** (ACID WAL, 5000 ms busy-timeout) |
| **Flat Markdown (`MEMORY.md`)** | ~5,286 tokens (unbounded O(N)) | ~1,200 to 2,500 ms | O(N) raw text appends | **Unsafe** (interleaved line corruption) |
| **JSON Rewrite (`notes.json`)** | ~6,765 tokens (unbounded O(N)) | ~2,500 to 5,000 ms | O(N^2) full array rewrites | **Unsafe** (full-file overwrite clobber) |

- **Durability Modes (`sync=FULL` vs. `sync=NORMAL`)**: In SQLite WAL mode, `sync=NORMAL` commits into the operating system page cache without issuing a physical hardware `fsync` on each commit. It is immune to application crashes and achieves lowest latency (0.26 ms on Optane, 0.46 ms on Samsung), but risks losing un-checkpointed commits if the host suffers sudden power failure. In contrast, `sync=FULL` enforces a hardware `fsync` barrier on every commit, guaranteeing power-cut and kernel panic immunity. On Intel Optane, byte-addressable 3D XPoint commits hardware `fsync` in 0.63 ms with zero flash wear. On SATA NAND flash, hardware `fsync` stalls for 5.53 ms due to Flash Translation Layer (FTL) DRAM flushing and block-erase barriers, accelerating drive wear. For this reason, `agent-memory` defaults to `sync=NORMAL` on standard flash storage and `sync=FULL` on Optane.
- **Bounded Query Tokens vs. Unbounded Store Dumps**: Flat notes files dump their entire history into every prompt turn (O(N) linear token growth). At 100 entries, an agent burns ~5,280 tokens per turn. At 500 entries, it burns over 25,000 tokens, adding 1,200 to 2,500 ms of Time-To-First-Token (TTFT) prompt prefill delay. In contrast, `agent-memory` caps context consumption to a bounded query envelope (O(K)). Search and recall return only top-matching facts (typically ~300 to 1,200 tokens, depending on query limit and note length). This keeps prompt prefill latency under 90 ms regardless of whether the store contains 100 or 100,000 observations.
- **Write Amplification**: Unassisted JSON rewrite patterns re-serialize the entire array on every observation, generating severe O(N^2) write amplification (writing ~1.38 MB to disk for a 27 KB file across 100 writes). SQLite WAL appends only modified 4KB pages (strictly O(N) write volume) with tuned pragmas (`journal_size_limit = 33554432` (32 MB), `wal_autocheckpoint = 2000`, `mmap_size = 268435456` (256 MB), `cache_size = -8192` (8 MB)).
- **Concurrency & Subagent Safety**: SQLite WAL handles concurrent subagent reads and serialized writes with a 5000 ms busy-timeout queue. Unassisted flat files lack write serialization and corrupt or clobber records during parallel subagent execution.
- **Linux Page Cache Masking on Read**: In all tests, read/search latency (~0.25 to 0.26 ms) is virtually identical across drives because the ~77 KB working set is completely cached in Linux kernel Page Cache (DRAM). Physical drive media is not queried during warm reads, and the reported latency measures CPU time for Python argument parsing and SQLite FTS5 BM25 index traversal in memory.
  - *Positive Exemplar*: `Run ./install.sh and verify "healthy": true via ~/.local/bin/agent-memory doctor before starting agent sessions.`
  - *Negative Exemplar*: `Copy bin/agent-memory manually without running preflight checks or append concurrent observations to flat MEMORY.md files.` (STRICTLY FORBIDDEN)

### Verification & Failure Recovery

Confirms that preflight, self-test, and `doctor` diagnostics pass after running `./install.sh` to verify deployment readiness, preventing uninitialized or misconfigured databases from serving MCP traffic.

- If `./install.sh` or `doctor` exits non-zero, inspect the failing field in the JSON output and consult the Troubleshooting table below before retrying.

## Configuration

Lists environment variables, security gates, MCP client registration snippets, and CLI commands to configure `agent-memory` across host environments, preventing path fallbacks, unauthorized file access, or argument splitting.

| Variable | Description | Default |
|---|---|---|
| `AGENT_MEMORY_DB` | Absolute path to SQLite database | `/mnt/optane/$USER/agent_memory/memory.db` (Optane) or `~/.local/share/agent-memory/memory.db` (non-Optane) |
| `AGENT_MEMORY_SYNC` | SQLite WAL synchronous mode (`FULL`, `NORMAL`, `OFF`, `EXTRA`) | `FULL` (Optane) or `NORMAL` (non-Optane) |
| `ALLOW_NON_OPTANE` | Set to `1` to bypass hardware checks for non-Optane storage | `0` |
| `OPTANE_BASE` | Base directory on `/mnt/optane/$USER` | `/mnt/optane/$USER` |

### 1. Storage Gate & Security Rules

Enforces filesystem permission, symlink, hardware verification, secret hygiene, and persona isolation gates to protect stored observations, preventing unauthorized local access or policy violations.

- **Directory Ownership**: The database directory must be owned by the calling UID and have mode `0700` (not group- or world-writable).
- **Database Permissions**: The database file and backups must be owned by the calling UID and have mode `0600`.
- **Symlink & Sidecar Defense**: Unowned symlinks and symlinked or group/world-writable database sidecars (`-wal`, `-shm`, `-journal`) are rejected.
- **Host Secret Perimeter Defense**: Database paths, backups, and restores inside quarantined credential directories are deterministically blocked.
- **Secret Hygiene & Hard Isolation**: Server-side `_screen_for_secrets` rejects raw credentials, private keys, API tokens, non-7-bit-ASCII bytes, and roleplay stage-direction markers on write, while the calling agent enforces the full Hard Isolation Rule across all recorded text. Input sizes are bounded (`content` max 8000 chars, `summary` max 2000 chars, `entity` / `session_id` / `relation_type` max 200 chars, `attributes` / `metadata` max 4000 serialized chars).
- **Optane Hardware Verification**: In Optane mode, `sysfs` resolves the mount to the underlying block device, checks `queue/rotational == 0`, and matches Intel Optane PCI/model IDs. Hybrid Optane H10/H20 drives and network filesystems are rejected.

### 2. MCP Client Configs

Provides MCP server registration snippets and configuration file locations across supported AI coding clients so agents can invoke `memory_*` tools over stdio, preventing unexpanded shell tokens or invalid paths from breaking server launch.

The installer configures Google Antigravity automatically. For other clients, add this definition (replacing `<user>` with your username):

```json
{
  "mcpServers": {
    "agent-memory": {
      "command": "/usr/bin/python3",
      "args": ["-I", "/home/<user>/.local/bin/agent-memory", "--mcp"],
      "env": {
        "ALLOW_NON_OPTANE": "0",
        "AGENT_MEMORY_DB": "/mnt/optane/<user>/agent_memory/memory.db"
      }
    }
  }
}
```

Client configuration file paths:
- **Antigravity / Gemini CLI**: `~/.gemini/config/mcp_config.json`
- **Claude Code**: `~/.claude.json` (or register via `claude mcp add --scope global agent-memory -e ALLOW_NON_OPTANE=0 -e AGENT_MEMORY_DB=/abs/path/memory.db -- /usr/bin/python3 -I ~/.local/bin/agent-memory --mcp`)
- **Cursor**: `~/.cursor/mcp.json` (or `.cursor/mcp.json` in project root)
- **Windsurf**: `~/.codeium/windsurf/mcp_config.json`
- **Claude Desktop**: `~/.config/Claude/claude_desktop_config.json` (Linux), `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS), `%APPDATA%\Claude\claude_desktop_config.json` (Windows)
- **VS Code / Cline**: `~/.cline/data/settings/cline_mcp_settings.json` (or via Cline UI: MCP Servers > Configure)

### 3. CLI Commands & Ontology

Demonstrates direct command-line usage via the `am()` shell function and lists canonical categories and relation verbs so operators can query and maintain the store from a shell, preventing unquoted aliases or ad-hoc taxonomy terms from fragmenting retrieval.

Define a word-splitting-safe shell function in your interactive shell environment:
```bash
am() {
    env ALLOW_NON_OPTANE=0 AGENT_MEMORY_DB="/mnt/optane/${USER}/agent_memory/memory.db" /usr/bin/python3 -I "${HOME}/.local/bin/agent-memory" "$@"
}
```

```bash
# Store a fact
am record "nginx proxy buffers must be disabled for SSE streaming" --entity gateway --type service --category debug_finding --tags nginx,sse

# Search
am search "SSE streaming" --category debug_finding

# Inspect an entity (optionally filtered by category)
am recall gateway --category debug_finding

# Relate entities
am relate gateway auth-service depends_on

# Delete an observation or entity
am forget --observation <uuid>
am forget --entity gateway

# Backup and restore
am backup ~/backup.db
am restore ~/backup.db

# Diagnostics & benchmark
am doctor
am benchmark -n 100
```

- **Allowed Categories**: `architecture`, `decision`, `invariant`, `preference`, `debug_finding`.
- **Canonical Forward Relation Verbs**: `depends_on`, `hosted_on`, `deploys_to`, `provisions`, `governs`, `references`, `synchronizes_with`, `stores_data_for`, `authenticates_against`.
  - *Positive Exemplar*: `Configure explicit absolute paths in mcp_config.json and invoke CLI subcommands through the quoted am() wrapper.`
  - *Negative Exemplar*: `Pass unexpanded ${HOME} variables in MCP args or store database files in group-writable directories.` (STRICTLY FORBIDDEN)

### Verification & Failure Recovery

Validates MCP configuration JSON syntax and runs `am doctor` after updating environment variables or client registrations to confirm valid settings, preventing broken stdio launches.

- If the MCP client fails to connect after a configuration update, run `./install.sh` to validate and rewrite the client registration entry.

## Troubleshooting

Maps common diagnostic errors from `agent-memory doctor` to their root causes and remediation commands to restore database health, preventing unaddressed storage or index errors from blocking MCP tools.

| Error | Cause | Fix |
|---|---|---|
| `storage_gate: not Intel Optane NVMe` | DB is on standard flash or virtual disk | Run with `--allow-non-optane`, or move DB to `/mnt/optane/$USER`. |
| `writable: no` | Directory or database permissions incorrect | Run `sudo chown $USER: <dir> && chmod 700 <dir>` (and `chmod 600 <db>`). |
| `is a symlink owned by uid ...` | Symlink target or sidecar owned by different user | Remove symlink or fix ownership. Symlinked sidecars are prohibited. |
| `fts_index: out of sync` | FTS5 index desynchronized | Run `agent-memory init` (or `init --force` for full rebuild). |
| `Foreign key violations` | Corrupt database relations | Restore from backup: `agent-memory restore <backup.db>`. |

- *Positive Exemplar*: `Diagnose health failures with agent-memory doctor and rebuild desynchronized FTS5 indexes with agent-memory init --force.`
- *Negative Exemplar*: `Delete SQLite -wal or -shm sidecar files manually while a writer connection is active.` (STRICTLY FORBIDDEN)

### Verification & Failure Recovery

Re-runs `agent-memory doctor` after executing any remediation step to confirm that `"healthy": true` is restored, preventing incomplete repairs from leaving the store offline.

- If `init --force` cannot repair a corrupted database file, restore the latest pre-migration or manual backup via `agent-memory restore <backup.db>`.
