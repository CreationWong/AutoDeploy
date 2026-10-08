# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 CreationWong
# See LICENSE for the license terms and warranty disclaimer.

"""Exercise release eligibility against real Git commit histories."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from ci.release import check_release, is_version_tag


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="autodeploy-release-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "CI")
        self.git("config", "user.email", "ci@example.com")
        tree = self.git("hash-object", "-t", "tree", "-w", "--stdin", input="")
        self.base = self.git("commit-tree", tree, "-m", "CI base")
        self.main = self.git("commit-tree", tree, "-p", self.base, "-m", "CI main")
        self.feature = self.git("commit-tree", tree, "-p", self.base, "-m", "CI feature")
        self.git("update-ref", "refs/remotes/origin/main", self.main)

    def git(self, *args, **kwargs):
        env = os.environ.copy()
        env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        return subprocess.run(["git", *args], cwd=self.root, env=env, text=True, capture_output=True, check=True, **kwargs).stdout.strip()

    def release(self, tag="V0.1.3", event="push", ref=None):
        return check_release(self.root, event, ref or f"refs/tags/{tag}", tag, "CreationWong/AutoDeploy")

    def test_version_formats(self):
        for tag in ["V0.1.3", "v1.2.3", "V0.1.3-rc.1", "v1.0.0-0"]:
            with self.subTest(tag=tag):
                self.assertTrue(is_version_tag(tag))
        for tag in ["main", "release", "V1.2", "V01.2.3", "v1.02.3", "V1.2.03", "V1.2.3-01", "v1.2.3-rc..1", "V1.2.3+build", "V1.2.3/extra", "V1.2.3\nimage=bad", "V1.2.3-" + "a" * 125]:
            with self.subTest(tag=tag):
                self.assertFalse(is_version_tag(tag))

    def test_main_commit_is_allowed(self):
        self.git("tag", "V0.1.3", self.main)
        result = self.release()
        self.assertEqual(result["valid"], "true")
        self.assertEqual(result["revision"], self.main)
        self.assertEqual(result["image"], "ghcr.io/creationwong/autodeploy")

    def test_prepare_outputs_pin_the_verified_commit(self):
        self.git("tag", "V0.1.3", self.main)
        output = self.root / "actions-output"
        env = os.environ.copy()
        env.update(
            GITHUB_EVENT_NAME="push", GITHUB_REF="refs/tags/V0.1.3",
            GITHUB_REF_NAME="V0.1.3", GITHUB_REPOSITORY="CreationWong/AutoDeploy",
            GITHUB_OUTPUT=str(output),
        )
        script = Path(__file__).resolve().parents[1] / "ci/release.py"
        subprocess.run([sys.executable, "-B", str(script), "prepare"], cwd=self.root, env=env, check=True, capture_output=True, text=True)
        values = dict(line.split("=", 1) for line in output.read_text().splitlines())
        self.assertEqual(values, {
            "valid": "true", "tag": "V0.1.3", "revision": self.main,
            "image": "ghcr.io/creationwong/autodeploy",
        })

    def test_main_history_is_allowed(self):
        self.git("tag", "V0.1.3", self.base)
        self.assertEqual(self.release()["revision"], self.base)

    def test_annotated_tag_resolves_to_commit(self):
        self.git("tag", "-a", "V0.1.3", self.main, "-m", "CI version")
        self.assertEqual(self.release()["revision"], self.main)

    def test_unmerged_branch_is_rejected(self):
        self.git("tag", "V0.1.3", self.feature)
        self.assertEqual(self.release()["valid"], "false")

    def test_merged_branch_is_allowed(self):
        tree = self.git("rev-parse", f"{self.main}^{{tree}}")
        merged = self.git("commit-tree", tree, "-p", self.main, "-p", self.feature, "-m", "CI merge")
        self.git("update-ref", "refs/remotes/origin/main", merged)
        self.git("tag", "V0.1.3", self.feature)
        self.assertEqual(self.release()["revision"], self.feature)

    def test_pr_events_are_rejected(self):
        for event in ["pull_request", "pull_request_target"]:
            with self.subTest(event=event):
                self.assertEqual(self.release(event=event)["valid"], "false")

    def test_branch_push_is_not_a_release(self):
        self.assertEqual(self.release(ref="refs/heads/main")["valid"], "false")

    def test_missing_main_history_fails_closed(self):
        self.git("tag", "V0.1.3", self.main)
        self.git("update-ref", "-d", "refs/remotes/origin/main")
        with self.assertRaises(subprocess.CalledProcessError):
            self.release()

    def verify_cli(self):
        env = os.environ.copy()
        env.update(
            GITHUB_EVENT_NAME="push", GITHUB_REF="refs/tags/V0.1.3",
            GITHUB_REF_NAME="V0.1.3", GITHUB_REPOSITORY="CreationWong/AutoDeploy",
            EXPECTED_REVISION=self.main,
        )
        script = Path(__file__).resolve().parents[1] / "ci/release.py"
        return subprocess.run([sys.executable, "-B", str(script), "verify"], cwd=self.root, env=env, capture_output=True, text=True)

    def test_verify_allows_unchanged_main_release(self):
        self.git("tag", "V0.1.3", self.main)
        self.git("update-ref", "refs/heads/main", self.main)
        self.assertEqual(self.verify_cli().returncode, 0)

    def test_verify_rejects_tag_moved_after_ci(self):
        self.git("tag", "V0.1.3", self.main)
        self.git("update-ref", "refs/heads/main", self.main)
        self.git("tag", "-f", "V0.1.3", self.base)
        result = self.verify_cli()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("与已通过 CI 的提交不一致", result.stderr)

    def test_verify_rejects_commit_removed_from_main(self):
        self.git("tag", "V0.1.3", self.main)
        self.git("update-ref", "refs/heads/main", self.main)
        self.git("update-ref", "refs/remotes/origin/main", self.base)
        self.assertNotEqual(self.verify_cli().returncode, 0)

    def test_verify_rejects_different_build_checkout(self):
        self.git("tag", "V0.1.3", self.main)
        self.git("update-ref", "refs/heads/main", self.feature)
        self.assertNotEqual(self.verify_cli().returncode, 0)


if __name__ == "__main__":
    unittest.main()
