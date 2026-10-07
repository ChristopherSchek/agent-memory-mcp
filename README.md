# agent-memory-mcp

A per-user SQLite store (CLI and stdio MCP server) for AI coding agents. It prevents prompt context blowup (O(N) token inflation from dumping flat `MEMORY.md` notes into prompts) and eliminates race conditions from uncoordinated file writes across subagents. By default, it requires an Intel Optane NVMe SSD to guarantee sub-millisecond durable fsync writes without flash wear. Non-Optane storage requires an explicit override flag.

## Quickstart

### 1. Check prerequisites
```bash
python3 -V                                                   # 3.10+ required
python3 -c "import sqlite3; conn = sqlite3.connect(':memory:'); conn.execute('CREATE VIRTUAL TABLE t USING fts5(x);'); print('SQLite', sqlite3.sqlite_version, 'with FTS5 and JSON1: OK')"
```

### 2. Install

**On an Intel Optane host:**
Requires `/mnt/optane/$USER` owned by your user (`chmod 700`).
```bash
sudo mkdir -p /mnt/optane/$USER && sudo chown $USER: /mnt/optane/$USER && sudo chmod 700 /mnt/optane/$USER
./install.sh
```

**On standard storage (SATA/NVMe SSD, VM, WSL2):**
```bash
./install.sh --allow-non-optane
```
Defaults database path to `~/.local/share/agent-memory/memory.db` (or `/mnt/optane/$USER/agent_memory/memory.db` if present). An explicit path can be passed with `--db /path/to/memory.db`.

### 3. Verify health
```bash
~/.local/bin/agent-memory doctor
```
Must return `"healthy": true`.

## Benchmarks

Measured using `python3 benchmark/benchmark_comparison.py -n 100` across physical test drives:

### Hardware Specifications (Manufacturer Published)

| Specification | Intel Optane Memory M10 (3D XPoint) | Samsung SSD 840 EVO (Standard NAND Flash) |
|---|---|---|
| **Model Number** | `MEMPEK1J032GA` | `MZ-7TE120BW` |
| **Capacity** | 32 GB | 120 GB |
| **Form Factor & Bus** | M.2 2280-S3-B-M, PCIe 3.0 x2 NVMe | 2.5-inch 7mm, SATA 6 Gb/s (SATA III) |
| **Storage Architecture** | Intel 3D XPoint (Phase-change, byte-addressable) | Samsung 19nm 3-bit MLC (TLC) NAND Flash |
| **Controller & DRAM** | Intel Optane Media Controller, direct cell write | Samsung 3-core MEX (400 MHz), 256MB LPDDR2 |
| **Sequential Read / Write** | 1,350 MB/s / 290 MB/s | 540 MB/s / 410 MB/s (TurboWrite pseudo-SLC buffer) |
| **Random 4KB Read / Write** | 240,000 IOPS / 65,000 IOPS | 94,000 IOPS / 35,000 IOPS |
| **Manufacturer Latency** | Read: 0.007 ms (7 µs), Write: 0.018 ms (18 µs) (typical) | Not rated for byte-level write (FTL page write) |
| **Endurance Rating** | 182.5 TBW (~100 GB/day for 5 years) | 72 TBW |
| **Write Mechanism** | In-place byte write (no block-erase overhead) | Flash Translation Layer (FTL) block-erase cycles |

### Benchmark Results (100 Iterations)

#### Table 1: Physical Storage Benchmark (Pure Hardware & Disk Latency)

| Implementation / Pattern | Intel Optane M10 | Samsung 840 EVO | Hardware Speedup | Durability Level |
|---|---|---|---|---|
| **agent-memory (`sync=FULL`)** | **0.63 ms** | 5.53 ms | **8.8x faster** | Hardware fsync (power-loss safe) |
| **agent-memory (`sync=NORMAL`)** | **0.26 ms** | 0.46 ms | **1.8x faster** | OS Page Cache (app-crash safe) |
| **Flat Markdown (`MEMORY.md`)** | 0.46 ms | 4.06 ms | 8.8x faster | File append fsync (unsafe concurrency) |
| **JSON Rewrite (`notes.json`)** | 1.09 ms | 6.18 ms | 5.7x faster | Full-file rewrite fsync (unsafe concurrency) |

#### Table 2: AI Agent Scaling & Safety Benchmark (Architecture & Context Health)

| Architecture / Pattern | Context Tokens (at 100 notes) | Est. LLM Prefill Delay (TTFT) | Disk Write Amplification | Multi-Agent Concurrency Safety |
|---|---|---|---|---|
| **agent-memory MCP** | **~300 - 1,200 tokens** (bounded O(K)) | **~45 - 90 ms** | O(N) modified 4KB pages | **Safe** (ACID WAL, 5000 ms busy-timeout) |
| **Flat Markdown (`MEMORY.md`)** | ~5,286 tokens (unbounded O(N)) | ~1,200 - 2,500 ms | O(N) raw text appends | **Unsafe** (interleaved line corruption) |
| **JSON Rewrite (`notes.json`)** | ~6,765 tokens (unbounded O(N)) | ~2,500 - 5,000 ms | O(N^2) full array rewrites | **Unsafe** (full-file overwrite clobber) |

