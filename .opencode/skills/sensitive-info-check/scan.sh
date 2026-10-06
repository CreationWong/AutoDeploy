#!/bin/bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
patterns="$here/patterns.txt"
mode="${1:---staged}"
found=0

error() { echo "[scan] $*" >&2; exit 2; }
[ -s "$patterns" ] || error "模式文件缺失或为空"
for tool in git grep; do
  command -v "$tool" >/dev/null || error "缺少工具: $tool"
done
git rev-parse --git-dir >/dev/null 2>&1 || error "当前目录不是 git 仓库"

# 白名单只用于完整的占位凭据值，不用于提供商 token 的任意子串。
is_placeholder() {
  local value="${1,,}"
  case "$value" in
    example|placeholder|changeme|dummy|sample|xxx|test|fake|pass|password|secret|token|localhost|127.0.0.1|0.0.0.0) return 0 ;;
    example-*|placeholder-*|dummy-*|sample-*|your-*|your_*|test-*|fake-*|'${'*'}'|'<'*'>') return 0 ;;
    *) return 1 ;;
  esac
}

scan_text() {
  local text="$1" label="$2" p hits hit value rc
  while IFS= read -r p || [ -n "$p" ]; do
    p="${p%$'\r'}"
    [ -n "$p" ] || continue
    rc=0
    hits="$(printf '%s\n' "$text" | grep -oE -- "$p")" || rc=$?
    [ "$rc" -le 1 ] || error "正则或扫描工具失败"
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      value=""
      case "$hit" in
        *://*@) value="${hit%@}"; value="${value##*:}" ;;
        *)
          if [[ "$p" == '(password|'* ]]; then
            case "$hit" in
              *\"*) value="${hit#*\"}" ;;
              *\'*) value="${hit#*\'}" ;;
            esac
          fi
          ;;
      esac
      if [ -n "$value" ] && is_placeholder "$value"; then
        continue
      fi
      found=1
      printf '[scan] 命中 %s 模式: %s（内容已脱敏）\n' "$label" "$p"
    done <<< "$hits"
  done < "$patterns"
}

scan_diff() {
  local diff="$1" label="$2" line file="" added=""
  while IFS= read -r line; do
    case "$line" in
      '+++ '*)
        [ -z "$added" ] || scan_text "$added" "$label 文件=$file"
        file="${line#+++ }"
        added=""
        ;;
      '+'*)
        added+="${line#+}"$'\n'
        ;;
    esac
  done <<< "$diff"
  [ -z "$added" ] || scan_text "$added" "$label 文件=$file"
}

scan_files() {
  local file rc
  while IFS= read -r -d '' file; do
    rc=0
    printf '%s\n' "$file" | grep -qiE '(^|/)(\.env[^/]*|id_rsa|id_ed25519|credentials|\.npmrc|\.netrc|htpasswd)(\.|$)|\.(pem|key|p12|pfx|jks|keystore|tfstate)$' || rc=$?
    [ "$rc" -le 1 ] || error "文件名扫描工具失败"
    if [ "$rc" = "0" ]; then
      found=1
      printf '[scan] 命中敏感文件名: %s\n' "$file"
    fi
  done
}

case "$mode" in
  --staged)
    diff="$(git diff --cached --no-ext-diff --no-textconv --unified=0 --)" || error "读取暂存区失败"
    scan_diff "$diff" "暂存区"
    scan_files < <(git diff --cached --name-only --diff-filter=AM -z --)
    query_pid=$!
    wait "$query_pid" || error "读取暂存文件失败"
    ;;
  --outgoing|--range)
    if [ "$mode" = "--range" ]; then
      [ "$#" = "2" ] || error "用法: scan.sh --range <a..b>"
      range="$2"
      [[ "$range" != -* ]] || error "非法提交范围"
    else
      git rev-parse --verify HEAD >/dev/null 2>&1 || error "无法读取 HEAD"
      up="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
      if [ -n "$up" ]; then
        range="$up..HEAD"
      else
        range=HEAD
        echo "[scan] 无 upstream，扫描 HEAD 的全部可达提交" >&2
      fi
    fi
    commits="$(git rev-list --reverse "$range" --)" || error "无法解析提交范围"
    while IFS= read -r commit; do
      [ -n "$commit" ] || continue
      diff="$(git show --format= --root -m --no-ext-diff --no-textconv --unified=0 "$commit" --)" || error "读取提交差异失败"
      scan_diff "$diff" "提交=$commit"
      message="$(git show -s --format='%s%n%b' "$commit" --)" || error "读取提交信息失败"
      scan_text "$message" "提交信息=$commit"
      scan_files < <(git diff-tree --root -m --no-commit-id --name-only --diff-filter=AM -r -z "$commit" --)
      query_pid=$!
      wait "$query_pid" || error "读取提交文件失败"
    done <<< "$commits"
    ;;
  *) error "用法: scan.sh [--staged|--outgoing|--range <a..b>]" ;;
esac

if [ "$found" = "1" ]; then
  echo "[scan] 发现疑似敏感信息，请先处理再提交/推送"
  exit 1
fi
echo "[scan] 未发现敏感信息 ($mode)"
