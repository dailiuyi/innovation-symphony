# GH-16 工程方案与验收记录

来源：2026-10-08 GH-16 Issue 与本次离线编码指令；基线决定编号止于 IS-078。
实施前已读取 AGENTS、README、REQUIREMENTS、DECISIONS、MODEL_SERVICES。
本页方案是工程选择，不登记为用户永久指定的架构或参数。

## 实施计划

1. 复用 Elixir ModelServices 的持久注册表、CAS、角色证据和冻结快照。
   默认选择扩展为预设、模型、实际参数的组合，兼容旧字符串默认；不修改预设，
   因而不破坏在途任务与已有证据绑定。目录与有效角色证据共同决定可选项。
2. 增加独立 Elixir 管理 HTTP 服务：受控静态清单把不透明仓库 ID 绑定到绝对
   WORKFLOW 路径、仓库身份和独占 state_dir；读取时重新核验绑定。
   不切换全局工作流，不启动调度器，不管理任务状态。
3. 管理服务与启用管理的 View 只监听 loopback。获准内网访问通过既有受控反向代理；
   本任务不安装代理或更改防火墙。管理员 Bearer 凭据来自后台环境引用，浏览器仅
   在当前页内存保存输入；读写均鉴权，写操作严格校验 Origin、JSON 和仓库范围。
   View 只向固定 loopback 管理地址转发，不接收客户端提供的 URL/文件路径。
4. DeepSeek Responses 复用 Codex AppServer 的自定义 Responses provider 和隔离工具
   执行环境，保留只读 reviewer、结构输出、预算和候选绑定。实际 reasoning.effort
   原样发送 none/low/high/max；GPT 参数来自账号目录。DeepSeek 目录按连接查询，
   不把 Codex 的 GPT 目录当作 DeepSeek 发现；无参数证据时不能猜测档位。
5. View 设置页增加双角色选择、取消、保存、冲突和切换未保存提示；任务采集仍只读。
   测试覆盖恶意输入、并发、失败保值、冻结/撤销、渠道能力与打包入口。

### 当前诊断渠道修复计划

前轮将围栏兼容扩展到公共 Recovery.parse/1，破坏既有严格裸 JSON 合同；
冻结回归的拒绝断言正确，不是待控制器消解的规格冲突。本轮工程修复：

1. 恢复 Recovery.parse/1 的严格解码，直接围栏拒绝；新增显式服务参数入口，
   由 DeepSeek 适配器核对冻结 provider、adapter、protocol 后规范化完整结果，
   再执行原语义校验。保持其他渠道和缺失快照的旧任务严格行为。
2. 核对全部诊断消费入口：Attempts 有限重试、Executor 普通诊断与外部等待源绑定、
   InterruptedCoder 中断与超时恢复；均用原 services.coder，不重新读取当前默认。
   保留原 output.txt/source_raw 及摘要，outcome.json 同时记录规范化文本。
3. 回归直接拒绝围栏、DeepSeek 成功、OpenAI 裸 JSON、失败输入与有限重试，
   对更改默认后的外部等待和中断恢复保留原始证据、只读及候选绑定验证。
4. 同会话修复所有检查失败，运行固定 candidate、baseline 和完整 View 入口；
   不修改基线、检查政策、控制器证据或测试环境来绕过断言。

无注册表／回执结构迁移；回滚代码不会改写原证据，但 DeepSeek 围栏诊断将停止，
保留预算和停点。该修复不新增用户决定、权限或真实调用授权。

## 外部停点

离线环境无真实账号凭据，不发起付费调用或外发真实仓库材料。不添加 ready，
不修改 Linux 运行预设；本任务 gpt-6.1-sol/high 的运行证据由控制器独立核验。
真实 DeepSeek/GPT 双角色、批准内网代理配置及准确候选独立 Review 待控制器／所有者验收。

### 旧 OpenAI null 预设设置兼容修复计划

本轮核实设置枚举将旧预设的 null 替换成空对象或目录中的显式档位，导致精确绑定
旧参数的有效证据无法展示。新增接口回归在修复前失败：当前合法默认没有 available 选项。
修复仅补入原 OpenAI 预设原型号的精确 null 组合，状态仍由渠道、当前凭据和本角色
有效证据校验。选项提供 `default_value`，页面保存旧 null 组合时提交原字符串预设；
不开放新默认对象中的 null，也不补造空对象／显式档位证据。页面显示“未指定思考参数”，
与关闭思考和不支持调节区分。无需数据迁移；回滚源码不改变原预设及证据，但会重新
出现设置枚举缺口。核验双仓库双角色保存、失败／冲突保值、重新读取及浏览器刷新；
原 packaged 管理入口、冻结和撤权回归保留。最终运行结果在本页末尾单列。

这是 IS-079 范围内的兼容修复，无新增用户决定或权限；外部停点保持。

## 迁移与回滚

旧字符串 defaults 无须迁移。先由后台登记渠道能力并验证所需角色组合，再在页面选择。
管理清单必须显式绑定仓库与现有 WORKFLOW/state_dir，不创建新调度范围。
上线前备份 model-services.json；回滚到旧代码前，用当前管理入口将对象默认恢复为
旧字符串预设并确认实际参数相符。在途完整快照保留，旧执行器无法识别时保持停点。
若不存在组合相符且证据有效的旧预设，回滚保持停点，不隐式换回另一档参数。
保存／源码交付不等于服务安装、网络配置或真实调用获准。


## 配置与访问合同

以下路径、域名、端口均为工程示例，必须由管理员替换为已有获准配置；本任务没有安装或
启动运行服务。管理清单放在控制器侧受控目录，配置文件只含安全环境引用，不写令牌：

```json
{
  "port": 8765,
  "origin": "https://view.example.internal",
  "token_ref": "env:SYMPHONY_SETTINGS_ADMIN",
  "repositories": {
    "repo-a": {"repository": "owner/a", "workflow": "/controlled/a/WORKFLOW.md", "state_dir": "/controlled/a/state"},
    "repo-b": {"repository": "owner/b", "workflow": "/controlled/b/WORKFLOW.md", "state_dir": "/controlled/b/state"}
  }
}
```

后台令牌至少 32 字节，由既有受控后台环境提供，不通过 CLI 参数、WORKFLOW 或源码注册；IS-098 授权页面在成功登录后将管理令牌保存在当前浏览器的同源 localStorage。打包入口 `elixir/bin/symphony --model-settings /controlled/manager.json`
只启动 Bandit 及依赖，不启动 Symphony 调度监督器。清单缺失／损坏或令牌不可用启动失败；
每个请求重读清单与令牌，撤权即时生效。仓库、WORKFLOW 和 state_dir 须唯一；读取时
核验规范绝对路径、WORKFLOW 仓库身份及当前 state_dir，拒绝别名／跨仓库绑定。

