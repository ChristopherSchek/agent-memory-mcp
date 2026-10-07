# agent-memory-mcp

Provides a per-user SQLite semantic memory and knowledge graph store (CLI and stdio MCP server) backed by Intel Optane NVMe media by default (or standard storage via `--allow-non-optane`) to persist durable technical context across sessions so operational and security invariants hold, preventing flat `MEMORY.md` files from causing O(N) prompt token blowup and concurrent subagent write corruption.

## 1. Quickstart & Benchmarks

Walks through runtime prerequisite checks, installation, health verification, and empirical performance benchmarks to deploy a verified local memory server so operational and security invariants hold, preventing prerequisite or storage-gate failures.

1. **Check Prerequisites**: Verify Python 3.10+ and SQLite 3.31+ with FTS5 and JSON1 (`json_patch`) extension availability before running the installer to confirm runtime compatibility, preventing missing SQLite extensions from blocking full-text index creation or JSON Merge Patch updates:

   ```bash
   python3 -V                                                   # 3.10+ required
   python3 -c $'import sqlite3; assert sqlite3.sqlite_version_info >= (3, 31, 0), sqlite3.sqlite_version\nconn = sqlite3.connect(":memory:")\nconn.execute("CREATE VIRTUAL TABLE t USING fts5(x)")\nconn.execute("SELECT json_patch(\'{}\', \'{}\')")\nprint("SQLite", sqlite3.sqlite_version, "with FTS5 and JSON1: OK")'
   ```

2. **Install**: Deploy the `agent-memory` binary, MCP schemas, and skill definition for the current user to register the memory server, preventing unverified directory ownership or storage flags from breaking client startup.
   - **On an Intel Optane host** (requires `/mnt/optane/$USER` owned by your user with mode `0700`):

     ```bash
     sudo mkdir -p /mnt/optane/$USER && sudo chown $USER: /mnt/optane/$USER && sudo chmod 700 /mnt/optane/$USER
     ./install.sh
     ```

   - **On standard storage (SATA/NVMe SSD, VM, WSL2)**:

     ```bash
     ./install.sh --allow-non-optane
     ```

   - **Defaults & Flags**: Defaults the database path to `/mnt/optane/$USER/agent_memory/memory.db` when `/mnt/optane/$USER` exists and is owned by `$USER` without group/world write permissions, or `${XDG_DATA_HOME:-~/.local/share}/agent-memory/memory.db` otherwise. Pass an explicit path with `--db /path/to/memory.db`. Additional installer flags include `--require-optane` (`--no-allow-non-optane`), `--no-client-config`, `--dry-run`, `--log-dir /abs/dir`, and `--uninstall`.
3. **Verify Health**: Confirm database integrity, permissions, storage gate status, and FTS5 index synchronization (`"healthy": true`) to validate the installation, preventing runtime MCP tool errors:

   ```bash
   ~/.local/bin/agent-memory doctor                         # Optane host (or after client config is written)
   ALLOW_NON_OPTANE=1 ~/.local/bin/agent-memory doctor      # Non-Optane host when --no-client-config was used
   ```

