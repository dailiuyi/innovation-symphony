# innovation-symphony

面向公司多仓库研发任务的 Symphony 框架。目标是部署到云端，统一接入 GitLab 与 GitHub；机器人自动发现带有 `ready` 标签的 Issue，领取并执行所属仓库的任务。

当前阶段：基于 [官方 Symphony](https://github.com/openai/symphony) 的 Elixir 实现开发 GitHub MVP。复用其调度、工作区、GitHub Client、AppServer 和状态页面，补充评论选模型、独立 Review、检查门禁和 Draft PR 交付。人工合并与升级。

IS-033 实施 coder 同会话自检：通过显式启用的 Linux 任务隔离，允许测试、静态分析和本地服务在编码阶段直接运行；控制器仍在独立环境执行冻结门禁并安排新鲜 Review。配置、四条底线及当前验收范围见 [Coder 执行规则](docs/CODER_EXECUTION_RULES.md)。

GH-3 当前候选仅有 `--preflight` 接管前只读配置及 GitHub 轮询体检；不启动调度，成功后退出。体检拒绝不含 `open` / `closed` 的状态列表，防止未查询远端就报告通过。A 收尾、版本切换和自动回退仍未实现，待确认机制未定案，完整 GH-3 尚未通过验收。见 [体检边界](docs/IMPLEMENTATION_V0.md#gh-3-最小增量接管前只读体检)。

GH-5 新增独立于运行器的本地进程看门狗入口，按固定版本指针和持久预算恢复退出的进程；人工暂停、解除及预算恢复使用同一打包入口。按 IS-042 已在本地 WSL 安装启用，并通过真实认证下的正常退出、强制结束和看门狗重启测试；新任务领取仍暂停。完整维护步骤及固定版本见 [OPERATIONS](docs/OPERATIONS.md#看门狗维护流程)。

GitHub MVP 的历史接入与授权见决策记录；有限返工支持可修复检查失败与 Review 拒绝共用预算，完整保存检查日志，Review 拒绝理由仍回帖。默认 `max_rework=0` 保持兼容，显式 1..5 启用，最多五次返工加初始一轮。固定检查 runner 使用结构化 ExUnit 结果识别普通及自定义断言，核对完整报告与退出码；缺失或矛盾报告不能通过。显式复检绑定原候选、基线、模型和预算，保留历史操作及终态审计，已用次数不重置；不会因修改配置而自动重启所有 blocked 任务。源码发布与实际运行版本须分别核实。详见 [返工合同与验收对应](docs/REVIEW_REWORK.md)。[实现合同](docs/IMPLEMENTATION_V0.md) · [官方基线](docs/UPSTREAM.md) · [验证记录](docs/VALIDATION_V0.md) · [接入说明](docs/OPERATIONS.md)。

GH-7 将固定版本的 innovation-view 导入 [`view/`](view/README.md)，提供独立 Python 只读采集与展示服务，可维护本地数据库、缓存和日志；启停不影响 `elixir/` 控制器。PR #9 已合入 main；2026-10-03 按 IS-055 安装固定版本看板，本机网址为 [http://127.0.0.1:8613/](http://127.0.0.1:8613/)，真实 Windows＋WSL 采集和浏览器检查通过。控制器仍运行 `43ef956`，原 GH-7 交付回执的身份不一致停点保留。实际安装及验证局限见 [运行记录](docs/OPERATIONS.md)，通用步骤见 [View 说明](view/README.md)，[迁移记录](view/docs/MIGRATION.md) 与 [前置准备](docs/VIEW_PREPARATION.md) 保留历史与边界。

Linux 执行补丁保留暂停领取后的既有任务合同，在受信审计入口处理外部补证和同一 Draft 的快进修订；固定检查按实际资源预算运行，View 只读标明已核验的宿主中断。代码审查与运行安装分别记录，见 [本轮补丁验证](docs/VALIDATION_LINUX_PATCHES.md)。

## 已确认的使用方式

本轮按 IS-026 完善显式启用的自动恢复：可由模型解决的技术失败交回编码或新的只读诊断，普通修复窗口无需逐次人工批准，同时保留严格检查、独立 Review、资源熔断与完整证据。未启用策略的任务继续遵守上面的 0..5 兼容合同；旧回执只通过明确审计迁移，不批量重启。工程默认见 [自动恢复合同](docs/AUTOMATIC_RECOVERY.md)。控制器 `07f7493` 已发布并在本地运行，真实 Issue #3 经自动诊断、检查失败返工、完整检查和独立 Review 交付 [Draft PR #4](https://github.com/dailiuyi/innovation-symphony/pull/4)，证据见 [验收记录](docs/VALIDATION_AUTOMATIC_RECOVERY.md)。按 IS-027，合并、合并冲突和升级交给人处理，系统不持续追赶 main。

1. 在已接入仓库创建 Issue，写明需求。
2. 可选：在一条独立 Issue 评论中，通过约定格式指定编码模型和 Review 模型。
3. 添加 `ready` 标签，机器人自动发现并领取执行，无需用户先指派机器人。
4. 在代码平台及查看型后台了解进度、日志和结果。`ready`、`review`、`blocked` 等标签承担基本工作流状态；模型选择通过评论解析。

每个仓库分别配置编码和 Review 默认模型；用户显式指定优先，未指定角色沿用仓库默认。各仓库独立处理任务，第一版不跨仓库修改。

领取前会校验 MVP 配置；配置错误会停止派发并写入服务日志。HTTP 状态页正常不代表领取门槛通过。运行打包 escript 时，路径隔离以真实工件所在目录为边界，而不是压缩包内部的虚拟应用路径。

## 文档与原型

- [文档入口](docs/README.md)
- [已确认需求](docs/REQUIREMENTS.md)
- [决策记录与被替代的决定](docs/DECISIONS.md)
- [自动恢复与自身迭代合同](docs/AUTOMATIC_RECOVERY.md)
- [待讨论问题](docs/OPEN_QUESTIONS.md)
- [架构与试点提案](docs/DESIGN_PROPOSAL.md)
- [Issue 交互协议草案](docs/ISSUE_PROTOCOL.md)
- [运行与交付说明](docs/OPERATIONS.md)
- [后台 HTML 原型](prototypes/symphony-dashboard.html)
- [第一版实际架构](prototypes/mvp-architecture.html)（官方复用与新增门禁）
- [架构与决策审核图](prototypes/architecture-review.html)（官方 Symphony 对照、候选模块、待定边界）

## 查看原型

在项目根目录运行：

```sh
python -m http.server 43221 --bind 127.0.0.1 --directory prototypes
```

然后访问 [本机预览](http://127.0.0.1:43221/symphony-dashboard.html)。也可以直接用浏览器打开 HTML 文件。此命令仅预览原型，不启动机器人或云端服务。

原型包含虚构的 Unity、Android、iOS、Web 仓库与任务，支持筛选、任务详情、日志和按仓库选择两种默认模型。模型设置仅保存在当前页面内存；没有真实计费、模型调用或 Issue 解析。

后续继续逐步确认需求，架构建议不自动视为已批准实现。项目从博客讨论中独立出来；不会继承博客的 ready 队列、凭据、固定 Reviewer 或部署授权。

GH-12 在原 Elixir 执行器中增加 coder/reviewer 服务预设、账号绑定的 GPT 目录及
持久默认管理；领取冻结完整配置，每次调用仍核验原 WORKFLOW 的当前授权。
评论兼容、后台入口与迁移边界见
[角色模型服务](docs/MODEL_SERVICES.md)。本轮离线测试不代表真实 GPT、安装或交付验收。


实验性的宽权限 rootless 容器、持久导出、失败分流和固定补证配置见 [实施合同](docs/ROOTLESS_OPEN.md)。默认未启用；代码不代表已安装或实机验收，旧冻结任务保持原后端。

GH-16 在独立 View 设置页增加受控内网的仓库双角色默认选择，并接入 DeepSeek
Responses；任务展示仍只读，配置授权、持久化和执行继续归 Elixir。GLM 后置，
真实账号与内网安装须分别验收，见 [方案及检查记录](docs/VIEW_MODEL_SETTINGS.md)。
