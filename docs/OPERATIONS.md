# 原型运行与项目交付

## 外部条件接手

`awaiting_external` 表示控制器已保存候选和交接记录并结束本次执行。操作者先运行 `mix mvp.external status RECEIPT.json` 查看缺失条目、所需证据和接手责任，按已有权限完成外部工作，再用绑定原回执摘要的请求调用 `mix mvp.external resume WORKFLOW.md RECEIPT.json REQUEST.json`。具体字段、冻结条件、证据格式与预算规则见 [EXTERNAL_HANDOFF.md](EXTERNAL_HANDOFF.md)。

此入口不会解除维护暂停、增加预算或自动迁移旧 `blocked` 回执；实现和运行安装状态分别记录在该合同的实施状态中。

## 看门狗维护流程（待 005 交付后适用）

本节对应 [005 看门狗草稿](issue-drafts/005-watchdog.md)，记录后续安装看门狗后的操作纪律；当前没有安装或验证看门狗，下面不是现有命令已可用的声明。交付时须补充实际命令及验收证据。

1. 首次启用前，配置无人值守启动所需凭据（部署环境变量或受限权限文件等），记录来源类别、权限和注入方式，不记录秘密值。在验收环境证明运行器退出后无需人工取 token、输入或登录就能自动拉起；没有该证据，WD-1 不能通过。
2. 人工维护或停机前，先设置持久维护暂停，并通过状态读取确认已生效。看门狗暂停仅禁止自动拉起，不停止任务领取或在途任务；仍须按已有运行器规则处理领取及在途工作，核实允许停机后再停止运行器。不通过清空回执或证据实现停机。
3. 若忘记暂停便直接停止运行器，无论正常退出还是异常退出，看门狗都会在其他启动条件满足后尝试恢复。终端退出、看门狗重启或等待都不会解除已设置的暂停。
4. 维护完成后，核对外部操作者设置的版本指针、凭据来源、进程身份与版本预算，明确解除维护暂停。预算已耗尽时，必须另行执行该版本的人工恢复操作并保留旧终态与证据；解除暂停不等于重置预算。随后核对实际运行版本、进程身份和本地动作记录。
5. 宿主重启不在本期自动恢复范围。在没有另外部署自启机制时，由操作者恢复 WSL／Linux 环境并重新启动值守入口；先核对持久维护暂停、指针、预算及现存进程，不默认清空状态。若停机发生在未来升级流程中，须按后续 002 的升级恢复合同处理，当前不提供自动续接或回退承诺。

## 2026-09-29 GPT 模型白名单扩充与同版本重启

