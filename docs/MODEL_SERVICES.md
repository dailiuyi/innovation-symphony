# GH-12：角色模型服务配置

本轮用户确认的范围为 IS-060–063；下述格式、命令和参数是本次工程实现，不登记为
用户批准的永久接口。只实现 OpenAI GPT / Codex AppServer 适配；DeepSeek 和其他
适配器目前在调用前明确拒绝。调度、隔离、预算、正式检查、候选 SHA 绑定及独立
Review 仍由 Elixir 控制器负责。View 没有写接口或新设置页面。

## 评论合同

沿用独立 Issue 评论、现有获准作者列表及 ready 事件授权。忽略非获准作者、机器人、
引用及普通讨论；授权作者以 `/symphony` 开头的错误命令报错。整条评论须严格匹配，
不接受缩进、换行、重复角色、未知角色、自由文本或连接/密钥/启动命令字段。

```text
/symphony configs coder=main-gpt reviewer=review-gpt
/symphony configs reviewer=default
/symphony models coder=gpt-example
```

按数字评论 ID 升序逐角色累计，每个角色最后一次赋值生效；一条命令未提及的角色
保持此前选择。同条重复角色拒绝；先前无效显式命令不能被后面的合法命令掩盖。
新旧语法可以组合。`configs ...=default` 清除该角色此前覆盖，选择领取时的项目默认；
启用新配置时旧 `models ...=default` 同义。编辑/删除影响下一次领取所读到的评论，
不重写已领取任务。旧工作流仍按已有 `models` 白名单合同解析。

旧模型评论在启用服务配置后，用**项目该角色默认预设**的服务商、连接、凭据和参数
作为模板，仅替换模型；不继承此前评论选择的另一个预设，也不按同名模型猜测账号。
替换后的完整配置必须有对应目录和角色证据。两个不同预设可以使用同一模型。
最终优先级是角色显式选择 > 角色项目默认 > 无新注册表时的旧默认兼容迁移。

## 注册表与后台

`mvp.model_services` 可放在现有 WORKFLOW front matter。管理员本地文件
`<mvp.state_dir>/model-services.json` 存在时，整体优先于该启动配置；损坏的持久文件
明确失败，不回退到 YAML。下一次 `Mvp.Config.settings` 读取即生效，不需重启；
重启仍使用该文件。现有全局 WORKFLOW 的启动配置重载边界保持原合同。

以下是**示例**，`gpt-example` 不是获准或已验证型号。启动目录和证据留空，必须
完成发现/人工登记和角色验证后才能领取，不能把此例当作可运行凭据。

```json
{
  "revision": 0,
  "defaults": {"coder": "main-gpt", "reviewer": "review-gpt"},
  "presets": {
    "main-gpt": {
      "version": 1,
      "provider": "openai",
      "adapter": "codex_app_server",
      "model": "gpt-example",
      "parameters": {"reasoning_effort": "medium"},
      "connection": {"base_url": "https://api.openai.com/v1", "protocol": "responses"},
      "credential_ref": "env:PROJECT_CODER_OPENAI_KEY"
    },
    "review-gpt": {
      "version": 1,
      "provider": "openai",
      "adapter": "codex_app_server",
      "model": "gpt-example",
      "parameters": {"reasoning_effort": "high"},
      "connection": {"base_url": "https://api.openai.com/v1", "protocol": "responses"},
      "credential_ref": "env:PROJECT_REVIEWER_OPENAI_KEY"
    }
  },
  "catalog": {},
  "validations": {}
}
```

