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

## 外部停点

离线环境无真实账号凭据，不发起付费调用或外发真实仓库材料。不添加 ready，
不修改 Linux 运行预设；本任务 gpt-6.1-sol/high 的运行证据由控制器独立核验。
真实 DeepSeek/GPT 双角色、批准内网代理配置及准确候选独立 Review 待控制器／所有者验收。

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

后台令牌至少 32 字节，由既有受控后台环境提供，不通过 CLI 参数、WORKFLOW、浏览器
存储或源码注册。打包入口 `elixir/bin/symphony --model-settings /controlled/manager.json`
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
环境、密钥或认证路径；auth_home 仅显示已配置引用。页面令牌仅保存在当前页面内存。

保存只修改原仓库 model-services.json 的 defaults 与 revision，不改变预设版本、
目录和历史能力证据。保存和每次执行都校验完整组合。失败和并发冲突保留旧文件，
页面保留草稿；默认变化不更新已领取快照或 GitHub 状态。GLM 没有可执行适配器。
保存回应使用本次提交的配置快照，避免提交后重读失败或读到他人更新造成错误反馈。
只修改一个角色时，页面保留另一角色原始默认表示，维持旧字符串预设的继承语义。

## 验收条目与证据对应

| GH-16 合同条目 | 仓库内验证 | 外部停点 |
| --- | --- | --- |
| 两仓库、双角色、持久读取及重启 | MvpModelSettingsTest：独立持久化、两个 packaged 管理进程读取 | 真实受管仓库配置与部署 |
| 未保存、取消、切换、保存／失败／冲突 | model-settings.test.mjs：草稿、精确旧默认、CAS、角色隔离、焦点保持 | 真浏览器键盘、窄屏及刷新 |
| OpenAI 兼容与 DeepSeek 工具／输出 | MvpModelRoutingTest：原 OpenAI 回归，原生 Codex + 本地 TLS Responses + 外部执行器工具往返 | 真实账号双角色权限与推理 |
| 分档、开关、不可关闭、固定、未知、过期／绕过 | MvpModelSettingsTest／MvpModelServicesTest：按渠道目录、角色证据、非法参数及未来未知值拒绝；JS 深度标签与切换清除 | 当前真实账号目录 |
| 参数、连接、凭据引用与角色隔离 | 路由测试检查独立 home、模型、provider、effort、HTTP 请求与冻结 options | 真实账号准确有效参数和返回 |
| 写入失败／CAS／权限／跨站／秘密 | Elixir 管理测试：busy、并发、版本、畸形默认、原值保留；Python API 测试：Host／Origin／头／路径／限长；auth_home 脱敏 | 受控凭据注册 |
| 内网监听和访问范围 | 管理 listener_info、View socket 及配置拒绝测试；两服务均 loopback | 所有者获准代理地址、来源限制和 TLS 实机验收 |
| 只影响新领取、评论兼容、冻结与撤权 | 管理测试冻结旧 coder／diagnosis，新默认与独立评论；原模型服务／恢复测试 | 控制器准确候选验收 |
| Reviewer 只读、隔离、预算、正式检查、SHA | 原 ExecutionSandbox／Review／Executor／Recovery／外部 handoff 冻结回归 | 生产内核挂载与准确候选正式证据 |
| 同步规格与可追溯历史 | IS-079、REQUIREMENTS、MODEL_SERVICES、README 和 AGENTS | 同一个功能 PR 由控制器另行处理 |
| 完整门禁及独立 Review | candidate／baseline 固定检查与下方实际结果 | 独立 Reviewer 由控制器执行 |

TLS 夹具使用实际 Codex AppServer 和 exec-server 完成命令工具读取及结构化 JSON，
请求包含 DeepSeek 实际 reasoning.effort=max。两角色使用各自的模拟凭据；夹具只在
本任务外层离线沙箱内运行，内层执行器是测试替身，不作为生产 reviewer 内核只读
或真实 DeepSeek 能力证明。原正式隔离回归保留。夹具仅在工具返回正确随机／指定内容
后给出有效结果，父 Port 关闭即退出，不留下维持检查输出管道的后台进程。

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
