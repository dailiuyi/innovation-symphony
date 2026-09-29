# V0 实现合同

GH-1 更新：默认 0 的历史合同继续兼容；显式 `max_rework=1/2` 的返工、回帖与逐轮证据合同见 [REVIEW_REWORK.md](REVIEW_REWORK.md)。下文固定单轮及“多轮未实现”描述仅指 V0 基线。

状态（V0 历史基线）：基于官方 Elixir 的本地开发版。GitHub 仓库未创建，未进行真实派发、模型调用、PR 创建或升级。以下运行细节是工程默认，未经逐条确认为永久产品规则。

## GH-3 最小增量：接管前只读体检

来源：2026-09-29 GH-3 实现请求。升级流程方向已确认，Issue 中的待确认机制继续待定。本次工程切片仅新增 escript `--preflight`，不登记新的用户产品决定，也不宣称完整接棒已完成。

- 直接加载指定 WORKFLOW，校验通用配置、已启用的 MVP 配置、串行本地 GitHub 执行限制和非空 active_states。使用显式配置查询 GitHub 任务列表，复用原 Client 的 GET 分页；空队列也可以通过。
- 不启动 Symphony 应用、调度器、任务监督器、WorkflowStore 或 HTTP 服务，不更改当前工作流缓存。不执行 hooks、模型、检查或交付，不领取任务，不创建/释放回执，不修改工作区、evidence 或远端资源。只启动查询所需的 Req 依赖。
- 成功向标准输出写 JSON（`mode=preflight`、`status=passed`、`issue_count`）并以 0 退出；配置/查询失败以非零状态退出。`issue_count` 是查询结果数量，不代表获准派发数量。成功也不会自动进入正常运行。
- 沿用显式 guardrails acknowledgement 开关。体检拒绝 `--port` 和 `--logs-root`，避免把服务启动选项误作体检设置。正常启动行为保持兼容。
- 没有新增体检超时默认值；调用方须显式选择外部进程超时，并保存输出和退出状态。查询客户端已有的单请求超时/重试不等于体检总时限。调用示例见 [OPERATIONS.md](OPERATIONS.md#gh-3-只读体检)。

此入口只证明候选能加载配置并读取队列，不验证 Codex 可执行性、模型可用性、检查命令、持久状态 schema 兼容性或完整运行健康；通过不构成接管授权。A 停止领取/收尾、互斥、超时强停、blocked 释放、ready 恢复、外部升级编排、自动回退和接管后对账均未实现；不得据此启动 A/B 同时领取。原 Issue 的待确认清单继续有效。

新增测试使用临时目录和模拟 GitHub 响应，覆盖只读 GET 分页、空队列、HTTP/传输失败、无效配置提前失败、保留已有回执/evidence，以及独立 VM 中零运行监督器的 CLI 体检路径。它们不证明真实接入或完整 GH-3 验收。

## 复用与扩展

基线为 openai/symphony 的 `be10a1b79df723d6d7612b5651c8522704dafb2e`，来源与文件范围见 [UPSTREAM.md](UPSTREAM.md)。不再开发独立 Python 调度器。

直接复用官方 Orchestrator、Workspace、GitHub Client、Codex AppServer 和 Phoenix 状态页面。仅在 AgentRunner 中增加可选有限任务链，在 Orchestrator 的候选筛选中检查持久领取记录。

`Mvp.Config/Intake` 解析固定格式评论和权限；`Mvp.Executor` 串联编码、机器检查、独立只读 Review；`Mvp.Receipt` 记录领取与交付意图；`Mvp.Delivery` 推送固定 SHA 并创建 Draft PR。AppServer 保留原默认行为，新增冻结模型、只读、关闭动态工具、结构化输出参数。

## 配置与执行合同

- V0 限 github.com、可信自有仓库、Linux/WSL、本地 worker、单实例串行（max_concurrent_agents=1）。每个进程绑定一个仓库，多仓库统一后台后置。
- 示例在 [elixir/WORKFLOW.github.example.md](../elixir/WORKFLOW.github.example.md)，默认 `mvp.enabled: false`。显式关闭意味着停用队列；只有完全没有 mvp 配置的原版工作流保持上游兼容。停机时保留 mvp 块，不通过删除块或换状态目录停机。
- tracker.required_labels 必须包含 mvp.ready_label，两处按大小写不敏感规则一致判断。ready 必须仍存在，最近添加者在 allowed_actors 中。首次启用会处理获准的存量 ready；不是旧博客的“只认新标签事件”。没有收回或自动替换模型的隐式规则。
- 固定独立评论：`/symphony models coder=MODEL reviewer=MODEL`，可只指定一个角色。仅允许名单内非 Bot 用户的整条评论有效；按评论 ID 累计覆盖角色。开始前冻结，运行中编辑不改变本轮模型。授权用户的非法指令或非白名单模型阻塞，不静默回退。
- 一次领取、一轮编码、一轮检查和独立 Review；max_rework=0。同一仓库+Issue 的 receipt 持久阻止重复执行，包括进程重启。磁盘状态目录必须保留且不能与源码/工作区重叠；比较前解析符号链接，不能定位运行目录时拒绝启用。不宣称多机或多状态目录的分布式去重。
- 编码进程没有 GitHub tracker token 和平台动态工具；保持 workspace-write 默认沙箱。Review 使用新进程/新会话和 read-only。控制器拥有检查、Git 提交、推送与 PR 创建。
- 测试命令来自运行工作流的 argv，不解析 Issue 中的 shell。`{baseline}` 是任务开始前从 base SHA 归档到状态目录的副本；`{workspace}` 是候选。示例先跑候选检查，再以基线中的构建配置和测试验证候选 lib。保留测试日志、Review JSON、base/candidate SHA；检查后或 Review 后源码发生变化会阻断发布。
- 发布前再次读取 Issue open/ready；先保存 publish_pending，再创建专用新分支及 Draft PR。已有分支不覆盖。不确定网络结果保留记录，通过只读 GitHub 查询对账，不盲目重发。
- ready/review/blocked 标签自动维护、计费、模型可用性预检、多轮返工和自动升级未实现。状态通过上游状态页面、receipt 与日志查看；人工处理提示会显示 blocked，receipt 区分 awaiting_human。

## 失败与恢复

先停止此仓库的 runner，再维护状态，保留完整状态目录和 evidence。

- 读取权限/评论等在编码前失败：修复原因后运行 `mix mvp.release /absolute/RECEIPT.json`。只允许 blocked 且没有 base_sha/candidate_sha 的记录，归档旧记录后才可重新领取；准备阶段留下的工作区仍需核实。
- coding/checking/reviewing、进程中断或任一候选已生成：不自动重试，保留证据人工检查。V0 不提供这些阶段的一键恢复。确认无有效交付后可通过新的 Issue 进行新尝试；不能直接删除记录盲目重发。
- publish_pending：`mix mvp.reconcile /absolute/WORKFLOW.md /absolute/RECEIPT.json` 只读取 GitHub，严格匹配 repo、branch、base、head SHA，成功后记录 PR。无匹配或多匹配继续阻塞。已推送但未建 PR 的情况由操作者核对后处理。
- awaiting_human：人工审核、合并；不提供自动合并或升级命令。即便 Issue 暂时仍 ready，receipt 也阻止新任务。

## 信任与交付限制

这是可信单仓库的本地 MVP，不是敌对代码执行平台。测试和 hooks 运行于控制器账号，目录分离及哈希不等于容器级隔离；生产环境需要独立执行账号/容器及凭据边界。不得把它直接接入未经授权的公司代码。

控制器必须运行固定的安装副本，不能从候选目录启动或覆盖自身安装。升级停机后保留原领取/交付记录，不能以旧备份覆盖新版本接管后的状态。V0→V1→V2、接管后故障和回退演练仍待真实仓库建立后验收，见 [SELF_ITERATION_MVP.md](SELF_ITERATION_MVP.md)。

本地假 AppServer 与临时 Git 测试验证协议和门禁，不证明真实模型质量、权限或自身迭代成功。当前复用上游 lockfile；依赖安装实际提示多项安全公告，尚未完成依赖升级/安全验收，不作为生产部署版本。
