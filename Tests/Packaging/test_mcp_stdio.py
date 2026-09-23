"""Exercise an installed StudioMCP helper as an interactive stdio client.

Run with SGS_MCP_BINARY=/absolute/path/to/StudioMCP python3 -m unittest
Tests/Packaging/test_mcp_stdio.py. The check intentionally keeps stdin open
while waiting for each reply; batched EOF tests cannot catch a blocking reader.
"""

import json
import os
import select
import subprocess
import unittest


class MCPInteractiveStdioTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("SGS_MCP_BINARY"), "Set SGS_MCP_BINARY to a built helper")
    def test_initialize_and_tool_discovery_reply_before_eof(self):
        process = subprocess.Popen(
            [os.environ["SGS_MCP_BINARY"]],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )

        def request(message):
            process.stdin.write(json.dumps(message) + "\n")
            process.stdin.flush()
            readable, _, _ = select.select([process.stdout], [], [], 5)
            self.assertTrue(readable, "StudioMCP did not reply while stdin remained open")
            return json.loads(process.stdout.readline())

        try:
            initialized = request({
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": {"protocolVersion": "2025-06-18", "clientInfo": {"name": "stdio-test", "version": "1"}},
            })
            self.assertEqual(initialized["result"]["protocolVersion"], "2025-06-18")
            process.stdin.write(json.dumps({
                "jsonrpc": "2.0", "method": "notifications/initialized", "params": {},
            }) + "\n")
            process.stdin.flush()
            discovered = request({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
            self.assertEqual(len(discovered["result"]["tools"]), 62)
        finally:
            process.stdin.close()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
            process.stdout.close()
            process.stderr.close()
        self.assertEqual(process.returncode, 0)


if __name__ == "__main__":
    unittest.main()
