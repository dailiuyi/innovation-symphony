# GH-12 本轮修复与验收对应

这是 2026-10-05 离线编码工作区的自检记录，不是提交、PR、独立 Review、运行安装、
真实 Issue 派发或生产验收。工程语法与参数保持实施方案身份，不新增用户批准决定。

本轮修复旧配置路由/参数丢失、检查时限截短模型预算、启动参数覆盖角色配置、
真实 Turn 失败终态被接受及零返工调用溯源丢失；补充完整非默认评论结果与受审计
历史回执迁移。迁移入口不会执行恢复，不改变原任务额度或不可变外部证据。

| 合同 | 本地证据与实际边界 |
| --- | --- |
| A01 旧配置与评论 | Intake 旧评论回归；routing 子进程使用旧自定义 HTTPS 渠道、环境凭据引用和 low effort；无法无歧义映射的 TOML 明确迁移阻塞。coder/reviewer/diagnosis 预算不受 check_timeout_ms 截短。 |
| A02 完整预设与默认 | services 回归分别及同时保留非默认预设 ID、连接、参数、凭据引用、来源；单角色恢复默认及新旧语法双向覆盖。 |
| A03 无效显式选择 | 授权评论畸形、未知配置/型号、重复角色及早期错误后跟 default 均拒绝；不回退。 |
| A04 角色实际路由 | 并发实际 AppServer 子进程连接模拟协议服务，核对角色 home、URL、effort、凭据指纹和 turn/start；拒绝命令行 config/profile/model 与 home 覆盖，清除继承的 OPENAI_BASE_URL。真实 GPT 未执行。 |
| A05 目录与角色能力 | 目录分页、重复游标、失败保留、人工登记和角色/账号/连接绑定；有效工具事件和正确 JSON 后仍 failed/interrupted 的真实协议形状探测必须失败，不增加成功证据。 |
| A06 启动前校验 | 未发现、禁用、不兼容协议/适配器、未验证角色及不支持 effort 明确拒绝；未知参数不发送。 |
| A07 冻结与全部恢复 | 原默认/评论改变后的返工、诊断、外部入口、恢复及中断入口回归；历史迁移核验原配置摘要和当前证据，保持原轮、handoff 和预算，外部恢复不重读评论。 |
| A08 并发隔离 | 两个子进程独立 home、凭据指纹和参数；宿主全局配置/环境保留，临时 home 清理。未增加调度并行功能。 |
| A09 持久管理 | 校验失败保持原文件、版本/CAS 修订检查、并发保存仅一个成功、持久文件重新读取及本地 Mix 管理入口。 |
| A10 撤权与脱敏 | 本地失效/轮换回归；服务端 TurnError 的 401/403 停止相关调用；错误、消息和日志脱敏，快照只保存引用和指纹。 |
| A11 Review 安全 | 保留只读执行环境策略、结构及候选 SHA 绑定回归。真实内核集成未执行：隔离预检退出 2，execution_sandbox: cgroup v2 is required。 |
| A12 不假通过 | failed/interrupted/畸形终态覆盖已有合法批准；权限/余额仅一次调用，429/503 按原阶段及总额度有限重试仍失败；原超时及结构错误回归保留。兼容旧版本省略 params/Turn 的完成通知。 |
| A13 迁移与回滚 | MODEL_SERVICES 提供有效值映射、后台入口、历史输入合同及原恢复入口衔接；迁移校验失败回执不变、成功保留历史及预算、审计漂移拒绝；资料缺失停点与回滚边界列明。 |
| A14 调用溯源 | max_rework=0、recovery=false 的完整服务 coder/reviewer 成功调用也持久保存来源、provider/model 和已确认 actual_model；缺失实际型号、用量和价格均为 null/未知。 |

测试文件为 elixir/test/symphony_elixir 下的 mvp_model_services、mvp_model_routing、
mvp_execution_sandbox、mvp_executor、mvp_external_task、mvp_recovery_resume、
mvp_interrupted_resume 及原 AppServer/Review 合同回归。

本轮真实 GPT 无凭据、无外部服务，未执行；模拟通过不证明任何真实账号/型号可用。
DeepSeek 不实现、不调用。Linux 隔离环境保持原要求，未降低门禁或使用前置补丁证据
替代本工作区实测。控制器另行冻结最终候选、执行独立 Reviewer 并核对真实验收证据。

本阶段在当前未提交工作树执行以下检查，全部保留冻结政策，两个 policy.json 的
policy_changes 均为空。门禁身份中的 Git HEAD 不代表这些未提交改动的最终候选 SHA；
控制器须另行固定准确候选并验证。

| 检查 | 本阶段结果 |
| --- | --- |
| `python3 /opt/symphony/scripts/check_isolated.py candidate` | 退出 0；format、specs.check、严格 Credo、测试覆盖率、Dialyzer、escript.build 均通过。714 项测试，708 通过、0 失败、6 跳过、0 排除、0 无效；冻结覆盖率报告为 100%；Dialyzer 0 错误。 |
| `python3 /opt/symphony/scripts/check_isolated.py baseline` | 退出 0；669 项原测试，663 通过、0 失败、6 跳过、0 排除、0 无效。 |
| `python3 -B -m unittest scripts.tests.test_execution_sandbox -v` | 退出 0；2 项 CLI 回归通过、2 项需受管 Linux 的内核集成跳过。 |
| `bash scripts/execution_sandbox.sh --check` | 退出 2；`execution_sandbox: cgroup v2 is required`，不宣称真实隔离验证通过。 |
| `git diff --check` | 通过。 |

candidate 与 baseline 的 6 项跳过均为真实外部平台 E2E：GitHub、GitLab、Jira、
Asana，以及 Linear 本地/SSH worker；未启用对应 live 开关，不调用外部服务。
本阶段证据分别保存于工作区 `.check-evidence/candidate-uav5_34a/` 和
`.check-evidence/baseline-9gr24eps/`；未改写控制器 `/evidence` 中的历史证据。
本阶段没有提交、推送、创建 PR、合并、部署或升级运行服务。
