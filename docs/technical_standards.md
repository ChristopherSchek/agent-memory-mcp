# AgentMemoryMCP Technical Standards

Establishes runtime baselines, linting gates, security invariants, and test requirements for `agent-memory-mcp` so the MCP server, CLI, installer, and benchmark suite maintain zero-defect reliability, preventing regressions.

## 1. Runtime Environment & Toolchain Baselines

Defines the Python 3.11+, SQLite FTS5, `sqlite-vec`, and Bash toolchain baselines so local development and production deployments behave identically, preventing extension-loading or environment mismatches.

1. **Python & SQLite Baseline**: Targets Python 3.11+ with built-in `sqlite3` (FTS5 enabled) and optional `sqlite-vec` / `fastembed` vector acceleration in an isolated virtualenv (`~/.local/share/agent-memory/venv`).
2. **First-Party Package Procurement**: Dependencies declared in [pyproject.toml](../pyproject.toml) are installed exclusively from verified PyPI releases during [install.sh](../install.sh) provisioning.
3. **Executable Size & Permission Discipline**: [bin/agent-memory](../bin/agent-memory) remains under the `262,144`-byte `PreToolUse` inspection ceiling and enforces `0700` directory modes and `0600` regular-file modes on all database and telemetry files.
   - *Positive Exemplar*: `Keep bin/agent-memory within the 262,144-byte ceiling and provision dependencies in ~/.local/share/agent-memory/venv via ./install.sh.`
   - *Negative Exemplar*: `Exceed 262,144 bytes on bin/agent-memory or create world-readable SQLite database files.` (STRICTLY FORBIDDEN)

### Verification & Failure Recovery

Verifies script byte size, Python version, and SQLite FTS5 capabilities prior to deployment so runtime prerequisites hold, preventing startup failures.

- Run `./bin/agent-memory --version` and `bash install.sh --version` to verify clean CLI initialization.

---

## 2. Code Quality & Static Analysis Gates

Enforces static analysis, shell linting, docstring structure, and Markdown formatting across all repository files so defects are caught pre-commit, preventing broken builds or policy violations.

1. **Python & Shell Linters**: [bin/agent-memory](../bin/agent-memory), [benchmark/benchmark_comparison.py](../benchmark/benchmark_comparison.py), and [tests/test_agent_memory.py](../tests/test_agent_memory.py) must pass `ruff check` with zero warnings, and [install.sh](../install.sh) must pass `shellcheck` cleanly.
2. **Single-Line 3-Part Docstrings**: Every Python module, class, and function docstring must be a single line containing `" so "` and `", preventing "` with zero semicolons.
3. **4-Part H2 Markdown Structure**: [README.md](../README.md), [LLM_ONBOARDING.md](../LLM_ONBOARDING.md), [skill/SKILL.md](../skill/SKILL.md), [skill/references/agent-memory-mcp.md](../skill/references/agent-memory-mcp.md), and `docs/*.md` must pass `markdownlint` and follow the 4-part H2 skeleton.
   - *Positive Exemplar*: `Validate all Python, Bash, and Markdown edits with ruff check, shellcheck, and markdownlint before staging.`
   - *Negative Exemplar*: `Use multi-line docstrings, prose semicolons, smart quotes, or inline linter suppressions.` (STRICTLY FORBIDDEN)

### Verification & Failure Recovery

Runs static analysis across all Python, Bash, and Markdown files prior to commit so syntax and style defects are eliminated immediately, preventing CI or audit failures.

- Run `ruff check bin/agent-memory benchmark/ tests/ && shellcheck install.sh && markdownlint *.md skill/**/*.md docs/*.md` and fix any reported issue.

---

## 3. Testing Disciplines & Gate Sequence

Mandates hermetic unit and integration testing across CLI subcommands, JSON-RPC 2.0 MCP tools, symlink/hardlink guards, and installer workflows so every execution path is verified, preventing regressions.

1. **Comprehensive Unit & MCP Test Suite ([tests/test_agent_memory.py](../tests/test_agent_memory.py))**: Exercises `init`, `record`, `search`, `recall`, `relate`, `forget`, `gc`, `export`, `import`, `doctor`, stdio JSON-RPC `Content-Length` and JSONL framing, RRF ranking, and [install.sh](../install.sh) Tri-Stream contracts inside hermetic temporary directories.
2. **Adversarial Input & Hardlink Rejection**: Verifies that `--f` prefix abbreviations are rejected (`exit_code == 2`), hardlinked database/log/export files (`st_nlink > 1`) are refused, and `--log-dir` collisions with the database path fail closed.
3. **Benchmark CLI Verification**: Confirms [benchmark/benchmark_comparison.py](../benchmark/benchmark_comparison.py) honors `--validate-args`, `--dry-run`, `--json`, and `--log-dir`.
   - *Positive Exemplar*: `Run pytest tests/test_agent_memory.py in hermetic temporary directories with AGENT_MEMORY_ALLOW_NON_OPTANE=1.`
   - *Negative Exemplar*: `Mutate the live host memory database inside unit tests.` (STRICTLY FORBIDDEN)

### Verification & Failure Recovery

Executes the full `pytest` suite before every commit and release so functional or security regressions are caught immediately, preventing broken deployments.

- Run `pytest -q` and confirm `13 passed` before staging commits.

---

## 4. Documentation & Secret Hygiene Invariants

Binds `agent-memory-mcp` to clean-room secret redaction, Hard Isolation, and Docs-as-Code watermark tracking so code and documentation stay synchronized and credential-free, preventing secret leaks.

1. **7-Bit ASCII & Hard Isolation**: All source code, schemas, comments, docstrings, logs, commits, and documentation strictly use printable 7-bit ASCII (`0x20`-`0x7E`, `\n`, `\t`) with zero persona framing.
2. **Secret Scanning**: Every staged diff is scanned with `secret_scanner.py` prior to commit, and runtime inputs/outputs pass through `redact_secrets`.
3. **Docs-as-Code Parity**: Updates to CLI flags, MCP schemas, or storage tables must be accompanied by updates to `docs/` and synchronized via `doc_manager.py update --target . --advance`.
   - *Positive Exemplar*: `Scan staged diffs with secret_scanner.py and verify docs/ with doc_manager.py audit --target . before committing.`
   - *Negative Exemplar*: `Commit unredacted credentials or leave docs/.doc_state.json lagging behind HEAD.` (STRICTLY FORBIDDEN)

### Verification & Failure Recovery

Scans the repository for secrets and documentation drift before handoff so clean-room and Docs-as-Code invariants hold, preventing security incidents.

- Run `python3 ~/.gemini/config/skills/secret-hygiene/scripts/secret_scanner.py .` and `python3 ~/.gemini/config/skills/documentation-management/scripts/doc_manager.py audit --target .`.
