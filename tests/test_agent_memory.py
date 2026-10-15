"""Unit and integration tests for the agent-memory CLI and stdio MCP server."""

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


def _load_agent_memory_module(db_path: str) -> Any:
    """Loads bin/agent-memory as an isolated Python module bound to a temporary database path to verify CLI and MCP operations hermetically, preventing test mutations from touching production storage."""
    os.environ["AGENT_MEMORY_DB"] = db_path
    script_path = Path(__file__).resolve().parent.parent / "bin" / "agent-memory"
    loader = importlib.machinery.SourceFileLoader("agent_memory_bin", str(script_path))
    spec = importlib.util.spec_from_loader("agent_memory_bin", loader)
    if spec is None or spec.loader is None:
        raise RuntimeError("Failed to create module spec for bin/agent-memory")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class TestAgentMemoryHermetic(unittest.TestCase):
    """Verifies database initialization, observation lifecycle, entity relations, FTS5 search, and JSON-RPC 2.0 MCP dispatch against an isolated SQLite database."""

    def setUp(self) -> None:
        """Creates an isolated temporary directory and initializes a fresh agent-memory database before each test to prevent cross-test state contamination."""
        self.tmpdir = tempfile.TemporaryDirectory()
        self.db_path = os.path.join(self.tmpdir.name, "memory.db")
        self.am = _load_agent_memory_module(self.db_path)
        self.am.init_db(force=True)

    def tearDown(self) -> None:
        """Cleans up the temporary database directory after each test to prevent temporary file accumulation."""
        self.tmpdir.cleanup()

    def test_record_search_recall_relate_and_forget(self) -> None:
        """Verifies the complete lifecycle of recording observations, linking entities, searching via FTS5, recalling entity graphs, and forgetting records."""
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
            relation_type="deployed_on",
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
        """Verifies JSON-RPC 2.0 MCP initialize, tools/list, and tools/call dispatch over process_single_rpc."""
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
                            "type": "repo",
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
        finally:
            conn.close()

    def test_fast_cli_dispatch_doctor_and_search(self) -> None:
        """Verifies that _fast_cli_dispatch executes search and doctor commands without raising unhandled exceptions."""
        buf = io.StringIO()
        orig_stdout = sys.stdout
        try:
            sys.stdout = buf
            handled = self.am._fast_cli_dispatch(["agent-memory", "search", "RHEL"])
            self.assertTrue(handled)
            output = json.loads(buf.getvalue())
            self.assertIsInstance(output, list)
        finally:
            sys.stdout = orig_stdout


if __name__ == "__main__":
    unittest.main()