4. **Benchmarks & Performance**: Compare physical write latency, context token scaling, and concurrency safety across storage media (`python3 benchmark/benchmark_comparison.py -n 100`) to quantify the architectural trade-offs of SQLite WAL + FTS5 versus flat files:

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

   | Implementation / Pattern | Intel Optane M10 | Samsung 840 EVO | Hardware Speedup | Durability Level |
   |---|---|---|---|---|
   | **agent-memory (`sync=FULL`)** | **0.63 ms** | 5.53 ms | **8.8x faster** | Hardware fsync (power-loss safe) |
   | **agent-memory (`sync=NORMAL`)** | **0.26 ms** | 0.46 ms | **1.8x faster** | OS Page Cache (app-crash safe) |
   | **Flat Markdown (`MEMORY.md`)** | 0.46 ms | 4.06 ms | 8.8x faster | File append fsync (unsafe concurrency) |
   | **JSON Rewrite (`notes.json`)** | 1.09 ms | 6.18 ms | 5.7x faster | Full-file rewrite fsync (unsafe concurrency) |

   | Architecture / Pattern | Context Tokens (at 100 notes) | Est. LLM Prefill Delay (TTFT) | Disk Write Amplification | Multi-Agent Concurrency Safety |
   |---|---|---|---|---|
   | **agent-memory MCP** | **~300 to 1,200 tokens** (bounded O(K)) | **~45 to 90 ms** | O(N) modified 4KB pages | **Safe** (ACID WAL, 5000 ms busy-timeout) |
   | **Flat Markdown (`MEMORY.md`)** | ~5,286 tokens (unbounded O(N)) | ~1,200 to 2,500 ms | O(N) raw text appends | **Unsafe** (interleaved line corruption) |
   | **JSON Rewrite (`notes.json`)** | ~6,765 tokens (unbounded O(N)) | ~2,500 to 5,000 ms | O(N^2) full array rewrites | **Unsafe** (full-file overwrite clobber) |

   - **Durability Modes (`sync=FULL` vs. `sync=NORMAL`)**: In SQLite WAL mode, `sync=NORMAL` commits into the operating system page cache without issuing a physical hardware `fsync` on each commit (0.26 ms on Optane, 0.46 ms on Samsung). `sync=FULL` enforces a hardware `fsync` barrier on every commit, guaranteeing power-cut and kernel panic immunity in 0.63 ms on Intel Optane 3D XPoint versus 5.53 ms on SATA NAND flash. `agent-memory` defaults to `sync=NORMAL` on standard flash storage and `sync=FULL` on Optane.
   - **Bounded Query Tokens vs. Unbounded Store Dumps**: Flat notes files dump their entire history into every prompt turn (O(N) linear token growth). `agent-memory` caps context consumption to a bounded query envelope (O(K), typically ~300 to 1,200 tokens), keeping prompt prefill latency under 90 ms regardless of whether the store contains 100 or 100,000 observations.
   - **Write Amplification & Concurrency**: Unassisted JSON rewrite patterns re-serialize the entire array on every observation (O(N^2) write amplification). SQLite WAL appends only modified 4KB pages (O(N) write volume) with tuned pragmas (`journal_size_limit = 33554432`, `wal_autocheckpoint = 2000`, `mmap_size = 268435456`, `cache_size = -8192`) and handles concurrent subagent reads and serialized writes with a 5000 ms busy-timeout queue.
   - **Linux Page Cache Masking on Read**: Read/search latency (~0.25 to 0.26 ms) is virtually identical across drives because the working set is cached in the Linux kernel Page Cache (DRAM).
   - *Positive Exemplar*: `Run ./install.sh and verify "healthy": true via ~/.local/bin/agent-memory doctor before starting agent sessions.`
   - *Negative Exemplar*: `Copy bin/agent-memory manually without running preflight checks or append concurrent observations to flat MEMORY.md files.` (STRICTLY FORBIDDEN)

### Verification & Failure Recovery

Confirms that preflight, self-test, and `doctor` diagnostics pass after running `./install.sh` to verify deployment readiness so operational and security invariants hold, preventing uninitialized or misconfigured databases from serving MCP traffic.

- If `./install.sh` or `doctor` exits non-zero, inspect the failing field in the JSON output and consult the Troubleshooting table below before retrying.

## 2. Configuration & Client Registration

Lists environment variables, security gates, MCP client registration snippets, and CLI commands to configure `agent-memory` across host environments so operational and security invariants hold, preventing path fallbacks, unauthorized file access, or argument splitting.

1. **Environment Variables**:

   | Variable | Description | Default |
   |---|---|---|
   | `AGENT_MEMORY_DB` | Absolute path to SQLite database | `/mnt/optane/$USER/agent_memory/memory.db` (Optane) or `${XDG_DATA_HOME:-~/.local/share}/agent-memory/memory.db` (non-Optane) |
   | `AGENT_MEMORY_SYNC` | SQLite WAL synchronous mode (`FULL`, `NORMAL`, `OFF`, `EXTRA`) | `FULL` (Optane) or `NORMAL` (non-Optane) |
   | `ALLOW_NON_OPTANE` | Set to `1` to bypass hardware checks for non-Optane storage | `0` |
   | `OPTANE_BASE` | Base directory on `/mnt/optane/$USER` | `/mnt/optane/$USER` |
   | `XDG_DATA_HOME` | Base directory for non-Optane default database path | `~/.local/share` |
   | `AGENT_MEMORY_NO_CFG_FALLBACK` | Set to `1` to disable reading `AGENT_MEMORY_DB`/`ALLOW_NON_OPTANE` from client MCP config files | `0` |
   | `AGENT_MEMORY_BIN_DIR` (`BIN_DIR`) | Installer target directory for `agent-memory` executable | `~/.local/bin` |
   | `AGENT_MEMORY_MCP_DIR` (`MCP_DIR`) | Installer target directory for Antigravity MCP schema files | `~/.gemini/antigravity-cli/mcp/agent-memory` |
   | `AGENT_MEMORY_SKILL_DIR` (`SKILL_DIR`) | Installer target directory for `agent-memory` skill files | `~/.gemini/config/skills/agent-memory` |
   | `AGENT_MEMORY_MCP_CONFIG` (`MCP_CONFIG`) | Installer target path for Antigravity `mcp_config.json` | `~/.gemini/config/mcp_config.json` |
   | `ALLOW_ROOT` | Set to `1` in `install.sh` to override the root-install guard | `0` |