View 的 `[board]` 配置 `model_settings_url = "http://127.0.0.1:8765"` 和
`model_settings_origin = "https://view.example.internal"`。后者必须与清单和浏览器实际
Origin 精确一致。仅支持固定 loopback 目标；启用时 View 同样强制监听 127.0.0.1。
内网代理必须只监听所有者获准内网地址、限制获准来源地址并使用 HTTPS；保留浏览器
原始 Host、Origin、Authorization，不把任意来源改写成合法来源。代理不得把管理端口
直接暴露出去，也不记录 Authorization 或请求正文。模板域名不授权任何新网段。

管理服务为 `GET /repositories`、`GET /repositories/{id}`、`POST /repositories/{id}`；
View 同源路径前缀 `/api/model-settings/`。读写均要求独立 Bearer 管理员令牌。
POST 仅接受精确 Origin 和 application/json，有界 16 KiB 正文；View 另校验 Host、
跨站请求标记、长度／重复头和固定路径。不用 Cookie 认证，不提供 CORS 许可。
Body 严格为 `revision`、`workflow_version`、`defaults`；后者只包含 coder／reviewer，
可为兼容字符串或严格的 preset／model／parameters 对象。成功 200；CAS 冲突或忙 409；
授权失败 401，来源／格式拒绝 403，非法选择 422，代理故障 503。错误不返回文件原文、
环境、密钥或认证路径；auth_home 仅显示已配置引用。IS-098：页面在成功鉴权后将令牌与仓库选择保存在当前浏览器的同源 localStorage；刷新或浏览器重启后自动读取。退出登录和 401 清除保存的管理登录，令牌撤销仍由后端即时检查。其他设备／浏览器需首次登录。

保存只修改原仓库 model-services.json 的 defaults 与 revision，不改变预设版本、
目录和历史能力证据。保存和每次执行都校验完整组合。失败和并发冲突保留旧文件，
页面保留草稿；默认变化不更新已领取快照或 GitHub 状态。GLM 没有可执行适配器。
保存回应使用本次提交的配置快照，避免提交后重读失败或读到他人更新造成错误反馈。
只修改一个角色时，页面保留另一角色原始默认表示，维持旧字符串预设的继承语义。

## 验收条目与证据对应

| GH-16 合同条目 | 仓库内验证 | 外部停点 |
| --- | --- | --- |
| GH16-A01 两仓库、双角色、持久读取及重启 | MvpModelSettingsTest：分别保存四份组合，逐次核验角色／仓库隔离、版本及目录不变；旧字符串／null 默认在空档位及显式档位目录下精确展示、选择和保存；packaged 管理进程重启后读取普通及旧 null 组合 | 真实受管仓库配置与部署 |
| GH16-A02 未保存、取消、切换、保存／失败／冲突 | model-settings.test.mjs 草稿和失败保留；browser-model-settings.cjs 原生键盘选择／保存／取消、切换确认、409／503、刷新及 390×844 控件可见与操作；旧 null 默认明确显示未指定参数，选择时保存字符串、失败重试和刷新后保留精确参数及其他角色／仓库 | 已完成合成数据真浏览器检查；真实部署另验 |
| GH16-A03 OpenAI 兼容与 DeepSeek 工具／输出 | ModelServices／Routing 测试旧 null 配置加载、领取和执行；原生 Codex + 本地 TLS Responses + 外部执行器工具往返 | 真实账号双角色权限与推理 |
| GH16-A04 分档、开关、不可关闭、固定、未知、过期／绕过 | MvpModelSettingsTest 为双角色 none／high 建立精确证据并分别保存，非法 low／未知／过期／固定参数请求拒绝且原值不变；Routing 断言 fixed 不携带任何思考参数，分档仅发送所选 effort；JS 模型切换清除深度 | 当前真实账号目录 |
| GH16-A05 参数、连接、凭据引用与角色隔离 | 路由测试检查独立 home、模型、provider、effort、HTTP 请求与冻结 options | 真实账号准确有效参数和返回 |
| GH16-A06 写入失败／CAS／权限／跨站／秘密 | Elixir 管理测试：busy、并发、版本、畸形默认、原值保留；Python API 测试：Host／Origin／头／路径／限长；auth_home 脱敏 | 受控凭据注册 |
| GH16-A07 内网监听和访问范围 | 管理 listener_info、View socket 及配置拒绝测试；两服务均 loopback | 所有者获准代理地址、来源限制和 TLS 实机验收 |
| GH16-A08 只影响新领取、评论兼容、冻结与撤权 | ModelServices／RecoveryResume 同时回归字符串深度及旧 null 快照的重试、Review、诊断、返工和审计恢复；撤权及凭据失效拒绝 | 控制器准确候选验收 |
| GH16-A09 Reviewer 只读、隔离、预算、正式检查、SHA | 原 ExecutionSandbox／Review／Executor／Recovery／外部 handoff 冻结回归 | 生产内核挂载与准确候选正式证据 |
| GH16-A10 同步规格与可追溯历史 | IS-079、REQUIREMENTS、MODEL_SERVICES、README 和 AGENTS | 同一个功能 PR 由控制器另行处理 |
| GH16-A11 完整门禁及独立 Review | candidate／baseline 固定检查；标准 run_view_checks 包含新增 JS 及设置页浏览器，浏览器报告必须包含设置用例完成项 | 独立 Reviewer 由控制器执行 |

TLS 夹具使用实际 Codex AppServer 和 exec-server 完成命令工具读取及结构化 JSON，
请求包含 DeepSeek 实际 reasoning.effort=max。两角色使用各自的模拟凭据；夹具只在
本任务外层离线沙箱内运行，内层执行器是测试替身，不作为生产 reviewer 内核只读
或真实 DeepSeek 能力证明。原正式隔离回归保留。夹具仅在工具返回正确随机／指定内容
后给出有效结果，父 Port 关闭即退出，不留下维持检查输出管道的后台进程。

本轮结构化解析补充 GH16-A03／A09 的以下回归，其他验收映射沿用上表并通过完整
门禁重新核验，不能用局部通过代替最终检查：

| 合同 | 本轮回归 | 仍需外部证据 |
| --- | --- | --- |
| A03 完整结果格式 | StructuredOutputTest：裸 JSON、单 json 围栏及 CRLF／外层空白；拒绝散文、多／非 json 围栏、拼接、残缺和非字符串 | 新候选真实渠道结果 |
| A03 语义校验 | ReviewExternalTest／RecoveryTest：Recovery 核心拒绝围栏，冻结 DeepSeek 适配后错误字段和无效外部条件仍拒绝；Review.validation_errors 与 parse 同规则 | 新候选独立 Review |
| A03 双角色能力 | ModelServicesTest：双角色正确 token 和成功工具事件；错误 token、额外字段、非法包装、缺失／失败工具均拒绝 | 准确候选、角色、模型、渠道、有效参数及脱敏原始探测 |
| A03 OpenAI／DeepSeek | ModelRoutingTest：原生 Codex、TLS Responses、真实工具往返；请求同时声明 tools 和 json_schema(strict)，DeepSeek 返回单围栏，OpenAI 保留裸 JSON；max／fixed 参数和双账号仍核验 | 真实账号双角色权限、reviewer 内核只读 |
| A09 失败 Turn | 双角色 AppServer 探测在裸／围栏正确结果后收到 failed／interrupted 仍拒绝且不增加证据 | 生产执行隔离实测 |
| A08／A09 返工和绑定 | RecoveryExecutorTest：DeepSeek 围栏诊断、恶意格式有限重试与 OpenAI 严格拒绝，重编码、只读角色、单次评论和最终新候选 SHA 绑定 | 控制器正式证据及最终独立 Review |

