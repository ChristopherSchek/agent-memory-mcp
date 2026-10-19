# Copyright (c) 2026 Christopher Schek
# SPDX-License-Identifier: GPL-3.0-only
"""Executes hermetic unit and integration tests for the agent-memory CLI and stdio MCP server so database lifecycle, FTS5 search, and JSON-RPC 2.0 protocol compliance are verified, preventing regressions from corrupting production memory stores."""

import importlib.machinery
import importlib.util
import io
import json
import os
import signal
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

_ENV_KEYS = (
    "AGENT_MEMORY_DB",
    "ALLOW_NON_OPTANE",
    "AGENT_MEMORY_NO_CFG_FALLBACK",
    "OPTANE_BASE",
    "AGENT_MEMORY_SYNC",
)


def _load_agent_memory_module(db_path: str) -> Any:
    """Loads bin/agent-memory as an isolated Python module bound to a temporary database path so CLI and MCP operations are verified hermetically, preventing test mutations from touching production storage."""
    os.environ["AGENT_MEMORY_DB"] = db_path
    os.environ["ALLOW_NON_OPTANE"] = "1"
    os.environ["AGENT_MEMORY_NO_CFG_FALLBACK"] = "1"
    os.environ.pop("OPTANE_BASE", None)
    script_path = Path(__file__).resolve().parent.parent / "bin" / "agent-memory"
    loader = importlib.machinery.SourceFileLoader("agent_memory_bin", str(script_path))
    spec = importlib.util.spec_from_loader("agent_memory_bin", loader)
    if spec is None or spec.loader is None:
        raise RuntimeError("Failed to create module spec for bin/agent-memory")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class TestAgentMemoryHermetic(unittest.TestCase):
    """Verifies database initialization, observation lifecycle, entity relations, FTS5 search, and JSON-RPC 2.0 MCP dispatch against an isolated SQLite database so end-to-end behavioral fidelity is confirmed, preventing schema or protocol drift from breaking client sessions."""

    def setUp(self) -> None:
        """Snapshots environment variables, creates an isolated temporary directory, and initializes a fresh agent-memory database before each test so test runs start from a clean state, preventing cross-test state contamination."""
        self._saved_env = {k: os.environ.get(k) for k in _ENV_KEYS}
        self.tmpdir = tempfile.TemporaryDirectory()
        self.db_path = os.path.join(self.tmpdir.name, "memory.db")
        self.am = _load_agent_memory_module(self.db_path)
        self.am.init_db(force=True)

    def tearDown(self) -> None:
        """Cleans up the temporary database directory and restores environment variables after each test so host state remains unmodified, preventing temporary file accumulation or environment leakage."""
        self.tmpdir.cleanup()
        for k, val in self._saved_env.items():
            if val is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = val

    def test_record_search_recall_relate_and_forget(self) -> None:
        """Verifies the complete lifecycle of recording observations, linking entities, searching via FTS5, recalling entity graphs, and forgetting records so CRUD and cascade invariants are confirmed, preventing orphaned records or search desynchronization."""
        rec = self.am.record_observation(
            content="Host linux-host-01 runs RHEL 10 with Kernel 6.12.",
            entity_name="linux-host-01",
            entity_type="host",
            summary="Primary bare-metal RHEL 10 host",
            category="architecture",
            tags="rhel10,bare-metal",
            confidence=1.0,
            session_id="test-session",
        )
        self.assertEqual(rec.get("status"), "success")
        obs_id = rec.get("observation_id")
        self.assertTrue(obs_id)

        dup = self.am.record_observation(
            content="Host linux-host-01 runs RHEL 10 with Kernel 6.12.",
            entity_name="linux-host-01",
            entity_type="host",
            category="architecture",
        )
        self.assertEqual(dup.get("status"), "exists")
        self.assertEqual(dup.get("observation_id"), obs_id)

        rel = self.am.relate_entities(
            source_name="core-platform",
            target_name="linux-host-01",
            relation_type="deploys_to",
            weight=1.0,
        )
        self.assertEqual(rel.get("status"), "success")

        search_res = self.am.search_memory(query="RHEL 10", category="architecture")
        self.assertIsInstance(search_res, list)
        self.assertGreaterEqual(len(search_res), 1)

        recall_res = self.am.recall_entity(name="linux-host-01")
        self.assertEqual(recall_res["name"], "linux-host-01")
        self.assertEqual(len(recall_res["observations"]), 1)

        forget_res = self.am.forget_memory(observation_id=obs_id)
        self.assertEqual(forget_res.get("status"), "success")
        self.assertEqual(forget_res.get("deleted_observations"), 1)
        self.assertEqual(self.am.search_memory(query="RHEL 10", category="architecture"), [])

        ent_forget = self.am.forget_memory(entity="linux-host-01")
        self.assertEqual(ent_forget.get("status"), "success")
        self.assertEqual(ent_forget.get("deleted_entity"), "linux-host-01")
        self.assertEqual(ent_forget.get("deleted_observations"), 0)
        self.assertEqual(ent_forget.get("deleted_relations"), 1)
        self.assertIn("error", self.am.recall_entity("linux-host-01"))
        self.assertIn("error", self.am.recall_entity("core-platform"))

    def test_mcp_jsonrpc_lifecycle(self) -> None:
        """Verifies JSON-RPC 2.0 MCP initialize, tools/list, and tools/call dispatch across all five tools over process_single_rpc so protocol compliance is enforced, preventing malformed envelopes or duplicate alias ambiguity from corrupting MCP state."""
        conn = self.am.get_connection()
        try:
            init_resp = self.am.process_single_rpc(
                {
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "initialize",
                    "params": {"protocolVersion": "2024-11-05"},
                },
                conn,
                self.am.TOOLS,
            )
            self.assertIsNotNone(init_resp)
            init_data = json.loads(str(init_resp))
            self.assertEqual(init_data["id"], 1)
            self.assertIn("protocolVersion", init_data["result"])

            list_resp = self.am.process_single_rpc(
                {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
                conn,
                self.am.TOOLS,
            )
            list_data = json.loads(str(list_resp))
            tool_names = {t["name"] for t in list_data["result"]["tools"]}
            self.assertEqual(
                tool_names,
                {"memory_record", "memory_search", "memory_recall", "memory_relate", "memory_forget"},
            )

            call_resp = self.am.process_single_rpc(
                {
                    "jsonrpc": "2.0",
                    "id": 3,
                    "method": "tools/call",
                    "params": {
                        "name": "memory_record",
                        "arguments": {
                            "content": "MCP protocol verification observation",
                            "entity": "agent-memory-mcp",
                            "entity_type": "repo",
                            "category": "invariant",
                        },
                    },
                },
                conn,
                self.am.TOOLS,
            )
            call_data = json.loads(str(call_resp))
            self.assertFalse(call_data["result"]["isError"])
            payload = json.loads(call_data["result"]["content"][0]["text"])
            self.assertEqual(payload["status"], "success")
            obs_id = payload["observation_id"]

            rel_resp = self.am.process_single_rpc(
                {
                    "jsonrpc": "2.0",
                    "id": 4,
                    "method": "tools/call",
                    "params": {
                        "name": "memory_relate",
                        "arguments": {
                            "source": "agent-memory-mcp",
                            "target": "sqlite-fts5",
                            "relation_type": "depends_on",
                        },
                    },
                },
                conn,
                self.am.TOOLS,
            )
            rel_data = json.loads(str(rel_resp))
            self.assertFalse(rel_data["result"]["isError"])
            self.assertEqual(json.loads(rel_data["result"]["content"][0]["text"])["status"], "success")

            search_resp = self.am.process_single_rpc(
                {
                    "jsonrpc": "2.0",
                    "id": 5,
                    "method": "tools/call",
                    "params": {
                        "name": "memory_search",
                        "arguments": {"query": "protocol verification", "category": "invariant"},
                    },
                },
                conn,
                self.am.TOOLS,
            )
            search_data = json.loads(str(search_resp))
            self.assertFalse(search_data["result"]["isError"])
            hits = json.loads(search_data["result"]["content"][0]["text"])
            self.assertEqual(len(hits), 1)
            self.assertEqual(hits[0]["observation_id"], obs_id)

            recall_resp = self.am.process_single_rpc(
                {
                    "jsonrpc": "2.0",
                    "id": 6,
                    "method": "tools/call",
                    "params": {
                        "name": "memory_recall",
                        "arguments": {"entity": "agent-memory-mcp"},
                    },
                },
                conn,
                self.am.TOOLS,
            )
            recall_data = json.loads(str(recall_resp))
            self.assertFalse(recall_data["result"]["isError"])
            recalled = json.loads(recall_data["result"]["content"][0]["text"])
            self.assertEqual(recalled["name"], "agent-memory-mcp")
            self.assertEqual(len(recalled["outgoing_relations"]), 1)

            forget_resp = self.am.process_single_rpc(
                {
                    "jsonrpc": "2.0",
                    "id": 7,
                    "method": "tools/call",
                    "params": {
                        "name": "memory_forget",
                        "arguments": {"observation_id": obs_id},
                    },
                },
                conn,
                self.am.TOOLS,
            )
            forget_data = json.loads(str(forget_resp))
            self.assertFalse(forget_data["result"]["isError"])
            self.assertEqual(json.loads(forget_data["result"]["content"][0]["text"])["deleted_observations"], 1)

            dup_resp = self.am.process_single_rpc(
                {
                    "jsonrpc": "2.0",
                    "id": 8,
                    "method": "tools/call",
                    "params": {
                        "name": "memory_record",
                        "arguments": {
                            "content": "Conflicting alias test",
                            "entity": "agent-memory-mcp",
                            "entity_type": "repo",
                            "type": "service",
                        },
                    },
                },
                conn,
                self.am.TOOLS,
            )
            dup_data = json.loads(str(dup_resp))
            self.assertTrue(dup_data["result"]["isError"])
        finally:
            conn.close()

    def test_fast_cli_dispatch_doctor_and_search(self) -> None:
        """Verifies that run_doctor and _fast_cli_dispatch execute health diagnostics and FTS5 search commands cleanly so fast-path CLI routing remains reliable, preventing CLI dispatch regressions from breaking health checks."""
        doc_buf = io.StringIO()
        orig_stdout = sys.stdout
        try:
            sys.stdout = doc_buf
            with self.assertRaises(SystemExit) as cm:
                self.am.run_doctor()
            self.assertEqual(cm.exception.code, 0)
            doc_out = json.loads(doc_buf.getvalue())
            self.assertTrue(doc_out.get("healthy"))
        finally:
            sys.stdout = orig_stdout

        buf = io.StringIO()
        try:
            sys.stdout = buf
            handled = self.am._fast_cli_dispatch(["agent-memory", "search", "RHEL"])
            self.assertTrue(handled)
            output = json.loads(buf.getvalue())
            self.assertIsInstance(output, list)
        finally:
            sys.stdout = orig_stdout

    def test_security_and_validation_guards(self) -> None:
        """Verifies secret screening, 7-bit ASCII and clinical prose enforcement, bounded integer parsing, and orphan stub entity pruning so input validation gates hold firm, preventing secret leaks, schema pollution, or invalid parameter coercion."""
        self.assertIsNotNone(self.am._screen_for_secrets("my_api_key=" + ("a" * 16)))
        self.assertIsNotNone(self.am._screen_for_secrets("pass" + "word=" + "'example-prod-val-9999'"))
        self.assertIsNotNone(self.am._screen_for_secrets("sec" + "ret = " + '"my val with spaces"'))
        self.assertIsNotNone(self.am._screen_for_secrets("AGE-SECRET-KEY-1" + ("Q" * 58)))
        self.assertIsNotNone(self.am._screen_for_secrets("Non-ASCII byte " + chr(0x2014) + " test"))
        self.assertIsNotNone(self.am._screen_for_secrets("Carriage return\rin input"))
        self.assertIsNotNone(self.am._screen_for_secrets("*Stage direction action* in technical record"))
        self.assertIsNotNone(self.am._screen_for_secrets("First line\n*Stage direction action* on second line"))
        self.assertIsNone(self.am._screen_for_secrets("api_key=<REDACTED>", "password=${DB_PASS}", 'password="redacted"'))

        c0_attr = self.am.record_observation(
            content="Valid content",
            entity_name="c0-test",
            attributes={"bad": "val\x07bell"},
        )
        self.assertIn("error", c0_attr)

        val, err = self.am._parse_bounded_int(3.9, "limit", 1, 100)
        self.assertIsNone(val)
        self.assertIsNotNone(err)

        empty_ent = self.am.record_observation(content="Valid content", entity_name="   ")
        self.assertIn("error", empty_ent)
        empty_cat = self.am.record_observation(content="Valid content", category="   ")
        self.assertIn("error", empty_cat)

        rel = self.am.relate_entities("stub-src", "stub-dst", "depends_on")
        self.assertEqual(rel.get("status"), "success")
        del_rel = self.am.forget_memory(
            source="stub-src", target="stub-dst", relation_type="depends_on"
        )
        self.assertEqual(del_rel.get("deleted_relations"), 1)
        self.assertIn("error", self.am.recall_entity("stub-src"))
        self.assertIn("error", self.am.recall_entity("stub-dst"))

    def test_json_merge_patch_and_post_merge_bounds(self) -> None:
        """Verifies RFC 7396 JSON Merge Patch key deletion, empty-object no-op semantics, and post-merge 4000-character bounds on entity attributes and relation metadata so attribute updates stay bounded, preventing unbounded JSON growth."""
        r1 = self.am.record_observation(
            content="Initial entity attributes",
            entity_name="merge-ent",
            attributes={"k1": "v1", "k2": "v2"},
        )
        self.assertEqual(r1.get("status"), "success")
        r2 = self.am.record_observation(
            content="Remove k1 and preserve k2",
            entity_name="merge-ent",
            attributes={"k1": None, "k3": "x" * 3000},
        )
        self.assertEqual(r2.get("status"), "success")
        recalled = self.am.recall_entity("merge-ent")
        self.assertNotIn("k1", recalled["attributes"])
        self.assertEqual(recalled["attributes"]["k2"], "v2")

        r_overflow = self.am.record_observation(
            content="Overflow attributes after merge",
            entity_name="merge-ent",
            attributes={"k4": "y" * 2000},
        )
        self.assertIn("error", r_overflow)
        self.assertIn("exceeds 4000 characters after merge", r_overflow["error"])

        rel1 = self.am.relate_entities(
            "merge-ent", "target-ent", "depends_on", metadata={"m1": "a" * 3000}
        )
        self.assertEqual(rel1.get("status"), "success")
        rel_overflow = self.am.relate_entities(
            "merge-ent", "target-ent", "depends_on", metadata={"m2": "b" * 2000}
        )
        self.assertIn("error", rel_overflow)
        self.assertIn("exceeds 4000 characters after merge", rel_overflow["error"])

    def test_recall_truncation_flags_and_fts_underscores(self) -> None:
        """Verifies recall_entity truncation flags (has_more_*) and FTS5 underscore/quote sanitization so pagination and search tokenization remain accurate, preventing silent recall truncation or punctuation-induced zero-hit searches."""
        for idx in range(3):
            self.am.record_observation(
                content=f"Fact number {idx} for trunc-ent",
                entity_name="trunc-ent",
            )
            self.am.relate_entities("trunc-ent", f"out-{idx}", "references")
            self.am.relate_entities(f"in-{idx}", "trunc-ent", "references")

        rec = self.am.recall_entity("trunc-ent", limit=2, relation_limit=2)
        self.assertTrue(rec["has_more_observations"])
        self.assertEqual(len(rec["observations"]), 2)
        self.assertTrue(rec["has_more_outgoing_relations"])
        self.assertEqual(len(rec["outgoing_relations"]), 2)
        self.assertTrue(rec["has_more_incoming_relations"])
        self.assertEqual(len(rec["incoming_relations"]), 2)

        self.assertEqual(self.am.sanitize_fts_query("_"), '""')
        self.assertEqual(self.am.sanitize_fts_query('"___"'), '""')
        hits = self.am.search_memory(query="Fact _ number")
        self.assertIsInstance(hits, list)
        self.assertGreaterEqual(len(hits), 1)

    def test_mcp_schema_and_instructions_bundle_parity(self) -> None:
        """Verifies that mcp/*.json and mcp/instructions.md match TOOLS and MCP_INSTRUCTIONS in bin/agent-memory so client tool definitions stay synchronized, preventing schema drift between lazy MCP files and the stdio server."""
        repo_root = Path(__file__).resolve().parent.parent
        mcp_dir = repo_root / "mcp"
        self.assertEqual((mcp_dir / "instructions.md").read_text(encoding="utf-8"), self.am.MCP_INSTRUCTIONS)
        for tool_def in self.am.TOOLS:
            schema_file = mcp_dir / f"{tool_def['name']}.json"
            self.assertTrue(schema_file.is_file(), f"Missing {schema_file}")
            disk_def = json.loads(schema_file.read_text(encoding="utf-8"))
            self.assertEqual(disk_def["name"], tool_def["name"])
            self.assertEqual(disk_def["description"], tool_def["description"])
            self.assertEqual(disk_def.get("parameters", disk_def.get("inputSchema")), tool_def["inputSchema"])

    def test_orphan_sidecar_and_empty_ro_guards(self) -> None:
        """Verifies that get_connection rejects pre-existing orphan sidecars when creating a new DB and refuses to initialize 0-byte empty databases on read-only opens so database open invariants hold, preventing sidecar adoption or read-only disk mutation."""
        orphan_db = os.path.join(self.tmpdir.name, "orphan.db")
        with open(orphan_db + "-wal", "wb") as f:
            f.write(b"stale wal")
        self.am.DB_PATH = orphan_db
        self.am._RAW_DB_PATH = orphan_db
        with self.assertRaises(RuntimeError) as cm:
            self.am.get_connection()
        self.assertIn("sidecar", str(cm.exception))

        empty_db = os.path.join(self.tmpdir.name, "empty.db")
        with open(empty_db, "wb"):
            pass
        os.chmod(empty_db, 0o600)
        self.am.DB_PATH = empty_db
        self.am._RAW_DB_PATH = empty_db
        with self.assertRaises(RuntimeError) as cm2:
            self.am.get_connection(read_only=True)
        self.assertIn("uninitialized", str(cm2.exception))
        self.assertEqual(os.path.getsize(empty_db), 0)

    def test_cli_normalization_and_inline_category(self) -> None:
        """Verifies CLI flag normalization for hyphen-prefixed positionals and attached short options alongside inline category extraction so CLI arguments parse predictably, preventing malformed CLI argv or FTS5 syntax errors."""
        norm = self.am._normalize_cli_argv(["agent-memory", "record", "-e", "ent1", "-n", "--flag-text"])
        self.assertEqual(norm, ["agent-memory", "record", "-e", "ent1", "-n", "--", "--flag-text"])
        norm_short = self.am._normalize_cli_argv(["agent-memory", "record", "content", "-a{\"k\":1}"])
        self.assertEqual(norm_short, ["agent-memory", "record", "-a{\"k\":1}", "content"])

        q, cat, err = self.am._extract_inline_category("foo AND category:decision")
        self.assertIsNone(err)
        self.assertEqual(cat, "decision")
        self.assertEqual(q, "foo")

        q2, cat2, err2 = self.am._extract_inline_category('"escaped "" quote" category:invariant')
        self.assertIsNone(err2)
        self.assertEqual(cat2, "invariant")
        self.assertEqual(q2, '"escaped "" quote"')

    def test_security_and_protocol_regression_contracts(self) -> None:
        """Verifies plain-text backslash acceptance, NUL and nested attribute secret/prose rejection, symlink and 0-byte DB guards, read-only non-mutation, signal handler restoration, and backup/restore MCP inode hot-swap so security and lifecycle contracts hold, preventing validation bypasses or stale file descriptors."""
        ok_regex = self.am.record_observation(
            content=r"Validate regex \bword\b and \Bnon-boundary in C:\repos\bin",
            entity_name="regex-ent",
        )
        self.assertEqual(ok_regex.get("status"), "success")

        nul_obs = self.am.record_observation(
            content="Null\x00byte in content",
            entity_name="nul-ent",
        )
        self.assertIn("error", nul_obs)

        attr_sec = self.am.record_observation(
            content="Valid content",
            entity_name="attr-sec-ent",
            attributes={"cfg": "sec" + 'ret = "my val with spaces"'},
        )
        self.assertIn("error", attr_sec)

        attr_prose = self.am.record_observation(
            content="Valid content",
            entity_name="attr-prose-ent",
            attributes={"note": "*Stage direction action*"},
        )
        self.assertIn("error", attr_prose)

        tag_prose = self.am.record_observation(
            content="Valid content",
            entity_name="tag-prose-ent",
            tags=["*Stage direction action*"],
        )
        self.assertIn("error", tag_prose)

        meta_prose = self.am.relate_entities(
            "src-ent",
            "dst-ent",
            "depends_on",
            metadata={"note": "*Stage direction action*"},
        )
        self.assertIn("error", meta_prose)

        with self.assertRaises(RuntimeError):
            self.am._check_not_guarded_path(
                os.path.join("~", "." + "ssh", "memory.db"), "DB_PATH"
            )

        self.assertFalse(
            self.am._fast_cli_dispatch(["agent-memory", "search", "-l=5", "RHEL"])
        )
        self.assertFalse(
            self.am._fast_cli_dispatch(["agent-memory", "record", "first", "--", "second"])
        )
        norm_forget = self.am._normalize_cli_argv(
            ["agent-memory", "forget", "extra", "-o", "obs-1"]
        )
        self.assertEqual(norm_forget[:3], ["agent-memory", "forget", "-o"])

        zero_orphan = os.path.join(self.tmpdir.name, "zero_orphan.db")
        with open(zero_orphan, "wb"):
            pass
        os.chmod(zero_orphan, 0o600)
        with open(zero_orphan + "-wal", "wb") as f:
            f.write(b"orphan wal")
        os.chmod(zero_orphan + "-wal", 0o600)
        self.am.DB_PATH = zero_orphan
        self.am._RAW_DB_PATH = zero_orphan
        with self.assertRaises(RuntimeError) as cm_zo:
            self.am.get_connection()
        self.assertIn("sidecar", str(cm_zo.exception))

        sym_target = os.path.join(self.tmpdir.name, "sym_subdir", "real.db")
        sym_link = os.path.join(self.tmpdir.name, "link.db")
        os.symlink(sym_target, sym_link)
        self.am._RAW_DB_PATH = sym_link
        self.am.DB_PATH = os.path.realpath(sym_link)
        conn = self.am.get_connection()
        self.am.init_db(conn)
        conn.close()
        self.assertTrue(os.path.isfile(sym_target))

        os.chmod(sym_target, 0o644)
        ro_conn = self.am.get_connection(read_only=True)
        ro_conn.close()
        self.assertEqual(os.stat(sym_target).st_mode & 0o777, 0o644)
        os.chmod(sym_target, 0o600)
        os.chmod(os.path.dirname(sym_target), 0o700)

        self.am.record_observation(content="Before backup", entity_name="bak-ent")
        bak_path = os.path.join(self.tmpdir.name, "backup.db")
        orig_stdout = sys.stdout
        orig_argv = sys.argv
        try:
            sys.stdout = io.StringIO()
            sys.argv = ["agent-memory", "backup", bak_path]
            self.am.main()
        finally:
            sys.stdout = orig_stdout
            sys.argv = orig_argv

        conn_holder = [None]
        err_holder = [None]
        try:
            r1 = self.am.process_single_rpc(
                {
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "tools/call",
                    "params": {"name": "memory_recall", "arguments": {"entity": "bak-ent"}},
                },
                conn_holder[0],
                self.am.TOOLS,
                conn_holder=conn_holder,
                err_holder=err_holder,
            )
            self.assertFalse(json.loads(str(r1))["result"].get("isError"))
            self.am.record_observation(content="After backup", entity_name="post-bak-ent")
            try:
                sys.stdout = io.StringIO()
                sys.argv = ["agent-memory", "restore", bak_path]
                self.am.main()
            finally:
                sys.stdout = orig_stdout
                sys.argv = orig_argv
            r2 = self.am.process_single_rpc(
                {
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "tools/call",
                    "params": {
                        "name": "memory_recall",
                        "arguments": {"entity": "post-bak-ent"},
                    },
                },
                conn_holder[0],
                self.am.TOOLS,
                conn_holder=conn_holder,
                err_holder=err_holder,
            )
            self.assertTrue(json.loads(str(r2))["result"].get("isError"))
        finally:
            if conn_holder[0] is not None:
                conn_holder[0].close()

        prev_int = signal.getsignal(signal.SIGINT)
        prev_term = signal.getsignal(signal.SIGTERM)
        try:
            sys.stdout = io.StringIO()
            sys.argv = ["agent-memory", "benchmark", "-n", "2"]
            self.am.main()
        finally:
            sys.stdout = orig_stdout
            sys.argv = orig_argv
        self.assertEqual(signal.getsignal(signal.SIGINT), prev_int)
        self.assertEqual(signal.getsignal(signal.SIGTERM), prev_term)


if __name__ == "__main__":
    unittest.main()


