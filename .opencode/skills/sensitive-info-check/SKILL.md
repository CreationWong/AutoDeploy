---
name: sensitive-info-check
description: Scan staged changes and outgoing commits for secrets, credentials, private keys, tokens, and privacy-sensitive data before git commit or git push. Use before every commit/push, when asked to check for sensitive information (检查敏感信息/隐私/密钥), or when reviewing a diff for leaks.
---

# Sensitive Info Check

在 `git commit` / `git push` 前扫描将要写入历史的变更，发现敏感或隐私信息时**阻止操作**并先处理。

## 触发时机

- 准备执行 `git commit` 前：扫描暂存区；
- 准备执行 `git push` 前：扫描所有待推送提交；
- 用户要求"检查敏感信息 / 有没有泄露密钥 / 隐私检查"时。

## 执行步骤

1. 选择范围：
   - 提交前：`bash .opencode/skills/sensitive-info-check/scan.sh --staged`
   - 推送前：`bash .opencode/skills/sensitive-info-check/scan.sh --outgoing`（同时扫描提交信息）
   - 指定区间：`bash .opencode/skills/sensitive-info-check/scan.sh --range <a..b>`
2. 脚本退出码 `1` = 命中疑似敏感信息；`0` = 干净；`2` = 用法/环境错误。
   - Windows 上 `bash` 可能不在 PATH，用 Git Bash：`& "$env:ProgramFiles\Git\bin\bash.exe" .opencode/skills/sensitive-info-check/scan.sh --staged`。
3. 若有命中：**不要继续 commit/push**，逐条向用户报告文件、类型、脱敏后的证据，并给出处理建议。
4. 处理完成（删除/改用环境变量/加 `.gitignore`/替换占位符）后重新扫描，直到通过。

也可用现成工具做交叉验证（已安装时优先）：`gitleaks protect --staged`、`gitleaks detect`、`trufflehog git file://.`。

## 判定与分级

高置信（阻断）：

- 私钥：`-----BEGIN ... PRIVATE KEY-----`、`id_rsa` / `id_ed25519` / `*.pem` / `*.key` / `*.p12` / `*.pfx` / `*.jks`
- 云与平台令牌：AWS `AKIA...`、GitHub `ghp_/gho_/ghu_/ghs_/ghr_`、`github_pat_`、Slack `xox...`、Google `AIza...`、Stripe `sk_live_...`
- JWT：`eyJ....eyJ....`
- URL 内嵌凭据：`scheme://user:password@host`、数据库连接串 `postgres|mysql|mongodb|redis|amqp://user:pass@host`
- 赋值型密钥：`password|secret|token|api_key|access_key|private_key` = 非占位符的长值
- 服务账号 JSON：`"type": "service_account"` + `private_key_id`
- 敏感文件名：`.env*`、`credentials`、`.npmrc`、`.netrc`、`htpasswd`、`*.tfstate`

隐私/PII（默认警告，按项目政策决定是否阻断）：

- 真实邮箱、手机号、身份证号、真实客户数据样本
- 内网主机名/IP、私有域名、内部 URL
- 个人绝对路径、真实姓名与账号

## 误报白名单

占位符与测试值不算：`example`、`placeholder`、`changeme`、`dummy`、`sample`、`your-`、`xxx`、`<...>`、`${VAR}`、`localhost`、`127.0.0.1`、`0.0.0.0`、`test`、`fake`。公钥、指纹、哈希、UUID 不算密钥。

## 发现后的处理

1. 阻断当前 commit/push。
2. 从工作区移除明文，改用环境变量 / secret manager，替换为占位符，并把文件加入 `.gitignore`。
3. 若已进入历史或已推送：**先轮换该凭据**，再用 `git filter-repo` 清理历史，并提醒远端缓存/fork 仍可能保留。
4. 复扫通过后才允许提交/推送。

## 注意

- 只扫描新增行（`git diff` 的 `+` 行），避免对既有内容反复告警；
- 报告证据时脱敏（只显示前缀/长度），不要把完整密钥再次输出到日志或对话；
- 本 skill 只做检查与阻止，不自动修改用户代码或历史，改动前先征得确认。