## 上一候选自检结果（历史）

固定 `python3 /opt/symphony/scripts/check_isolated.py candidate` 的 format、lint、
Credo、test、Dialyzer 和 build 全部通过；799 项测试中 793 通过、0 失败、6 跳过，
覆盖率 100%。证据目录为 `.check-evidence/candidate-bgoj6nhp/`。
固定 `python3 /opt/symphony/scripts/check_isolated.py baseline` 通过；789 项测试中
783 通过、0 失败、6 跳过，证据目录为 `.check-evidence/baseline-4ocftike/`。
两轮政策检查均为 `policy_changes: []`，`git diff --check` 通过。
源码仅保存在工作区，没有提交、PR、安装或部署。独立 Review 未在此编码会话执行，
真实模型和内网安装未验证；以下 View 环境失败使整体验收仍未完成。

检查环境说明：继承的 umask=077 使原有导入恢复测试的 chmod(0600) 没有形成权限变化。
固定候选与基线检查均显式使用 umask=022，保留原测试、冻结策略和门槛；没有修改隔离
政策或控制器证据。6 个原有真实外部 E2E（GitHub、GitLab、Asana、Jira、Linear 本地／SSH）
保持原环境开关的跳过状态，没有新增 skip／exclude。独立 Reviewer 尚未执行。

View 的指定 `/opt/toolchain/view-validation/python/bin/python` 和
`/opt/toolchain/view-validation/node/bin/node` 在此沙箱不存在，PATH 也没有 Node。
系统 Python 3.14 的完整 suite 执行 38 项，37 通过、1 渲染错误：
`test_first_cycle_caches_and_renders_without_existing_directories` 抛出
`ModuleNotFoundError: No module named 'codex_transcript_viewer'`。
修复新测试导入对 worker 的模块路径影响后，`scripts/run_view_checks.py` 再跑仍被该
缺依赖错误阻断，未通过完整 View 门禁。独立尝试 root-default 打包入口同样在 self_check
渲染处失败，其余 7 入口模式未执行。Linux 采集的 11 项合成子进程回归通过，后续服务
渲染被同一依赖阻断，整项集成不记通过。Node 既有 JS 门禁、真实浏览器／窄屏和固定
HTML 等价比较未执行。没有模拟渲染库、修改原预期或弱化检查来制造成功。

新增配置 API 的 3 个 Python 测试通过；`gjs -m view/tests/model-settings.test.mjs`
完成合成 DOM／API 交互回归（包括键盘焦点），不替代真实浏览器验收。目标 Elixir
模型路由及管理 34 项测试通过，包括原生 Codex 工具链路和打包管理重启。所有真实账号
验证、获准内网代理、服务安装和最终候选独立 Review 保持待外部验收。

## 控制器检查失败后的最小修复

控制器 `/evidence/check-1.log` 的唯一失败为导入恢复权限篡改测试：进程
`umask=077` 将原文件创建为 0600，测试再 chmod(0600) 未改变权限，恢复合法通过。
只读基线的同一测试在本环境复现该失败（1 项失败），不据此放宽生产恢复校验。
本轮仅将该用例的原始夹具权限显式设为 0644，断言失败导入后保持 0644、篡改后为
0600，并保留内容篡改拒绝、权限篡改拒绝及完整回滚的全部断言。
修复用例分别在 umask=077 和 022 下通过；目标运行每次 1 项通过，39 项未选中。
生产权限、恢复实现、冻结配置、门禁及控制器证据不修改，不新增用户决定。

候选完整固定检查保留本环境 umask=077；冻结 baseline 含未修复的旧用例，沿用
历史 umask=022 单独运行。baseline 的结果不能作为旧用例在 077 下通过的证据。
本次检查结果及外部停点以下列实际记录为准，不沿用上节历史候选的通过状态。

`python3 /opt/symphony/scripts/check_isolated.py candidate` 在 umask=077 下退出 0：
format、specs、Credo、全量覆盖测试、Dialyzer 和 escript build 均通过。
799 项中 793 通过、0 失败、6 个既有真实外部 E2E 跳过，0 排除，覆盖率 100%；
恢复／隔离文件的独立整文件运行另有 40 项通过、0 失败。
本次候选检查目录为 `.check-evidence/candidate-6gopxn7w/`，`policy_changes: []`。

`umask 022; python3 /opt/symphony/scripts/check_isolated.py baseline` 退出 0：789 项中
783 通过、0 失败、6 个既有真实外部 E2E 跳过，0 排除。检查目录为
`.check-evidence/baseline-k6e17r4r/`，`policy_changes: []`；`git diff --check` 通过。
仅保存测试修复及本记录，没有提交、push、PR、合并、安装、部署或升级服务。
准确最终候选的控制器验证、独立 Review、真实账号及获准内网验收仍待外部执行。

本轮 View 验证：指定 `/opt/toolchain/view-validation/python/bin/python` 与
`/opt/toolchain/view-validation/node/bin/node` 仍不存在；指定 Python 检查命令退出 127
（No such file or directory）。系统 `python3 -B scripts/run_view_checks.py` 退出 1：
38 项中 37 通过、1 错误、0 跳过，原首次缓存／渲染用例缺少
`codex_transcript_viewer`（ModuleNotFoundError，随后报告需要 codex-transcript-viewer）。
私有副本的 root-default 入口退出 1，同样在 self_check 渲染处失败；其余 7 个入口模式、
固定 HTML 比较、Node 轮次检查及真实浏览器／窄屏检查未执行。未使用替代渲染器、
修改预期或放宽检查。本轮 3 项 Python 模型管理 API 测试及 gjs 合成 DOM 交互回归通过，
不替代完整 View 验收。检查输出位于 `/tmp/gh16-repair-view-check/`，入口诊断位于
`/tmp/gh16-repair-entrypoint.log`；缺失的离线依赖须由执行环境提供。

## 本次冻结基线失败接续

接续依据为控制器 `/evidence/round-2/check-2.log`：冻结 baseline 在 `umask=077`
下运行，原权限篡改用例的 `chmod(0600)` 没有改变原本就是 0600 的文件。
本次保留既有 GH-16 实现、生产恢复校验、只读基线及全部检查政策，仅扩展候选的
回归用例：显式创建 0644／0600 两种原始权限，分别验证内容篡改、双向权限篡改
拒绝；重复设置原权限仍合法恢复，并核验恢复后的内容和权限。共八个场景，避免
将正常的无变化操作误判为生产缺陷。没有新增用户决定或修改运行配置。

