# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 CreationWong
# See LICENSE for the license terms and warranty disclaimer.

"""Check endpoint output from the production Bash helper using a Docker stub."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
set -euo pipefail
docker() {
  [ "$1" = inspect ] && [ "${@: -1}" = "$HOSTNAME" ] || return 1
  printf '%s\n' "$MOCK_BINDINGS"
  return "$MOCK_STATUS"
}
timeout() { shift; "$@"; }
log() { printf '[AutoDeploy] %s\n' "$*"; }
. "$ENDPOINT_SCRIPT"
autodeploy_log_endpoints
'''


class EndpointTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="autodeploy-endpoints-")
        self.addCleanup(self.temporary.cleanup)
        self.data = Path(self.temporary.name)

    def render(self, bindings="80/tcp\t0.0.0.0\t8096", status=0, **settings):
        env = os.environ.copy()
        for key in ["AUTODEPLOY_HOST", "AUTODEPLOY_HTTP_PORT", "AUTODEPLOY_SSH_PORT", "AUTODEPLOY_HTTP_USER"]:
            env.pop(key, None)
        env.update(
            AUTODEPLOY_LANG="en", AUTODEPLOY_DATA_DIR=str(self.data), HOSTNAME="autodeploy-test-container",
            REPO_NAME="app", DEPLOY_BRANCH="main", MOCK_BINDINGS=bindings,
            MOCK_STATUS=str(status), ENDPOINT_SCRIPT=str(ROOT / "src/scripts/autodeploy-endpoints"),
        )
        env.update(settings)
        return subprocess.run(["bash", "-c", HARNESS], env=env, check=True, capture_output=True, text=True).stdout

    def test_published_port_and_unpublished_ssh(self):
        output = self.render()
        self.assertIn("http://autodeploy@<host>:8096/app.git", output)
        self.assertIn("SSH has no published host port", output)
        self.assertNotIn(":8080/", output)
        self.assertNotIn(":2222/", output)

    def test_actual_ports_and_saved_username_override_defaults(self):
        (self.data / "htpasswd").write_text("saved-user:unused-test-hash\n")
        output = self.render(
            bindings="80/tcp\t0.0.0.0\t8096\n22/tcp\t127.0.0.1\t22022",
            AUTODEPLOY_HTTP_PORT="8080", AUTODEPLOY_HOST="deploy.example.test",
            AUTODEPLOY_HTTP_USER="changed-user", REPO_NAME="project", DEPLOY_BRANCH="release/*",
        )
        self.assertIn("http://saved-user@deploy.example.test:8096/project.git", output)
        self.assertIn("ssh://git@deploy.example.test:22022/~/project.git", output)
        self.assertIn("deployment branch: release/*", output)
        self.assertNotIn("unused-test-hash", output)

    def test_specific_addresses_ipv6_and_wildcard_deduplication(self):
        output = self.render(bindings="80/tcp\t127.0.0.1\t8096\n80/tcp\t::1\t8097\n22/tcp\t0.0.0.0\t22022\n22/tcp\t::\t22022")
        self.assertIn("http://autodeploy@127.0.0.1:8096/app.git", output)
        self.assertIn("http://autodeploy@[::1]:8097/app.git", output)
        self.assertEqual(output.count("ssh://git@<host>:22022/"), 1)

    def test_no_published_port_is_not_an_inspection_failure(self):
        output = self.render(bindings="")
        self.assertIn("HTTP has no published host port", output)
        self.assertNotIn("HTTP push address:", output)
        self.assertNotIn("Cannot detect host port", output)

    def test_gateway_ports_without_published_ports(self):
        for status in [0, 1]:
            with self.subTest(status=status):
                output = self.render(bindings="", status=status, AUTODEPLOY_HTTP_PORT="18080", AUTODEPLOY_SSH_PORT="22022")
                self.assertIn("http://autodeploy@<host>:18080/app.git", output)
                self.assertIn("ssh://git@<host>:22022/~/app.git", output)

    def test_inspection_failure_uses_address_templates(self):
        output = self.render(bindings="", status=1)
        self.assertIn("Cannot detect host port", output)
        self.assertIn(":<HTTP_PORT>/app.git", output)
        self.assertNotIn(":8080/", output)
        self.assertNotIn(":2222/", output)

    def test_ipv6_external_host_is_bracketed(self):
        output = self.render(bindings="", status=1, AUTODEPLOY_HOST="2001:db8::1")
        self.assertIn("http://autodeploy@[2001:db8::1]:<HTTP_PORT>/app.git", output)

    def test_chinese_and_unknown_language(self):
        chinese = self.render(AUTODEPLOY_LANG="zh")
        self.assertIn("HTTP 推送地址:", chinese)
        self.assertIn("部署分支: main", self.render(AUTODEPLOY_LANG="zh", AUTODEPLOY_SSH_PORT="2222"))
        self.assertIn("SSH 未发布宿主机端口", chinese)
        self.assertEqual(self.render(AUTODEPLOY_LANG="unsupported"), self.render())

    def test_untrusted_values_are_not_evaluated(self):
        host = "$(touch /tmp/autodeploy-i18n-unexpected);%s\\test"
        for language in ("en", "zh"):
            output = self.render(AUTODEPLOY_LANG=language, AUTODEPLOY_HOST=host)
            self.assertIn(host, output)


if __name__ == "__main__":
    unittest.main()
