# innovation-symphony

面向公司多仓库研发任务的 Symphony 框架。目标是部署到云端，统一接入 GitLab 与 GitHub；机器人自动发现带有 `ready` 标签的 Issue，领取并执行所属仓库的任务。

当前阶段：基于 [官方 Symphony](https://github.com/openai/symphony) 的 Elixir 实现开发 GitHub MVP。复用其调度、工作区、GitHub Client、AppServer 和状态页面，补充评论选模型、独立 Review、检查门禁和 Draft PR 交付。人工合并与升级。

GitHub MVP 的历史接入与授权见决策记录；有限返工支持可修复检查失败与 Review 拒绝共用预算，完整保存检查日志，Review 拒绝理由仍回帖。默认 `max_rework=0` 保持兼容，显式 1..5 启用，最多五次返工加初始一轮。固定检查 runner 使用结构化 ExUnit 结果识别普通及自定义断言，核对完整报告与退出码；缺失或矛盾报告不能通过。显式复检绑定原候选、基线、模型和预算，保留历史操作及终态审计，已用次数不重置；不会因修改配置而自动重启所有 blocked 任务。源码发布与实际运行版本须分别核实。详见 [返工合同与验收对应](docs/REVIEW_REWORK.md)。[实现合同](docs/IMPLEMENTATION_V0.md) · [官方基线](docs/UPSTREAM.md) · [验证记录](docs/VALIDATION_V0.md) · [接入说明](docs/OPERATIONS.md)。

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