连接必须为 HTTPS Responses URL，禁止 URL 用户信息、查询、片段及未知字段。
凭据引用支持 `env:NAME`、`auth_home:/absolute/path`（后者读取控制器侧 auth.json）；
文件内容、API key 和 token 从不写入注册表或快照。`auth_home` 中的 ChatGPT
登录采用内置 OpenAI provider；未指定后台根时，领取解析为
`https://chatgpt.com/backend-api/codex` 并冻结。管理员明确给出的 ChatGPT 后台根
也可冻结为受控 HTTPS `/codex` 连接；OAuth 不发往 API key 的
`api.openai.com/v1` 路由。`auth_home` 的独立配置不覆盖保留的
`[model_providers.openai]`：API key 使用顶层 `openai_base_url`，ChatGPT 使用顶层
`chatgpt_base_url`（后台 API 根，Codex 添加 `/codex`），继续保留原推理参数。
环境变量 API key 使用非保留的 `symphony` provider，保留管理员显式配置的渠道。角色启动命令来自受控 WORKFLOW
`codex.command`，冻结为执行适配身份，评论无法设置它。含 `--config`/`-c`、
`--profile`/`-p`、`--model`/`-m` 或 CODEX_HOME、provider/base_url/env_key
覆盖及 shell 变量/命令展开的启动命令在新预设冻结与启动前拒绝（包括看似无害的 config 参数），避免 Codex
命令行优先级覆盖角色路由；改用预设字段。受管进程清除继承的 OPENAI_BASE_URL。每次 AppServer 使用独立
0700 主机配置目录和进程环境；沙盒中的模型主机目录包含隔离环境定义，凭据不进任务
执行环境。既有安全功能开关及 reviewer 的内核只读挂载保留，不修改共享 Codex 配置。

本期本地管理员入口（从 `elixir/` 运行，不启动调度器）：

```text
mix mvp.models show WORKFLOW.md
mix mvp.models register WORKFLOW.md main-gpt gpt-example medium high
mix mvp.models refresh WORKFLOW.md main-gpt
mix mvp.models verify WORKFLOW.md main-gpt gpt-example coder /controlled/workspaces/probe
mix mvp.models attest WORKFLOW.md main-gpt gpt-example coder PROOF.json
mix mvp.models save WORKFLOW.md 3 REGISTRY.json
```

`show` 提供安全引用、凭据是否配置、目录/验证记录，以及 availability 中逐预设、
型号和角色的状态；`ModelCatalog.status` 返回可用、待验证、禁用、不兼容或未发现状态及原因。`show` 的展示字段不能直接
当作保存文件，保存使用上面的原始注册表结构。后台 API 是 `ModelServices` 和
`ModelCatalog`，未来设置页面可以通过控制器的获准管理边界复用它们。

保存先校验结构、预设版本和改变后的默认能力，再以修订号比较并交换，持独占本地
文件锁，通过同步写入临时文件及原子 rename 持久化。并发请求返回 busy 或 conflict，
失败保留旧文件。已有预设任何变化必须提升 version。先登记新预设、完成验证，再
修改默认；未验证的新默认保存失败。目录变化或管理员禁用可使原默认不可用，领取
与调用明确停止，不擅自替换默认。异常退出留下的 `.lock` 是管理停点，管理员确认
没有保存进程后才可处理；不得通过删除任务回执解决。

## 发现与能力证据

`refresh` 在同一账号的 AppServer `model/list` 中请求隐藏项，遍历游标到结束；重复
游标及错误响应拒绝。不把任意 `gpt-*` 当白名单。保留管理员禁用和历史目录，发现
记录绑定服务商、协议、连接、凭据引用与安全凭据指纹。失败保留原目录和原刷新时间，
另外记录 discovery_failed；不能声称渠道目录必然等于账号全部模型权限。每个渠道
的受管协议流如收到 `configWarning` 表示配置无效或回退默认，或通知格式无效，
立即返回 `model_service_configuration_invalid`，不接受后续默认渠道的目录、输出或
批准，不自动重试/换配置；刷新保留原目录、原时间及能力证据。普通环境提示仍兼容。
每个渠道分别保存发现时间、参数集合和人工/AppServer 来源，刷新新连接不改写旧冻结连接的
参数证据；未知未来推理参数不发送，仍保留该型号已支持的参数和待验证状态。

无法取得完整目录时用 `register` 人工登记型号及渠道支持的推理参数。此操作不产生
推理验证证据。目录中尚未验证的 GPT 型号为待验证，非 GPT/未知适配器为不兼容。
每个选择需同时满足协议、目录、有效参数、当前凭据及本角色的能力证据。

