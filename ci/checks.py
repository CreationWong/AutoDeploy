#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 CreationWong
# See LICENSE for the license terms and warranty disclaimer.

"""Run the same project checks locally and in GitHub Actions."""

import argparse
import ast
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(*args: str, cwd: Path = ROOT, **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(args, cwd=cwd, check=True, **kwargs)


def lint() -> None:
    scripts = [ROOT / "entrypoint.sh", *sorted((ROOT / "scripts").iterdir())]
    scripts += sorted((ROOT / "examples/sample-app/.AutoDeploy").glob("*.sh"))
    for script in scripts:
        run("bash", "-n", str(script))
    run("shellcheck", "-S", "error", *(str(script) for script in scripts))
    for folder in ("ci", "tests", "examples"):
        for source in (ROOT / folder).rglob("*.py"):
            ast.parse(source.read_text(), filename=str(source))
    print("Shell 和 Python 语法检查通过。")


def unit() -> None:
    run(sys.executable, "-B", "-m", "unittest", "discover", "-s", "tests", "-p", "test_*.py", "-v")


def scanner_selftest() -> None:
    scanner = ROOT / ".opencode/skills/sensitive-info-check/scan.sh"
    with tempfile.TemporaryDirectory(prefix="autodeploy-scanner-") as temporary:
        repo = Path(temporary)
        run("git", "init", "-q", "-b", "main", cwd=repo)
        (repo / "ok.txt").write_text("hello\n")
        run("git", "add", "ok.txt", cwd=repo)
        run("bash", str(scanner), "--staged", cwd=repo)
        (repo / "leak.txt").write_text("aws_key = " + "AKIA" + "A" * 16 + "\n")
        run("git", "add", "leak.txt", cwd=repo)
        result = subprocess.run(["bash", str(scanner), "--staged"], cwd=repo)
        if result.returncode != 1:
            raise RuntimeError(f"扫描器应拦截测试密钥并返回 1，实际返回 {result.returncode}。")
    print("敏感信息扫描器的正向和负向校验通过。")


def containers(image: str, build: bool, platform: str | None) -> None:
    if build:
        command = ["docker", "build", "-t", image]
        if platform:
            command += ["--platform", platform]
        run(*command, ".")
    run(sys.executable, "-B", "tests/container_checks.py", image, *(["--platform", platform] if platform else []))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("lint", "unit", "scanner-selftest"):
        commands.add_parser(command)
    container = commands.add_parser("containers")
    container.add_argument("--image", default="autodeploy:ci")
    container.add_argument("--build", action="store_true")
    container.add_argument("--platform", choices=["linux/amd64", "linux/arm64"])
    args = parser.parse_args()
    try:
        if args.command == "containers":
            containers(args.image, args.build, args.platform)
        else:
            {"lint": lint, "unit": unit, "scanner-selftest": scanner_selftest}[args.command]()
    except (subprocess.CalledProcessError, RuntimeError, OSError) as exc:
        parser.exit(1, f"检查失败：{exc}\n")


if __name__ == "__main__":
    main()