候选完整门禁使用继承的 `umask=077`；冻结 baseline 用原测试所需的 `umask=022`
运行，命令为 `umask 022; python3 /opt/symphony/scripts/check_isolated.py baseline`。
这不修改冻结测试或检查政策，也不能证明原测试在 077 下通过。控制器若继续以
077 运行原测试，同一夹具假设仍存在，须由控制器提供正确的测试环境。

View 指定 Python 和 Node 路径仍不存在，直接调用均退出 127。系统 Python 的完整
检查执行 38 项，37 通过、1 错误、0 跳过，仍因缺少 `codex_transcript_viewer`
退出 1。另行逐一执行八种私有副本入口（根目录／view 目录，默认／TOML／JSON／
serve），均退出 1，且均报告同一缺失渲染依赖；不是通过。Linux 合成集成中的
11 项采集回归通过，随后服务渲染同样失败，完整集成退出 1。3 项模型管理 Python
测试通过，`gjs -m view/tests/model-settings.test.mjs` 合成交互回归通过。固定 HTML
比较、Node 轮次测试和真实浏览器／窄屏验证未执行；没有替代渲染器、安装依赖或
弱化门槛。输出分别位于 `/tmp/gh16-current-view-check/` 和
`/tmp/gh16-current-view-entrypoints/`。

本次 `python3 /opt/symphony/scripts/check_isolated.py candidate` 退出 0，格式、规格、
Credo、覆盖测试、Dialyzer 和 escript build 全部通过。799 项测试中 793 通过、
0 失败、6 个既有真实外部 E2E 跳过、0 排除，覆盖率 100%；扩展后的八场景权限
回归通过。证据目录为 `.check-evidence/candidate-gbb0c6dv/`，`policy_changes: []`。
这些结果针对本次未提交工作区，不将检查记录中的原 Git HEAD 当作包含本次改动的
已提交候选身份；最终候选绑定由控制器完成。

本次 `umask 022; python3 /opt/symphony/scripts/check_isolated.py baseline` 退出 0：
789 项中 783 通过、0 失败、6 个既有外部 E2E 跳过、0 排除；原权限恢复用例通过。
证据目录为 `.check-evidence/baseline-1k4k6os6/`，`policy_changes: []`。
`git diff --check` 通过；源码改动仅为该权限回归与本节记录，生成的本地检查证据另存。

真实账号、批准内网部署、最终候选的控制器正式验证及独立 Review 保持外部停点。
本次仅保存仓库内测试与本记录，未提交、发布、合并、安装、部署或升级服务。

## round-3 冻结夹具接入停点与最小修复

本次接续重新核对了只读 `/evidence/round-2/check-2.log`、
`/evidence/round-3/check-2.log` 和 `/baseline/elixir/test/symphony_elixir/mvp_execution_sandbox_test.exs`。
诊断内容仅作待核实材料，不作为修改受信门禁的授权。两轮原命令均在同一权限断言失败：

| 控制器检查 | ExUnit seed | 执行结果 | 失败位置 |
| --- | --- | --- | --- |
| round-2 | 216655 | 789 项、1 失败、6 跳过，outcome=10 | 恢复用例 1014 行，期待拒绝，实际 `:ok` |
| round-3 | 379228 | 789 项、1 失败、6 跳过，outcome=10 | 同一恢复用例、同一断言 |

冻结夹具的 `context!/0` 在约 1029 行写入 source.txt 后未设置权限；继承 umask=077
时文件为 0600，旧用例的 `chmod(0600)` 是无变化操作。候选与冻结基线的生产
`lib/symphony_elixir/mvp/execution_sandbox.ex` 字节相同，SHA-256 均为
`2db8f194436b907f8625c52052b3234d419605e1061de136a19b4ba6c67c7dc0`。
没有证据支持改变恢复语义以拒绝这个合法操作。

本次只在候选共享 `context!/0` 写入 source.txt 后添加以下初始化和断言；不继续
扩展同一个八场景用例，不修改生产权限、恢复实现或其他任务配置：

```elixir
File.chmod!(Path.join(workspace, "source.txt"), 0o644)
assert Bitwise.band(File.stat!(Path.join(workspace, "source.txt")).mode, 0o777) == 0o644
```

这也是交给固定门禁维护者的最小夹具修复位置。既有回归保留 0644→0600、0600→0644、
内容篡改、无篡改及重复设置相同权限；真实变化拒绝，无变化允许。候选修复不能自行
进入冻结测试：受信 `/opt/symphony/scripts/check_isolated.py` 的 `prepare_harness`
只复制候选 lib/priv，baseline 模式使用 `/baseline/elixir/test`。维护者须在任务沙箱
之外核验上述修复、更新受信测试来源，再由控制器将修复后的固定基线提供给任务。
当前没有已提供的受信修复接入路径；不修改 /baseline、/evidence、检查器或有效政策，
不通过候选生产代码改写基线测试。

前文临时 `umask 022` 的通过记录仅保留为历史诊断，不能代替原正式命令或证明旧
冻结用例已修复。本次 candidate 和 baseline 均按指定原命令、继承 umask=077 运行；
不把仅候选通过当作全部门禁通过。受信修复接入后，须对准确新候选重跑全部固定
检查、适用 View 检查和控制器独立 gpt-6.1-sol/high 只读 Review。

本次 `python3 /opt/symphony/scripts/check_isolated.py candidate` 退出 0；format、
specs、Credo、覆盖测试、Dialyzer 和 escript build 均通过。799 项中 793 通过、
0 失败、6 个既有真实外部 E2E 跳过、0 排除，覆盖率 100%；检查目录为
`.check-evidence/candidate-d_qlb7uz/`，`policy_changes: []`。结果针对未提交工作区；
报告中的 Git HEAD 不代表包含本次修改的已提交候选，最终 SHA 绑定归控制器。

本次指定 View Python／Node 直接调用均退出 127（No such file or directory）。
系统 `python3 -B scripts/run_view_checks.py --output /tmp/gh16-round4-view` 退出 1：
38 项中 37 通过、1 错误、0 跳过，首次缓存／渲染用例缺少 `codex_transcript_viewer`。
另外逐一执行的八种私有副本入口均退出 1，均为同一缺失依赖；Linux 集成的 11 项
采集测试通过，随后的实际渲染失败，整项集成退出 1。日志和入口结果分别保存在
`/tmp/gh16-round4-view/`、`/tmp/gh16-round4-entrypoints/`。模型管理 API 的 3 项
Python 测试及 `gjs -m view/tests/model-settings.test.mjs` 合成 DOM／API 回归通过，
不替代 Node、固定 HTML 比较、真浏览器键盘／窄屏及完整 View 验收；后者均未完成。
没有替代渲染器、安装运行依赖或修改预期。真实账号、内网部署与独立 Review 未执行。

