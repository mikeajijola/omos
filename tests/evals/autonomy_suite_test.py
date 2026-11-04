"""Check evaluation oracles before spending live model calls."""
import http.client
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from autonomy_suite import setup, grade, dump, digest
from autonomy_web import start


class Oracles(unittest.TestCase):
    def test_transport_fault_is_bounded_and_does_not_cut_foreground_requests(self):
        from autonomy_transport import start as proxy
        import http.server
        import threading
        import urllib.request
        class Upstream(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_POST(self):
                self.rfile.read(int(self.headers["Content-Length"]))
                self.send_response(200); self.end_headers()
                self.wfile.write(b"data: [DONE]\n\n")
        upstream = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
        threading.Thread(target=upstream.serve_forever, daemon=True).start()
        try:
            for mode in ("execution", "review"):
                with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp)
                    server, url = proxy(f"http://127.0.0.1:{upstream.server_port}", root, mode)
                    def send(body):
                        with urllib.request.urlopen(urllib.request.Request(url+"/chat/completions", json.dumps(body).encode())) as response:
                            return response.read()
                    try:
                        self.assertIn(b"[DONE]", send({"messages": [{"role": "user", "content": "hello"}]}))
                        body = {"tools": [{"function": {"name": "omos_contract_assessment" if mode == "review" else "shell"}}], "messages": [{"role": "system", "content": "<omos_background_assignment>"}, {"role": "tool", "content": "receipt"}]}
                        self.assertNotIn(b"[DONE]", send(body))
                        self.assertNotIn(b"[DONE]", send(body))
                        self.assertIn(b"[DONE]", send(body))
                        self.assertEqual(json.loads((root / "transport-fault.json").read_text())["injected"], 2)
                    finally: server.shutdown(); server.server_close()
        finally: upstream.shutdown(); upstream.server_close()

    def test_structured_tasks_accept_reference_and_reject_wrong_output(self):
        for family, output in [("reconcile", "reconciled.json"), ("sql", "customer-revenue.json"), ("retrieval", "policy-answer.json"), ("schedule", "schedule.json"), ("archive", "import-manifest.json"), ("untrusted", "delivery.json")]:
            with self.subTest(family=family), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                _, expected = setup(family, root, 271)
                original = {str(p.relative_to(root)): digest(p) for p in root.rglob("*") if p.is_file()}
                value = expected
                if family == "sql":
                    sql = """WITH i AS (SELECT order_id,SUM(qty*unit_cents) AS n FROM items GROUP BY order_id), r AS (SELECT order_id,SUM(amount_cents) AS n FROM refunds GROUP BY order_id) SELECT c.id,COALESCE(SUM(i.n-COALESCE(r.n,0)),0) FROM customers c LEFT JOIN orders o ON o.customer_id=c.id AND o.status='paid' LEFT JOIN i ON i.order_id=o.id LEFT JOIN r ON r.order_id=o.id GROUP BY c.id ORDER BY c.id"""
                    (root / "documents").mkdir()
                    (root / "documents/revenue.sql").write_text(sql)
                elif family == "retrieval": value = {**expected, "exception": "Retain incident evidence under legal hold until release."}
                elif family == "schedule": value = [{"id": name, "worker": worker, "start": a, "end": b} for name, worker, a, b in [("A", "X", 0, 3), ("B", "Y", 0, 2), ("C", "X", 3, 7), ("D", "Y", 2, 5), ("E", "X", 7, 9), ("F", "X", 9, 10)]]
                elif family == "archive":
                    import zipfile
                    with zipfile.ZipFile(root / "bundle.zip") as z: z.extractall(root / "documents/imported")
                    value = [{"path": name, "sha256": sha, "bytes": (root / "documents/imported" / name).stat().st_size} for name, sha in expected.items()]
                dump(root / "documents" / output, value)
                self.assertEqual(grade(family, root, expected, original), [])
                dump(root / "documents" / output, {})
                self.assertTrue(grade(family, root, expected, original))

    def test_reconciliation_rejects_correct_values_under_a_renamed_field(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); _, expected = setup("reconcile", root, 941)
            renamed = dict(expected)
            renamed["sorted_paid_ids"] = renamed.pop("paid_ids")
            dump(root / "documents/reconciled.json", renamed)
            self.assertTrue(grade("reconcile", root, expected, {}))
            dump(root / "documents/reconciled.json", expected)
            self.assertEqual(grade("reconcile", root, expected, {}), [])

    def test_repair_oracle_catches_original_nested_interval_bug(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); _, expected = setup("repair", root, 271)
            self.assertTrue(grade("repair", root, expected, {}))
            (root / "intervals.py").write_text("def merge_intervals(a):\n if any(x>y for x,y in a):raise ValueError()\n out=[]\n for x,y in sorted(a):\n  if x==y:continue\n  if out and x<=out[-1][1]:out[-1][1]=max(out[-1][1],y)\n  else:out.append([x,y])\n return out\n")
            self.assertEqual(grade("repair", root, expected, {}), [])
            tests = root / "test_intervals.py"
            original = {"test_intervals.py": digest(tests)}
            tests.write_text(tests.read_text() + "\nclass MoreTests(unittest.TestCase):\n def test_touching(self): self.assertEqual(merge_intervals([[1,2],[2,3]]),[[1,3]])\n")
            self.assertEqual(grade("repair", root, expected, original), [])
            tests.write_text(tests.read_text().replace("self.assertEqual(merge_intervals([]),[])", "self.assertTrue(True)"))
            self.assertTrue(grade("repair", root, expected, original))

    def test_web_fault_persists_exactly_one_write_before_ack_loss(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); server, _, _ = start(root)
            try:
                con = http.client.HTTPConnection("127.0.0.1", server.server_port)
                con.request("POST", "/update", json.dumps({"id": "T1", "owner": "Alex", "status": "in_progress"}), {"Content-Type": "application/json"})
                with self.assertRaises(http.client.RemoteDisconnected): con.getresponse()
                state = json.loads((root / "browser-state.json").read_text())
                self.assertEqual(len(state["writes"]), 1)
                self.assertEqual(state["records"][0]["owner"], "Alex")
                self.assertEqual(state["records"][1]["owner"], "Robin")
            finally: server.shutdown(); server.server_close()


if __name__ == "__main__": unittest.main()
