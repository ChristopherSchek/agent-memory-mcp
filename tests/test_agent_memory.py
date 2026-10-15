"""Executes hermetic unit and integration tests for the agent-memory CLI and stdio MCP server to validate database lifecycle, FTS5 search, and JSON-RPC 2.0 protocol compliance, preventing regressions from corrupting production memory stores."""

import importlib.machinery
import importlib.util
import io
import json
import os
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
    """Loads bin/agent-memory as an isolated Python module bound to a temporary database path to verify CLI and MCP operations hermetically, preventing test mutations from touching production storage."""
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
    """Verifies database initialization, observation lifecycle, entity relations, FTS5 search, and JSON-RPC 2.0 MCP dispatch against an isolated SQLite database to confirm end-to-end behavioral fidelity, preventing schema or protocol drift from breaking client sessions."""

    def setUp(self) -> None:
        """Snapshots environment variables, creates an isolated temporary directory, and initializes a fresh agent-memory database before each test to prevent cross-test state contamination."""
        self._saved_env = {k: os.environ.get(k) for k in _ENV_KEYS}
        self.tmpdir = tempfile.TemporaryDirectory()
        self.db_path = os.path.join(self.tmpdir.name, "memory.db")
        self.am = _load_agent_memory_module(self.db_path)
        self.am.init_db(force=True)

    def tearDown(self) -> None:
        """Cleans up the temporary database directory and restores environment variables after each test to prevent temporary file accumulation or environment leakage."""
        self.tmpdir.cleanup()
        for k, val in self._saved_env.items():
            if val is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = val

    def test_record_search_recall_relate_and_forget(self) -> None:
        """Verifies the complete lifecycle of recording observations, linking entities, searching via FTS5, recalling entity graphs, and forgetting records to confirm CRUD and cascade invariants, preventing orphaned records or search desynchronization."""
        rec = self.am.record_observation(
            content="Host sg-antigravity-pd1 runs RHEL 10 with Kernel 6.12.",
            entity_name="sg-antigravity-pd1",
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

        rel = self.am.relate_entities(
            source_name="agent-baseline",
            target_name="sg-antigravity-pd1",
            relation_type="deploys_to",
            weight=1.0,
        )
        self.assertEqual(rel.get("status"), "success")

        search_res = self.am.search_memory(query="RHEL 10", category="architecture")
        self.assertIsInstance(search_res, list)
        self.assertGreaterEqual(len(search_res), 1)

        recall_res = self.am.recall_entity(name="sg-antigravity-pd1")
        self.assertEqual(recall_res["name"], "sg-antigravity-pd1")
        self.assertEqual(len(recall_res["observations"]), 1)

        forget_res = self.am.forget_memory(observation_id=obs_id)
        self.assertEqual(forget_res.get("status"), "success")
        self.assertEqual(forget_res.get("deleted_observations"), 1)

    def test_mcp_jsonrpc_lifecycle(self) -> None:
        """Verifies JSON-RPC 2.0 MCP initialize, tools/list, and tools/call dispatch over process_single_rpc to ensure protocol compliance, preventing malformed envelopes or duplicate alias ambiguity from corrupting MCP state."""
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

            dup_resp = self.am.process_single_rpc(
                {
                    "jsonrpc": "2.0",
                    "id": 4,
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
        """Verifies that run_doctor and _fast_cli_dispatch execute health diagnostics and FTS5 search commands cleanly, preventing CLI dispatch regressions from breaking health checks."""
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
        """Verifies secret screening, 7-bit ASCII and Hard Isolation enforcement, bounded integer parsing, and orphan stub entity pruning to prevent secret leaks, schema pollution, or invalid parameter coercion."""
        self.assertIsNotNone(self.am._screen_for_secrets("my_api_key=" + ("a" * 16)))
        self.assertIsNotNone(self.am._screen_for_secrets("Non-ASCII byte " + chr(0x2014) + " test"))
        self.assertIsNotNone(self.am._screen_for_secrets("*Stage direction action* in technical record"))
        self.assertIsNone(self.am._screen_for_secrets("api_key=<REDACTED>", "password=${DB_PASS}"))

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

    def test_cli_normalization_and_inline_category(self) -> None:
        """Verifies CLI flag normalization for hyphen-prefixed positionals and attached short options alongside inline category extraction, preventing malformed CLI argv or FTS5 syntax errors."""
        norm = self.am._normalize_cli_argv(["agent-memory", "record", "-e", "ent1", "-n", "--flag-text"])
        self.assertIn("--flag-text", norm)
        norm_short = self.am._normalize_cli_argv(["agent-memory", "record", "content", "-a{\"k\":1}"])
        self.assertEqual(norm_short, ["agent-memory", "record", "-a{\"k\":1}", "content"])

        q, cat, err = self.am._extract_inline_category("foo AND category:decision")
        self.assertIsNone(err)
        self.assertEqual(cat, "decision")
        self.assertEqual(q, "foo")


if __name__ == "__main__":
    unittest.main()
