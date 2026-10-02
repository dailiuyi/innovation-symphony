# Issue #7 无人值守前置准备

PR #8 准备了固定来源制品、独立检查代码和脱敏夹具。随后 IS-045 授权完成 ready 前剩余准备，包括真实隔离、依赖、可信检查接入及安装验证。两阶段均不提前执行 [Issue #7](https://github.com/dailiuyi/innovation-symphony/issues/7) 的 View 合仓，`view/` 尚未导入。源码保存、本地提交、门禁安装、真实验收和远端发布是不同状态；新增入口的实际安装及调用证据见本文末尾记录。

## 授权及来源

项目所有者于 2026-10-01 07:10:27 UTC 明确选择：由 elma-pc 上的 Codex，以 Sol 6.1 ultra 在独立分支完成准备。父任务提交的模型配置为 `gpt-6.1-sol` / `ultra`；这里不把调度参数当作独立测得的实际推理元数据。Issue 完整正文由父任务从已连接的 GitHub 工具提供，本机 GitHub CLI 返回 HTTP 401，没有重新登录或改凭据。

固定来源为本机已核实、工作区干净的 `innovation-view`：

- 仓库：`dailiuyi/innovation-view`；原仓库及历史保留。
- commit：`d734a087d83243530bd79f40dfbaedaabf8fe677`。
- tree：`8a61f1a9d1aa13b7e97e0143ff3a4a33f123d73a`。
- Symphony 准备基线：`da561affa23b72ea5b3e02a740ebf77e6a050530`。
- 37 个 tracked 文件，明确排除 `app/config.toml`，包含 36 个文件及配置示例。
- 未读取真实配置内容。排除记录保留路径、Git blob ID、mode 和原因，`content_read=false`。

源码包来自固定 Git 对象，不读取 checkout 内容或 untracked 文件。保留逐文件 Git blob ID、字节数和 SHA256、完整 tree、完整 commit、排除记录、生成器摘要、包 SHA256。验证器重新计算每个 blob 和完整 Git tree，因此重写包和 manifest 中的摘要也不能伪造固定来源。HEAD 在导出前后均须匹配；CLI 不接受更换来源 SHA 的参数。

View 的该固定 tree 没有独立 LICENSE/NOTICE 文件。准备不会改写 Symphony 的 LICENSE/NOTICE，也不将 View 标作 OpenAI 原创。未来导入时仍须记录实际来源、迁移调整及发现的第三方来源问题；此准备不是第三方授权结论。

## 固定来源制品

使用现有 Python 运行，不需要安装依赖。输出目录必须不存在，避免覆盖旧制品；脚本校验路径穿越、常见 Windows 保留名称、完整路径的大小写碰撞、链接、junction、submodule 和特殊文件。独立审查另核对本次固定来源的全部路径组件，无 Windows 别名或目录前缀大小写碰撞。当前接口只支持该固定 tree；扩展到其他来源前，仍须补齐通用 Windows 别名及目录组件防护。

```powershell
python -X utf8 -B scripts/prepare_view_source.py build `
  --repository E:\code\innovation-view --output <新的隔离制品目录>

python -X utf8 -B scripts/prepare_view_source.py verify `
  --package <制品目录>/view-source.zip --manifest <制品目录>/source-manifest.json
```

ZIP 使用固定时间戳、确定排序和无压缩存储，便于同一生成器版本重复生成完全相同的字节。ZIP 中的 `SOURCE_MANIFEST.json` 与外部 manifest 的来源部分一致；外部 manifest 额外记录 ZIP 摘要和大小。产物必须保存在候选工作区以外，`.local` 不视为隔离区，不能依赖它被沙箱复制或校验时忽略。

需要独立副本时，仅提取已验证的常规文件到不存在的新目录：

```powershell
python -X utf8 -B scripts/prepare_view_source.py extract `
  --package <制品目录>/view-source.zip --manifest <制品目录>/source-manifest.json `
  --destination <新的隔离副本目录>
```

## 领取前时序准备