### Key Trade-offs & Operational Guidance:
- **Durability Modes (sync=FULL vs. sync=NORMAL):** In SQLite WAL mode, `sync=NORMAL` commits into the operating system page cache without issuing a physical hardware fsync on each commit. It is completely immune to application crashes and achieves lowest latency (0.26 ms on Optane, 0.46 ms on Samsung), but risks losing un-checkpointed commits if the host suffers sudden power failure. In contrast, `sync=FULL` enforces a hardware fsync barrier on every commit, guaranteeing complete power-cut and kernel panic disaster immunity. On Intel Optane, byte-addressable 3D XPoint commits hardware fsync in 0.63 ms with zero flash wear. On SATA NAND flash, hardware fsync stalls for 5.53 ms due to Flash Translation Layer (FTL) DRAM flushing and block-erase barriers, accelerating drive wear. For this reason, agent-memory defaults to `sync=NORMAL` on standard flash storage and `sync=FULL` on Optane.
- **Bounded Query Tokens vs. Unbounded Store Dumps:** Flat notes files dump their entire history into every prompt turn (O(N) linear token growth). At 100 entries, an agent burns ~5,280 tokens per turn. At 500 entries, it burns over 25,000 tokens, adding 1,200 to 2,500 ms of Time-To-First-Token (TTFT) prompt prefill delay. In contrast, agent-memory caps context consumption to a bounded query envelope (O(K)). Search and recall return only top-matching facts (typically ~300 to 1,200 tokens, depending on query limit and note length). This keeps prompt prefill latency under 90 ms regardless of whether the store contains 100 or 100,000 observations.
- **Write Amplification:** Unassisted JSON rewrite patterns re-serialize the entire array on every observation, generating severe O(N^2) write amplification (writing ~1.38 MB to disk for a 27 KB file across 100 writes). SQLite WAL appends only modified 4KB pages (strictly O(N) write volume).
- **Concurrency & Subagent Safety:** SQLite WAL handles concurrent subagent reads and serialized writes with a 5000 ms busy-timeout queue. Unassisted flat files lack write serialization and corrupt or clobber records during parallel subagent execution.
- **Linux Page Cache Masking on Read:** In all tests, read/search latency (~0.25 - 0.26 ms) is virtually identical across drives because the ~77 KB working set is completely cached in Linux kernel Page Cache (DRAM). Physical drive media is not queried during warm reads, and the reported latency measures CPU time for Python argument parsing and SQLite FTS5 BM25 index traversal in memory.

## Configuration & Environment Variables

| Variable | Description | Default |
|---|---|---|
| `AGENT_MEMORY_DB` | Absolute path to SQLite database | `/mnt/optane/$USER/agent_memory/memory.db` (Optane) or `~/.local/share/agent-memory/memory.db` (non-Optane) |
| `AGENT_MEMORY_SYNC` | SQLite WAL synchronous mode (`FULL`, `NORMAL`, `OFF`, `EXTRA`) | `FULL` (Optane) or `NORMAL` (non-Optane) |
| `ALLOW_NON_OPTANE` | Set to `1` to bypass hardware checks for non-Optane storage | `0` |
| `OPTANE_BASE` | Base directory on `/mnt/optane/$USER` | `/mnt/optane/$USER` |

### Storage Gate Rules
- Directory must be owned by the calling UID and mode `0700`.
- Database file must be mode `0600`.
- Symlinked database sidecars (`-wal`, `-shm`, `-journal`) are rejected.
- In Optane mode, sysfs resolves the mount to the underlying block device, checks `queue/rotational == 0`, and matches Intel Optane PCI/model IDs. Hybrid Optane H10/H20 drives and network filesystems are rejected.

## MCP Client Configs

The installer configures Google Antigravity automatically. For other clients, add this definition:

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

Config paths:
- **Antigravity / Gemini CLI:** `~/.gemini/config/mcp_config.json`
- **Claude Code:** `claude mcp add --scope global agent-memory -e ALLOW_NON_OPTANE=0 -e AGENT_MEMORY_DB=/abs/path/memory.db -- /usr/bin/python3 -I ~/.local/bin/agent-memory --mcp`
- **Cursor:** `~/.cursor/mcp.json` (or `.cursor/mcp.json` in project root)
- **Windsurf:** `~/.codeium/windsurf/mcp_config.json`
- **Claude Desktop:** `~/.config/Claude/claude_desktop_config.json` (Linux), `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS), `%APPDATA%\Claude\claude_desktop_config.json` (Windows)
- **VS Code / Cline:** `~/.cline/data/settings/cline_mcp_settings.json` (or via Cline UI: MCP Servers > Configure)

## CLI Commands & Tools

Define a shell alias:
```bash
am() { ~/.local/bin/agent-memory "$@"; }
```

```bash
# Store a fact
am record "nginx proxy buffers must be disabled for SSE streaming" --entity gateway --type service --category debug_finding --tags nginx,sse

# Search
am search "SSE streaming" --category debug_finding

# Inspect an entity
am recall gateway

# Relate entities
am relate gateway auth-service depends_on

# Delete an observation or entity
am forget --observation <id>
am forget --entity gateway

# Backup and restore
am backup ~/backup.db
am restore ~/backup.db

# Diagnostics & benchmark
am doctor
am benchmark -n 100
```

### Relations
Use standard forward verbs: `depends_on`, `hosted_on`, `deploys_to`, `provisions`, `governs`, `references`, `synchronizes_with`, `stores_data_for`, `authenticates_against`.

### Categories
`architecture`, `decision`, `invariant`, `preference`, `debug_finding`.

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `storage_gate: not Intel Optane NVMe` | DB is on standard flash or virtual disk | Run with `--allow-non-optane`, or move DB to `/mnt/optane/$USER`. |
| `writable: no` | Directory permissions incorrect | Run `sudo chown $USER: <dir> && chmod 700 <dir>`. |
| `is a symlink owned by uid ...` | Symlink target or sidecar owned by different user | Remove symlink or fix ownership. Symlinked sidecars are prohibited. |
| `fts_index: out of sync` | FTS5 index desynchronized | Run `agent-memory init` (or `init --force` for full rebuild). |
| `Foreign key violations` | Corrupt database relations | Restore from backup: `agent-memory restore <backup.db>`. |
