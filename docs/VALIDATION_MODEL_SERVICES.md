# GH-12 本轮修复与验收对应

这是 2026-10-05 离线编码工作区的自检记录，不是提交、PR、独立 Review、运行安装、
真实 Issue 派发或生产验收。工程语法与参数保持实施方案身份，不新增用户批准决定。

上一阶段在已有 GH-12 实现上修复旧隔离路径错误读取 auth_home/config.toml、正式
CodexErrorInfo 字符串枚举未分类，并删除无协议依据的 actualModel 采集。新增
回归在修复前复现 4 项失败，修复后的两份定向套件共 35 项通过。此前已覆盖的
评论、预算、启动覆盖、失败终态和历史回执迁移回归保持；迁移入口不会执行恢复，
不改变原任务额度或不可变外部证据。

| 合同 | 本地证据与实际边界 |
| --- | --- |
| A01 旧配置与评论 | Intake 旧评论回归；非隔离 routing 子进程保留自定义 HTTPS 渠道、环境凭据引用和 low effort，无法映射的 TOML 停止迁移；无新注册表的隔离领取分别输入 low、自定义 provider、profiles，两个角色均冻结并调用内置 OpenAI、原 auth.json 认证和 high，冻结后 TOML 变化不影响调用。coder/reviewer/diagnosis 预算不受 check_timeout_ms 截短。 |
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
| A12 不假通过 | failed/interrupted/畸形终态覆盖已有合法批准；权限/余额仅一次调用；HTTP 和正式枚举暂时错误按原预算重试仍失败；原超时及结构错误回归保留。兼容旧版本省略 params/Turn 的完成通知。 |
| A13 迁移与回滚 | MODEL_SERVICES 提供有效值映射、后台入口、历史输入合同及原恢复入口衔接；迁移校验失败回执不变、成功保留历史及预算、审计漂移拒绝；资料缺失停点与回滚边界列明。 |
| A14 调用溯源 | max_rework=0、recovery=false 的完整服务 coder/reviewer 调用仍持久保存来源及请求 provider/model。模拟协议子进程到 AppServer 结果、Usage.request 及回执的三轮回归拒绝把 Thread.model 或未经定义的 actualModel 当确认值（含无效字段、缺失字段），实际型号、用量和价格为 null/未知。现有注入 agent 的非空型号断言只证明记录层，不能证明 Codex 型号采集成功。所提供协议没有逐轮型号遥测，无法构造受支持的确认成功路径；不虚构协议字段。 |
| A15 错误与有界恢复 | 正式 unauthorized/usageLimitExceeded 停止，rateLimitExceeded/serverOverloaded/internalServerError 分类后进入原 Attempts；AppServer 模拟子进程分别验证阶段次数、总次数与剩余墙钟限制，重试保留服务及只读策略；badRequest、other 及其他未知/非暂时枚举不笼统重试。 |

测试文件为 elixir/test/symphony_elixir 下的 mvp_model_services、mvp_model_routing、
mvp_execution_sandbox、mvp_executor、mvp_external_task、mvp_recovery_resume、
mvp_interrupted_resume 及原 AppServer/Review 合同回归。

本轮真实 GPT 无凭据、无外部服务，未执行；模拟通过不证明任何真实账号/型号可用。
DeepSeek 不实现、不调用。Linux 隔离环境保持原要求，未降低门禁或使用前置补丁证据
替代本工作区实测。控制器另行冻结最终候选、执行独立 Reviewer 并核对真实验收证据。

前一编码阶段曾在当时的未提交工作树执行以下检查，全部保留冻结政策，两个 policy.json 的
policy_changes 均为空。门禁身份中的 Git HEAD 不代表这些未提交改动的最终候选 SHA；
控制器须另行固定准确候选并验证。这些历史结果不替代下方本次沙箱的重新检查。

| 检查 | 本阶段结果 |
| --- | --- |
| `python3 /opt/symphony/scripts/check_isolated.py candidate` | 修复后完整重跑退出 0；format、specs.check、严格 Credo、测试覆盖率、Dialyzer、escript.build 均通过。716 项测试，710 通过、0 失败、6 跳过、0 排除、0 无效；冻结覆盖率报告为 100%；Dialyzer 0 错误。 |
| `python3 /opt/symphony/scripts/check_isolated.py baseline` | 退出 0；669 项原测试，663 通过、0 失败、6 跳过、0 排除、0 无效。 |
| `python3 -B -m unittest scripts.tests.test_execution_sandbox -v` | 退出 0；2 项 CLI 回归通过、2 项需受管 Linux 的内核集成跳过。 |
| `bash scripts/execution_sandbox.sh --check` | 退出 2；`execution_sandbox: cgroup v2 is required`，不宣称真实隔离验证通过。 |
| `git diff --check` | 通过。 |