现有 `ExecutionSandbox` 将控制器 evidence 只读挂载到 `/evidence`。`Executor.execute` 调用 `File.mkdir_p!(receipt <> ".evidence")`，不清空现有目录；baseline 快照另写 `baseline/`。候选新增文件不会自动升级正在运行的可信入口。

下面命令只在一个不存在的新隔离根目录中建立伪 receipt，顺序为验证来源、预置来源、写伪领取记录、模拟已存在 evidence 的 mkdir 并重新验证完整性：

```powershell
python -X utf8 -B scripts/prepare_view_source.py pseudo-task `
  --package <制品目录>/view-source.zip --manifest <制品目录>/source-manifest.json `
  --isolated-root <新的伪任务隔离目录>
```

它拒绝 `.local` 和 `innovation-symphony-v0*` 运行路径，标记 `production_claim=false`、`execution_started=false`、`sandbox_mount_executed=false`、`formal_acceptance=false`。这只证明文件级预置时序和 mkdir 保留行为。IS-045 的实际安装方案将源码包在领取前预置到固定可信安装的 `scripts/view_validation/source/`，任务通过只读 `/opt/symphony/scripts/view_validation/source/` 取得制品，不需本轮向生产 receipt 写入。该本机制品目录忽略于 Git，安装时认证来源并记录摘要；缺少制品时门禁失败，没有动态下载或凭据回退。

## 独立 View 检查的职责

`scripts/view_validation/validator.py` 保留前置准备接口和 `formal_acceptance=false`。IS-045 新增 `check_view.py` 路由标记及 `check_view_isolated.py` 可信包装器，由 `ExecutionSandbox.check` 单独路由到固定工具链 Python 和固定可信脚本；host 直接运行标记失败，额外参数及其他命令不回退宿主。已有 `check_isolated.py` 的全部 Elixir 检查保持不变。

View 包装器核实 Linux 私有网络、候选 Git/控制器 evidence/工具链/可信脚本的只读挂载，运行冻结 Python/JS、候选测试和实际 self_check/HTML 生成，校验来源与候选摘要，再导出 `.check-evidence`。报告区分 `controller_view_check`、`formal_code_checks`、`formal_acceptance=false` 和 `real_windows_wsl_acceptance=false`；正式代码门禁通过不表示最终实机验收完成。工作流必须保留原两条 Elixir 检查并追加 `[python3, "{baseline}/scripts/check_view.py"]`。安装与配置字段存在仍不证明入口已经被实际调用。

共享 launcher 会向每个私有工作区注入 `elixir/deps`。View 包装器在确认隔离契约后，先拒绝 HEAD 跟踪该路径的候选，再只清理私有副本中的注入依赖；不修改宿主工具链或候选工作区。之后严格比较 HEAD、index 和所有候选文件。View 使用独立 Python/Node/Viewer，无需这份 Elixir 依赖。worker 的可信入口在候选首次导入前捕获，入口与测试输入发生篡改即失败；独立审查已复现并要求拒绝 `__main__.run_tests` 替换。该守卫不被解释为对任意恶意 Python 的完整防伪证明。

全量控制器检查与独立 View 检查分别记录：前者为 Elixir 生命周期回归，不能代替后者的冻结测试和实际渲染。

独立检查必须使用冻结基线测试和脱敏固定夹具，实际执行 Python 16 项、JS 10 项基线及 self_check 的解析／HTML 生成；数量是基线而非新增测试上限。必须报告并拒绝必测项零执行、skip、缺依赖、渲染失败和检查期间候选变化。证据绑定候选 SHA、候选树／源码摘要、来源制品、验证器及冻结夹具摘要、依赖、命令和原始结果。固定来源中的 `once` 不调用 `write_context_pages`，不能用一次采集返回成功代替 HTML 生成证明。

未来在实际合仓后，候选的 `view/` 路径、首次运行缺目录修复、唯一临时脚本及异常清理、TOML/JSON/default 配置、原有参数和 cwd 语义必须一起验收。准备阶段的临时伪候选结果不能覆盖未来真实合仓候选。

## PR #8 准备阶段的实机环境与外部停点（历史）