本次原命令 `python3 /opt/symphony/scripts/check_isolated.py baseline` 在继承的
umask=077 下退出 10，child_exit=2；seed=634298，789 项中 782 通过、1 失败、
6 个既有真实外部 E2E 跳过、0 排除。唯一失败仍是旧用例第 1014 行权限断言
（期望 `{:error, :sandbox_import_recovery_required}`，实际 `:ok`）。检查目录为
`.check-evidence/baseline-8sybe45w/`，`policy_changes: []`。本次没有再以 022
改写运行环境或重复运行同一失败；完整 baseline 门禁未通过，不能交付为全部验收完成。
须由固定门禁维护者接入上述受信夹具修复，并补齐指定 View 工具链和渲染依赖，
才具备重跑剩余必需检查的条件。源码仅保存于本仓库，未提交、发布、安装或升级服务。

## round-4 诊断后的回归补强

本次先核对任务基线文档、既有实现及只读 `/evidence/round-4/check-2.log`。
历史限制和上表验收合同不变：不修改受信测试来源、检查器、控制器证据、生产恢复
语义或运行配置，不以调整正式检查 umask 取得通过。该失败仍是冻结测试夹具的
确定缺陷及受信接入问题，不归类为缺少外部条件；候选代码无法替代 baseline 的 test。

最小工程计划与实际修改仅为补强原八场景回归：明确断言双向权限篡改前后不同；
每次真实篡改连续两次请求恢复，验证文件内容／权限、回执及 journal 原字节不变，
且未创建审计目录或执行锁。恢复原始内容和权限后，同一授权请求成功闭合，并核验
归档 journal 和 receipt-before 与原字节一致。合法无变化与重复设置权限仍成功。
这是失败重试与现场／审计完整性的新增行为证据，不修改产品需求或新增用户决定。

接入责任仍归受信门禁维护者：审查已有 `context!/0` 的显式 0644 初始化及权限差异
断言，通过沙箱外可追溯路径更新实际冻结夹具。未接入前保持 baseline 失败状态；
本候选回归通过不能解除该停点，也不能替代准确候选的独立 Review。

新增权限回归在独立临时检查副本中分别以 umask=077／022 运行：每次 1 项通过、
0 失败、39 项因位置选择未执行。该选测只验证环境独立性，完整门禁不作排除或
环境覆盖。原始输出为 `/tmp/gh16-session-permissions.log`。

本次 View 指定 Python／Node 路径均不存在，直接调用退出 127；指定净化源码包
目录 `/opt/symphony/scripts/view_validation/source` 也不存在。系统 Python 完整
检查退出 1：38 项中 37 通过、1 错误、0 跳过，错误为缺少
`codex_transcript_viewer`。另行运行八种私有副本入口均退出 1，全部被同一渲染
依赖阻断。Linux 集成的 11 项采集测试通过，后续渲染失败使整项退出 1。
3 项模型管理 Python API 测试及 gjs 合成 DOM／API 回归通过；Node、固定 HTML
比较、真浏览器键盘／窄屏检查未执行，不以 gjs 替代。输出分别位于
`/tmp/gh16-session-view/`、`/tmp/gh16-session-entrypoints/`。
真实账号、获准内网部署及控制器独立 Review 仍未执行；没有新增服务安装或调用。

随后再次只读查找时，指定 View 工具链已在环境中可用，本会话没有安装或改写该
工具链。使用 `/opt/toolchain/view-validation/python/bin/python -B
scripts/run_view_checks.py --node /opt/toolchain/view-validation/node/bin/node
--output /tmp/gh16-session-view-provisioned` 复检退出 0：38 项 Python 全通过、
0 错误／跳过；10 项 Node 全通过、0 跳过；固定 snapshot/context/HTML 比较、
self_check 渲染、八种入口和 Linux 合成集成全部通过，后者含 11 项采集回归及实际
loopback HTTP／渲染／失败恢复验证。Python 为 3.14.4，Node 为 v24.19.0。
另用该 Node 执行 `view/tests/model-settings.test.mjs` 通过。上述结果解除本轮
工具链／渲染检查停点，早先失败记录保留；真浏览器键盘／窄屏及真实账号、内网
部署和独立 Review 仍未执行。净化源码包目录仍缺失，未运行要求该包的来源验证器；
本次没有迁移新的 View 来源，已通过的 HTML 比较使用仓库内固定迁移预期。

本次 `python3 /opt/symphony/scripts/check_isolated.py candidate` 继承 umask=077，
退出 0：format、specs、Credo、覆盖测试、Dialyzer 和 escript build 全部通过；
799 项中 793 通过、0 失败、6 个既有真实外部 E2E 跳过、0 排除。六项跳过分别
为 Jira、Asana、Linear SSH／本地、GitLab、GitHub，未新增跳过。
覆盖率 100%；检查目录为 `.check-evidence/candidate-jrgm2ts2/`，`policy_changes: []`。
本次结果针对未提交工作区，检查记录中的原 HEAD 不代表包含这些改动的最终候选；
准确 SHA 绑定及独立 Review 由控制器完成。

另行调用指定 Node 的 `view/tests/browser-fixture.cjs
/tmp/gh16-session-view-provisioned/fixture` 退出 1：
`Cannot find module 'playwright/package.json'`（MODULE_NOT_FOUND）。浏览器未启动，
不将该诊断记为 UI 验收通过；日志为 `/tmp/gh16-session-browser.log`。

## 所有者授权的受信环境维护后复检

来源：本轮操作者维护通知明确告知所有者已授权 GH-16 门禁环境修复。
受信 `check_isolated.py` 现以历史夹具 SHA-256 精确匹配，仅在临时 baseline harness
中插入 0644 初始化及断言，保留 `/baseline` 原文件和全部篡改断言，并生成
`baseline-maintenance.json`；维护 ID 为 `gh16-fixture-mode-20261008`。
本会话只读核验该接入，未修改受信入口、`/baseline`、`/evidence`、运行凭据或
冻结合同。指定 View 工具链已由维护者提供，本轮完整复检结果见上节。
按通知重新执行原 candidate／baseline 固定命令，保留继承 umask=077、全部检查、
覆盖率与既有外部 E2E 开关；不运行排在本会话之后的维护探针。
准确最终候选的控制器正式检查及独立 Review 仍由控制器执行。

维护前已启动的原 baseline 随后退出 10：seed=419277，789 项中 782 通过、
1 失败、6 个既有外部 E2E 跳过、0 排除，仍为旧夹具第 1014 行的权限断言。
其目录为 `.check-evidence/baseline-trcu4iw3/`，`policy_changes: []`。
该进程在维护安装前已加载旧入口，此结果保留为历史；维护后的重新检查另行记录。

维护后原命令 `python3 /opt/symphony/scripts/check_isolated.py candidate` 退出 0：
format、specs、Credo、覆盖测试、Dialyzer、escript build 全通过；799 项中
793 通过、0 失败、6 项既有跳过、0 排除，覆盖率 100%。目录为
`.check-evidence/candidate-gfgmpgo_/`，`policy_changes: []`；其
`baseline-maintenance.json` 为 `repairs: []`，未给候选注入基线夹具维护。