candidate 与 baseline 的 6 项跳过均为真实外部平台 E2E：GitHub、GitLab、Jira、
Asana，以及 Linear 本地/SSH worker；未启用对应 live 开关，不调用外部服务。
本阶段通过证据分别保存于工作区 `.check-evidence/candidate-fhewsgu1/` 和
`.check-evidence/baseline-ofyjwlin/`。首次 candidate 在新增测试长行的严格 Credo
检查失败，整体退出 10，其余检查均通过；修正长行后完整重跑以上 candidate。
首次失败证据保留于 `.check-evidence/candidate-czhrqvgf/`，未删除失败历史，
未改写控制器 `/evidence` 中的历史证据。
本阶段没有提交、推送、创建 PR、合并、部署或升级运行服务。

## 2026-10-05 独立 Review 后的最小修复

复现并修复 `auth_home` 配置覆盖 Codex 保留 provider，以及初始化后配置回退警告
被忽略的问题。原独立审查记录作为缺陷线索，未操作其外部证据、凭据或运行服务。
修复不更改快照身份、评论语法、角色默认、恢复预算或验收政策。

- A01/A04：真实 `/opt/codex`（codex-cli 0.160.0）离线加载生成配置、创建两个
  角色的 thread 并通过 `config/read` 核对有效连接和 effort。不启用新注册表的
  `auth_home` 同时覆盖合成 API key 与合成 ChatGPT 认证，保留旧模型评论及隔离
  基线 high；新预设覆盖两个角色不同环境凭据、连接与 medium/high 参数。
  修复前真实客户端明确拒绝保留的 `model_providers.openai`。这些仅为客户端
  配置加载合同，未发出 `turn/start`，不证明账号权限或真实 GPT 推理成功。
- A05/A12/A15：模拟协议覆盖初始化响应前/后、第二页目录、turn/start 响应前
  和合法批准输出后的无效配置警告，以及回退信息仅在 details 中、畸形 params/details
  的通知；断言拒绝刷新、保留原目录/
  原刷新时间/验证证据、不新增型号，且不同预算下仅调用一次、不产生 passed。
  普通环境警告继续兼容。原分页、恢复、并发路由和只读回归保留。

本次自检结果在下方记录；真实 GPT 的准确候选复验仍待有凭据和授权的操作者执行，
不以旧失败证据或本次模拟结果标记通过。控制器另行固定候选并独立 Review。

### 本次沙箱的检查环境诊断

本次重新运行冻结 `check_isolated.py candidate`，format、specs.check 和严格 Credo
通过；测试阶段退出 3，可信检查器整体退出 1：719 项中 656 通过、57 失败、6 跳过，
覆盖率 92.13%，未继续 Dialyzer 和打包。失败集中在正常配置、恢复、本地管理及打包
入口的路径检查：可信检查器将私有 `TMPDIR` 设置为源码副本内部的 `<harness>/tmp`，
而 `Mvp.Config` 禁止 state/workspace 与整个源码根重叠，故返回
`mvp_state_source_overlap`，部分调用随后产生 MatchError/Mix.Error。源码隔离规则、
测试及 `/opt` 检查器均未为消除这些失败而修改；已请求控制器纠正临时目录位置。
本次失败记录为 `.check-evidence/candidate-sxenz_0e/`，不能沿用上阶段的通过标记。
要求的 `check_isolated.py baseline` 也已运行，整体退出 1（测试子进程退出 2）：
669 项中 610 通过、53 失败、6 跳过，0 排除、0 无效，同样因源码内 TMPDIR 触发
路径边界错误；记录为 `.check-evidence/baseline-rms3ya7e/`。

这次失败套件中的真实 Codex 客户端两个加载回归及配置回退拒绝回归均通过；它们
不能证明完整门禁已通过。另安排补充自检：保持冻结配置、全部测试、覆盖率阈值和
Erlang 资源约束，用源码根外的独立私有临时目录诊断此路径冲突；补充结果与要求的
`check_isolated.py` 结果分开记录，不替代控制器门禁。

