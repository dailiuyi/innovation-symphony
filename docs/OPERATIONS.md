# 原型运行与项目交付

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

## 看门狗维护流程（待 005 交付后适用）

以下是 GH-5 源码交付后的操作合同；当前运行服务尚未安装或启用看门狗。值守只处理进程退出，不作健康检查、更新、回退或任务处置。先核实固定安装、`WORKFLOW.md` 的状态目录及工作区、Elixir/OTP 和原生 Linux `codex`、Git、GNU timeout、`flock`、`setsid`、`sh` 所在的 `PATH`，再配置新入口。旧 `runtime-v1/launch.py` 是历史安装脚本，不参与新互斥；接入看门狗前须人工暂停值守、结束该旧入口启动的进程并核实退出。其一次性空队列预检不属于 ready 领取规则。

看门狗配置为 JSON，以下路径和数字均是工程示例，按实际固定安装填写。`controller` 是含本代码的打包 `bin/symphony`；`state_dir`、`status_file`、`maintenance_file` 与 `pointer_file` 必须位于持久目录，不能放在临时清理目录。`workflow` 是原运行配置的**同一个绝对路径**；不复制、重建或清空其中指定的状态与工作区。值守按 CLI `--port` 优先、否则 `WORKFLOW.md` 的 `server.port` 确定实际端口；配置 `port` 时即作为 `--port` 覆盖工作流端口。值守用同一端口检查启动冲突、构造启动参数及核对进程命令；工作流端口无效时阻塞启动。运行中的进程端口没有响应不会触发另启。

```json
{
  "controller": "/srv/symphony/watchdog/bin/symphony",
  "pointer_file": "/srv/symphony/runtime/current.json",
  "state_dir": "/srv/symphony/runtime/watchdog",
  "status_file": "/srv/symphony/runtime/watchdog/status.json",
  "maintenance_file": "/srv/symphony/runtime/watchdog/maintenance.lock",
  "workflow": "/srv/symphony/runtime/WORKFLOW.md",
  "credential_file": "/srv/symphony/runtime/github-token",
  "logs_root": "/srv/symphony/runtime/logs",
  "port": 43223,
  "interval_ms": 1000,
  "backoff_ms": 30000,
  "max_attempts": 3,
  "stable_ms": 300000
}
```

指针只由外部操作者写入；看门狗只读。格式为 `{"version":"固定版本目录名","install":"/绝对路径/releases/固定版本目录名"}`。`install/bin/symphony` 必须存在，安装目录及可执行文件路径不能经过符号链接。指针非法、安装不存在时阻塞，不自动选择其他版本；切换指针不会停止仍在运行的旧版。外部更新器写指针和写维护锁属于后续实现。

无人值守 GitHub 凭据来源是 `credential_file`：由操作者预先写入 token，文件须归值守用户所有，权限至多 `0600`，父目录限制无关用户访问。启动时看门狗读取该文件并只通过子进程环境变量 `GITHUB_TOKEN` 注入固定安装，不通过命令参数、指针、状态或审计日志传递。缺失、不可读、空文件或权限不安全时拒绝启动并留脱敏阻塞原因；不得在故障后要求人工从 `gh` 活跃账号重新输入。Codex CLI 所需的其他认证也须在值守用户的受限配置目录中提前完成，值守环境需包含可用的 `CODEX_HOME`、工具链 `PATH` 和仓库访问。验收 WD-1 时记录文件来源、owner/mode、父目录权限、`GITHUB_TOKEN` 注入路径及其他认证的非交互核验结果，不记录秘密值；必须在运行器退出后无人输入或登录仍能拉起，缺少这项实测不能判 WD-1 通过。

本轮离线验收记录：凭据来源为测试在 `symphony-watchdog-*` 临时目录预先创建的普通文件，测试用户拥有该文件，文件权限为 `0600`、父目录为 `0700`；值守读取后仅通过子进程环境变量 `GITHUB_TOKEN` 注入固定安装。打包运行器被强制结束后，未输入、确认或登录，测试观察到新 PID 和新进程环境中的测试 token，并确认状态与审计未含 token。测试工作流禁用任务执行；沙箱没有真实 GitHub 仓库凭据或 Codex 认证，因此**真实 GitHub/Codex 无人值守恢复的 WD-1 验收未执行，不能判通过**。实际安装验收须记录真实文件来源、owner/mode、父目录权限、注入路径和其他认证的非交互核验结果，不记录秘密值；随后在无人输入或登录的情况下结束运行器，核对固定安装恢复、GitHub 查询及 Codex 可用性，并保存脱敏结果。