维护后原命令 `python3 /opt/symphony/scripts/check_isolated.py baseline` 同样继承
umask=077，退出 0：seed=628418，789 项中 783 通过、0 失败、6 项既有外部 E2E
跳过、0 排除。原失败的篡改拒绝用例通过；检查目录为
`.check-evidence/baseline-7__50584/`，`policy_changes: []`。
该目录的 `baseline-maintenance.json` 记录维护 ID、精确原始／生效摘要和
`assertions_removed: false`。受信夹具接入停点已解除，早先失败不再作为当前门禁
结论；未通过调整 umask、改生产语义或减少测试取得通过。

本次验收对应表仍见前文，各条的仓库内测试均已执行通过；真浏览器因缺少 Playwright
尚未启动，真实账号双角色、获准内网部署及最终候选控制器正式验证／独立 Review
继续单列。`git diff --check` 通过。本轮源码仅修改恢复回归与本页记录，没有提交、
push、PR、合并、部署或升级运行服务；维护验证的独立探针留在本会话之后执行。

## GH-16 审查缺口续修

本轮继续保留既有工作区补丁，核验旧 OpenAI null 参数不改写快照／证据绑定，
补齐四份默认选择保存与 packaged 管理进程重启、双角色 switch 精确证据和
fixed 原生请求不发送有效思考参数的回归。设置页用原生键盘完成操作，修复异步重绘
后的焦点保持；错误令牌、503 后保存重试和 409 冲突都保留明确失败反馈。
标准 `scripts/run_view_checks.py` 与 CI 同时执行新增 JS 和设置页真浏览器用例。
浏览器夹具必须读取包含设置页完成项的 smoke 报告，不能仅凭旧看板进程退出 0
认定 GH16-A02 通过；浏览器环境和执行项目进入标准检查报告。

使用维护者提供的只读 `/opt/toolchain/view-validation/playwright/node-playwright`，
Playwright 1.62.1、Chromium 151.0.7922.34；本会话没有安装工具链或改运行配置。
首次标准 View 检查输出 `/tmp/gh16-current-view/` 退出 0：38 项 Python、11 项 JS、
11 项 Linux 来源回归，均零失败／跳过；固定迁移比较、self_check、8 种入口及
真实浏览器 9 组操作通过。设置页浏览器操作含两仓库双角色、键盘、刷新、取消、
409／503、切换提示及 390×844 窄屏；管理 API、凭据和任务数据均为合成夹具。
另行使用指定 wrapper 调用 `view/tests/browser-fixture.cjs` 的新报告断言退出 0，
输出 `/tmp/gh16-current-browser.log`。增加登录和保存重试回归后再次运行完整标准
View 检查，最终结果另记下文。

首次 candidate 检查 `.check-evidence/candidate-vz8or4zr/` 退出 10：804 项测试中
1 失败、6 项既有外部 E2E 跳过，另有 3 项 Credo 问题。新的原生 fixed 请求回归
捕获 Codex 默认添加 `reasoning.summary=auto`；适配器现在对固定配置和 DeepSeek
关闭该默认。Credo 的两处长行及测试 helper 嵌套已修复，没有改检查政策。
协议诊断进一步证明，Codex 0.160.0 即使关闭 summary 仍会序列化空 `reasoning: {}`。
这个空容器没有有效参数；测试因此按实际参数合同核验全部键，而不要求客户端省略
空容器。TLS 服务端严格拒绝 fixed 的任何实际思考键、分档的任何额外键；请求断言
同时检查 fixed 为缺省／空对象、graded 恰为 `{"effort":"max"}`，防止 summary、
未知键或隐式 effort 混入。既有模型目录、系统指令、冻结快照和参数证据未被替换。
单项 native DeepSeek 双角色 max／fixed 工具往返修复后通过；最终全量进一步覆盖
OpenAI fixed 双角色，不用合成凭据标记真实账号可用。

最终标准 View 检查 `/tmp/gh16-final-view/code-check-result.json` 退出 0：38 项 Python、
11 项 JS、11 项 Linux 专用回归均零失败／跳过；固定迁移比较、self_check、8 种
入口和 9 组真实浏览器操作全部通过。浏览器报告记录 Node v24.19.0、Playwright
1.62.1、Chromium 151.0.7922.34，新增错误令牌后登录及 503 后保留草稿再成功保存
也已执行。标准入口及 CI 必须执行设置页 JS／浏览器用例，失败返回非零。

最终固定 `python3 /opt/symphony/scripts/check_isolated.py candidate` 退出 0，目录
`.check-evidence/candidate-1u1h5dli/`：format、specs、Credo、全量覆盖测试、Dialyzer
及 escript build 全通过。804 项中 798 通过、0 失败、6 项既有外部 E2E 跳过、
0 排除，覆盖率 100%，`policy_changes: []`。检查继承 umask=077，没有注入候选
基线夹具维护。最终 baseline 的重新检查结果见下文。

最终固定 `python3 /opt/symphony/scripts/check_isolated.py baseline` 退出 0，目录
`.check-evidence/baseline-q1g6ko5h/`：789 项中 783 通过、0 失败、6 项既有外部
E2E 跳过、0 排除，`policy_changes: []`。受信入口的维护记录仅作用于临时
baseline harness，保留原冻结文件和所有篡改断言；本会话未改入口或控制器证据。
六项既有跳过仍为 Jira、Asana、Linear SSH／本地、GitLab、GitHub；没有新增跳过。
`git diff --check` 通过。源码仅保存，未提交、push、创建 PR、合并、部署或升级服务。

上述自检针对未提交工作区；检查报告中的原 HEAD 不能充当包含这些修改的最终
候选 SHA。控制器仍须绑定准确最终候选、完成其正式检查和独立 Review。
真实 GPT／DeepSeek 双角色账号探测、获准内网代理／来源限制／TLS、生产执行
隔离实测及运行安装仍为外部停点，不以合成 HTTP、模型返回或浏览器结果替代。

## 本轮结构化结果解析修复的实际检查

本轮只修复角色输出解析与回归，不改变模型配置、授权或冻结合同。反馈补丁中
会放行前后散文的扫描方式未采用；实现使用全字符串锚定。六个新增测试身份与
既有循环回归覆盖上方补充表；原生 TLS 夹具保持 OpenAI 裸 JSON 路径，并复现
DeepSeek 声明工具后返回单个 json 围栏。真实账号无凭据，未发起付费调用或外发
真实材料；旧候选的外部诊断不作为本工作区或最终候选的实测证据。

完整 View 检查使用预装 Python、Node 和 Playwright：

```bash
NODE_PATH=/opt/toolchain/view-validation/playwright/node_modules \
PLAYWRIGHT_BROWSERS_PATH=/opt/toolchain/view-validation/playwright/browsers \
/opt/toolchain/view-validation/python/bin/python -B scripts/run_view_checks.py \
  --node /opt/toolchain/view-validation/node/bin/node \
  --output /workspace/.check-evidence/gh16-structured-view-2
```