补充自检的完整 candidate 测试已通过：719 项中 713 通过、0 失败、6 跳过，
0 排除、0 无效，冻结覆盖率阈值仍为 100%，报告覆盖率 100%。格式、specs.check
及严格 Credo 均通过。记录位于 `.check-evidence/gh12-supplementary-hetdhz9e/`，
其中 policy_changes 为空；没有修改源码路径保护或跳过受影响的入口测试。
补充流程最终退出 0：Dialyzer 0 错误，`mix escript.build` 通过；原 669 项测试
复跑为 663 通过、0 失败、6 跳过、0 排除、0 无效。两个套件的 6 项跳过仍是未启用
live 开关的外部平台 E2E。临时目录与源码目录分离后，所有此前路径冲突的正常配置、
重试、恢复及打包入口回归通过；要求的两条冻结命令仍需控制器修正环境后重跑，
不能把这次补充流程记为它们已通过。

本次另运行 Python 沙盒 CLI 套件，2 项通过、2 项内核集成跳过；
`bash scripts/execution_sandbox.sh --check` 再次退出 2，原始诊断仍为
`execution_sandbox: cgroup v2 is required`，未降低要求或宣称本环境内核集成通过。
真实 GPT 推理、准确最终候选的外部复验及独立 Review 均未在此会话执行。
所有改动仅本地保存，没有提交、推送、创建 PR、合并、部署或升级运行服务。

## 2026-10-05 本轮：非隔离原生连接兼容修复

本轮确认旧非隔离 config.toml 的 openai_base_url/chatgpt_base_url 被迁移解析器
拒绝，且连接提取遗漏这两个原生字段。新增三项回归在修复前均因
legacy_model_service_migration_required 失败；修复后模型服务与路由套件共
41 项通过。保留原自定义 provider、隔离路径忽略 auth_home/config.toml、重试、
诊断、所有恢复入口、Review 结构及候选提交绑定回归。

新回归不启用新注册表，沿用旧模型评论，分别核对两个角色的认证引用和指纹、
原生连接、low/medium 及未指定 effort；领取冻结后改写原 config.toml，模拟
AppServer 的实际 turn/start 仍采用冻结配置。另覆盖原生 API 地址与环境覆盖的
优先级、自定义 provider 优先级、ChatGPT 后台根的末尾斜杠及已含 `/codex` 的
往返映射；布尔/整数、HTTP、含凭据或查询的连接在冻结前拒绝。

真实 codex-cli 0.160.0 离线创建角色 thread，通过 config/read 核对生成配置的
有效连接和推理参数。此项只验证客户端加载，不执行真实 GPT 推理，不产生模型
能力验证证据。模拟 turn/start、离线客户端加载与真实 GPT 验收仍分别记录。

本次重新运行的完整门禁结果在下方记录；上节旧轮 TMPDIR 冲突保留为历史。
检查报告中的 candidate_sha 仍是原 Git HEAD，本轮修复属于未提交工作树，不能
把该字段当作包含修复的最终候选 SHA；控制器另行固定候选和独立 Review。

| 本轮检查 | 结果 |
| --- | --- |
| `python3 /opt/symphony/scripts/check_isolated.py candidate` | 退出 0；format、specs.check、严格 Credo、覆盖率测试、Dialyzer、escript.build 全部通过。722 项中 716 通过、0 失败、6 跳过、0 排除、0 无效；覆盖率 100%，Dialyzer 0 错误。 |
| `python3 /opt/symphony/scripts/check_isolated.py baseline` | 退出 0；669 项中 663 通过、0 失败、6 跳过、0 排除、0 无效。 |
| `python3 -B -m unittest scripts.tests.test_execution_sandbox -v` | 退出 0；2 项 CLI 回归通过，2 项受管 Linux 内核集成跳过。 |
| `bash scripts/execution_sandbox.sh --check` | 退出 2；`execution_sandbox: cgroup v2 is required`，本环境无法执行所需内核集成。 |
| `git diff --check` | 通过。 |

本轮证据为 `.check-evidence/candidate-fhh806lg/` 和
`.check-evidence/baseline-yntpc6ei/`，两个 policy.json 的 policy_changes 均为空。
两套 Elixir 测试的 6 项跳过仍为未启用 live 开关的外部平台 E2E。
真实双角色 GPT 推理、准确候选的受管 Linux 内核隔离及独立交付 Review 未执行，
不以本次模拟路由或离线客户端结果标记这些验收通过。改动仅本地保存，未提交、
推送、创建 PR、合并、部署或升级运行服务；未修改控制器证据或运行凭据。