2026-10-01 本次预检：Windows Python 3.12.5 64 位；`codex-transcript-viewer` 0.5.0；Node v24.19.0；npm 11.17.0；Chrome 153.0.8010.54；Edge 154.0.4258.37。Codex runtime 既有 Playwright / playwright-core 1.62.1 成功加载，其默认 Chromium 文件不存在。一次隔离浏览器尝试指定系统 Chrome、既有 Playwright、全新私有 profile 和 `chromiumSandbox:true`，在当前受限执行上下文中因 GPU 子进程 `0xC0000022`／应用能力 `0x80070005` 拒绝而退出，未执行任何 UI 断言。自建 loopback 夹具服务已关闭，浏览器退出已记录；没有重试、提权或更改安全选项。浏览器自动化代码已准备，但可用性及 UI 验收尚未证明。

原普通沙箱读取 E:\code、WSL 服务和监听表被拒绝；按最新明确授权提交的只读沙箱重试成功，没有修改系统权限。WSL 默认发行版 `desktop` 和 `docker-desktop` 均为 Stopped，版本 2。父任务已要求暂不启动 WSL；它可能带起已有服务。WSL Python/Git/Node、实际运行目录计数、运行 WORKFLOW 的 intake／trusted_root／依赖路径及 Windows Python→wsl.exe 采集均未验证。

Windows 监听表查询时 43191、5187、8765 未见监听，这只是瞬时快照。后续隔离服务须只绑定 loopback、使用独立数据目录、确认绑定成功，停止自身子进程；不得操作旧看板或控制器。

未完成的外部验收由项目所有者或其明确指定的实机验收负责人接手：

1. 确认可启动 WSL 且不会意外恢复生产任务，再核实工具链及脱敏的运行配置字段。
2. 在准确的最终合仓候选 SHA 上，用新端口和独立数据目录完成 Windows Python→wsl.exe 的真实固定夹具采集、首次缓存和 HTML 生成。
3. 先取得在正常桌面用户上下文运行私有浏览器夹具的明确授权，使用同一保留浏览器沙箱的脚本及新证据目录，不操作现有浏览器 profile、不更改系统安全设置。完成浏览器看板／详情／轮次／重试／会话断言，以及深链接、前进后退、关闭重开、刷新阅读保持和窄屏检查；确认看板启停不影响控制器、不写 receipt 或 GitHub 状态。
4. 保留准确候选 SHA、环境、完整命令、结果、未执行项、证据摘要和独立 Review；来源、候选或检查实现变更后重新取得相应证据。
5. 若改由 Symphony 无人值守执行，另行审核可信检查入口的运行方法和安装／激活授权，并实际确认领取前来源挂载。用户添加 ready 后才可领取。

目前不宣布 Issue 完成，不生成 PR，不把离线准备、伪任务或未来 Draft PR 视作全部实机验收通过。

## IS-045 的当前准备实测

本轮从干净 main 快进到 PR #8 合并提交 `d49829488c1cce65c1917b219e428e98ff7050bb`，之后只在 `codex/issue7-ready-preparation` 保存准备改动。复核远端 main 仍为该 SHA，Issue #7 为 OPEN 且没有标签；没有导入 `view/`，没有远端发布。