`verify` 必须启用 WORKFLOW 的 `mvp.sandbox`，通过既有 ExecutionSandbox 的内核只读工作区、无本地回退的工具执行环境运行真实调用；凭据仍留宿主，沙箱未启用时在调用前拒绝。管理入口先绑定指定 WORKFLOW，重载失败不沿用另一份运行配置。验证在受控临时工作区显式运行（须为包含 `.git` 的受管仓库工作区，满足既有沙箱挂载合同）：生成随机文件，要求模型通过命令
工具读取，并严格返回指定 JSON；须收到成功工具事件及正确内容，禁止把模型自己
声称执行了工具当证据。用只读会话验证工具和结构输出能力，两种角色分别验证。
成功证据绑定完整角色配置（含执行命令、模型、参数、版本和凭据指纹），有效期工程
值为 24 小时。通过后该绑定自动可选，无须逐型号再启用，默认不变。未运行的型号
不产生成功证据。真实探测需要凭据及既有材料外发授权，此沙箱未执行真实探测。

`attest` 是本地管理员导入外部实测证据的信任边界，不是 Issue 指令。PROOF.json
字段为 role、validated_at、expires_at、capabilities（tools、structured_output）、
actual_model（无法确认时 null）、source（manual）；管理员负责核对外部真实测量
与当前配置一致并保留原始证据。无效、过期或缺少能力的证据拒绝。程序生成的实测
source 为 inference。模拟服务测试中的 inference 记录仅在临时测试注册表中存在，
不代表真实账号已验证。新账号、连接、模型、参数、执行命令或角色不能复用旧证据。

凭据指纹为 SHA-256，非秘密值。账号引用下的 key 或 auth.json 变化会停止原冻结
调用，要求重新验证；当前实现对 OAuth 文件刷新也保守停止，避免把引用相同误当作
账号相同。旧指纹的目录和证据仅保留为历史。当前禁用、撤销、证据删除/过期和真实
服务端权限检查始终生效。目录没有自动后台刷新任务，操作者按需刷新；刷新时间和
各渠道发现时间可见，目录过旧不会被新时间冒充，能力证据过期不能继续调用。

## 冻结、恢复与兼容迁移

领取时写入两个最终服务快照及来源（项目默认或评论 ID/作者/语法），包括 ID/version、
provider/model、有效参数、连接、适配身份、执行命令、凭据引用/指纹和当时能力证据。
之后编码、Review、返工、技术重试和只读诊断全部复用该快照；诊断只继承 coder，
没有第三种评论角色。round、回执和外部 handoff 均保存它，所有恢复入口的公共
身份绑定比较完整快照，不能仅比较模型名。外部恢复对**新完整快照**不重新解析评论，
仍检查 Issue 范围、ready、原资源/检查/审计合同及当前访问条件。

未配置新注册表的工作流和旧评论沿用白名单，领取时标记 legacy_migration，冻结旧
模型、现有 Codex 命令及旧执行路径的有效配置。非隔离路径读取控制器 CODEX_HOME
中 config.toml 的 model_provider、provider base_url/wire_api/env_key、原生
openai_base_url/chatgpt_base_url 和 model_reasoning_effort，保留自定义 HTTPS
Responses 渠道及环境凭据引用。内置 API 路由优先使用 openai_base_url，再取
OPENAI_BASE_URL 和旧默认；自定义 provider 的显式 base_url 优先，原生字段不
覆盖它。ChatGPT 登录取 chatgpt_base_url（缺省为官方后台根），忽略 API 路由字段
及环境连接，去除根地址末尾斜杠后按 Codex 行为追加一次 `/codex`；若原根已经
以 `/codex` 结尾，也追加，生成角色配置时只移除最后一次追加的后缀以还原原根。
凭据引用保持原认证选择，不把两个角色切换到新账号；
未指定 effort 时不强加 high。隔离路径原本自行生成配置，固定内置 OpenAI 和
high，仅从 sandbox.auth_home 取得 auth.json；该目录 config.toml 的 low、
自定义 provider、profiles 或不可解析内容均不影响冻结或调用，不能引入迁移阻塞。
内置 OpenAI 保留原 CODEX_API_KEY / OPENAI_API_KEY 优先级、auth_home 认证后备及
OPENAI_BASE_URL 环境连接覆盖。能力证据
仍未知，不宣称旧白名单已完成真实验证。已冻结的地址/参数不再读取后来变动的
config.toml。管理员仍可用 disabled_models 禁用历史型号。

