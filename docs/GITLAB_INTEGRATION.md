# GitLab 与 luca 接入

## 当前部署与交付（2026-10-21）

当前在独立 VM 原生运行固定版本 `9cf6c1701f26-20261021`，其源码是远端 main 的 PR #20 合并提交 `9cf6c17`。唯一真实验收替代任务 [GL-4](https://81.71.154.125:8443/innovation/luca/-/work_items/4) 已通过真实 Docker 正式检查与 20 项独立 Review，交付 [Draft MR !3](https://81.71.154.125:8443/innovation/luca/-/merge_requests/3)，准确候选为 `267aa8f24c57d857f4bdc651099c7e5d903a22c3`。状态 awaiting_human，MR 未合并，luca 未部署；旧 GL-3 的 blocked 历史不变。

前段两次部署故障需人工审计接续，因此“首次 ready 后完全无人干预”仍未通过；最终检查、Review、推送和 MR 创建由控制器完成，没有人工补 Docker 证据。GitLab 拒绝返工/外部条件去重及不确定发布对账有回归，真实 GL-4 Reviewer 首次即批准，不混称实机拒绝返工测试。文中较早的“尚未验证”只描述对应日期。

2026-10-21 清理只涉及宿主旧归档，回执、工作区、证据及远端 MR 未改。现存日备份早于 GL-4；恢复时先保存当前发布记录并对账，不能覆盖成旧快照后重新消费 ready。现存恢复源与已删文件见 [VM_DEPLOYMENT](VM_DEPLOYMENT.md#存储清理与现存恢复源2026-10-21)。

## 2026-10-20 独立 VM 闭环实施

所有者批准将整套服务迁入具备 Docker 和 sudo 的独立 VM，补齐正式检查证据输入、GitLab 自动返工和新任务重启接续，并限一个替代 GL-3 的新 Issue 做真实模型、任务分支推送和 Draft MR 验收。旧 GL-3 的 blocked 历史不变。具体当前状态与证据见 [VM_DEPLOYMENT](VM_DEPLOYMENT.md)，下文日期较早的“尚未验证/未经授权”只描述对应历史操作，不能覆盖本次明确授权，也不能以新授权代替实际验收通过。

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

## 2026-10-16 真实实例验证与首次派发

本节记录 IS-101 落地到真实实例的过程与实测证据。来源为本轮实际执行；其中的配置取值与命令属工程安排，不是用户逐项指定的决定。

### 实例与凭据实测

实例为 GitLab 19.3.2 CE。项目 `innovation/luca`（id 10）`default_branch=main`、`ci_config_path` 为空、`only_allow_merge_if_pipeline_succeeds=false`；仓库根为 Java + Docker（`backend/src/LucaV2Server.java`、`backend/test_backend.py`、`start.sh`），**没有 `elixir/`**。

令牌持有者 `daily`（戴柳逸）在项目中为 Owner，具备 `api`、`read_repository`、`write_repository` 等 scope，与 `allowed_actors: [daily]` 一致——因此添加 `ready` 的账号必须是 `daily`。自签名 CA（SAN 含 `IP:81.71.154.125`）经 `openssl s_client` 实测 `Verify return code: 0 (ok)`，协商 TLSv1.3。项目标签原先为零，现已创建 `ready`；控制器只读取标签、不写标签，故只需这一个。

实例 `ci_config_path` 为空，且系统全库不存在读取 pipeline 状态的代码，**门禁完全由控制器自跑，不需要配置 GitLab CI/CD**。

### `verify_fun` 是必需的（纠正此前的实现描述）

`GitLab.Client.connect_options/1` 中针对自签名证书的 `verify_fun` **不是冗余**。在同一镜像内用 Erlang 探针实测（OTP 28／erts 16.4.0.6）：

| 变体 | 传输选项 | 结果 |
| --- | --- | --- |
| A | `verify_peer` + `cacertfile` | 失败 `bad_certificate / selfsigned_peer`（113ms） |
| B | A + `cacerts` | 失败，同上（59ms） |
| C | B + `verify_fun` | **成功**（67ms；`selfsigned_peer hit: encoded=951 deriv_trusted=true`） |
| D | `verify_none` | 成功（59ms） |
| E | A + 关闭 SNI | 失败，同 A |

OTP 即使证书已在该信任库内，也会对自签名对端返回 `selfsigned_peer`。**因此 main 上曾提交的简化实现（仅传 `cacertfile`）无法连接该实例；从 main 重新构建会静默失去私有 CA 能力。** 该段 `verify_fun` 与自签证书比对已在提交 `5aab130` 正式纳入源码，并已移除冗余的 `cacertfile` 选项以消除 OTP "cacertfile ignored, cacerts is set" 噪声。

### `WORKFLOW.md` 必须保持纯 ASCII

配置解析器 yamerl 不接受非 ASCII 字节：加入中文注释后，`--preflight` 与控制器启动都会以 `{:workflow_parse_error, %YamlElixir.ParsingError{type: :invalid_unicode}}` 失败，即使文件本身是合法 UTF-8。**这是运维硬约束**：带非 ASCII 的配置重启会使控制器起不来。已在 `.local/WORKFLOW.md` 内留下提醒注释。

### luca 的检查门禁配置

`mvp.checks` 从 Elixir 专用（`check_candidate.py` / `check_baseline.py`，内部执行 `mix` 系列）改为 `[python3, "{workspace}/backend/test_backend.py"]`。

**必须用 `{workspace}` 而非 `{baseline}`**：`test_backend.py` 以 `ROOT = Path(__file__).resolve().parents[1]` 推导项目根（据此编译 `backend/src/LucaV2Server.java`、执行 `start.sh`），且不接收任何命令行参数。指向 `{baseline}` 只会在基线快照上运行，**永远测不到候选改动**。luca 与自迭代仓库不同——它的检查脚本只能来自候选自身，无法照搬"冻结脚本 + 候选参数"的模式；防篡改依赖独立 Reviewer 审阅完整 diff（CODER_EXECUTION_RULES 的 B3）。

### 真实实例实测结果

| 项目 | 结果 |
| --- | --- |
| `--preflight`（真实 escript，与控制器轮询同一代码路径） | 连续 3 次 `{"status":"passed","mode":"preflight","issue_count":0}`，每次约 0.8s |
| 检查门禁 `python3 backend/test_backend.py` | `PASS`，退出码 0，耗时 7s |
| 容器工具链 | javac 21.0.12.1 / java 21 / Python 3.13.5 / numpy 2.2.4 / git |
| 宿主机与容器内 curl | 均 0.08s 返回 401 |

控制器日志中 08:22–09:36 UTC 的 `{:gitlab_api_request, :timeout}` 为**间歇性**现象（每次轮询在 SSL 配置告警后卡满 30 秒），preflight 实测不复现；倾向宿主机经 FlClash（Clash tun 模式，`198.18.0.0/16` fake-IP 段，`ip route get` 显示 `dev FlClash`）代理路径的偶发卡顿，非代码缺陷。控制器每 30s 重试，偶发超时只延迟领取。

### 首次真实派发（GL-1）与阻塞

Issue #1（`feat: add public /api/health endpoint and integration test`）由 `daily` 添加 `ready` 后，控制器于 10:22:48 自动领取并建立工作区 `/var/tmp/innovation-symphony-linux-runtime/workspaces/GL-1`，随后在建立 Codex 线程时阻塞：

```
{:response_error, %{"code" => -32600,
 "message" => "Invalid request: unknown variant `reject`, expected one of
  `untrusted`, `on-request`, `granular`, `never`"}}
```

原因是 `codex.approval_policy` 使用了已废弃的 `reject` 结构（`Config.Schema` 的默认值仍是它）。当前客户端只接受 `untrusted` / `on-request` / `granular` / `never`；`granular` 含五个布尔位 `sandbox_approval`、`rules`、`skill_approval`、`request_permissions`、`mcp_elicitations`。

本次阻塞发生在任何模型调用之前（`session_id` 为空、用量为 0、无候选 SHA），但**回执已写入 `base_sha`**（`ced3e7ec...`），因此不满足 `mvp.release` 的前置条件，控制器也不会自动重领（`executor.ex` 以非空 `base_sha` 判定 `:mvp_execution_already_started`）。处置须走操作者核验后的完整归档路径，见 [OPERATIONS](OPERATIONS.md)。

### 尚未验证

- **推送与 Draft MR 交付链路未经真实验证**。读取、配置与门禁已实测，但 `git push`、MR 创建与交付后的身份核对尚未在真实实例上跑通。
- `mvp.sandbox.enabled` 仍为 `false`，本轮走非隔离兼容路径；隔离是 CODER_EXECUTION_RULES 的四条底线之一，正式使用前需单独安排。
- 检查门禁覆盖面窄：只覆盖 `backend/test_backend.py`（Java 后端）。luca 新增的 `scripts/tests/*.test.cjs`（Node）与 `test_dance_4dgs.py` 等不在门禁内。
- 2026-10-16 的 luca 提交 `ced3e7ec` 做了 Luka→Luca 全项目改名（环境变量 `LUKA_V2_*` → `LUCA_V2_*`、源文件更名为 `backend/src/LucaV2Server.java`），并删除了 `public/models/*` 模型资源。门禁脚本与 Java 源在同一提交内同步更名，交叉核对无错配；但**改名后未再实跑门禁**。模型资源删除后，需要模型测试的任务当前无法满足其资产条件。

## 分阶段验收与待办

1. 本地代码与回归：已完成，结果见下方验证记录。
2. 只读实例预检：**已于 2026-10-16 在真实实例完成**（`--preflight` 连续 3 次通过），见上节。
3. 实际执行：**进行中**。首次派发（GL-1）在建立 Codex 线程时因 `approval_policy` 格式废弃而阻塞，属编码前停点；修正配置并释放回执后需重新派发，验证隔离编码、检查、Review 与 Draft MR。
4. 人工验收与安装：未开始。验证桌面/手机以及 4DGS 播放、控制、后台行为，按结果决定是否安装或合并。

`luca` 的后端检查入口为 `python3 backend/test_backend.py`，依赖 Java 17+（实测容器内为 openjdk 21.0.12.1）。**注意：2026-10-16 的提交 `ced3e7ec` 已删除 `public/models/*` 模型资源，此前"模型测试另需 NumPy、原始模型资产与修正后的数据路径"的条件现已无法满足**，需要模型测试的任务在补齐资产前不可派发。不得用通用 `true` 或缺失资产跳过来声明通过。

## 验证记录

**范围区分：** 2026-10-16 之前记录的均为本地合成验证（`--network=none`，未连接真实 GitLab、未调用模型、未写远端）；2026-10-16 的真实实例验证单独记录于上文"真实实例验证与首次派发"一节。两者不可互相替代。

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


2026-10-21：VM 已切换本机原端口，固定 release 与备份/独立恢复验收见 VM_DEPLOYMENT。只创建替代任务 GL-4；首次 Git fetch 120 秒超时已通过保留原合同的审计接续完成；随后两次实际模型调用因缺失 Codex 原生执行组件均未能读取或修改项目，在诊断阶段 blocked，尚无 Draft MR。原始回执、停止记录及冻结预算保留，已补齐同版 helper 并通过无模型只读沙箱探针，同任务显式审计接续已进入第 2 轮编码，累计调用 3 次，原预算起点不变。这些人工部署修复不记作首次 ready 后无人干预闭环通过。原 GL-3 保持历史状态。

2026-10-21 最终交付：GL-4 已进入 awaiting_human，独立 deepseek-v4-flash/high Reviewer 批准 20 项验收；[Draft MR !3](https://81.71.154.125:8443/innovation/luca/-/merge_requests/3) 为 opened/draft、目标 main，远端分支/MR SHA 与候选 267aa8f24c57d857f4bdc651099c7e5d903a22c3 一致。两项正式检查包含真实 Docker，未人工补验收证据。GL-4 累计 4 次模型调用、一次返工、原预算未归零。前段两次部署故障人工审计接续保留，不以最终交付声称首次 ready 后全程无人干预通过。GitLab 代码拒绝返工和 awaiting_external 去重已由回归覆盖；本次实机 Reviewer 首次即批准，未把回归误报为实机拒绝返工。
