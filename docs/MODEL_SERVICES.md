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
登录采用内置 OpenAI provider；旧 API 默认地址在领取时解析为
`https://chatgpt.com/backend-api/codex` 并冻结。ChatGPT OAuth 不发往 API key 的
`api.openai.com/v1` 路由或其他连接。环境变量 API key 保留管理员显式配置的渠道。角色启动命令来自受控 WORKFLOW
`codex.command`，冻结为执行适配身份，评论无法设置它。每次 AppServer 使用独立
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
分别保存发现时间、参数集合和人工/AppServer 来源，刷新新连接不改写旧冻结连接的
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

未配置新注册表的工作流和旧评论无需修改，领取时标记 legacy_migration，冻结旧模型、
现有 Codex 命令、旧参数 high，以及原 CODEX_API_KEY / OPENAI_API_KEY 环境引用
或控制器 auth_home，能力证据为未知。此兼容路径不宣称账号的所有 GPT 都已验证，
仍使用旧 allowed_models；已有冻结兼容任务不会因启用新注册表改变来源，管理员可用
注册表可选字段 disabled_models 明确禁用历史型号。新领取采用上述严格验证。历史回执没有连接/凭据/能力信息时不补造快照：保留旧外部审计比较，
受管执行适配器明确拒绝缺失完整服务快照的真实推理。必须通过操作者审计记录取得的
旧运行配置及新验证证据后显式迁移，不能用今天的默认解释历史，也不能手改回执绕过
已有审计/预算规则。无法取回历史配置时保持停点。

回滚前暂停新领取、备份注册表和回执，再还原旧代码及原 WORKFLOW；新快照任务保持
停点，不能在不认识完整配置的旧执行器中自动继续。只改变新领取默认时可用当前
修订号保存已验证的旧预设，保留版本和历史证据。部署/恢复/安装各需已有具体授权，
本轮仅保存本仓库代码，不执行这些步骤。

## 失败、用量和验证边界

模型未知、未验证、参数不支持、协议不兼容、管理员禁用、凭据缺失/失效/变更及证据
过期在调用前给出具体原因；真实服务端 401/403、429、余额不足、型号不存在和服务
故障分别分类。限流、暂时服务故障和超时只按原有 stage/总次数/墙钟预算重试，权限
及余额停点不切换模型或服务商。Review 结构错误保留原文并有限重试，不能计为通过。

每次模型尝试记录请求配置和 requested provider/model，明确 actual_model 为服务端
显式确认值或 null（未知），不把请求值冒充实际值。token/费用缺失仍为未知，不记零。
AppServer 输出、事件和诊断日志对该调用凭据值脱敏，快照仅含引用/指纹。

本轮自动化覆盖评论兼容/恶意输入、角色/账号/连接/参数绑定、并发 AppServer 子进程、
目录分页/失败/人工验证、保存冲突/失败/重读、凭据撤销/轮换、重试/诊断/恢复，沿用
reviewer 只读、Review 结构与最终候选 SHA 回归。候选和原测试套件均须通过冻结
`check_isolated.py` 门禁。真实 GPT 和真实 Linux 宿主隔离实测与这些模拟结果分开记录；
维护者前置补丁证据不是本候选完整验收。本次离线沙箱的宿主隔离预检返回
`execution_sandbox: cgroup v2 is required`（退出码 2）；真实内核沙箱集成未执行，
仅验证隔离入口及受控模拟协议，不降低环境要求。独立 Reviewer 由控制器另行执行。
