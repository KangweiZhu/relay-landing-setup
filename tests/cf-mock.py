#!/usr/bin/env python3
"""测试用的假 Cloudflare API + 假"查公网 IP"服务。

  cf-mock.py <端口> <状态目录>
状态目录里：ip1 / ip2 是两个 IP 来源返回的内容，puts.log 记录每次 PUT 的请求体。
只认 KEY=testkey、EMAIL=me@example.com，zone kz7.site，A 记录 ddns.kz7.site。
"""
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

PORT, STATE = int(sys.argv[1]), sys.argv[2]
ZONE_ID, RECORD_ID = "a" * 32, "b" * 32

def read(name):
    with open(os.path.join(STATE, name)) as f:
        return f.read()

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def send(self, code, body):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code); self.end_headers(); self.wfile.write(data)

    def authed(self):
        if self.headers.get("X-Auth-Key") == "testkey" and self.headers.get("X-Auth-Email") == "me@example.com":
            return True
        self.send(403, {"success": False, "errors": [{"code": 9103, "message": "Unknown X-Auth-Key or X-Auth-Email"}]})
        return False

    def do_GET(self):
        u = urlparse(self.path); q = parse_qs(u.query)
        if u.path in ("/ip1", "/ip2"):
            return self.send(200, read(u.path[1:]).encode())
        if not self.authed(): return
        if u.path == "/zones":
            res = [{"id": ZONE_ID, "name": "kz7.site", "account": {"id": "c" * 32}}] if q.get("name") == ["kz7.site"] else []
            return self.send(200, {"success": True, "result": res})
        if u.path == f"/zones/{ZONE_ID}/dns_records":
            ok = q.get("name") == ["ddns.kz7.site"] and q.get("type") == ["A"]
            return self.send(200, {"success": True, "result": [{"id": RECORD_ID, "type": "A", "name": "ddns.kz7.site"}] if ok else []})
        self.send(404, {"success": False})

    def do_PUT(self):
        if not self.authed(): return
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        if urlparse(self.path).path != f"/zones/{ZONE_ID}/dns_records/{RECORD_ID}":
            return self.send(404, {"success": False, "errors": [{"message": "record not found"}]})
        with open(os.path.join(STATE, "puts.log"), "a") as f:
            f.write(body + "\n")
        self.send(200, {"success": True, "result": json.loads(body)})

HTTPServer(("127.0.0.1", PORT), H).serve_forever()