以下命令使用实际实现的打包入口。人工启动和看门狗每轮检查都由同一个 `flock` 服务锁串行复核身份、维护状态、端口、预算，并覆盖启动和身份落盘。锁及持久绑定文件位于规范化 `workflow` 的父目录，以 workflow 路径摘要命名；该目录须允许值守用户创建文件。绑定记录规范化的 workflow、状态目录、状态文件、维护锁和指针路径；同一服务使用冲突路径的配置会被拒绝，不能通过换 `state_dir` 绕开互斥或预算。绑定异常另记于同目录的 `.binding-events.jsonl`，供核对冲突配置与时间。`status` 输出 JSON；`status.json` 保存当前指针、记录的运行进程 `process`、本次核对读到的 `observed`、暂停、每版本本轮尝试数、退避时间、待人工及最近动作。正常归属时，两者均含实际版本及 PID/宿主启动 ID/进程启动时间；身份冲突时，`process` 保留旧记录，`observed` 留本次可读取的身份字段，未知字段不猜测。`history.jsonl` 追加每轮检查、退出、拉起、阻塞、放弃与人工操作，包含可恢复的完整状态快照；历史不会因稳定清零或人工恢复而删除。读取状态时核对审计末尾事件的计数及快照；审计已写而状态尚未替换时，从末尾事件恢复后重新核对进程。末尾事件损坏、计数跳跃或状态与对应事件不符时阻止启动，不重置预算。完整历史保留供离线审计。外层 CLI 的 controller 缺失、子进程失败及响应异常也保存为脱敏阻塞事件。`runner.log` 只保存子进程输出。身份冲突、记录缺失但发现疑似运行器、未知端口占用均阻塞，操作员须核对证据和进程归属，不要结束未知进程。运行器退出后的退避从首次确认退出时重新计时；启动失败则从确认失败时计时，并将截止时间写入状态。

```sh
WATCHDOG=/srv/symphony/watchdog/bin/symphony
CONFIG=/srv/symphony/runtime/watchdog.json
"$WATCHDOG" --watchdog status "$CONFIG"
"$WATCHDOG" --watchdog pause "$CONFIG"
# 核对 status.json 的 paused=true 后，人工停止已确认归属的运行器。
"$WATCHDOG" --watchdog resume "$CONFIG"
"$WATCHDOG" --watchdog start "$CONFIG"
# 仅同版本预算耗尽且故障已修复时，明确开启新一轮；不会解除维护暂停。
"$WATCHDOG" --watchdog recover "$CONFIG"
"$WATCHDOG" --watchdog run "$CONFIG"
```

`resume` 恢复值守但不绕过退避，也不清除待人工。`recover` 清零**当前指针版本**的本轮预算并保留完整历史，维护暂停仍须另行解除。正常与异常退出均按同一预算和退避处理；持续存活超过 `stable_ms` 只表示进程存在，会清零未耗尽的本轮计数，不代表业务健康。状态端口没有响应不等于进程死亡。每轮只读取审计末尾事件并与状态快照核对，避免持续增长的历史拖慢检测；完整历史仍保留于 `history.jsonl` 供离线审计。建议由 Linux/WSL 的 systemd 用户服务运行 `--watchdog run` 并设置 `Restart=always`，同时显式提供已核实的工具链环境；本次不安装服务单元，也不实测看门狗自身开机自启或宿主重启恢复。宿主停机后，恢复宿主及值守入口仍需人工处理。

首轮失败候选保留在 `/var/tmp/innovation-symphony-v0/workspaces/GH-1`，回执与证据在同级 `state` 目录。经本次显式重跑授权，使用独立的运行目录、状态目录、工作区；启动前核对队列只有获准的 Issue，记录原回执和新基线 SHA。禁止通过清空原状态目录实现重试。新轮仍停在 Draft PR 或 blocked，结果单独报告。
