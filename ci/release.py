#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 CreationWong
# See LICENSE for the license terms and warranty disclaimer.

"""Validate release tags against main and write GitHub Actions outputs."""

import argparse
import os
from pathlib import Path
import re
import subprocess


def is_version_tag(tag: str) -> bool:
    number = r"(?:0|[1-9][0-9]*)"
    identifier = r"(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
    pattern = rf"[vV]{number}\.{number}\.{number}(?:-{identifier}(?:\.{identifier})*)?"
    return len(tag) <= 128 and re.fullmatch(pattern, tag) is not None


def git(root: Path, *args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=root, check=True, text=True, capture_output=True
    ).stdout.strip()


def check_release(root: Path, event: str, ref: str, tag: str, repository: str) -> dict:
    if event != "push" or ref != f"refs/tags/{tag}" or not is_version_tag(tag):
        return {"valid": "false", "reason": "仅版本标签推送可发布镜像。"}

    # Resolve annotated and lightweight tags to the same commit representation.
    revision = git(root, "rev-parse", "--verify", f"{ref}^{{commit}}")
    main = git(root, "rev-parse", "--verify", "refs/remotes/origin/main^{commit}")
    result = subprocess.run(
        ["git", "merge-base", "--is-ancestor", revision, main],
        cwd=root, text=True, capture_output=True,
    )
    if result.returncode == 1:
        return {"valid": "false", "reason": "版本标签的提交尚未进入 main，跳过发布。"}
    result.check_returncode()
    return {
        "valid": "true",
        "tag": tag,
        "revision": revision,
        "image": f"ghcr.io/{repository.lower()}",
    }


def current_release() -> dict:
    return check_release(
        Path.cwd(), os.environ["GITHUB_EVENT_NAME"], os.environ["GITHUB_REF"],
        os.environ["GITHUB_REF_NAME"], os.environ["GITHUB_REPOSITORY"],
    )


def prepare() -> None:
    result = current_release()
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
        for key, value in result.items():
            if key != "reason":
                print(f"{key}={value}", file=output)
    print(result.get("reason", f"发布提交：{result.get('revision')}"))


def verify() -> None:
    result = current_release()
    if result["valid"] != "true":
        raise RuntimeError(result["reason"])
    expected = os.environ["EXPECTED_REVISION"]
    if result["revision"] != expected or git(Path.cwd(), "rev-parse", "HEAD") != expected:
        raise RuntimeError("版本标签或构建提交与已通过 CI 的提交不一致，停止发布。")
    print(f"发布前检查通过：{expected} 已进入 main，且与 CI 检查的提交一致。")


def summary() -> None:
    with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as output:
        print(f"镜像：`{os.environ['IMAGE']}:{os.environ['VERSION_TAG']}`\n", file=output)
        print(f"摘要：`{os.environ['DIGEST']}`\n", file=output)
        print("平台：`linux/amd64`、`linux/arm64`", file=output)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["prepare", "verify", "summary"])
    args = parser.parse_args()
    try:
        {"prepare": prepare, "verify": verify, "summary": summary}[args.command]()
    except subprocess.CalledProcessError as exc:
        parser.exit(1, f"无法验证发布提交，请确认已获取 main 和标签的完整历史：{exc.stderr or exc}\n")
    except RuntimeError as exc:
        parser.exit(1, f"发布检查失败：{exc}\n")


if __name__ == "__main__":
    main()
