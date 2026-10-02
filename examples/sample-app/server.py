import http.server
import os

PORT = int(os.environ.get("PORT", "3000"))


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = "Hello from AutoDeploy sample app\n".encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        print(fmt % args, flush=True)


if __name__ == "__main__":
    server = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print("sample-app listening on {}".format(PORT), flush=True)
    server.serve_forever()