- 固定源码包为 36 个净化文件，ZIP SHA256 `a6849efb34a88b892a5d8773a301e490be17a85b5153985be33472ba79594bf2`，外部 manifest SHA256 `a8e0e001d5e293ad0069185beb8c7ffb4eecf4df45a64faaa9ac802e28f057a5`。在真实私有 bubblewrap 中已认证、解包并读取 `app/run.py` 和测试文件；`/evidence` 写入探针得到只读错误，来源前后摘要一致。
- 在授权后启动 desktop WSL；没有 Symphony systemd 单元自动启动，旧 d4e913e 控制器与 watchdog 当时均不存在。docker-desktop 保持停止。Linux Python 3.12.3、Git 2.43.0、bwrap、cgroup v2、unshare、timeout 等可用。
- 单独预置 `/var/tmp/innovation-symphony-toolchain/view-validation/` 下的 Python venv、Node 24.19.0 与 Viewer 0.5.0。Node 官方校验值为 `14b342e71204f811bde6153be8e04b62aef63c236fef92b55f9c83154b409647`；Viewer wheel 为 `71f2f3ab33cdca42d0174fc7df83aab2d11255264e4be5f0eeac55fe9935a0eb`。没有替换系统 Python/Node 或原 Elixir 工具链。
- 在 `/var/tmp/issue7-controller-view-probe-1790869215166431617`，实际调用 `SymphonyElixir.Mvp.ExecutionSandbox.check`，返回 `{:ok, 0}`，导出 `controller_view_check=true`、`formal_code_checks=true`、`formal_acceptance=false` 的报告。这是独立伪候选调用，不是主服务领取 #7；安装后的固定版本仍须重新取得调用证据。
- Windows Python 实际通过 wsl.exe 读取独立 WSL 脱敏夹具并生成六个 HTML：一个任务、19 轮、Review 尝试 41–44，环境链路成功。固定原来源的首次 `once` 仍因 `build/rollouts` 缺失退出 1；明确创建缓存后的环境验证退出 0。此绕行只证明环境可用，首次运行修复与唯一临时文件清理仍是 #7 的执行内容。证据为 `issue7-real-collection-run3/collection-result.json`。
- 最新完整浏览器证据为 `issue7-browser-desktop-final/browser-result.json`；当前源码绑定的 pipeline 伪候选为 `a66f3d0939129ff1d14fd8427be8267b7efbe1ea`。Chrome 153.0.8010.54、私有 profile、sandbox=true，七项导航／刷新／关闭重开／390px 检查通过，浏览器错误为空，输入未变，自建服务和浏览器均已关闭。
- 控制器全量回归为 653 项、0 失败、6 项既有跳过、覆盖率 100%；格式、公共规格、Credo、Dialyzer 和 escript 构建通过。最终脚本与 View 流程使用已预置依赖运行，必测项不跳过。独立复审已用同一伪造输入确认 worker 从虚假通过变为明确拒绝。

上述 Windows、浏览器证据位于本机 Codex 制品目录 `C:/Users/emla/.codex/visualizations/2026/10/01/01a0f7e7-9589-7590-b992-9120f50f53d9/`。工具报告始终保留准备阶段标记，不把环境成功当作最终迁移候选验收。固定安装、实际进程与原状态保留结果在安装完成后追加。

### 固定安装与最后核对（2026-10-02，北京时间）

准备代码已本地提交为 `a63d3fd09e4ce02b8a72eef7179cd8bde5118e0d`，安装到 `/var/tmp/innovation-symphony-v0-rerun1/releases/a63d3fd09e4ce02b8a72eef7179cd8bde5118e0d`。`runtime-v1/current.json` 指向该版本，可信源码包在此安装的忽略目录 `scripts/view_validation/source/` 中预置；安装前已认证摘要。原固定安装保留，运行配置、指针及入口备份在 `/var/tmp/issue7-runtime-install-1790871031954408253/`。本次本地提交没有推送或合并。

通过受管 `--watchdog start` 启动后重新设置维护暂停。实际控制器 PID `40124`，cwd 为该固定安装的 `elixir/`，启动 ticks `283400`，宿主 boot ID `def38c35-e337-4164-b29e-3f4ed7417337`；这些字段与 `/proc` 中的进程命令、可执行文件逐项相符。状态 API `127.0.0.1:43223/api/v1/state` 返回 200。`mvp.enabled=false`，watchdog `paused=true`，没有启动自动值守循环；不会仅因标签变化自动开始领取。

运行 WORKFLOW 保留原候选和基线 Elixir 检查，追加固定安装下的两参数 View 标记。关闭领取的配置本身返回空 checks，因此另外在独立的**只读 workflow 副本**里解析 `enabled=true` 来认证完整三条 checks、串行 GitHub 与隔离路径，再调用打包 `--preflight`。真实 GitHub GET 预检通过，两个 OPEN Issue 均读取成功；程序实际 `Receipt.exists?`/`Mvp.available?` 计算确认 GH-5 虽 ready 但有回执、GH-7 尚无 ready 且无回执，可领取数为 0。没有修改持久领取开关或调用 claim。

