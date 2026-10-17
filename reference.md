# Agent Baseline Catalog Reference

Links this standalone repository to the general `agent-baseline` catalog repository so shared engineering rules, security invariants, and baseline verification tooling remain referenced via a clean pointer without cross-repository file bleed.

## 1. Upstream Baseline Repository & Isolation Boundary

Establishes the upstream URL and isolation boundary between this standalone repository and `agent-baseline` to prevent general catalog rules or unrelated repository assets from duplicating across repositories.

1. **Upstream Baseline Repository**: [`https://github.com/ChristopherSchek/agent-baseline`](https://github.com/ChristopherSchek/agent-baseline)
2. **Local Clone Path**: `~/Git/agent-baseline`
3. **Deployed Runtime Root**: `~/.gemini/config/` and `~/.claude/`
4. **Isolation Invariant**: Each standalone repository houses only its own domain-specific assets and links to `agent-baseline` via `reference.md`. General engineering rules (`rules/*.md`), baseline skills, and catalog schemas reside in `~/Git/agent-baseline`.
   - *Positive Exemplar*: `Reference ~/Git/agent-baseline via reference.md while keeping repository-specific source files isolated to their own repository.`
   - *Negative Exemplar*: `Copy unrelated repository files or persona configurations across standalone repository boundaries.` (STRICTLY FORBIDDEN)

### Verification & Failure Recovery

Verifies that cross-repository references resolve cleanly and that `update-baseline` reports zero configuration drift.

- Run `python3 ~/.gemini/config/skills/update-baseline/scripts/baseline_updater.py check` to verify baseline alignment.
