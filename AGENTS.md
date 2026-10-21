# Repository agent guidance

先读 `docs/README.md`、`docs/REQUIREMENTS.md`、`docs/DECISIONS.md`，再读相关规格。用户希望逐步讨论需求，每次聚焦一个关键问题；不得把候选架构、命令示例或实现默认值登记为用户已批准决定。

项目基于官方 Symphony Elixir 扩展，已支持 GitHub/GitLab 单仓库任务交付。2026-10-21 本机活动部署是独立 QEMU/KVM VM，实际项目为 `innovation/luca`，单任务并发；当前运行状态以 `docs/VM_DEPLOYMENT.md` 为准。不要把静态原型、旧博客控制器或旧 innovation 项目的同名容器当成活动服务。调度与 AppServer 复用 elixir/，不要重新实现独立调度器；Python 可用于预览、验收脚本及 `view/` 独立只读采集与展示服务；`view/` 可维护自己的数据库、缓存和日志，启停不影响控制器。GH-16 允许受控管理员通过 View 管理按仓库的双角色默认模型；配置校验、授权、持久化和冻结归 Elixir，任务仍只读，不扩展多仓库调度。调度、编码、检查、Review、恢复、交付与 AppServer 仍归 `elixir/`。

本机运维先读 `docs/VM_DEPLOYMENT.md` 和 `scripts/vm/README.md`。宿主用户级 `symphony-vm.service` 与 production SSH 隧道管理 VM/入口；guest 系统级 `symphony-controller.service`、`symphony-model-settings.service`、`symphony-view.service` 管理应用。旧宿主 `innovation-symphony-*` 三服务已停止并禁用，不得照历史命令重启成第二个消费者。固定 release 与开发工作区分离，源码 HEAD 不等于运行版本。

显式 VM 模式使用外层虚拟机隔离，coder 在 guest 内有 sudo/Docker 权限；独立 Reviewer/诊断会话只读。不能沿用旧 rootless 文档宣称 VM 内凭据、控制器和证据受任务权限隔离。新任务四小时/30 次返工/96 次模型调用，重启不重置预算；旧 blocked 任务不自动复活。当前默认 coder `gpt-6.1-sol/high`、reviewer `deepseek-v4-flash/high`，改动前先核对实际注册表。

文件清理先列出准确清单、大小及归属，再核对进程占用、备份和恢复依赖；无法观察不等于闲置。2026-10-21 经专项授权删除的 11 个旧归档只构成一次清理记录，不授予后续通配删除、prune 或删除历史的权限。保留系统盘、最终迁移归档、成功日备份及其回执、工作区和运行证据；已删除文件与现存恢复入口见 VM_DEPLOYMENT。不要在文档中把历史已删除快照继续列为可用恢复源。

已确认入口是机器人自动发现并领取 ready Issue，无需先指派机器人。模型通过固定格式的独立 Issue 评论由程序解析，编码与 Review 各有仓库默认值，用户指定按角色覆盖默认。标签承担基本状态和 ready 启动门槛，不用于选择模型。

项目任务限所属仓库。架构、云环境、权限、去重/恢复、命令更新、验收与发布策略以文档中的已确认/待定标记为准。

在同一任务内记录持久的用户决定、来源、范围及被替代的旧决定，更新相关规格，避免在旧博客项目继续维护另一套框架正文。保留他人未提交改动，只修改任务范围内文件。

默认中文。代码搜索优先 rg。原型可用浏览器检查；选择与改动相称的验证，不以演示数据证明真实接入。提交前按 team-mode 的简化/审查要求执行适用检查。

保存、Git 提交、远端发布、运行安装和云端部署是不同状态。收尾必须准确报告。文档和本地开发不自动授予真实 Issue 派发、公司代码外发、合并、云资源购买或生产部署权限；已获得的具体授权无需重复询问。