从新固定安装加载的 `ExecutionSandbox.check` 在独立伪候选 `9e7a764e2f4f43410184ff2663da75fe3bb51853` 上返回 `{:ok, 0}`，真实 bubblewrap 内使用安装中的只读净化源码包，实际执行冻结与候选 Python 各 16 项、JS 各 10 项、self_check 及六页 HTML，导出绑定候选、来源、工具链、脚本和夹具的结果。证据目录为 `/var/tmp/issue7-controller-view-probe-1790871181005609838/`；调用属于**使用已安装控制器的独立检查进程**。主服务没有领取 #7、没有运行其编码或 Review，不能登记为主服务已完成 #7 的自动验收。

最终补测：sandbox 模块 22 项；Python 脚本 68 项；View 验证器 24 项；浏览器绑定 16 项，均 0 失败、0 跳过。真实 sandbox 的清理／超时／进程／内存／磁盘限制也已执行通过。独立 Review 复核了同形态篡改从假通过变为失败，以及只清理私有注入依赖的边界。实际 Codex 0.159.1 只查询 `model/list`，返回当前模型目录，配置默认 `gpt-6-astra` 在列表内；没有 thread/turn 或编码调用。

原 `state/attempt-4` 与 `workspaces/v1` 的 6830 个条目，文件内容摘要、类型、mode、uid/gid、inode、链接目标在操作前后完全相同，清单 SHA256 均为 `cd03b42d40980bd4c2bdd14d9a6a138bc22e6146a2bf25c30ab6b01441e46610`。没有向生产 receipt 写入本轮证明。归档 `issue7-ready-preparation/summary.json` 包含实际身份、状态 API、预检、模型目录、控制器调用与原状态保留结果，原始日志和渲染结果同目录保留。

结论：**ready 的执行前准备门槛已经满足，可以由所有者给 #7 添加 ready。** 本轮不添加该标签，也不打开领取。首次运行、唯一临时文件及异常清理、配置／参数／cwd 兼容性、准确最终候选的 Windows＋WSL 与浏览器验收，仍在 #7 的执行范围内；它们不是准备阶段已经验收的迁移功能。后续标签操作、开启领取及最终人工合并分别由用户授权，任何代码／来源／检查变化都需要重取对应证据。

### 最终候选的实机执行方式

项目所有者负责批准领取与人工合并，获其授权的本机 Codex 负责复跑。先冻结最终候选完整 SHA，在新独立目录认证 HEAD/index/源码，使用固定可信 runner 取得新的 View 代码检查和 browser 输入。示例参数是执行安排，不能把准备伪候选或旧报告替换成最终候选证据。

Windows＋WSL：以最终候选的独立净化副本及专用 TOML/JSON/default 夹具配置，运行 `python -B <副本>/view/app/run.py once --config <夹具配置> --out <新证据>/snapshot.json`。`runtime_glob` 只指向独立 WSL 合成 runtime；首次运行不得预建 `build/rollouts`，必须确认修复后自然成功。继续实际调用 `wslpull.pull_snapshot`、`collector.load_sessions`、`pagegen.viewer_pages`，核验一个任务、19 轮、Review 41–44 与六页真实 HTML；检查并发唯一临时脚本及失败清理。不要把 once 的退出码当成完整 HTML 或浏览器验收。

浏览器：在正常桌面用户上下文使用以下入口，保留 `chromiumSandbox:true`、私有 profile 和随机 loopback 端口。`<新验证证据>` 必须来自准确最终候选的当前成功报告；脚本会认证输入完整清单和摘要。输出目录必须不存在。

```powershell
node E:/code/innovation-symphony/scripts/view_validation/browser_fixture.cjs `
  --validation-root <新验证证据> --output <新浏览器证据目录> `
  --chrome 'C:/Program Files/Google/Chrome/Application/chrome.exe' `
  --playwright-root 'C:/Users/emla/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright'
