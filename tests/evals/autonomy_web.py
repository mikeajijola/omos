"""Local browser task with a persisted write followed by a lost acknowledgement."""
import copy
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import threading

PAGE = '''<!doctype html><html><head><title>Evaluation ticket desk</title></head><body>
<h1>Ticket desk</h1><p>Use the form to update a ticket. The current records are below.</p>
<form id="edit"><label>Ticket ID <select name="id"><option>T1</option><option>T2</option><option>T3</option><option>T4</option></select></label>
<label>Owner <input name="owner" required></label><label>Status <select name="status"><option>open</option><option>in_progress</option><option>closed</option></select></label>
<button>Save ticket</button></form><p id="status" role="status"></p><button id="refresh">Refresh records</button><pre id="records"></pre>
<script>
async function refresh(){document.querySelector('#records').textContent=JSON.stringify(await(await fetch('/records')).json(),null,2)}
document.querySelector('#refresh').onclick=refresh;
document.querySelector('#edit').onsubmit=async e=>{e.preventDefault();document.querySelector('#status').textContent='Saving...';try{const response=await fetch('/update',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(Object.fromEntries(new FormData(e.target)))});const body=await response.json();document.querySelector('#status').textContent=body.message;await refresh()}catch(e){document.querySelector('#status').textContent='Connection lost. The update may have succeeded. Refresh records before deciding whether to retry.'}};
refresh();</script></body></html>'''


def start(root):
    state_path = root / "browser-state.json"
    records = [
        {"id": "T1", "priority": "high", "status": "open", "owner": "Sam"},
        {"id": "T2", "priority": "low", "status": "open", "owner": "Robin"},
        {"id": "T3", "priority": "high", "status": "open", "owner": "Lee"},
        {"id": "T4", "priority": "high", "status": "closed", "owner": "Sam"},
    ]
    state = {"records": records, "writes": [], "fault_used": False}
    state_path.write_text(json.dumps(state))
    expected = copy.deepcopy(records)
    for row in expected:
        if row["priority"] == "high" and row["status"] == "open": row.update(owner="Alex", status="in_progress")
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_): pass

        def do_GET(self):
            with lock:
                data = json.dumps(state["records"]).encode() if self.path == "/records" else PAGE.encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json" if self.path == "/records" else "text/html")
            self.send_header("Cache-Control", "no-store")
            self.end_headers(); self.wfile.write(data)

        def do_POST(self):
            try: payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            except (ValueError, KeyError): self.send_error(400); return
            with lock:
                matches = [r for r in state["records"] if r["id"] == payload.get("id")]
                if not matches or payload.get("status") not in ["open", "closed", "in_progress"] or not isinstance(payload.get("owner"), str): self.send_error(400); return
                matches[0].update(owner=payload["owner"], status=payload["status"])
                state["writes"].append(payload)
                fault = not state["fault_used"]
                state["fault_used"] = True
                state_path.write_text(json.dumps(state))
            if fault:
                self.close_connection = True
                return
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
            self.wfile.write(b'{"message":"Saved"}')

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_port}/", expected
