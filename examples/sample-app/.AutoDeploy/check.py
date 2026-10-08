#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 CreationWong
# See LICENSE for the license terms and warranty disclaimer.

"""Example deployment checks and environment handoff between workflow steps."""

import argparse
import ast
from datetime import datetime, timezone
import os
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("check", choices=["files", "syntax", "export-env", "print-env"])
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[1] / "server.py"
    if args.check == "files":
        if not source.is_file():
            parser.exit(1, "缺少 server.py，无法部署示例服务。\n")
        print("项目文件检查通过。")
    elif args.check == "syntax":
        ast.parse(source.read_text(), filename=str(source))
        print("Python 语法检查通过。")
    elif args.check == "export-env":
        with Path(os.environ["GITHUB_ENV"]).open("a") as output:
            print(f"CHECKED_AT={datetime.now(timezone.utc).isoformat()}", file=output)
    else:
        print(f"检查时间：{os.environ['CHECKED_AT']}")


if __name__ == "__main__":
    main()