- 按 IS-029，用户明确要求“加入gpt系所有模型，重启服务”。使用运行器实际 Codex 二进制及同一 CODEX_HOME，按 [OpenAI App Server 文档](https://learn.chatgpt.com/docs/app-server) 查询分页 `model/list`，包含隐藏项；本次目录返回 8 个 GPT 型号。
- 当前 `runtime-v1/WORKFLOW.md` 的白名单为：`gpt-6-astra`、`gpt-6-sol`、`gpt-6-luna`、`gpt-5.6-sol`、`gpt-5.6-terra`、`gpt-5.6-luna`、`gpt-5.5`、`gpt-reserve`。最后一项在目录中标记为隐藏；全部返回支持 `high`。这是一份本次实际查询的配置快照，不是任意模型通配符，也不自动纳入未来新增型号。
- 默认编码与 Review 仍为 `gpt-6-astra`，原推理配置与恢复策略保持不变。通过固定安装的配置校验及评论解析器，逐个验证每个白名单型号同时作为 coder/reviewer 的指令；没有启动真实模型任务，不将目录或解析成功描述为逐型号推理实测。
- 17:39（Asia/Shanghai）完成重启：原 PID `3268970` 已退出，新 PID `1173655` 的 cwd 与固定安装 `11acc1b8b40d471247b60b55d92239ea6ae81a1d` 一致，状态接口返回 HTTP 200，running/retrying/blocked 均为 0。启动前后只读查询的 open/claimable Issue 均为 0，正常 ready 领取已恢复。
- 操作先备份配置，验证候选配置并确认空闲，再暂停新领取、停止旧进程及使用原启动器重启。沿用 `state/attempt-4` 和原工作区，576 项历史状态与证据条目内容不变，原 `previous-release.json` 也已保留；未改变运行版本、任务回执、远端标签或评论。
- 模型目录及结果保存在本机 `.local/model-whitelist-20260929/`；运行侧备份及脱敏验证日志在 `/var/tmp/innovation-symphony-v0-rerun1/operator-model-whitelist-20260929T093856Z/`。较早的 `operator-model-whitelist-20260929T093813Z/` 保留一次 Mix 验证参数传递错误的日志，该次失败发生在运行配置修改和停机之前；修正参数后验证与重启通过。本条记录本地配置变更与重启，不代表远端发布。

## 2026-09-29 当前 main 安装与运行切换

- 按 IS-028，用户明确要求安装当前 main。PR #4 已合并；安装固定提交 `11acc1b8b40d471247b60b55d92239ea6ae81a1d`，其 [GitHub CI](https://github.com/dailiuyi/innovation-symphony/actions/runs/36545295566) 成功。该提交与此前通过 478 项 Elixir 测试（0 失败、6 跳过、覆盖率 100%）及 28 项 Python 集成测试的冲突修复内容一致。
- WSL `desktop` 独立安装目录：`/var/tmp/innovation-symphony-v0-rerun1/releases/11acc1b8b40d471247b60b55d92239ea6ae81a1d`。从固定 Git 提交安装，重新编译和 escript 构建通过，安装工作树干净。
- 新版实际 `--preflight` 通过真实 GitHub 只读查询，返回 `status=passed`、`issue_count=0`；旧进程空闲后暂停领取并退出，新进程 PID `3268970` 的 cwd 与固定安装一致。
- 沿用 `runtime-v1`、`state/attempt-4`、`workspaces/v1`。编码和 Review 仍为 Astra，恢复策略及预算未改变；仅将启动器、工具链包装器和检查脚本路径指向新安装。新服务恢复原有 ready 领取配置。
- 状态接口 `http://127.0.0.1:43223/api/v1/state` 返回 HTTP 200，running/retrying/blocked 均为 0；两份历史回执及证据所在的 576 项目录、文件、链接条目内容全部保持不变。
- 旧 `07f7493` 安装及运行文件备份保留，`previous-release.json` 记录实际旧版本。本机证据在 `.local/main-switch-11acc1b/`，运行侧备份在 `operator-main-switch-11acc1b8b40d/runtime-before/`。未新建或重新派发 Issue，未配置云部署或开机自启动；本次人工切换不作为完整自动接棒或回退演练的验收。

以下章节保留各次交付时的历史状态；当前运行版本以上述固定提交为准。

## 2026-09-29 自动恢复实测

控制器 `07f74936f77e30c6337da70a1fec9476a61eac8f` 已发布、通过 CI 并安装在本地 WSL。Issue #3 保留原五次返工，通过自动诊断及两次新增编码，自动处理一次真实测试失败后通过完整检查和独立 Review，交付 [Draft PR #4](https://github.com/dailiuyi/innovation-symphony/pull/4)。完整版本、检查数字和证据见 [验收记录](VALIDATION_AUTOMATIC_RECOVERY.md)。

运行入口仍为 `runtime-v1`，状态目录仍为 `state/attempt-4`，intake 已恢复，历史证据未清空。PR 候选尚未合并或安装；按 IS-027，与 main 的冲突由人处理，停止自动集成扩展，不持续追赶主分支。下文保留此前各次启动与切换的历史记录。

## 当前状态

已在官方 Elixir 源码基础上实现本地 GitHub MVP，包括确定性评论解析、检查、独立 Review 与 Draft PR 交付链；需求文档和后台 HTML 原型继续保留。私有 GitHub 仓库和真实 Issue #1 已接入；经过环境隔离与中断分支修复，PR #2 已由用户合并。2026-09-29 按 IS-019 授权切换本地 WSL 运行器，运行版本及状态见文末记录。尚未部署云服务；历史验证见 [VALIDATION_V0.md](VALIDATION_V0.md)。

本机目录为 `E:\code\innovation-symphony`，远端为私有仓库 `dailiuyi/innovation-symphony`，已有 V0 基线提交。提交及运行状态以当前 Git 和回执核实。

## 预览

在项目根目录运行：

```sh
python -m http.server 43221 --bind 127.0.0.1 --directory prototypes
```

访问 [原型](http://127.0.0.1:43221/symphony-dashboard.html)，或直接用浏览器打开 `prototypes/symphony-dashboard.html`。端口被占用时先确认归属，不关闭无关服务。预览服务只绑定本机，不能据此宣称已经部署到云端。

筛选任务、查看日志、选择仓库默认模型都只操作演示数据。选择保存在当前页面内存，刷新会重置；已有演示任务继续显示原来的模型快照。实际 MVP 从工作流读取默认值并解析 Issue 评论，尚未与此原型页面连接。

## 架构审核图预览

架构图包含本地文档链接，建议从项目根目录提供预览，而不是仅提供 prototypes 目录：

```sh
python -m http.server 43222 --bind 127.0.0.1 --directory E:\code\innovation-symphony
```

打开 [第一版实际架构](http://127.0.0.1:43222/prototypes/mvp-architecture.html)。此前的 [架构审核提案](http://127.0.0.1:43222/prototypes/architecture-review.html) 作为历史讨论保留。也可直接打开 HTML 文件。模块点击仅切换展示，不提交决定或触发执行。

## 抽离来源

2026-09-28，从博客活动托管工作树的框架提案、D-016 决策及后台 HTML 原型抽离。来源本机路径为 `C:\Users\emla\.codex\worktrees\symphony-label-intake\astro-blog`。

原型迁入后将启动说明改为 ready 自动领取；文档重新分为已确认需求、决策、协议草案、待讨论问题和架构建议。旧博客保留迁移说明，不继续在那里维护完整框架正文。旧博客的固定 Review 模型、运行合同、队列、凭据和安装快照没有迁入。

本机历史上可能已有其他项目使用 `innovation-symphony` 作为容器或镜像名称。本次新建的是源码项目；没有认领、重启、替换或迁移那些服务。未来命名运行服务前须检查归属。

## 验证与状态边界

2026-09-28，抽离后验证通过：9 份 Markdown 的 17 个本地链接均可解析；HTTP 预览内容与新项目 HTML 一致；ready 自动领取文案、任务筛选、模型选择、1440px 桌面截图和 390px 手机布局检查通过，无浏览器脚本错误。独立只读审查发现原型曾以 ready 命名“待人工审查”，已改为独立内部状态 awaiting_review，ready 保留为启动门槛。

保存文件、Git 提交、发布到远端、安装执行服务与云端部署分别报告。真实任务派发及提供商调用已发生，PR #2 已合并且用户已授权运行版本切换；完整自迭代闭环与回退演练仍需验收。

## 2026-09-29：PR #2 合并后的本地版本切换

- GitHub 合并提交：`003a0db85da88ef79b882433108df2f3d782c092`；内容与通过审查的候选 `5867d36` 一致，合并后的 CI 成功。
- WSL 发行版：`desktop`。固定安装：`/var/tmp/innovation-symphony-v0-rerun1/releases/003a0db85da88ef79b882433108df2f3d782c092`。
- 运行配置与 PID：`/var/tmp/innovation-symphony-v0-rerun1/runtime-v1/WORKFLOW.md`、`pid.json`；日志在同目录 `logs/log/symphony.log.1`。
- 本地状态页：`http://127.0.0.1:43223/`；状态 API：`/api/v1/state`，仅绑定回环地址。
- 已显式启用 `max_rework: 2`。串行处理本仓库 ready Issue；保持编码与 Review 模型冻结及独立审查，失败停止边界不变。
- 继续原地使用 `state/attempt-4` 的领取与交付记录，未清空状态。新任务工作区为 `workspaces/v1`，旧候选工作区不受启动清理影响。
- 旧固定安装 `runner-replay`（`50955cf`）和全部历史回执、候选证据保留。回退必须先停当前进程并确认没有活动任务，沿用最新状态及新工作区路径；旧版配置将 max_rework 改为 0，不能恢复旧状态备份覆盖新记录。
- 以后台进程运行，未安装 Windows/WSL 开机自启动或自动重启服务。凭据通过标准输入交给启动器后仅保存在控制器环境中；关闭进程后重新启动需重新提供凭据。
- 本次只验证固定版本构建、真实 GitHub 读取、原回执保留、进程与状态接口；没有创建新的测试 Issue，不把空队列启动视为真实自动返工闭环验收。

本机操作和检查证据保存在 `.local/runtime-switch/`（忽略目录，不提交凭据或运行状态）。启动入口为 runtime-v1/launch.py，启动时拒绝已有 PID、端口冲突或预检发现非空待执行队列；该保守空队列要求是本次安装验收安排，不是产品 ready 协议的新规则。

### 2026-09-29：重启服务与发布下一项 Issue

- 按 IS-020 启动已安装的 `003a0db85da88ef79b882433108df2f3d782c092`。发现旧进程已退出、端口未监听，原 `/tmp/innovation-symphony-toolchain` 已丢失；固定安装、领取记录和 evidence 仍在。
- 恢复相同版本 Erlang 28.5 / Elixir 1.19.5-otp-28 及 Hex/Rebar，工具链改放 `/var/tmp/innovation-symphony-toolchain`；更新本机 `runtime-v1/runtime-env.sh` 的路径并保留原包装器备份。这是本次启动修复，不是新部署架构或运行版本升级。
- 启动预检通过：真实 GitHub ready 队列为空、Issue #1 关闭且原回执保留、`max_rework=2`。新进程 PID 638，状态接口返回 HTTP 200，running/retrying/blocked 均为 0。
- 已审阅并发布 [Issue #3](https://github.com/dailiuyi/innovation-symphony/issues/3)，保持无标签，等待人工修改；升级接棒功能尚未实现。草稿已补充回执重派、Review 完成边界、接管前体检门禁及生命周期竞态的审阅结果。
- 本轮文档仅保存到本地，未提交或推送；Issue 已发布，服务本地运行，未配置开机自启动或云部署。

### 2026-09-29：再次启动服务与预检门槛修正

- 再次启动已安装的 `003a0db85da88ef79b882433108df2f3d782c092`。启动前核实：旧进程已退出、端口 43223 空闲、工具链在 `/var/tmp/innovation-symphony-toolchain`；凭据取自本机 `gh` 活跃账号（dailiuyi），经标准输入交给启动器，未写入文档、仓库或本记录。
- 首次预检失败：原 `preflight.exs` 以 `[] = candidates` 把 open 状态的全部 Issue 视为待执行队列，而 Issue #3 按发布边界保持无标签、等待人工维护。运行时领取需同时满足 tracker `required_labels: [ready]`（`Tracker.Issue.routable?/2`）与 `Mvp.Intake.ready?/2`，无标签 Issue 不会被领取。
- 修正：预检断言改为"不存在任何 open Issue 可被运行时领取"（复用上述两个运行时判定），门槛意图不变——带着可执行 ready 任务启动仍然拒绝。原预检保留为 `runtime-v1/preflight.exs.empty-queue.bak`，新脚本同步存放于本机忽略目录 `.local/runtime-switch/preflight.claimable.exs`。
- 预检通过：`PREFLIGHT_OK max_rework=2 claimable_queue=0 open_issues=1 issue1_receipt_retained=true usage_aggregate_loaded=true`。新进程 PID 447，状态接口 HTTP 200，running/retrying/blocked 均为 0。
- Issue #3 保持无标签等待人工处理；服务运行期间人工打上 ready 即会被自动领取。仍未配置开机自启动，WSL 关闭或重启后进程退出，再次启动需重新提供凭据。
- 本次只改动运行目录预检脚本与本文档，未触碰安装版本代码、WORKFLOW 配置或状态目录。

## 官方实现与 V0 本地检查

### 2026-09-29：修复 escript 静默跳过 ready Issue

- 故障：旧版打包 escript 的 `:code.lib_dir(:symphony_elixir)` 返回归档内虚拟路径，MVP 路径隔离校验报 `enotdir`；`Mvp.available?/1` 将配置错误当成不可领取，状态页仍可正常访问，因此空闲页面和 HTTP 200 未揭示故障。
- 修复本地提交及实际运行版本：`94e376803ea1e7332e6a927d6871c1f385593204`，独立安装在同名 `releases/` 目录。归档路径使用解析符号链接后的实体工件目录，工件丢失时停止派发；每轮配置错误会明确记日志。旧 `003a0db` 安装保留。
- 验证：380 tests、0 failures、6 个既有实平台测试跳过；覆盖率达到现有配置要求的 100%；format、lint/specs、dialyzer、build 与独立审查通过。一次上游重试时钟断言差 2ms，同 seed 完整重跑通过，未修改该断言。真实 escript 子进程覆盖合法 ready 候选、目录重叠及符号链接边界。
- 按 IS-021 预检 ready 操作者及队列只包含获准的 Issue #3 后切换；沿用 state/attempt-4 和 workspaces/v1，原有 161 个状态/证据文件哈希不变。启动器端口探测增加 SO_REUSEADDR，避免旧连接 TIME_WAIT 被误判为仍有监听服务；仍拒绝真实端口占用。
- 11:31（Asia/Shanghai）自动领取 GH-3，PID 13384，11:32 回执为 `coding`，已有实际 Codex 会话及 token 用量。编码与独立 Review 均为 `gpt-6-astra`，沿用 `high`；尚未证明该 Issue 完成交付。
- 启动入口仍为 runtime-v1/launch.py；此次显式准入仅用于获准的 #3，启动后恢复原来的空可领取队列预检，未修改 ready 标签。修复提交尚未推送远端；GH-3 冻结的远端任务 base 仍为 `003a0db`，以后合并候选时须同时保留本次领取修复。
- 本机证据保存在 `.local/intake-repair/`：release.json、applied.json、running-evidence.json；安装切换前的启动器与 PID 记录位于 runtime-v1/before-intake-fix-94e3768。未自动合并或安装 GH-3 产生的候选，也未配置云部署。

保留上游 WORKFLOW.md 仅为参考；本项目使用 WORKFLOW.github.example.md，复制到独立运行目录后填写配置。不要把原 Linear 示例当作本项目执行入口。

运行要求：Linux/WSL、Elixir 1.19.x / OTP 28（沿用官方 mise.toml）、Git、GNU timeout、Python 3，以及原生 Linux Codex CLI。必须确认 `codex` 不是 `/mnt/c` 的 Windows npm 包装脚本。首次接入前先准备独立运行目录、工作区和状态目录；本次没有安装常驻服务。

```sh
cd elixir
mix deps.get
GITHUB_REPO=example/example GITHUB_TOKEN=local-validation-only mix mvp.check "$PWD/WORKFLOW.github.example.md"
mix format --check-formatted
mix lint
mix test
mix test --cover
mix dialyzer --format short
mix build
```

`mvp.check` 不连接 GitHub、不验证模型可用性、不启动调度。上方 example/example 和 local-validation-only 是本地解析占位值，不是仓库或凭据。未设置 repo/token 时检查会报配置缺失。默认 disabled 可安全核对模板；运行目录中的工作流填写真实值后再检查。`mvp.enabled=false` 表示暂停新派发，需停止进程才能确保当前工作也已停止；不要删除整个 mvp 配置块来停机。

本仓库已获得明确接入及 Issue #1 派发授权。新接入时设置 GITHUB_REPO/GITHUB_TOKEN、模型白名单与允许的 ready 操作者，将 mvp.enabled 设为 true，并使用上游 CLI 的显式 guardrails acknowledgement 开关启动。首次启用会扫描获准的存量 ready Issue，不能作为只读连通性测试。

自迭代运行时，固定版本 A 安装在候选工作区之外。修改发生在 B 的工作区；PR 待人审核。完整领取状态及 evidence 必须在升级时保留，已进入编码/发布阶段的失败不自动重试。具体恢复命令见 IMPLEMENTATION_V0.md。

### GH-3 只读体检

新增 `--preflight` 用于独立进程中加载候选配置并只读查询 GitHub；它直接退出，不启动调度。配置须为完整且已启用的 GitHub MVP 配置；停用模板不能作为候选可接管的证据。与 `mvp.check` 不同，这会访问配置指定的 GitHub 仓库，执行前需有该仓库的读取授权。

以下是调用示例，不是安装、切换或已执行记录。`CANDIDATE_ESCRIPT` 和 `CANDIDATE_WORKFLOW` 指向隔离的固定安装及配置；`PREFLIGHT_TIMEOUT` 由操作者明确指定 GNU timeout 时限，本次没有确定产品默认值。

```sh
timeout --signal=KILL "${PREFLIGHT_TIMEOUT:?set an explicit duration}" \
  "${CANDIDATE_ESCRIPT:?set the fixed candidate path}" \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --preflight "${CANDIDATE_WORKFLOW:?set the candidate workflow path}"
```

保存标准输出、标准错误和退出码：0 表示配置及只读轮询通过，非零（包括外部超时）表示未通过。成功输出示例：`{"mode":"preflight","status":"passed","issue_count":0}`。体检不验证模型、命令执行或回执兼容性；成功不自动接管，也不证明 A 已退出。A 收尾、升级/回退入口仍未实现，完整边界见 [实现合同](IMPLEMENTATION_V0.md#gh-3-最小增量接管前只读体检)。

体检的标准输出仅包含成功 JSON；重试日志和失败原因写入标准错误，解析 JSON 时不要合并两个输出流。沿用客户端的有界安全重试；重试后查询成功仍可通过，耗尽重试或任一页含未知状态、畸形记录则失败，不计为合法空队列。日志重定向仅用于退出式 CLI 体检，不改变正常服务的日志配置。

### 检查环境与显式重跑

`scripts/check_candidate.py` 和 `scripts/check_baseline.py` 调用 Mix 时移除 `GITHUB_REPO`、`GITHUB_TOKEN`、`GH_TOKEN`。保留 PATH、Mix/Hex/mise 缓存等构建配置；不修改父进程环境。控制器已有的动态凭据过滤继续适用。这是当前 GitHub MVP 的配置隔离，不是通用环境白名单或安全沙箱。

回归命令：`python3 -m unittest discover -s scripts/tests -v`。检查步骤、错误传播及覆盖率门槛保持不变。

检查入口在导入共享辅助模块前禁用 Python 字节码写入，防止 `__pycache__` 改变冻结基线指纹。回归测试实际执行两个归档入口，并逐文件比较执行前后的基线；完整性校验不排除缓存文件或放宽匹配。

首轮失败候选保留在 `/var/tmp/innovation-symphony-v0/workspaces/GH-1`，回执与证据在同级 `state` 目录。经本次显式重跑授权，使用独立的运行目录、状态目录、工作区；启动前核对队列只有获准的 Issue，记录原回执和新基线 SHA。禁止通过清空原状态目录实现重试。新轮仍停在 Draft PR 或 blocked，结果单独报告。
