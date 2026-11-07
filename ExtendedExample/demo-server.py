#!/usr/bin/env python3
"""A local stand-in for the Tracive Open API, for the sample's `demo` scheme.

Runs the screens with no Tracive app and no grant:

    python3 ExtendedExample/demo-server.py [--stall-uploads]

A report id picks what the status screen shows: demo-submitted, demo-in-review, demo-reviewed,
demo-need-revision, demo-gone, or demo-needs-consent. --stall-uploads never finishes an upload, and
logs when the app hangs up, which is how to watch a closed form cancel one.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 18787
STALL = "--stall-uploads" in sys.argv

REQUIREMENTS = {
    "enabled": True,
    "remainingToday": 5,
    "limits": {
        "titleMaxLength": 50,
        "chronologyMinLength": 50,
        "chronologyMaxLength": 2000,
        "commentMaxLength": 150,
        "maxIdentifiers": 10,
        "attachmentsPerIdentifier": 3,
        "extraAttachmentsWithPhone": 2,
        "maxAttachmentBytes": 1048576,
        "attachmentTypes": ["image/avif", "image/jpeg", "image/png", "application/pdf"],
    },
    "terms": [
        {"id": "TERMS_OF_SERVICE", "version": "3", "url": "https://tracive.id/terms"},
        {"id": "PRIVACY_POLICY", "version": "2", "url": "https://tracive.id/privacy"},
    ],
}

STATUSES = {
    "demo-submitted": "SUBMITTED",
    "demo-in-review": "IN_REVIEW",
    "demo-reviewed": "REVIEWED",
    "demo-need-revision": "NEED_REVISION",
}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def reply(self, status, body=None):
        data = b"" if body is None else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        return self.rfile.read(int(self.headers.get("Content-Length", 0)))

    def do_GET(self):
        if self.path == "/v1/report-requirements":
            return self.reply(200, REQUIREMENTS)
        report_id = self.path.rsplit("/", 1)[-1]
        if self.path.startswith("/v1/reports/"):
            if report_id == "demo-needs-consent":
                return self.reply(403, {"error": {"code": "missing_scope", "message": "No scope."}})
            if report_id == "demo-gone":
                return self.reply(404, {"error": {"code": "report_not_found", "message": "Gone."}})
            return self.reply(200, {"reportId": report_id, "status": STATUSES.get(report_id, "SUBMITTED")})
        self.reply(404, {"error": {"code": "not_found", "message": "No route."}})

    def do_POST(self):
        body = json.loads(self.body() or b"{}")
        if self.path == "/v1/report-uploads":
            host = f"http://{self.headers['Host']}"
            attachments = [
                {"attachmentId": f"att_{i}", "url": f"{host}/upload/{i}"}
                for i, _ in enumerate(body.get("attachments", []))
            ]
            return self.reply(200, {"uploadId": "upl_demo", "attachments": attachments})
        if self.path == "/v1/reports":
            return self.reply(202, {"reportId": "demo-submitted", "status": "SUBMITTED"})
        self.reply(404, {"error": {"code": "not_found", "message": "No route."}})

    def do_PUT(self):
        if STALL:
            received = len(self.body())
            print(f"upload stalled after {received} bytes, waiting for the app to hang up", flush=True)
            self.connection.settimeout(120)
            try:
                closed = self.connection.recv(1) == b""
            except OSError:
                closed = True
            print(f"app hung up: {closed}", flush=True)
            self.close_connection = True
            return
        self.body()
        self.reply(200)

    def log_message(self, format, *args):
        print(self.requestline, flush=True)


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
