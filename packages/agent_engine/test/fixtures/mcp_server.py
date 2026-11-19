#!/usr/bin/env python3
"""Kleiner MCP-Testserver: Streamable HTTP (JSON oder SSE-Antwort) und altes HTTP+SSE.
   /mcp          Streamable HTTP, Antwort als JSON
   /mcp-sse      Streamable HTTP, Antwort als text/event-stream
   /legacy/sse   altes Protokoll (GET = Strom, POST an /legacy/messages?sid=…)
   /secure       wie /mcp, verlangt Authorization: Bearer geheim"""
import json, queue, sys, threading, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

TOOLS = [
    {"name": "echo", "description": "Gibt den Text zurück.",
     "inputSchema": {"type": "object", "properties": {"text": {"type": "string", "description": "Text"}}, "required": ["text"]}},
    {"name": "add", "description": "Addiert zwei Zahlen.",
     "inputSchema": {"type": "object", "properties": {"a": {"type": "number"}, "b": {"type": "number"},
                     "note": {"type": "string", "description": "optional"}}, "required": ["a", "b"]}},
    {"name": "fail", "description": "Liefert immer einen Fehler.", "inputSchema": {"type": "object", "properties": {}}},
]
SESSIONS = set()
LEGACY = {}

def handle(msg):
    m = msg.get("method"); mid = msg.get("id")
    if mid is None:
        return None
    if m == "initialize":
        res = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "test", "version": "1"}}
    elif m == "tools/list":
        cur = (msg.get("params") or {}).get("cursor")
        res = {"tools": TOOLS[:2], "nextCursor": "p2"} if not cur else {"tools": TOOLS[2:]}
    elif m == "tools/call":
        p = msg["params"]; a = p.get("arguments", {})
        if p["name"] == "echo":
            res = {"content": [{"type": "text", "text": "echo: " + str(a.get("text"))}]}
        elif p["name"] == "add":
            res = {"content": [{"type": "text", "text": str(a["a"] + a["b"]) + (" " + a["note"] if "note" in a else "")}]}
        else:
            res = {"content": [{"type": "text", "text": "kaputt"}], "isError": True}
    else:
        return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "unbekannt"}}
    return {"jsonrpc": "2.0", "id": mid, "result": res}

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def do_GET(self):
        u = urlparse(self.path)
        if u.path != "/legacy/sse":
            self.send_response(405); self.end_headers(); return
        sid = uuid.uuid4().hex; q = queue.Queue(); LEGACY[sid] = q
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
        self.wfile.write(f"event: endpoint\ndata: /legacy/messages?sid={sid}\n\n".encode()); self.wfile.flush()
        while True:
            item = q.get()
            if item is None: break
            self.wfile.write(f"event: message\ndata: {json.dumps(item)}\n\n".encode()); self.wfile.flush()

    def do_POST(self):
        u = urlparse(self.path)
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        if u.path == "/legacy/messages":
            sid = parse_qs(u.query)["sid"][0]
            r = handle(body)
            self.send_response(202); self.end_headers(); self.wfile.write(b"Accepted")
            if r: LEGACY[sid].put(r)
            return
        if u.path not in ("/mcp", "/mcp-sse", "/secure"):
            self.send_response(404); self.end_headers(); return
        if u.path == "/secure" and self.headers.get("Authorization") != "Bearer geheim":
            self.send_response(401); self.end_headers(); return
        if body.get("method") != "initialize":
            if self.headers.get("Mcp-Session-Id") not in SESSIONS:
                self.send_response(400); self.end_headers(); self.wfile.write(b"no session"); return
        r = handle(body)
        if r is None:
            self.send_response(202); self.end_headers(); return
        self.send_response(200)
        if body.get("method") == "initialize":
            sid = uuid.uuid4().hex; SESSIONS.add(sid); self.send_header("Mcp-Session-Id", sid)
        if u.path == "/mcp-sse":
            self.send_header("Content-Type", "text/event-stream"); self.end_headers()
            self.wfile.write(b'event: message\ndata: {"jsonrpc":"2.0","method":"notifications/progress","params":{}}\n\n')
            self.wfile.write(f"event: message\ndata: {json.dumps(r)}\n\n".encode())
        else:
            out = json.dumps(r).encode()
            self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(out))); self.end_headers()
            self.wfile.write(out)

srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