```

本轮准确命令在 `.local/issue7-browser-command.txt`，实机采集脚本在 `.local/issue7-windows-wsl-probe.py`，只作为脱敏夹具流程参考。最终复跑需移除该脚本对“已知首次运行失败”的历史预期及缓存绕行，改为断言修复后成功，并增加迁移兼容性、唯一临时文件和异常清理检查。若最终环境、权限或证据仍有缺口，保留 `awaiting_external`，不批准合并或把未执行项记为通过。

### 获准开启领取（2026-10-02，北京时间）

按 IS-046，所有者已添加 ready，并授权 #7 使用双 Sol 6.1 和开启领取。独立模型评论为 [5944045994](https://github.com/dailiuyi/innovation-symphony/issues/7#issuecomment-5944045994)，控制器通过真实 GitHub GET 解析确认 `coder=gpt-6.1-sol`、`reviewer=gpt-6.1-sol`；当时唯一可领取任务为 GH-7，仓库默认双 Astra 保留。评论必须无末尾换行，预检已发现并修正此严格语法问题。

北京时间 09:47:13 对现有 WORKFLOW 的 `mvp.enabled` 从 false 原子修改为 true，服务通过既有热更新机制生效，没有重启，PID 仍为 40124。09:47:29 实际领取 #7，base 为 `d49829488c1cce65c1917b219e428e98ff7050bb`；09:47:36 首次 coder 会话启动，真实 `thread/settings/updated` 返回模型 `gpt-6.1-sol`，随后已有隔离工作区命令完成事件。回执状态为 `coding`，两角色模型均冻结为 Sol 6.1；此时 reviewer 尚未调用，最终检查及实机验收尚未完成。

操作证据在 `/var/tmp/innovation-symphony-v0-rerun1/operator-gh7-enable-sol61/`，包含原配置备份、只读解析、启用记录及真实回执/状态快照。回执为 `state/attempt-4/4aabe612425a799ec4157fd8d7a3df9a6e0122063fb9aa3ffc55b5351e8de74e.json`，实际会话证据在其 `.evidence/round-1/agent-attempt-1/messages.log`。本次操作前 state/workspaces 中 22916 个既有普通文件内容摘要均保持不变，新 #7 回执和工作区由控制器正常创建；看门狗维护暂停继续保留。本节更新此前“本轮不打开领取”的操作状态，不将编码启动登记为合仓验收通过。

### 服务启动与中断接续阻塞（2026-10-02，北京时间）

按 IS-047 启动原固定服务，新 PID 2397，cwd 及固定 SHA 与指针一致，API HTTP 200；领取仍开启，看门狗维护暂停保留。此前 WSL boot ID 从 `def38c35-e337-4164-b29e-3f4ed7417337` 变为 `dfce0a37-8c44-48cc-89f8-75bbd03d8ba1`，旧控制器及 coder 已消失。原 #7 第 1 轮 View 正式检查拒绝测试导入对 sys.path 的副作用，诊断后进入第 2 轮 coder；10:22:53 中断时尚未形成该轮候选，也没有前序 Review 拒绝。

实际调用已安装 `Executor.resume_recovery` 返回 `{:error, :mvp_resume_binding_mismatch}`，原回执字节未变。现有入口仅接受特定 blocked 停点，开放编码轮还要求前序有效 Review 拒绝；当前状态不满足，不能重启后宣称任务已恢复。当前回执 status=coding，但 API running=0，原 3 次 Agent 尝试、1 次返工、双 Sol 6.1、开始时间和预算均保留。恢复需要补齐并验证狭窄的可信中断接续入口，激活及切换运行版本按既有批准边界处理。

新服务、原回执 SHA256、362 个非构建工作区普通文件摘要、现有入口实际拒绝及剩余阻塞记录在 Codex 制品 `issue7-service-restarted/summary.json`；原文件和配置备份在其 operation 路径。该记录证明服务已启动，不证明 #7 已继续或迁移验收通过。
