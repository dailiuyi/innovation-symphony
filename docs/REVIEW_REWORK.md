# GH-1：有限返工合同与验收对应

来源：IS-015/016，以及 IS-022 的检查返工更新。此文件描述任务工作区中的实现，不代表已发布、真实 GitHub 验收或运行版本升级。

`mvp.max_rework` 仅接受整数 0..2，默认 0。0 保持 V0 单轮行为及 `{approved, summary}` Review 输出；显式 1/2 开启以下合同，替代 V0 中“固定为 0、未实现多轮返工”的限制。其他恢复和交付边界不变。

- 明确可修复的检查失败与有效 `approved=false` 的独立 Review 共用返工预算。最多执行 `max_rework + 1` 轮，不因失败来源切换而重置；最后一次失败保留证据并 blocked。Review 拒绝仍回帖；检查失败不新增平台评论。未知检查错误、环境/权限/超时、模型错误、非法输出、源码/基线/Git 元数据变化均停止。
- 同一工作区与初始 base SHA；每次编码前持久记录 `rework_count` 和新轮次。领取时模型保持冻结。每轮重新执行完整检查，通过后才调用新的只读 Review 会话，平台动态工具禁用。
- receipt 的 `rounds` 保存各轮 base/candidate SHA、模型、检查 argv、证据目录、Review、用量和评论意图。证据在 `RECEIPT.json.evidence/round-N/`；初始 `baseline/` 共享但不可修改。旧轮证据不覆盖。
- 每项检查的完整合并 stdout/stderr 直接写入 `check-N.log`，成功、失败和超时均保留已输出的原始字节；退出状态、命令、分类与日志路径写入 `check-N.json`。`check_failure` 记录到对应轮次及顶层；开始新轮时清空顶层旧失败，历史轮次不变。日志超过 32000 字节时，编码输入提供首尾各 16000 字节及完整日志的只读路径；仅输入摘录修复非法 UTF-8，磁盘日志不截断、不重编码。
- 固定检查 runner 协议：0 通过，10 明确可修复，其余停止。`scripts/check_results.py` 根据固定阶段、原始退出码和已核对的 Elixir 1.19 诊断分类：格式不合规、可识别 ExUnit 断言、覆盖率不足、缺失 `@spec`、项目源码编译错误可返工。未知或混合未知测试错误、未知 Credo/Dialyzer 输出、依赖下载、权限、超时、信号均停止；不得把所有 exit 1 都当成可修复。旧 runner 不产生 10 时保留停止行为。
- 编码收到检查失败的结构化信息与日志摘录，不得降低覆盖率、禁用检查或改写证据。即使检查失败，返工前仍验证候选 SHA、工作区、Git 元数据及冻结基线完整性。编码沙箱的 Mix.PubSub socket 限制由提示明确说明，禁止重复撞同一权限错误或临时替换标准测试；正式检查由控制器执行。
- 发评论之前保存 `comment_pending`、随机标记、完整评论正文、轮次和候选 SHA；收到匹配正文及有效 ID 才确认成功。POST 不自动重试。失败、超时、异常或不确定结果均停止；拒绝反馈按字面文本转义，ASCII `@` 替换为全角字符，不触发提及。
- `mix mvp.reconcile WORKFLOW.md RECEIPT.json` 对评论只分页读取原 Issue，精确匹配已保存正文（含随机标记）与已知 ID。唯一匹配才补录 ID，状态仍为 blocked。零匹配、多匹配或查询失败保留记录；不补发、不恢复、不归零。中断 receipt 继续阻止再次领取，需人工检查。
- 新 Review schema 要求 `criteria` 非空数组，每项包含 `acceptance`（验收 ID 和行为）、`tests`（文件及测试名称）、`assertion_strength`（具体断言）、`failure_sensitivity`（哪种实现破坏会导致失败）和 `adequate`。缺少测试时必须列出该验收项，`tests=[]`、`adequate=false`、`approved=false` 并说明理由。矛盾的批准或缺字段输出非法，直接停止。控制器验证结构和一致性；语义覆盖完整性由独立 reviewer 推理审查。
- 每角色每轮记录实际观察到的会话累计 token 值，重复累计通知取最大值，跨角色/轮次相加。汇总字段的 `observed` 是已知部分之和，`complete=false` 表示至少一个角色/轮次未知；全未知为 null。未取得费用时 `cost=null`，不从 token 数推算价格。中途已收到的用量也立即落盘。每轮调用 agent 前，新轮次及刷新后的汇总在同一次 `Receipt.update` 中持久化；即使首条消息前中断，也保留此前已知总量并将新会话的未知状态计入汇总。
- 批准后沿用原交付门禁，只发布最终检查和 Review 的候选，最多一个 Draft PR。无自动改标签、合并、安装、升级或自动恢复。

