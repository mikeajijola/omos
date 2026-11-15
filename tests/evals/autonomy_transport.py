"""Local streaming proxy for a bounded, recorded model transport fault."""
import http.server
import json
import threading
import urllib.error
import urllib.request


def start(upstream, root, mode):
    state = {"mode": mode, "injected": 0}
    lock = threading.Lock()

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_POST(self):
            raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            body = json.loads(raw)
            names = {t.get("function", {}).get("name") for t in body.get("tools", [])}
            reviewer = "omos_contract_assessment" in names
            messages = body.get("messages", [])
            background = any("<omos_background_assignment" in str(m.get("content", "")) for m in messages if m.get("role") == "system")
            has_result = any(m.get("role") == "tool" for m in messages)
            eligible = reviewer if mode == "review" else background and has_result and not reviewer
            with lock:
                inject = eligible and state["injected"] < 2
                if inject:
                    state["injected"] += 1
                    (root / "transport-fault.json").write_text(json.dumps(state))
            if inject:
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                self.wfile.write(b'data: {"choices":[{"index":0,"delta":{"content":"Interrupted evaluation stream"},"finish_reason":null}]}\n\n')
                return
            headers = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "content-length", "connection")}
            request = urllib.request.Request(upstream.rstrip('/') + self.path, raw, headers)
            try:
                response = urllib.request.urlopen(request, timeout=300)
            except urllib.error.HTTPError as error:
                response = error
            try:
                self.send_response(response.status)
                self.send_header("Content-Type", response.headers.get("Content-Type", "application/json"))
                self.end_headers()
                while chunk := response.read1(8192):
                    self.wfile.write(chunk)
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                response.close()

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_port}"
