#!/bin/bash
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
patterns="$here/patterns.txt"
allow='(example|placeholder|changeme|dummy|sample|your[-_]|xxx|<[^>]+>|\$\{|localhost|127\.0\.0\.1|0\.0\.0\.0|test|fake|user:pass|user:password|:pass@|:password@|:secret@|:token@)'

mode="${1:---staged}"
case "$mode" in
  --staged) args=(--cached) ;;
  --outgoing)
    up="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
    if [ -n "$up" ]; then args=("$up...HEAD"); else args=(HEAD~20..HEAD); fi
    ;;
  --range)
    shift
    if [ "$#" -lt 1 ]; then
      echo "用法: scan.sh --range <a..b>" >&2
      exit 2
    fi
    args=("$1")
    ;;
  *)
    echo "用法: scan.sh [--staged|--outgoing|--range <a..b>]" >&2
    exit 2
    ;;
esac

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "[scan] 当前目录不是 git 仓库" >&2
  exit 2
fi

diff_text="$(git diff "${args[@]}" 2>/dev/null || true)"
if [ -z "$diff_text" ]; then
  echo "[scan] 无可扫描的变更 ($mode)"
  exit 0
fi

added="$(printf '%s\n' "$diff_text" | grep -E '^\+' | grep -vE '^\+\+\+')"
found=0

while IFS= read -r p; do
  [ -n "$p" ] || continue
  hits="$(printf '%s\n' "$added" | grep -nE -- "$p" | grep -vEi -- "$allow" || true)"
  if [ -n "$hits" ]; then
    found=1
    printf '[scan] 命中模式: %s\n' "$p"
    printf '%s\n' "$hits" | sed 's/^/    /'
  fi
done < "$patterns"

files="$(git diff --name-only "${args[@]}" 2>/dev/null || true)"
bad_files="$(printf '%s\n' "$files" | grep -Ei '(^|/)(\.env|id_rsa|id_ed25519|credentials|\.npmrc|\.netrc|htpasswd)(\.|$)|\.(pem|key|p12|pfx|jks|keystore|tfstate)$' || true)"
if [ -n "$bad_files" ]; then
  found=1
  echo "[scan] 命中敏感文件名:"
  printf '%s\n' "$bad_files" | sed 's/^/    /'
fi

if [ "$found" = "1" ]; then
  echo "[scan] 发现疑似敏感信息，请先处理再提交/推送"
  exit 1
fi
echo "[scan] 未发现敏感信息 ($mode)"
