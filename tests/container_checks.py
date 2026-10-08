#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 CreationWong
# See LICENSE for the license terms and warranty disclaimer.

"""Verify fresh-volume permissions and published endpoints in real containers."""

import argparse
import json
import subprocess
import time
import uuid


def docker(*args: str) -> str:
    return subprocess.run(["docker", *args], check=True, text=True, capture_output=True).stdout.strip()


def cleanup(*args: str) -> None:
    result = subprocess.run(["docker", *args], text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f"测试资源清理失败：{result.stderr.strip()}")


def wait_ready(container: str) -> str:
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        output = docker("logs", container)
        if "启动完成" in output:
            return output
        time.sleep(0.5)
    raise RuntimeError(f"测试容器初始化超时：\n{docker('logs', container)}")


def start(container: str, image: str, platform: str | None, *options: str) -> None:
    args = ["run", "-d", "--name", container]
    if platform:
        args += ["--platform", platform]
    try:
        docker(*args, *options, "-e", "AUTODEPLOY_HTTP_PASSWORD=test-placeholder", image)
    except subprocess.CalledProcessError:
        # Docker can create a container before discovering a startup error.
        exists = subprocess.run(["docker", "container", "inspect", container], capture_output=True)
        if exists.returncode == 0:
            cleanup("rm", "-f", container)
        raise


def permissions(image: str, platform: str | None) -> None:
    name = "autodeploy-volume-test-" + uuid.uuid4().hex[:12]
    docker("volume", "create", name)
    try:
        start(name, image, platform, "--mount", f"type=volume,source={name},target=/data", "-e", "REPO_NAME=fresh-volume-test")
        try:
            wait_ready(name)
            docker("exec", "--user", "git", name, "mkdir", "-p", "/data/deploy/.versions/fresh-volume-test")
            docker("exec", "--user", "git", name, "mktemp", "-d", "/data/deploy/.versions/fresh-volume-test/.staging-XXXXXX")
            owner = docker("exec", name, "stat", "-c", "%U:%G %a", "/data/deploy", "/data/deploy/.versions")
            if owner != "git:git 755\ngit:git 755":
                raise RuntimeError(f"全新数据卷的部署目录权限不正确：\n{owner}")
            print("全新数据卷权限检查通过，git 用户可以写入版本目录。", flush=True)
        finally:
            cleanup("rm", "-f", name)
    finally:
        cleanup("volume", "rm", name)


def endpoints(image: str, platform: str | None) -> None:
    name = "autodeploy-address-test-" + uuid.uuid4().hex[:12]
    start(name, image, platform, "-p", "127.0.0.1::80", "-v", "/var/run/docker.sock:/var/run/docker.sock", "-e", "AUTODEPLOY_HTTP_USER=address-test-user", "-e", "AUTODEPLOY_HTTP_PORT=8080")
    try:
        output = wait_ready(name)
        port = json.loads(docker("inspect", name))[0]["NetworkSettings"]["Ports"]["80/tcp"][0]["HostPort"]
        expected = f"http://address-test-user@127.0.0.1:{port}/app.git"
        for label, content in [("启动日志", output), ("管理命令", docker("exec", name, "autodeploy", "show"))]:
            if expected not in content or "SSH 未发布宿主机端口" not in content:
                raise RuntimeError(f"{label}未显示正确的推送地址 {expected}：\n{content}")
        print("容器日志和管理命令中的实际推送地址检查通过。", flush=True)
    finally:
        cleanup("rm", "-f", name)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image")
    parser.add_argument("--platform", choices=["linux/amd64", "linux/arm64"])
    args = parser.parse_args()
    try:
        permissions(args.image, args.platform)
        endpoints(args.image, args.platform)
    except (subprocess.CalledProcessError, RuntimeError) as exc:
        parser.exit(1, f"容器检查失败：{getattr(exc, 'stderr', None) or exc}\n")


if __name__ == "__main__":
    main()
