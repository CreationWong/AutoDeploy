# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 CreationWong
#
# This file is part of AutoDeploy.
#
# AutoDeploy is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, version 3 of the License.
#
# AutoDeploy is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with AutoDeploy. If not, see <https://www.gnu.org/licenses/>.

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
