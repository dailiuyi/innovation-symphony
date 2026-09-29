# 原型运行与项目交付

## 当前状态

已在官方 Elixir 源码基础上实现本地 GitHub MVP，包括确定性评论解析、检查、独立 Review 与 Draft PR 交付链；需求文档和后台 HTML 原型继续保留。私有 GitHub 仓库和真实 Issue #1 已接入。首轮在检查阶段 blocked，控制器已停止；未合并候选、未部署云服务。验证范围见 [VALIDATION_V0.md](VALIDATION_V0.md)，显式重跑授权见 IS-017。

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

保存文件、Git 提交、发布到远端、安装执行服务与云端部署分别报告。真实任务派发及提供商调用已发生；完整自迭代验收、合并及候选升级尚未完成。


## 官方实现与 V0 本地检查

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
