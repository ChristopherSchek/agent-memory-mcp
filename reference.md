# Agent Baseline Catalog Reference

Links this standalone repository (`~/Git/agent-memory-mcp`) to the general `agent-baseline` catalog repository (`~/Git/agent-baseline`) so shared engineering rules, security invariants, and baseline verification tooling remain referenced via a clean pointer, preventing cross-repository file bleed or duplicated source trees.

## 1. Upstream Baseline Repository & Isolation Boundary

Establishes the upstream URL, reciprocal pointer, and isolation boundary between `~/Git/agent-memory-mcp` and `~/Git/agent-baseline` so each repository houses only its authoritative assets, preventing general catalog rules or standalone MCP server files from duplicating across repositories.

1. **Upstream Baseline Repository**: [`https://github.com/ChristopherSchek/agent-baseline`](https://github.com/ChristopherSchek/agent-baseline)
2. **Local Baseline Clone Path**: `~/Git/agent-baseline` (reciprocal stub: `~/Git/agent-baseline/agent-memory/reference.md`)
3. **Deployed Runtime Targets**: `~/.local/bin/agent-memory` (CLI and stdio MCP server binary), `~/.gemini/config/skills/agent-memory/` and `~/.claude/skills/agent-memory/` (`SKILL.md` and `references/agent-memory-mcp.md`), `~/.gemini/antigravity-cli/mcp/agent-memory/` (`instructions.md` and `memory_*.json` schemas), and `~/.gemini/config/mcp_config.json` (MCP server registration)
4. **Isolation Invariant**: `~/Git/agent-memory-mcp` houses the MCP server binary, schemas, companion skill files, benchmark suite, and unit tests, while `~/Git/agent-baseline` houses only the `agent-memory/reference.md` stub alongside general engineering rules (`rules/*.md`) and baseline skills.
   - *Positive Exemplar*: `Reference ~/Git/agent-baseline via reference.md while keeping agent-memory-mcp source files isolated to ~/Git/agent-memory-mcp.`
   - *Negative Exemplar*: `Copy standalone agent-memory source files or persona configurations into ~/Git/agent-baseline.` (STRICTLY FORBIDDEN)

### Verification & Failure Recovery

Verifies that cross-repository references resolve cleanly and that `update-baseline` reports zero configuration drift across deployed runtimes, preventing uncoordinated edits from diverging.

- Run `./install.sh` from `~/Git/agent-memory-mcp` and `python3 ~/.gemini/config/skills/update-baseline/scripts/baseline_updater.py check` to verify baseline alignment.

## 2. Hardwired Cross-Discipline Contracts

Binds `~/Git/agent-memory-mcp` to the canonical `agent-baseline` engineering rules and companion skills so every commit and runtime deployment preserves host security and four-way baseline parity, preventing secret leaks, path quarantine violations, or documentation drift.

1. **Plain-Writing & Hard Isolation (`plain-writing`, `personas`)**: Enforce the 4-part H2 skeleton, 3-part First-Sentence Rule, strict 7-bit ASCII, and zero conversational persona prose across all repository files and recorded observations.
2. **Secret Hygiene & Host Perimeter Defense (`secret-hygiene`, `guard-secret-paths`)**: Screen staged diffs with `secret_scanner.py` and block all quarantined credential paths via `_check_not_guarded_path` and deterministic `PreToolUse` hooks.
3. **Principal Tooling & Four-Way Parity (`principal-tooling`, `update-baseline`)**: Validate modified files with `tool_manager.py diff-check` and maintain parity across `~/Git/agent-memory-mcp`, `~/Git/agent-baseline/agent-memory/reference.md`, `~/.gemini/config/`, and `~/.claude/`.
   - *Positive Exemplar*: `Keep reference.md in ~/Git/agent-memory-mcp and agent-memory/reference.md in ~/Git/agent-baseline synchronized across all deployment targets.`
   - *Negative Exemplar*: `Allow standalone repository files to bleed into ~/Git/agent-baseline or skip baseline_updater.py check after updates.` (STRICTLY FORBIDDEN)

### Verification & Failure Recovery

Audits reciprocal `reference.md` stubs and deployed skill/MCP artifacts after updates to prevent cross-repository drift.

- If `baseline_updater.py check` or `agent-memory doctor` reports drift or health issues, re-run `./install.sh` from `~/Git/agent-memory-mcp` and reconcile `manifest.json` in `~/Git/agent-baseline`.