旧工作流的 `codex.command` 可继续使用 `--config` / `-c` 设置
`model_reasoning_effort`（支持分离或附着的参数值、`--config=...` / `-c=...` 及 shell 引号）。领取时确定性解析，
命令行值优先于旧配置文件或隔离路径生成的 high，多个合法设置取最后一个，任一无效值均拒绝；
冻结原命令和最终参数，两个角色、后续重试与恢复均沿用。启动前还会核对命令中的值
与快照一致，不允许快照参数与命令互相覆盖。未知参数值、缺失值、profile/model、
连接/认证覆盖及 shell 展开、组合命令或重定向仍拒绝。此兼容例外只用于
legacy_migration，不允许新预设用启动参数覆盖已登记配置。

非隔离兼容读取仅接受可无歧义映射的单行标量 TOML（字符串、布尔、非负整数和普通表，
以及 `projects."/controlled/repo"` / 单引号项目表）；项目 trust_level 不改变服务路由，
不需要修改旧文件。项目表按解码后的名称检测重复，换用单引号或裸键不能绕过检测；
profile、复杂/重复赋值、额外 provider 参数/headers、未知推理参数、非 Responses
协议、非 HTTPS 地址等返回 legacy_model_service_migration_required。不能用固定
地址或 high 冒充未知有效值。遇到停点，由管理员从旧版本、原启动参数和原配置核对
有效值，按本页示例将连接、env_key→credential_ref、model_reasoning_effort→parameters
映射成有版本的预设；无法表示的额外参数继续保持停点。登记全部目标型号，再分别
执行 verify 或导入已核对的 attest 证据，最后以当前 revision 保存两个角色默认。
历史任务不得使用这一新默认重新解释。

### 历史回执的本地审计迁移

没有 services 的历史回执默认停止受管推理。资料齐全时提供本地入口：

```text
mix mvp.models migrate WORKFLOW.md /controlled/state/RECEIPT.json MIGRATION.json
```

此入口只补充冻结信息，不派发任务或恢复执行。回执须为配置 state_dir 中的普通文件，
处于 blocked 或 awaiting_external，且保留非空原 rounds（没有历史轮次或原身份资料
的回执继续停点，不能凭今日默认补造）。操作者确认原任务执行者已停止，按既有
OperatorRecheck 合同提供 id、authorization、runtime_version（操作者运行版本完整
SHA）、command（实际管理员入口 argv）、predecessor、legacy_closures。追加字段：

- receipt_sha256：操作前回执原始字节 SHA-256；变化后请求作废。
- historical_config：仅有 path、sha256，指向操作者核对的脱敏历史有效配置 JSON。
  JSON 顶层 coder/reviewer，各自严格含 provider、adapter、model、parameters、
  connection、credential_ref、command；不得含秘密或按新默认生成。
- services：coder/reviewer 两个完整 ModelServices.snapshot 输出。必须与上述历史
  有效字段及原回执 models 一致，source 为 historical_migration:<id>，并且当前目录、
  账号指纹和独立角色验证有效；preset ID/version 是这次明确登记的受控身份。

操作者通过 ModelServices.snapshot(settings, id, role, source) 取得完整安全快照，
核对历史字段后填入请求，不直接编辑原回执。新证据描述当前可继续执行的能力，
不追认历史调用已验证。校验失败不改回执。写入或进程中断保留原审计链及锁，
需由操作者核查，不能删锁重领或继续推理。成功在原执行审计互斥下保存 receipt-before、
authorization、completion 和审计链 head，只添加顶层 services、model_service_migration、
operator_recheck 及更新时间；候选/base、旧 rounds、不可变外部 handoff、原证据、
开始时间、用量、次数和预算均保留。恢复入口通过审计前回执核验旧轮及 handoff 的
服务映射，不重解析现有评论。真正续跑时，当前执行轮添加本次 services，旧轮、原始回执
和外部 handoff 的历史副本保持不变。然后使用**原恢复入口**，以新回执摘要和该迁移 id
作为 predecessor 请求继续；该操作不自动授予续跑或预算扩充。缺少旧有效值、
授权、证据或当前权限时保持停点。审计文件缺失/变动同样拒绝历史映射。

