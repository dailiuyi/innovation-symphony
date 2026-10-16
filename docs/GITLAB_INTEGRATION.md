# GitLab 与 luca 接入

日期：2026-10-15。来源：用户指定私有 GitLab 和本地 luca 目录，批准分阶段本地实现计划（IS-101）。

## 范围与当前边界

目标为 ready Issue → 独立工作区编码 → 固定检查 → 独立 Review → Draft MR，人工合并。复用现有 Elixir 生命周期、回执、预算和恢复，View 仅展示。单实例只接一个项目，不新增多仓库调度。

本轮在 `codex/gitlab-luca-integration` 分支实施，以已有 `origin/main` 的 `f0e96c4` 为基线。原开发工作区与 luca 的未提交内容不变。新增代码不代表服务已安装或任务可执行。

## 已检查的实例条件

- SSH remote 为 `git@gitlab.innovation:innovation/luca.git`，本机别名指向目标主机的 2222 端口；只读 `ls-remote HEAD` 成功。只证明读权限，不证明推送权限。
- HTTPS 入口的默认 TLS 校验返回自签名证书错误，不能据此认证 API。需要管理员已核验的 CA/证书及匹配的主机名或 IP SAN；不得自动信任网络上下载的证书或关闭校验。
- 尚未验证该实例版本、API token 权限、Issue 功能、模型授权和 rootless 实际执行环境。

## 实现合同

- GitLab provider 使用 `api_url`（以 `/api/v4` 结尾）、`project_path`、`api_key` 与可选 `ca_file`。凭据只以环境引用配置，禁止提交明文。
- 默认停用的示例工作流见 [elixir/WORKFLOW.gitlab.example.md](../elixir/WORKFLOW.gitlab.example.md)；未配置 `ca_file` 时必须省略该项，只写不可用路径会被配置检查拒绝。
- `api_url` 的协议、主机和端口必须与实例对外返回的 Web 链接一致（即 GitLab 的 `external_url`）：MR 的 `web_url` 会与按 `api_url` 推导出的地址逐字比较，这是防重定向的身份校验，不因内网/公网差异放宽。若实例面向客户端返回公网域名而配置写成内网地址，交付会以 `:mvp_pr_identity_mismatch` 失败；此时改配置，不改校验。
- 读取 `resource_label_events` 的 ready 授权用户与事件，模型参数从独立 notes 解析；撤销 ready 后禁止交付。
- GitLab 回执保存 tracker 类型、API 地址、项目路径、Issue iid/URL；旧 GitHub 回执保持兼容。
- 交付后校验同项目、source/target 分支、准确 SHA、Draft 与 URL；跨项目 MR 拒绝。写入结果不确定时只读对账，不能自动重复发布。
- 回执作用域与当前配置不符时统一返回 `:mvp_tracker_scope_mismatch`（2026-10-16 review 修正）：`Forge.receipt_scope` 的失败不再被 `:mvp_comment_already_attempted`、`:mvp_no_unique_matching_pr`、`:mvp_no_unique_matching_comment` 掩盖，排查时能直接区分配置错配与业务停点。影响 `Mvp.Feedback.post/reconcile`、`Mvp.Delivery.reconcile`、`Mvp.ExternalDraft.reconcile`。
- Git 使用指定 HTTPS 实例的受限凭据头和 CA，禁止重定向；SSH 当前只作为连接诊断证据，不把用户 SSH 密钥交给模型。
- 当前 View 的 MR 合并状态来自回执或显示未知，不使用 GitHub CLI 查询 GitLab。

## 分阶段验收与待办

1. 本地代码与回归：测试结果完成后记录于下方。
2. 只读实例预检：需要可信 CA、受限 API token、允许操作用户、项目检查环境和角色模型配置。token 由人工在本机输入，不发送聊天或写入仓库。
3. 实际执行：经明确授权后用一个专用测试 Issue，验证隔离编码、检查、Review 与 Draft MR。模型接触私有代码和远端写操作分别确认。
4. 人工验收与安装：验证桌面/手机以及 4DGS 播放、控制、后台行为，按结果决定是否安装或合并。

`luca` 的后端检查入口为 `python3 backend/test_backend.py`，依赖 Java 17+。模型测试另需 NumPy、原始模型资产与修正后的数据路径，不可用通用 `true` 或缺失资产跳过来声明通过。

## 验证记录

环境：`localhost/symphony-gitlab-check:20261015` 容器（Debian、Elixir 1.19.6/OTP 28、含 `git`、`python3`、`ca-certificates`），`--network=none`，挂载本工作区。以下都是本地合成验证；没有连接真实 GitLab、没有调用模型、没有写入远端。

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| `mix format --check-formatted` | 通过 | `.local/test-image/` 同轮日志 |
| `mix specs.check` | 通过，所有公开函数有 `@spec` | 同上 |
| `mix credo --strict` | 通过，0 issues | 同上 |
| 目标回归：GitLab 交付/入站/传输/适配器 + GitHub 外部恢复、任务与执行器 | 208 tests, 0 failures | `.local/test-image/target-tests.log` |
| `mix dialyzer --format short`（`MIX_ENV=dev`，容器 PLT） | 0 errors | `.local/test-image/dialyzer.log` |
| 全量 `mix test --cover` | 855 tests, 8 failures, 6 skipped；覆盖率 99.98%（门槛 100%） | `.local/test-image/full-cover-5.log` |
| View：`node --test tests/rounds.test.mjs tests/model-settings.test.mjs` | 13 tests, 0 failures | 主机 Node 24.21.0 |
| View：`python3 -B -m unittest discover -s tests` | 46 项中 45 通过；1 项因缺少 `codex-transcript-viewer` 报错 | 主机 Python 3.14.4 |

全量套件里 8 个失败全部在 `MvpModelRoutingTest`，原因是该容器没有真实 Codex 客户端：断言直接报 `Codex client unavailable: /opt/codex`，另有 `{:port_exit, 127}`（容器内 `command -v codex` 退出码 127）。同一原因使 `SymphonyElixir.Mvp.LegacyModelService` 停在 98.94%（未覆盖行 `command_config(["-c" <> value | rest], ...)` 只在真实 Codex 命令行分支执行），该模块本分支未改动。除它之外 78 个模块全部为 100.00%，包含新增的 `SymphonyElixir.Mvp.Forge` 与本轮改动的 `Mvp.Delivery`、`Mvp.ExternalDraft`、`Mvp.Feedback`、`Mvp.Intake`、`Mvp.Preflight`、`Mvp.Receipt`、`Mvp.Config`、`Mvp.ModelSettings`、`Mix.Tasks.Mvp.External`。

以上都不构成真实接入证据：没有可信 CA/证书、没有受限 token、没有确认推送权限，也没有让模型接触 luca 私有代码。luca 的桌面/手机查看、4DGS 播放与控制体验仍需人工验收。
