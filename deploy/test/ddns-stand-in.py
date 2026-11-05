#!/usr/bin/env python3
"""Stands in for the Cloudflare and DuckDNS APIs so the installer's calls can be checked.

It answers with the shapes the real APIs document and records every request, one JSON
object per line. A test that greps this file proves what the installer sent; it cannot
prove the real services would accept it.

    ddns-stand-in.py <listen-ip> <cert> <key> <requests.jsonl>
"""
import http.server
import json
import re
import ssl
import sys
import urllib.parse

ZONE_NAME = "aurora.test"
ZONE_ID = "a" * 32
RECORD_ID = "b" * 32

listen_ip, cert, key, log_path = sys.argv[1:5]
records = []


def log(entry):
    with open(log_path, "a") as handle:
        handle.write(json.dumps(entry) + "\n")


class Handler(http.server.BaseHTTPRequestHandler):
    def _answer(self, payload, content_type="application/json"):
        # Compact, as the real API answers.
        body = payload if isinstance(payload, bytes) else json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _record(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else ""
        log({
            "method": self.command,
            "host": self.headers.get("Host", ""),
            "path": self.path,
            "auth": self.headers.get("Authorization", ""),
            "body": body,
        })
        # The test greps a flat line, so keep the method and the JSON body side by side.
        with open(log_path, "a") as handle:
            handle.write('"%s" %s\n' % (self.command, re.sub(r'":', '": ', body)))
        return body

    def _route(self):
        body = self._record()
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        if parsed.path == "/update":
            self._answer(b"OK", "text/plain")
        elif parsed.path == "/client/v4/zones":
            found = query.get("name", [""])[0] == ZONE_NAME
            self._answer({"result": [{"id": ZONE_ID, "name": ZONE_NAME}] if found else [], "success": True})
        elif parsed.path == "/client/v4/zones/%s/dns_records" % ZONE_ID and self.command == "GET":
            self._answer({"result": [{"id": RECORD_ID, "type": "A"}] if records else [], "success": True})
        elif parsed.path.startswith("/client/v4/zones/%s/dns_records" % ZONE_ID):
            records.append(body)
            self._answer({"result": {"id": RECORD_ID}, "success": True})
        else:
            self.send_error(404)

    do_GET = _route
    do_POST = _route
    do_PUT = _route

    def log_message(self, *_):
        pass


server = http.server.ThreadingHTTPServer((listen_ip, 443), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(cert, key)
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