## 2026-10-06：旧启动参数与项目表兼容修复

继续核验工作区已恢复的五份改动，保留原失败历史和控制器边界。本轮修复仅涉及
旧配置迁移解析与回归，不更改调度、模型目录、管理员授权、恢复预算或正式门禁。

- A01/A04/A07：无新注册表时，旧 `--config` / `-c` 的
  `model_reasoning_effort` 确定性解析并冻结；覆盖分离参数、附着参数、引号及
  重复合法设置的最后值。另发现并补齐当前 Codex 支持的 `-c=...` 形式：补齐前
  解析返回 `model_service_command_unsafe`，客户端接受该参数形式。两个角色真实
  Codex 离线 `config/read` 保留 xhigh；随后修改启动默认与原 config.toml，
  模拟 AppServer 重复调用仍核对原连接、认证指纹、请求模型和 xhigh。
- A01：非隔离原 config.toml 包含双引号或单引号的项目表及 trust_level 时，
  无需改写文件即可冻结两个角色的连接、认证引用和参数；领取不修改原文件，
  后续原文件变化不影响调用。重复表以解码后的名称比较，引用形式变化不能绕过；
  畸形引号、非法转义、歧义认证及不支持的路由继续拒绝。
- A06/A11/A12：无效或缺失参数、任一早期无效值、连接/认证覆盖、profile/model、
  shell 展开/组合/重定向，以及命令与快照参数不一致，均在调用前拒绝。兼容例外
  只用于 legacy_migration；新预设依旧拒绝任何 config 启动参数覆盖。
- A07/A11：补充 ExecutionSandbox 配置生成回归，分别对 coder、reviewer 和
  继承 coder 的诊断重复调用；原命令、有效参数、连接、认证引用及只读属性保持。
  此项使用注入执行适配器检查生成配置，不冒充内核隔离或真实推理证据。

原目录刷新、保存失败/CAS、脱敏、并发路由、阶段/总次数/墙钟预算、外部/中断/审计
恢复、Review 结构及候选 SHA 绑定合同由完整 candidate 和原 baseline 套件复验。
真实 Codex 加载只使用合成认证，不发送 `turn/start`；真实双角色 GPT 推理未执行。
内核预检仍退出 2：`execution_sandbox: cgroup v2 is required`，因此不能执行所需
受管 Linux 内核集成。未修改隔离策略，也不复用旧候选或前置补丁的外部通过标记。
当前改动未提交，检查报告中的 Git HEAD 不代表包含修复的最终候选 SHA；控制器
另行固定候选、完整验证并独立 Review。没有提交、推送、PR、合并、安装、部署或
升级运行服务，没有改写运行凭据、.git 或控制器证据。

| 本轮检查 | 结果 |
| --- | --- |
| `python3 /opt/symphony/scripts/check_isolated.py candidate`（最终代码） | 退出 0；format、specs.check、严格 Credo、覆盖率测试、Dialyzer、escript.build 全部通过。726 项中 720 通过、0 失败、6 跳过、0 排除、0 无效；冻结覆盖率报告 100%，Dialyzer 0 错误。 |
| `python3 /opt/symphony/scripts/check_isolated.py baseline` | 退出 0；669 项中 663 通过、0 失败、6 跳过、0 排除、0 无效。 |
| `python3 -B -m unittest scripts.tests.test_execution_sandbox -v` | 退出 0；2 项 CLI 回归通过，2 项受管 Linux 内核集成跳过。 |
| `bash scripts/execution_sandbox.sh --check` | 退出 2；`execution_sandbox: cgroup v2 is required`，内核集成未执行，不记为通过。 |
| `git diff --check` | 通过。 |

最终代码的 candidate 证据为 `.check-evidence/candidate-hszedqsn/`，baseline 为
`.check-evidence/baseline-ci581ihq/`，两者 policy_changes 均为空。两套 Elixir 测试
的 6 项跳过均为未启用 live 开关的真实外部平台 E2E：GitHub、GitLab、Jira、Asana
以及 Linear 本地/SSH worker。本轮中途还完整运行过恢复的五份改动，candidate
退出 0（725 项、719 通过、6 跳过），证据 `.check-evidence/candidate-vg2arg_d/`；
此记录早于补充的 `-c=...` 与隔离诊断回归，不代替最终代码的检查结果。