退出 0：38 项 Python、11 项 JS、11 项 Linux 来源回归全部通过，无失败或跳过；
固定 HTML 迁移比较、self_check、八种入口及九组浏览器操作通过，含双角色／双仓库
设置、键盘、取消、切换提示、409／503 后恢复、刷新及窄屏。Node v24.19.0、
Playwright 1.62.1、Chromium 151.0.7922.34。报告为
`.check-evidence/gh16-structured-view-2/code-check-result.json`；标记 synthetic，
formal_acceptance 和 real_windows_wsl 为 false。首次没有 NODE_PATH 的检查退出 1，
浏览器未执行；补齐预装依赖的环境路径后完整重跑，不安装依赖或修改门槛。

固定 `python3 /opt/symphony/scripts/check_isolated.py baseline` 退出 10，目录
`.check-evidence/baseline-szdj7zs6/`，完整日志 `.check-evidence/gh16-structured-baseline.log`：
789 项中 782 通过、1 失败、6 项既有外部 E2E 跳过、0 排除、0 无效。
唯一失败是 RecoveryTest 的 `diagnosis requires one complete JSON object with
nonempty summary and steps`，冻结文件 133–134 行要求单个 json 围栏返回
`:mvp_invalid_diagnosis`。前轮错误地将其记为冻结合同冲突；实际是公共解析器
放宽的代码缺陷，现按本页当前计划修复，保留这次历史失败结果。没有修改 `/baseline`、可信脚本、
测试环境分支或检查政策。`policy_changes: []`；可信入口已有的权限夹具维护仍仅
作用于临时 harness，并未处理或绕过本次 Recovery 冲突。

首轮 candidate 退出 10，原因仅为六处模块 alias 的 Credo 提示；其 810 项测试
0 失败、6 项跳过，覆盖率 100%，Dialyzer 和 escript build 通过。已修复全部提示，
另行 Credo 退出 0，原生工具／strict schema 回归 1 项通过（26 项选测排除）；
其余修复的定向重跑 2 项通过（51 项选测排除）。最终完整 candidate 结果另记下文，
不将选测或首轮结果登记为完整门禁通过。

最终 `python3 /opt/symphony/scripts/check_isolated.py candidate` 退出 0，目录
`.check-evidence/candidate-prmejkpt/`，完整日志
`.check-evidence/gh16-structured-candidate-final.log`。format、specs、Credo、完整覆盖
测试、Dialyzer 和 escript build 全部通过；810 项中 804 通过、0 失败、6 项既有
外部 E2E 跳过、0 排除、0 无效，覆盖率 100%，`policy_changes: []`。
跳过项为 Asana、Jira、GitHub、GitLab 和 Linear 本地／SSH，均未启用真实环境开关；
没有新增 skip 或 exclude。`git diff --check` 通过。

GH16-A01／A02／A04–A10 的仓库内回归及本轮 A03 补充均通过相应 candidate／View
检查，但当时 A11 的冻结 baseline 仍失败，整体验收不能登记为通过。此前建议
由控制器处理“合同冲突”有误；必须先修复候选代码，再绑定准确新候选，
重新正式验证并执行独立 gpt-6.1-sol/high
Review；获授权操作者另补新候选真实账号双角色的渠道、模型、有效参数、工具执行、
reviewer 只读、结构化结果及 SHA 绑定脱敏证据。真实内网部署和生产隔离证据仍按
原合同验收，不用离线夹具或旧候选证据替代。

本轮结果针对未提交工作区，检查报告的原 HEAD `3da7fce788c7d62139cd88aa876c9b94b91711d4`
不包含这些改动，不能充当新候选 SHA。仅保存所属仓库源码、测试、规格和本地检查
产物；未提交、push、创建 PR、合并、安装、部署、升级服务或添加 ready。没有修改
运行凭据、控制器证据、可信入口、冻结基线或检查政策；独立 Review 未在本会话执行。

## 严格诊断合同与冻结渠道边界修复（本会话）

依据 `/evidence/round-7/check-2.log` 只读核对，公共 Recovery.parse/1 接受围栏是
候选代码缺陷；上节所谓“冻结合同冲突”及应交控制器修改的建议已撤回。直接解析
恢复严格裸 JSON，DeepSeek Responses 的格式兼容由 DeepSeek 适配器按原冻结身份
处理后再校验。OpenAI 和无完整服务身份的旧诊断保持原合同。

本次没有注册表或回执迁移。Attempts 的 output.txt 保持原始响应，outcome.json
额外记录规范化文本；外部 handoff 的 source_raw/source_digest 与解析后的 source_data
分别保留。恢复重新从原始字节和原回执 services.coder 推导结果，不信任当前默认
或单独的规范化字段。旧完整快照、当前撤权／凭据校验及恢复入口的服务绑定均保留。
回滚前应停领并保留已有证据；回滚代码会恢复此前不兼容的诊断行为，不能把本次
结果当作旧执行器的继续执行授权。不安装／切换服务或改写运行数据。

本次验收对应（完整 GH16-A01–A11 对应表仍见上文）：

| 合同 | 本次回归／证据 | 限制 |
| --- | --- | --- |
| A03 严格公共诊断与渠道适配 | RecoveryTest 直接拒绝围栏；DeepSeek provider/adapter/protocol 精确匹配后才接受完整 json 围栏；OpenAI 裸 JSON 保持 | 不代表真实模型可用 |
| A03 恶意及无效输出 | 前后散文、多围栏、拼接、残缺、错误字段、空 summary/steps、无效外部条件拒绝 | 不调整核心 Schema 或语义 |
| A03 角色能力与 Turn | ModelServicesTest 精确 token、成功工具事件、缺失／失败工具拒绝；ModelRoutingTest strict Schema、工具往返及失败／中断 Turn 拒绝 | 真实账号、内核执行隔离另行验收 |
| A08 有限重试与冻结 | RecoveryExecutorTest DeepSeek 恶意格式重试后成功，原始及规范化文本分别保留；OpenAI 围栏耗尽三次后停止 | 原阶段／总次数／墙钟预算保留 |
| A08 审计恢复 | ExternalHandoffTest 默认改为 OpenAI 后仍按冻结 DeepSeek 解析原始诊断并恢复；InterruptedResumeTest 原始字节摘要、中断续跑与候选绑定 | 不重读新默认、不改旧证据 |
| A09 独立角色与最终候选 | RecoveryExecutorTest 单次拒绝评论、只读诊断／reviewer、重编码后新 SHA 绑定；既有隔离、撤权及正式检查全回归 | 独立 gpt-6.1-sol/high Review 由控制器执行 |
| A01／A02／A04–A07 View 与配置 | 完整 View 检查：双仓库双角色、刷新、键盘、窄屏、取消、切换提示、409／503 恢复；Elixir 管理／目录回归 | 获准内网真实访问与部署仍未验收 |
| A10／A11 同步规格和完整门禁 | REQUIREMENTS、DECISIONS、MODEL_SERVICES 与本页同步；固定 candidate、baseline 及 View 结果另记下文 | 准确候选 SHA 和正式验收由控制器绑定 |

