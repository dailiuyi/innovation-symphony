# 原型运行与项目交付

## 当前状态

已在官方 Elixir 源码基础上实现本地 GitHub MVP，包括确定性评论解析、检查、独立 Review 与 Draft PR 交付链；需求文档和后台 HTML 原型继续保留。当前没有已接入的平台凭据、运行中的控制器、真实任务或云服务。验证范围见 [VALIDATION_V0.md](VALIDATION_V0.md)。

本机目录为 `E:\code\innovation-symphony`。已初始化本地 Git 仓库，未创建远端或提交。后续以实际 Git 状态核实这些时间性信息。

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

保存文件、Git 提交、发布到远端、安装执行服务与云端部署分别报告。当前没有真实任务派发、业务项目验收、提供商调用、合并或部署。


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

仓库尚未创建，当前停在此处。未来经明确接入授权后，设置 GITHUB_REPO/GITHUB_TOKEN、模型白名单与允许的 ready 操作者，将 mvp.enabled 设为 true，并使用上游 CLI 的显式 guardrails acknowledgement 开关启动。首次启用会扫描获准的存量 ready Issue，不能作为只读连通性测试。

自迭代运行时，固定版本 A 安装在候选工作区之外。修改发生在 B 的工作区；PR 待人审核。完整领取状态及 evidence 必须在升级时保留，已进入编码/发布阶段的失败不自动重试。具体恢复命令见 IMPLEMENTATION_V0.md。
