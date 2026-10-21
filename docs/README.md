# 文档入口

2026-10-21 当前运行是独立 VM 固定 release `9cf6c1701f26-20261021`，GL-4 已交付 Reviewer 批准的 Draft MR !3；其源码是远端 main 的 PR #20 合并提交 `9cf6c17`，后续文档同步与运行版本分开记录。宿主清理已按授权释放 20.52 GiB，目录约 30 GiB；旧预复制和准备 v2 归档已删除。固定版本、现存恢复源、真实门禁、人工接续及剩余手动验收统一见 [VM_DEPLOYMENT](VM_DEPLOYMENT.md)。

| 内容 | 文档 |
| --- | --- |
| 当前 VM 版本、存储清理、现存备份与真实闭环验收 | [VM_DEPLOYMENT.md](VM_DEPLOYMENT.md) |
| VM 准备、检查、维护排空、启停与备份恢复命令 | [scripts/vm/README.md](../scripts/vm/README.md) |
| GitLab 与 luca 接入、验证和待办 | [GITLAB_INTEGRATION.md](GITLAB_INTEGRATION.md) |
| 领取前执行环境就绪检查与激活边界 | [EXECUTION_READINESS.md](EXECUTION_READINESS.md) |
| 三项 rootless 审查问题修复及回归 | [ROOTLESS_REVIEW_FIXES.md](ROOTLESS_REVIEW_FIXES.md) |
| 宽权限实验代码验收与实机前置条件 | [VALIDATION_ROOTLESS.md](VALIDATION_ROOTLESS.md) |
| 宽权限 rootless 容器、持久产物、固定补证与未完成验收 | [ROOTLESS_OPEN.md](ROOTLESS_OPEN.md) |
| Linux/WSL 来源分流、只读采集与独立合成验证 | [LINUX-SOURCE.md](../view/docs/LINUX-SOURCE.md) |
| GH-7 View 安装、配置、独立检查与运行 | [view/README.md](../view/README.md) |
| GH-7 来源、迁移差异与固定兼容性夹具 | [MIGRATION.md](../view/docs/MIGRATION.md) |
| GH-7 本轮检查与外部停点 | [VALIDATION_VIEW.md](VALIDATION_VIEW.md) |
| Issue #7 固定来源、独立 View 检查与待外部验收准备 | [VIEW_PREPARATION.md](VIEW_PREPARATION.md) |
| V0 实现范围与恢复边界 | [IMPLEMENTATION_V0.md](IMPLEMENTATION_V0.md) |
| GH-1 有限返工合同与验收对应 | [REVIEW_REWORK.md](REVIEW_REWORK.md) |
| 技术失败自动诊断、修复与验收 | [AUTOMATIC_RECOVERY.md](AUTOMATIC_RECOVERY.md) |
| 外部条件等待、分阶段 Draft PR 与审计接手 | [EXTERNAL_HANDOFF.md](EXTERNAL_HANDOFF.md) |
| Coder 自主测试、四条隔离底线与实施配置 | [CODER_EXECUTION_RULES.md](CODER_EXECUTION_RULES.md) |
| 隔离自主测试实测与恢复记录 | [VALIDATION_CODER_ISOLATION.md](VALIDATION_CODER_ISOLATION.md) |
| 自动恢复实测与 Issue #3 交付记录 | [VALIDATION_AUTOMATIC_RECOVERY.md](VALIDATION_AUTOMATIC_RECOVERY.md) |
| 已批准的结构化检查与复检修复 | [004-structured-check-recovery.md](issue-drafts/004-structured-check-recovery.md) |
| Issue #12 角色模型服务的本地审查修订稿与待定项 | [006-role-model-services.md](issue-drafts/006-role-model-services.md) |
| Linux 保留补丁的整合审查与代码门禁 | [VALIDATION_LINUX_PATCHES.md](VALIDATION_LINUX_PATCHES.md) |
| Issue #12 全部会话、返工原因与外部等待分析 | [ISSUE12_PROCESS_ANALYSIS.md](ISSUE12_PROCESS_ANALYSIS.md) |
| V0 本地验证与未验收范围 | [VALIDATION_V0.md](VALIDATION_V0.md) |
| 官方来源及改动接缝 | [UPSTREAM.md](UPSTREAM.md) |
| GH-16 仓库默认设置、内网管理、方案与验收 | [VIEW_MODEL_SETTINGS.md](VIEW_MODEL_SETTINGS.md) |
| GH-12／16 角色模型服务、目录、管理与迁移 | [MODEL_SERVICES.md](MODEL_SERVICES.md) |
| GH-12 离线自检及外部验收边界 | [VALIDATION_MODEL_SERVICES.md](VALIDATION_MODEL_SERVICES.md) |
| 当前产品需求与范围 | [REQUIREMENTS.md](REQUIREMENTS.md) |
| 决策来源、历史替代关系 | [DECISIONS.md](DECISIONS.md) |
| 下一步需要讨论什么 | [OPEN_QUESTIONS.md](OPEN_QUESTIONS.md) |
| 评论指令、ready 与状态标签 | [ISSUE_PROTOCOL.md](ISSUE_PROTOCOL.md) |
| 尚未定案的架构与试点方案 | [DESIGN_PROPOSAL.md](DESIGN_PROPOSAL.md) |
| 官方基线对照与架构审核意见 | [ARCHITECTURE_REVIEW.md](ARCHITECTURE_REVIEW.md) |
| GitHub MVP 与自身迭代验收建议 | [SELF_ITERATION_MVP.md](SELF_ITERATION_MVP.md) |
| 第一版实际架构图 | [mvp-architecture.html](../prototypes/mvp-architecture.html) |
| 可点击的架构与决策审核图 | [architecture-review.html](../prototypes/architecture-review.html) |
| 原型预览、迁移与交付状态 | [OPERATIONS.md](OPERATIONS.md) |
| 可交互 HTML 原型 | [symphony-dashboard.html](../prototypes/symphony-dashboard.html) |

需求与决策是当前讨论结果；提案、草案与待定项必须保持相应状态。新决定同时更新当前规格与决策历史。聊天和运行日志用于追溯，不是唯一规范来源。

IS-041 进一步授权实现、验证和安装分阶段 Draft 交付，并通过控制器继续原 GH-5。当前源码、固定运行版本与真实任务结果分别记录于 [EXTERNAL_HANDOFF.md](EXTERNAL_HANDOFF.md)，不以决定条目代替实际交付证据。
