# AgentMemoryMCP Documentation

Provides the central architectural entrypoint, sitemap, and operational guide for AgentMemoryMCP (python) so engineers and automated agents navigate system contracts cleanly, preventing unindexed drift.

## 1. System Overview & Architecture

Synthesizes architectural topology and component interactions so contributors understand system flow, preventing misaligned changes.

1. **System Topology**: Review service boundaries and state diagrams in [architecture.md](architecture.md).
2. **Technical Standards**: Inspect runtime rules and validation gates in [technical_standards.md](technical_standards.md).
3. **Human-Centric Engineering Charter**: Curated for human governance while associative patterns persist in `agent-memory`.
4. **Diagrams as Code**: Author architectural diagrams in native Mermaid code fences.
   - *Positive Exemplar*: `Route all new architectural and operational specifications through docs/INDEX.md.`
   - *Negative Exemplar*: `Create unindexed markdown files that are not linked from docs/INDEX.md.` (STRICTLY FORBIDDEN)

### Verification & Failure Recovery

Verifies architectural alignment against source files before merging so docs match code, preventing service drift.

- Run `doc_manager.py audit --target .` to confirm all diagrams and references match active code.

---

## 2. Canonical Documentation Index

Catalogs the canonical documentation files within `docs/` so technical assets remain discoverable, preventing orphaned specifications.

1. **Canonical Domain Registry**: Categorizes active `docs/` files by Diataxis role and concern.

   | Documentation Domain | Canonical File | Diataxis Category | Primary Concern |
   | :--- | :--- | :--- | :--- |
   | **System Architecture** | [architecture.md](architecture.md) | Explanation | Topology, boundaries, and state flows |
   | **Technical Standards** | [technical_standards.md](technical_standards.md) | Reference | Runtime baselines, linters, and gates |

   - *Positive Exemplar*: `Register every newly added domain specification in the Canonical Domain Registry table.`
   - *Negative Exemplar*: `Delete or rename a canonical documentation file without updating docs/INDEX.md.` (STRICTLY FORBIDDEN)

### Verification & Failure Recovery

Audits relative markdown links across the index before publication so pointers resolve cleanly, preventing broken links.

- Confirm each linked file exists on disk or run `doc_manager.py converge --target . --migrate`.

---

## 3. Diagrams as Code & Visual Assets

Governs architectural diagrams using Mermaid blocks and structured asset directories so visuals stay editable, preventing stale images.

1. **Mermaid-First Architecture**: Author state machines and topologies in Mermaid code blocks.
2. **Asset Directory Discipline**: Store non-text assets strictly inside `docs/assets/`.
3. **Editable Source Invariant**: Pair static assets in `docs/assets/` with text definitions.
   - *Positive Exemplar*: `Embed Mermaid flowcharts in markdown and store referenced assets under docs/assets/.`
   - *Negative Exemplar*: `Commit unreferenced binary images or unquoted parenthetical Mermaid node labels.` (STRICTLY FORBIDDEN)

### Verification & Failure Recovery

Verifies that referenced assets in `docs/assets/` exist and resolve cleanly so docs stay complete, preventing missing artifacts.

- Confirm every asset in `docs/assets/` is referenced in `docs/` before running `doc_manager.py audit`.

---

## 4. Documentation Lifecycle & Synchronization

Binds repository docs to Docs-as-Code commit watermarks so documentation merges with code, preventing specification lag.

1. **Concurrent Commit Standard**: Update relevant docs in the same commit that alters code.
2. **Commit Watermark (`docs/.doc_state.json`)**: Track the last verified commit SHA.
3. **Automated Drift Verification**: Run `doc_manager.py audit` during validation gates.
   - *Positive Exemplar*: `Run doc_manager.py update --target . --advance after updating domain documentation.`
   - *Negative Exemplar*: `Hand off code changes while docs/.doc_state.json reports unresolved documentation lag.` (STRICTLY FORBIDDEN)

### Verification & Failure Recovery

Audits commit watermarks and drift status before handoff so code matches specs, preventing documentation debt.

- Run `doc_manager.py update --target . --advance` after updating lagging files in `docs/`.

---

## 5. Additional References

Cross-references supplementary repository documentation discovered during convergence analysis so external notes remain discoverable, preventing orphaned specifications.

1. **Discovered External Documentation**:
   - [agent-memory-mcp Repository Guide](../README.md) (189 lines)
   - [agent-memory: Autonomous Agent Deployment & Operation Runbook](../LLM_ONBOARDING.md) (343 lines)
   - [Agent Memory MCP Instructions](../mcp/instructions.md) (24 lines)
   - [Skill: agent-memory (Persistent Semantic Memory & Knowledge Graph)](../skill/SKILL.md) (230 lines)
   - [Reference Specification: agent-memory-mcp](../skill/references/agent-memory-mcp.md) (113 lines)
   - *Positive Exemplar*: `Consolidate or cross-link repository markdown notes in docs/INDEX.md and verify link targets with doc_manager.py audit.`
   - *Negative Exemplar*: `Leave external markdown files unindexed or point to deleted paths.` (STRICTLY FORBIDDEN)

### Verification & Failure Recovery

Verifies cross-linked external documentation targets during audit runs so moved files are detected, preventing broken reference links.

- Run `doc_manager.py audit --target .` to confirm all cross-linked markdown paths resolve cleanly, and if any linked file was moved or deleted, update its link in `docs/INDEX.md` before re-running `audit`.