## 自动化验收对应

下表名称均对应 `elixir/test/symphony_elixir/` 下测试。新集成测试使用临时真实 Git 仓库及模拟 GitHub/AppServer；不证明真实平台接入。

| ID | 测试文件与名称（前缀） |
| --- | --- |
| A1 | `mvp_intake_test.exs`: `A1 max_rework accepts only integers...`；`mvp_executor_test.exs`: `A1 executor rejects...`；原 `creates a checked candidate...`、`a rejected review prevents publish` 保留旧路径 |
| A2 | `mvp_executor_test.exs`: `A2 A4 A5 A8 A9 A10 rejection is posted before rework...`；`mvp_app_server_test.exs`: 原 `MVP session freezes model...` 验证独立 AppServer 的只读参数 |
| A3 | `mvp_executor_test.exs`: `A3 continuous rejection...`（1/2 两种上限，含最终评论 ID） |
| A4 | `mvp_executor_test.exs`: `A4 rework approval delivers exactly one draft PR...` 与原 `publish pushes the candidate branch...`（固定 SHA 和 Draft 请求） |
| A5 | `mvp_executor_test.exs`: `A2 A4...`（两轮不同 SHA、共同 base、逐轮检查日志及 Review 文件） |
| A6 | `mvp_executor_test.exs`: `A6 comment failures...`、`A6 interrupted rework...`；`mvp_rework_contract_test.exs`: 三项 `A6 ... reconciliation...` |
| A7 | `mvp_executor_test.exs`: `A7 unclassified check failures...`、`A7 rework mode still rejects...`；原 Git 元数据、基线变动及失败门禁测试 |
| A8 | `mvp_rework_contract_test.exs`: `A8 review rejects malformed...`；`mvp_executor_test.exs`: `A2 A4...` 使用缺少对应测试的明确拒绝作为返工原因 |
| A9 | `mvp_rework_contract_test.exs`: `A9 cumulative notifications...`；`mvp_executor_test.exs`: `A2 A4...`（四次会话累计及未知字段）、`A9 interruption before any second coder message...`（首轮完整用量、拒绝回帖确认、第二轮无消息中断）、`A9 initial interruption before telemetry...`（首轮全未知及 0/1/2 兼容） |
| A10 | `mvp_executor_test.exs`: `A10 model comments arriving after claim...` 与 `A2 A4...`（模拟运行中新增有效模型评论，每次调用断言冻结模型、禁用工具、回帖无 @、仅允许评论 API）；原 AppServer、intake 和 Draft PR 测试保留 |

## 验证与交付状态

IS-022 新增验收：`mvp_executor_test.exs` 覆盖检查与 Review 两种顺序的混合返工、共用预算耗尽、零预算、超过 40000 字节及非法 UTF-8 的日志、超时输出保留、未知错误停止、完整性破坏停止及重启不重置预算。`scripts/tests/test_check_results.py` 覆盖固定 runner 的诊断分类、混合未知错误停止、原始输出保留及冻结副本不写 pycache。以下 GH-1 验证记录为历史结果，不代表本次改动的验证或安装结果。

