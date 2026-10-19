# Agent Memory MCP Companion Reference

Links the general `agent-baseline` catalog (`~/Git/agent-baseline`) to the standalone `agent-memory-mcp` repository (`~/Git/agent-memory-mcp`) so the Model Context Protocol server binary, companion skill, and reference documentation remain isolated in their dedicated repository, preventing duplicated source trees or cross-repository file bleed in `agent-baseline`.

## 1. Upstream Repository & Isolation Boundary

Establishes the repository boundary, reciprocal pointer, and upstream URL for `agent-memory-mcp` so standalone MCP server and skill assets deploy cleanly from their dedicated repository, preventing standalone source files from bleeding into `agent-baseline`.

1. **Upstream Repository**: [`https://github.com/ChristopherSchek/agent-memory-mcp`](https://github.com/ChristopherSchek/agent-memory-mcp)
2. **Local Clone Path**: `~/Git/agent-memory-mcp` (reciprocal stub: `~/Git/agent-memory-mcp/reference.md`)
3. **Deployed Runtime Targets**: `~/.local/bin/agent-memory` (CLI and stdio MCP server binary), `~/.gemini/config/skills/agent-memory/` (companion `SKILL.md`, `reference.md`, and `references/agent-memory-mcp.md`), `~/.gemini/antigravity-cli/mcp/agent-memory/` (`instructions.md` and `memory_*.json` schemas), and `~/.gemini/config/mcp_config.json` (MCP server registration)
4. **Isolation Invariant**: `~/Git/agent-baseline/agent-memory/` contains only `reference.md`. The full skill implementation, MCP server source code, schema bundle, benchmark suite, and test suite reside exclusively in `~/Git/agent-memory-mcp`.
   - *Positive Exemplar*: `Maintain agent-memory/reference.md in ~/Git/agent-baseline and manage the skill and MCP server source inside ~/Git/agent-memory-mcp.`
   - *Negative Exemplar*: `Duplicate agent-memory SKILL.md or MCP server source files inside ~/Git/agent-baseline/agent-memory/.` (STRICTLY FORBIDDEN)

### Verification & Failure Recovery

Verifies that `~/Git/agent-baseline/agent-memory/` contains only `reference.md` and that the active runtime installation in `~/.gemini/config/skills/agent-memory/` and `~/.local/bin/agent-memory` is healthy so standalone MCP tools resolve deterministically, preventing stale or missing deployments from breaking memory recall.

- If `~/.gemini/config/skills/agent-memory/SKILL.md` or `~/.local/bin/agent-memory` is missing or drifted, deploy it from `~/Git/agent-memory-mcp` (`./install.sh`) and run `python3 ~/.gemini/config/skills/update-baseline/scripts/baseline_updater.py check`.

---

## 2. Hardwired Cross-Discipline Contracts

Binds the `agent-memory` catalog stub to all seventeen canonical `agent-baseline` rules, skills, and persona isolation contracts so standalone MCP deployments maintain host perimeter safety and repository parity, preventing secret leakage, persona bleed, or catalog drift.

1. **`plain-writing`** (`rules/plain-writing.md`): Enforce the 4-part H2 skeleton, 3-part First-Sentence Rule, comment minimalism, and 7-bit ASCII across `reference.md` and all `agent-memory` observations and documentation.
2. **`secret-hygiene`** (`rules/secret-hygiene.md`, `~/.gemini/config/skills/secret-hygiene/SKILL.md`): Never record raw tokens, keys, or connection strings into `agent-memory` and scan staged diffs with `secret_scanner.py` before committing.
3. **`guard-secret-paths`** (`rules/guard-secret-paths.md`, `~/.gemini/config/skills/guard-secret-paths/SKILL.md`): Reject any database initialization, connection, backup, or restore path targeting quarantined host credential directories.
4. **`permissions-hygiene`** (`rules/permissions-hygiene.md`, `~/.gemini/config/skills/permissions-hygiene/SKILL.md`): Restrict whitelisted `agent-memory` CLI rules to explicit subcommands without unconstrained wildcards.
5. **`git-forge-governance`** (`rules/git-forge-governance.md`): Enforce non-delegable human authority for merges, releases, and remote repository mutations across `~/Git/agent-memory-mcp` and `~/Git/agent-baseline`.
6. **`delegated-execution-scripting`** (`rules/delegated-execution-scripting.md`): Emit structured Tri-Stream telemetry (`stdout`, `results.json`, `debug.log`) with `0700`/`0600` permissions during `install.sh` and `benchmark.py` execution.
7. **`principal-tooling`** (`rules/principal-tooling.md`, `~/.gemini/config/skills/principal-tooling/SKILL.md`): Validate modified source, test, and markdown files with `tool_manager.py diff-check` before handoff.
8. **`skunkworks-scratch`** (`rules/skunkworks-scratch.md`, `~/.gemini/config/skills/skunkworks-scratch/SKILL.md`): Route transient benchmark runs, scratch scripts, and test databases to `~/Git/SkunkWorks/`.
9. **`cleanup-skunkworks`** (`~/.gemini/config/skills/cleanup-skunkworks/SKILL.md`): Preserve active `agent-memory` Optane and user-share storage paths and never prune them as scratch workspaces.
10. **`audit-harness`** (`rules/audit-harness.md`, `~/.gemini/config/skills/audit-harness/SKILL.md`): Route multi-agent adversarial audit artifacts for `agent-memory-mcp` into `~/Git/SkunkWorks/`.
11. **`agent-memory`** (`agent-memory/reference.md`, `~/.gemini/config/skills/agent-memory/SKILL.md`): Maintain this catalog stub in `~/Git/agent-baseline/agent-memory/reference.md` in byte-for-byte parity with `~/Git/agent-memory-mcp/reference.md`.
12. **`sync-ide-conversations`** (`sync-ide-conversations/reference.md`, `~/.gemini/config/skills/sync-ide-conversations/SKILL.md`): Keep conversation trajectory databases isolated from the `agent-memory` SQLite knowledge graph.
13. **`sync-cli-conversations`** (`sync-cli-conversations/reference.md`, `~/.gemini/config/skills/sync-cli-conversations/SKILL.md`): Coordinate macOS workstation trajectory synchronization independently of `agent-memory` graph storage.
14. **`cleanup-conversations`** (`~/.gemini/config/skills/cleanup-conversations/SKILL.md`): Ensure conversation index pruning never touches `agent-memory` SQLite files or backups.
15. **`update-baseline`** (`~/.gemini/config/skills/update-baseline/SKILL.md`): Track `agent-memory/reference.md` in `manifest.json` and hydrate `SKILL.md` and `references/agent-memory-mcp.md` from `~/Git/agent-memory-mcp` during `baseline_updater.py adopt`.
16. **`personas`** (`personas/reference.md`, `~/.gemini/config/personas/`): Enforce the Hard Isolation Rule so `~/Git/agent-baseline`, `~/Git/agent-memory-mcp`, and all stored `agent-memory` records remain 100% clinical and persona-free.
17. **`agy-customizations` & `antigravity-guide`** (`~/.gemini/antigravity-cli/builtin/skills/agy-customizations/SKILL.md`, `~/.gemini/antigravity-cli/builtin/skills/antigravity_guide/SKILL.md`): Register lazy-loaded MCP tool schemas in `~/.gemini/antigravity-cli/mcp/agent-memory/` in accordance with Antigravity platform standards.
    - *Positive Exemplar*: `Keep agent-memory/reference.md byte-for-byte identical between ~/Git/agent-baseline and ~/Git/agent-memory-mcp and verify with baseline_updater.py check.`
    - *Negative Exemplar*: `Track deployed ~/.gemini/config/skills/agent-memory/SKILL.md files inside ~/Git/agent-baseline instead of the reference.md stub.` (STRICTLY FORBIDDEN)

### Verification & Failure Recovery

Audits `manifest.json` integrity and `baseline_updater.py check` status after any change to `agent-memory/reference.md` so catalog and companion hashes stay aligned, preventing catalog hash mismatches.

- Run `python3 ~/.gemini/config/skills/update-baseline/scripts/baseline_updater.py check --json` to confirm `modified_count: 0` across `~/Git/agent-baseline`.