2. **Storage Gate & Security Rules**:
   - **Directory Ownership**: The database directory must be owned by the calling UID and have mode `0700` (not group- or world-writable).
   - **Database Permissions**: The database file, client configuration files modified by `install.sh`, and backups must be owned by the calling UID and have mode `0600`.
   - **Symlink & Sidecar Defense**: Unowned symlinks and symlinked, pre-existing orphan, or group/world-writable database sidecars (`-wal`, `-shm`, `-journal`) are rejected.
   - **Host Secret Perimeter Defense**: Database paths, backups, and restores inside quarantined credential directories are deterministically blocked.
   - **Secret & Input Screening**: Server-side `_screen_for_secrets` rejects raw credentials, private keys, API tokens, `AGE-SECRET-KEY-1...` keys, non-7-bit-ASCII bytes (including `\r`, NUL, and C0 control escapes), and non-clinical stage-direction or conversational markers on write across all fields (`content`, `summary`, `entity`, `tags`, `attributes`, `metadata`). Input sizes are bounded (`content` max 8000 chars, `summary` max 2000 chars, `query` max 2000 chars, `entity` / `session_id` / `relation_type` / `observation_id` max 200 chars, `tags` max 50 items of 100 chars each, `attributes` / `metadata` max 4000 serialized chars both before and after JSON Merge Patch).
   - **Optane Hardware Verification**: In Optane mode, `sysfs` resolves the mount to the underlying block device, checks `queue/rotational == 0`, and matches Intel Optane PCI/model IDs. Hybrid Optane H10/H20 drives and network filesystems are rejected.
3. **MCP Client Configs**: The installer configures Google Antigravity (`~/.gemini/config/mcp_config.json`) automatically. For other clients (`~/.claude.json`, `~/.cursor/mcp.json`, `~/.codeium/windsurf/mcp_config.json`, `~/.config/Claude/claude_desktop_config.json`, `~/Library/Application Support/Claude/claude_desktop_config.json`, `~/.cline/data/settings/cline_mcp_settings.json`), add this definition (replacing `<user>` with your username):

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

4. **CLI Commands & Ontology**: Define a word-splitting-safe `am()` shell function in your interactive shell environment and use canonical entity types (`service`, `repo`, `pattern`, `concept`, `operator`, `host`), categories (`architecture`, `decision`, `invariant`, `preference`, `debug_finding`), and forward relation verbs (`depends_on`, `hosted_on`, `deploys_to`, `provisions`, `governs`, `references`, `synchronizes_with`, `stores_data_for`, `authenticates_against`):

   ```bash
   am() {
       env ALLOW_NON_OPTANE=0 AGENT_MEMORY_DB="/mnt/optane/${USER}/agent_memory/memory.db" /usr/bin/python3 -I "${HOME}/.local/bin/agent-memory" "$@"
   }

   am init [--force|-f]
   am record "nginx proxy buffers must be disabled for SSE streaming" --entity gateway --type service --summary "Edge API gateway" --category debug_finding --tags nginx,sse --confidence 1.0 --session default --attributes '{"port":443}'
   am search "SSE streaming" --category debug_finding --session default --limit 10
   am recall gateway --category debug_finding --session default --limit 20 --relation-limit 50
   am relate gateway auth-service depends_on --weight 1.0 --metadata '{"protocol":"gRPC"}'
   am forget --observation|-o <uuid>
   am forget --entity gateway
   am forget --source gateway --target auth-service [--relation-type depends_on]
   am backup ~/backup.db
   am restore ~/backup.db
   am doctor
   am benchmark -n 100
   ```

   - *Positive Exemplar*: `Configure explicit absolute paths in mcp_config.json and invoke CLI subcommands through the quoted am() wrapper.`
   - *Negative Exemplar*: `Pass unexpanded ${HOME} variables in MCP args or store database files in group-writable directories.` (STRICTLY FORBIDDEN)