IS-023 显式续跑：`Executor.resume_checks/2` 仅供可信操作者在校验完整上下文和原回执 SHA256 后调用，调度器不自动调用。只接受检查失败的 blocked 回执，绑定原 base、候选、分支、工作区、模型、轮次和预算，并验证候选与冻结基线完整性。接受后保存原回执到原轮次的 `operator-check-resume/`，在新目录重新检查；原日志不覆盖。独占锁在成功、中断后均保留，不能自动重复调用或通过恢复旧回执重置预算。新的固定 runner 可以由操作者指定，仍记录完整命令和证据；这不是通用中断恢复或升级接棒实现。

标准门禁仍是 `scripts/check_candidate.py`（格式、lint/specs、100% 覆盖率、Dialyzer、build）及控制器持有的外部冻结 `scripts/check_baseline.py`。没有修改阈值、豁免模块或冻结基线。本任务仅保存源码和测试，不提交、不推送、不建 PR。

本沙箱的标准 `mix test` 在 Mix.PubSub 启动时因 TCP socket `:eperm` 失败。可用已安装依赖直接编译和运行 ExUnit 做补充验证，但不能代替完整门禁；真实 GitHub 评论、模型质量和版本接棒仍由控制器及人工验收。

本轮本地验证（2026-09-29）：

| 检查 | 结果 |
| --- | --- |
| `mix format --check-formatted`、`git diff --check` | 通过 |
| 直接调用已编译的 `specs.check` 与严格 Credo | 通过，无问题 |
| 直接编译后运行 executor/intake/rework-contract/AppServer 的 ExUnit | 63 项，0 失败 |
| 补充全仓库 ExUnit | 375 项，2 项因 socket `:eperm` 失败，6 项实平台测试跳过；其余通过 |
| 补充 `:cover` 分析 | MVP 模块没有未覆盖的源码行；不宣称标准全仓库 100% 门禁已通过 |
| `scripts/check_candidate.py` | 依赖准备及格式检查后，在 Mix lint 启动时被 socket 限制阻断 |
| 标准覆盖率、Dialyzer、build、外部冻结基线 | 尚待控制器在允许的检查环境完成 |

未改动运行中 V0、控制器配置/证据、冻结测试或 Git 元数据；未进行真实评论、Issue 派发、推送、PR 创建、合并、部署或升级。

### A9/P2 定向修复验证（2026-09-29）

针对候选 `91ed293fde764040e5ec91b1b633c0ecc2f0e01b` 的独立审查发现，仅修复新轮次开始时汇总未刷新。复用原有汇总算法，保持 `max_rework=0` 路径。新增测试在第二轮 coder 的任何 `on_message` 前直接中断；确认首轮评论 ID、保留各角色用量、禁止重启续跑且无额外 Review/PR。

以工作区原实现先运行新增的两项实际 Executor 回归，直接编译源码并运行 ExUnit：**2 项均失败**。第二轮已知 input/output/total 为 **20/5/25**，但 `complete` 错误地全部为 true；首轮无遥测时顶层 usage 为 nil。修复后同两项 **0 失败**，已知总量保持 20/5/25，完整性全部为 false，新轮两角色各字段和 cost 均为 null。执行器及 rework-contract 全部 **39 项、0 失败**。

`mix format --check-formatted`（改动的三个 Elixir 文件）、`git diff --check` 通过；直接调用已编译的 `specs.check` 和严格 Credo 通过。标准 `mix test test/symphony_elixir/mvp_executor_test.exs` 仍在 Mix.PubSub 启动时因 TCP socket `:eperm` 阻断，未改检查配置或绕过权限。上述直接 ExUnit 为补充验证；标准覆盖率、Dialyzer、构建与外部冻结基线仍由控制器执行。