回滚前暂停新领取、备份注册表和回执，再还原旧代码及原 WORKFLOW；新快照任务保持
停点，不能在不认识完整配置的旧执行器中自动继续。只改变新领取默认时可用当前
修订号保存已验证的旧预设，保留版本和历史证据。部署/恢复/安装各需已有具体授权，
本轮仅保存本仓库代码，不执行这些步骤。

## 失败、用量和验证边界

模型未知、未验证、参数不支持、协议不兼容、管理员禁用、凭据缺失/失效/变更及证据
过期在调用前给出具体原因；真实服务端 401/403、429、余额不足、型号不存在和服务
故障分别分类，包括 TurnError.codexErrorInfo 中的 httpStatusCode 及正式字符串
枚举：unauthorized 为权限停点、usageLimitExceeded 为额度停点、rateLimitExceeded
为限流、serverOverloaded/internalServerError 为暂时服务故障。其余枚举保留原错误，
不笼统归为可重试；阶段、总次数和墙钟额度分别约束重试。
turn/completed 的 Turn 必须为 completed 且无 error；failed/interrupted、未知状态或
格式错误均拒绝，即使此前已输出合法批准或探测 JSON。旧版本省略整个 params 或整个 Turn 的
通知兼容，显式 null Turn 或省略 Turn 却携带 error 不视为旧版本成功。限流、暂时服务故障和超时只按原有 stage/总次数/墙钟预算重试，权限
及余额停点不切换模型或服务商。Review 结构错误保留原文并有限重试，不能计为通过。

每次模型尝试记录请求配置和 requested provider/model，明确 actual_model 为服务端
确认值或 null（未知），不把请求值冒充实际值。当前受支持的 Codex 协议未提供逐轮
实际型号遥测，AppServer 结果的 actual_model 始终为 null；Thread.model 明确仅为
当前配置/持久配置，不是逐轮执行遥测，未经协议定义的 params.actualModel 也不作为
确认依据。依据为本地安装 Codex 生成的 ThreadStartResponse.json 中 Thread/Turn
定义（控制器只读协议证据，SHA-256
`92f5ddc37717b922de1dc0b0405e9a6d463f370554e2091610c6e595bc2616d4`）；没有
可据此构造的型号确认成功夹具。若以后渠道提供明确逐轮遥测，需另行实现采集及
成功路径回归，不能用模拟扩展字段宣称本期已确认型号。token/费用缺失仍为未知，不记零。完整服务任务在 max_rework=0 且 recovery
关闭时同样保存一轮调用溯源，不依赖返工开关。模型时限沿用任务剩余预算或
Codex 原 turn_timeout_ms；正式检查仍独立受 check_timeout_ms 限制。
AppServer 输出、事件和诊断日志对该调用凭据值脱敏，快照仅含引用/指纹。

本轮自动化覆盖评论兼容/恶意输入、角色/账号/连接/参数绑定、并发 AppServer 子进程、
目录分页/失败/人工验证、保存冲突/失败/重读、凭据撤销/轮换、重试/诊断/恢复，沿用
reviewer 只读、Review 结构与最终候选 SHA 回归。候选和原测试套件均须通过冻结
`check_isolated.py` 门禁。真实 GPT 和真实 Linux 宿主隔离实测与这些模拟结果分开记录；
维护者前置补丁证据不是本候选完整验收。本次离线沙箱的宿主隔离预检返回
`execution_sandbox: cgroup v2 is required`（退出码 2）；真实内核沙箱集成未执行，
仅验证隔离入口及受控模拟协议，不降低环境要求。独立 Reviewer 由控制器另行执行。