定向运行 RecoveryTest／RecoveryExecutorTest：38 项通过；
InterruptedResumeTest／ExternalHandoffTest：72 项通过；无跳过。
完整 View 检查退出 0，38 项 Python、11 项 JS、11 项 Linux 来源回归、八种入口和
九组浏览器操作通过，无跳过；报告 `.check-evidence/gh16-channel-view/code-check-result.json`。
此报告明确 synthetic=true、formal_acceptance=false、real_windows_wsl=false。

首轮候选检查 `.check-evidence/gh16-channel-candidate.log` 发现新增测试的 alias／
嵌套提示，已修正；814 项中另有旧 OpenAI 原生根配置测试一次 response_timeout，
覆盖率仍为 100%。未放宽超时或验收政策，按同一固定入口顺序重跑最终工作区。
本次目录初建前的两条日志重定向曾因 `.check-evidence` 不存在退出 1，检查尚未启动；
建立仓库内本地输出目录后重跑，未改控制器证据。

冻结 baseline 完整重跑退出 0：789 项中 783 通过、0 失败、6 跳过、0 排除、0 无效。
固定入口为 `python3 /opt/symphony/scripts/check_isolated.py baseline`，报告目录
`.check-evidence/baseline-1g0i4q9_/`，完整日志 `.check-evidence/gh16-channel-baseline.log`。
`policy_changes: []`；可信工具自身已有的权限夹具维护仅作用于临时 harness，
本会话没有修改维护入口、冻结文件或任何断言。

最终工作区候选的完整覆盖测试通过：814 项中 808 通过、0 失败、6 跳过、0 排除、
0 无效，覆盖率 100%；格式、公开函数规格和严格 Credo 同样通过。首轮旧 OpenAI
原生根配置测试的 response_timeout 在保持原检查策略的串行重跑中未重现。
跳过项均为原有真实 E2E：Asana、Jira、GitHub、GitLab、Linear 本地和 SSH；
对应真实环境开关未启用，未新增 skip/exclude，也未放宽时间或覆盖率门槛。
检查产物中的 candidate_sha 仍是工作区原 HEAD `c93bae36fea738e8b07625bb61ea0fa3b34360c8`，
不包含本次未提交修改，不能作为新候选身份或替代控制器准确 SHA 的验证／Review。

最终 `python3 /opt/symphony/scripts/check_isolated.py candidate` 退出 0：格式、公开
函数规格、严格 Credo、完整覆盖测试、Dialyzer 与 escript build 均通过；报告目录
`.check-evidence/candidate-v4cb5mr_/`，完整日志
`.check-evidence/gh16-channel-candidate-final.log`，`policy_changes: []`。
`git diff --check` 通过。本会话所有适用离线门禁已通过；A11 的准确最终候选正式
验证和独立 gpt-6.1-sol/high Review 仍由控制器完成，不能用这些工作区产物替代。
真实 DeepSeek／GPT 双角色账号调用、获准内网配置及访问、生产隔离实测未执行，
没有凭据、付费调用或真实材料外发授权。不添加 ready，不修改运行预设。
仅保存本仓库源码、测试、规格及本地检查产物；未提交、push、创建 PR、合并、
安装、部署或升级服务，未修改 .git、运行凭据、兄弟目录或控制器证据。

## 旧 null 预设设置兼容修复的本轮检查

新增 `settings preserve and save verified legacy null presets without inventing depth evidence`
回归在修复前失败：当前合法默认的选项缺失，`current["state"]` 为 nil。修复后定向
模型设置检查 10 项通过。最终该回归还包含双仓库／双角色、空档位和显式档位目录、
原参数及全部证据不变、字符串选择保存、精确 null 对象请求拒绝、CAS 冲突保值和
packaged 管理进程两次重启读取。普通配置的既有 packaged 回归同样保留。

完整 View 入口使用预装 Python／Node／Playwright，退出 0；输出目录
`.check-evidence/gh16-legacy-null-view/`，完整日志
`.check-evidence/gh16-legacy-null-view.log`。38 项 Python、11 项 JS、11 项 Linux
回归均无失败／跳过；固定迁移比较、self_check、八种入口及九组 Chromium 操作通过。
设置浏览器新增旧字符串默认的准确显示、null 控制标签、重新选择／保存、503 保留
草稿及成功重试、刷新后精确参数和其他角色／仓库不变断言。浏览器 Node v24.19.0、
Playwright 1.62.1、Chromium 151.0.7922.34；数据和管理员身份均为合成夹具。

该输出目录的 `source-identity.json` 保存本轮 View 和验证入口共 72 个文件的
SHA-256 清单；它只标识未提交工作区内容，原 HEAD 不代表包含修改的最终候选。
`code-check-result.json` 的 formal_acceptance／real_windows_wsl 均为 false。
最终候选 SHA、完整正式证据和独立 Review 仍由控制器绑定；真实双角色账号调用及
获准内网代理／TLS／来源限制没有外部条件，未执行，不采用旧候选或模拟证据替代。
没有提交、发布、安装、部署、升级、添加 ready 或修改运行凭据／配置。

固定 `python3 /opt/symphony/scripts/check_isolated.py candidate` 本轮退出 0：格式、
公开函数规格、严格 Credo、完整覆盖测试、Dialyzer 和 escript 构建全部通过。
815 项中 809 通过、0 失败、6 项既有外部 E2E 跳过、0 排除、0 无效，覆盖率 100%。
报告目录 `.check-evidence/candidate-kso3baji/`，完整日志
`.check-evidence/gh16-legacy-null-candidate.log`；`policy_changes: []`，候选没有注入
基线夹具维护。跳过项为 Asana、Jira、GitHub、GitLab、Linear 本地／SSH。
检查记录中的原 HEAD `fdb391d98ebbc2ed4bb366065d24a1da2b0224da` 不包含本次修改，
不能作为新候选 SHA 或代替控制器正式验证／独立 Review。

固定 `python3 /opt/symphony/scripts/check_isolated.py baseline` 本轮退出 0：789 项中
783 通过、0 失败、6 项既有外部 E2E 跳过、0 排除、0 无效；报告目录
`.check-evidence/baseline-g0ctsp3j/`，完整日志 `.check-evidence/gh16-legacy-null-baseline.log`。
`policy_changes: []`；可信入口已有的权限夹具维护仅在临时 baseline harness 初始化
0644，记录 `assertions_removed: false`，未修改冻结基线、可信入口或断言。
`git diff --check` 通过。工作区源码摘要与三组自检位置记录在
`.check-evidence/gh16-legacy-null-worktree.json`，不替代最终 SHA 的正式证据。
本轮所有适用离线检查通过；A03 真实账号、A07 获准内网入口和 A11 准确候选
正式验证／独立 Review 仍未完成，没有降低验收标准或扩大授权。
