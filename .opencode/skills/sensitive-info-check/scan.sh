#!/bin/bash
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
patterns="$here/patterns.txt"
allow='(example|placeholder|changeme|dummy|sample|your[-_]|xxx|<[^>]+>|\$\{|localhost|127\.0\.0\.1|0\.0\.0\.0|test|fake|user:pass|user:password|:pass@|:password@|:secret@|:token@)'

if [ ! -s "$patterns" ]; then
  echo "[scan] 模式文件缺失或为空: $patterns" >&2
  exit 2
fi

mode="${1:---staged}"
case "$mode" in
  --staged) args=(--cached) ;;
  --outgoing)
    up="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
    if [ -n "$up" ]; then
      args=("$up...HEAD")
    else
      args=(HEAD~20..HEAD)
      echo "[scan] 警告: 无 upstream，仅扫描最近 20 个提交" >&2
    fi
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
added="$(printf '%s\n' "$diff_text" | grep -E '^\+' | grep -vE '^\+\+\+' || true)"

msg_text=""
if [ "$mode" = "--outgoing" ]; then
  msg_text="$(git log --format='%h %s%n%b' "${args[@]}" 2>/dev/null || true)"
fi

if [ -z "$added" ] && [ -z "$msg_text" ]; then
  echo "[scan] 无可扫描的变更 ($mode)"
  exit 0
fi

found=0

scan_text() {
  local text="$1" label="$2" p hit lineno line m hits
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    hits=""
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      lineno="${hit%%:*}"
      line="${hit#*:}"
      m="$(printf '%s\n' "$line" | grep -oE -- "$p" | head -n1 || true)"
      if [ -n "$m" ] && printf '%s' "$m" | grep -qiE -- "$allow"; then
        continue
      fi
      hits+="    ${lineno}:${line}"$'\n'
    done < <(printf '%s\n' "$text" | grep -nE -- "$p" || true)
    if [ -n "$hits" ]; then
      found=1
      printf '[scan] 命中%s模式: %s\n' "$label" "$p"
      printf '%s' "$hits"
    fi
  done < "$patterns"
}

scan_text "$added" ""
if [ -n "$msg_text" ]; then
  scan_text "$msg_text" "提交信息"
fi

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