### Verification & Failure Recovery

Validates MCP configuration JSON syntax and runs `am doctor` after updating environment variables or client registrations to confirm valid settings so operational and security invariants hold, preventing broken stdio launches.

- If the MCP client fails to connect after a configuration update, run `./install.sh` to validate and rewrite the client registration entry.

## 3. Troubleshooting & Recovery

Maps common diagnostic errors from `agent-memory doctor` to their root causes and remediation commands to restore database health so operational and security invariants hold, preventing unaddressed storage or index errors from blocking MCP tools.

1. **Diagnostic Error Reference**:

   | `doctor` Output Field | Cause | Fix |
   |---|---|---|
   | `storage_gate: ... is not on a verified Intel Optane NVMe device` (or `not under '/mnt/optane/...'`) | DB is on standard flash or virtual disk without non-Optane override | Run `./install.sh --allow-non-optane` (or set `ALLOW_NON_OPTANE=1`), or move DB to `/mnt/optane/$USER`. |
   | `writable: no: '<path>' is not writable by uid ...` (or `is on a read-only mount`) | Directory or database permissions incorrect or read-only mount | Run `sudo chown $USER: <dir> && chmod 700 <dir>` (and `chmod 600 <db>`). |
   | `permissions: error: ... is a symlink owned by uid ...` (or `sidecar ... is a symlink`) | Symlink target or sidecar owned by different user | Remove symlink or fix ownership. Symlinked sidecars are prohibited. |
   | `fts_index: out of sync: <M> indexed vs <N> facts (run 'agent-memory init')` | FTS5 index desynchronized from `observations` table | Run `agent-memory init` (or `agent-memory init --force` for full rebuild). |
   | `foreign_keys: <N> violation(s): ...` | Corrupt database relations | Run `agent-memory init --force` or restore from backup via `agent-memory restore <backup.db>`. |

   - *Positive Exemplar*: `Diagnose health failures with agent-memory doctor and rebuild desynchronized FTS5 indexes with agent-memory init --force.`
   - *Negative Exemplar*: `Delete SQLite -wal or -shm sidecar files manually while a writer connection is active.` (STRICTLY FORBIDDEN)

### Verification & Failure Recovery

Re-runs `agent-memory doctor` after executing any remediation step to confirm that `"healthy": true` is restored so operational and security invariants hold, preventing incomplete repairs from leaving the store offline.

- If `init --force` cannot repair a corrupted database file, restore the latest pre-migration or manual backup via `agent-memory restore <backup.db>`.

## 4. License & Governance

Governs source distribution and modification under the GNU General Public License v3.0 (`GPL-3.0-only`) to protect author attribution and reciprocal open-source obligations so operational and security invariants hold, preventing unauthorized proprietary relicensing or closed-source commercial redistribution.

1. **Copyright**: Copyright (c) 2026 Christopher Schek.
2. **SPDX Identifier**: `GPL-3.0-only` (see [`LICENSE`](LICENSE) for full terms).
3. **Modification & Distribution Reciprocity**: Any distribution of modified or unmodified copies requires preserving copyright notices and making the complete corresponding source code available under `GPL-3.0-only`.
   - *Positive Exemplar*: `Retain the LICENSE file, copyright notices, and SPDX-License-Identifier: GPL-3.0-only headers in all copies and modified distributions.`
   - *Negative Exemplar*: `Strip copyright notices or distribute agent-memory as part of a closed-source commercial product.` (STRICTLY FORBIDDEN)

### Verification & Failure Recovery

Verifies that `LICENSE` and `SPDX-License-Identifier: GPL-3.0-only` headers remain intact across source files and release archives before packaging or distribution so operational and security invariants hold, preventing unattributed or unlicensed artifacts.

- If `LICENSE` is missing or modified in a local checkout or release archive, restore the canonical `GPL-3.0-only` text from the repository root before redistributing.
