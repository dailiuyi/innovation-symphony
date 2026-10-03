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

### 获准固定修复及真实接续（2026-10-02，北京时间 11:45 快照）

按 IS-048，本地控制器修复已提交为 `b12e5ab42e3c762d19e4ceac7fb7d692e92620d0`，完整六项门禁通过：663 项测试、0 失败、6 项既有跳过、覆盖率 100%，格式、公共规格、严格 Credo、Dialyzer 和 escript 构建通过。先前一次既有看门狗计时断言超出 6 毫秒的失败日志另存，未改断言或跳过。独立 Sol 6.1 Review 完成正确性、遗漏及简化检查，并纠正操作脚本的 PID 复用竞态。

首次安装在停止服务前被逐文件摘要门禁拒绝：操作同步脚本误将 PNG 作文本换行处理。修正后补充新鲜独立复审，实际 WSL 归档的 229 个文件全部匹配；执行源码字节没有变化。失败归档保留，不把被拒安装算作成功。

11:43 固定版本安装完成，实际控制器 PID `114696`，cwd 为新固定安装的 `elixir/`，API HTTP 200。安装前后 22,935 个既有状态及工作区普通文件内容摘要完全相同，原 #7 回执字节未变；WORKFLOW 字节及三条冻结检查、沙盒可信根仍沿用原固定安装 `a63d3fd`，没有扩充权限、资源或模型。领取保持开启，看门狗维护暂停保留；本地提交没有推送或合并。

安装后真实只读预检通过，随后经 `Executor.resume_interrupted/3` 审计入口接续原 #7，执行进程 PID `115012`、cwd 指向新固定版本。原第 2 轮继续，新增第 4 次 Agent 尝试、coder 阶段第 2 次；真实 thread/settings/updated 返回 `gpt-6.1-sol`，thread 为 `01a0fab6-1987-7283-b727-a7f671cb2e14`，11:45 已观察到 13 个隔离命令完成事件。回执 status=coding，原失败候选、事件前缀、返工次数 1、开始时间及冻结合同均保留。此为独立受审续跑进程，不登记为主服务 API running=1。

原截止仍为 11:47:29，本次没有追加预算。上述快照不证明新候选、最终 View 检查、真实 Windows＋WSL/浏览器验收、Reviewer 或 Draft PR 已完成；精确后续状态以本次回执及证据为准。安装、完整门禁、独立审查、真实预检和续跑快照归档在 Codex 制品 `issue7-interrupted-resumed/summary.json`，原始审计目录为 `/var/tmp/innovation-symphony-v0-rerun1/operator-gh7-interrupted-1790909784477234160/`。

11:48 终态核实：原墙钟预算耗尽，回执为 `blocked / :mvp_recovery_resource_exhausted`，第 4 次尝试记录 `{:error, :wall_timeout}`；29 个命令完成事件已保留，没有新候选或 Reviewer/Draft PR。HEAD 仍为 `3960c9064e9a5b45bf148be74bfdfc883bc6418a`，导出的 `view/tests/test_migration.py` 修改保留在原工作区；原回执、二进制 diff 和完整工作区另存为 `receipt-after-budget.json`、`exported-after-budget.patch`、`workspace-after-budget`。续跑操作 `gh7-interrupted-2594` 已形成完成链。本次修复和真实接续已经执行，继续验收仍需要追加有限预算及核实相应审计停点入口，不能沿用本次授权热改回执或归零重领。

### IS-049 加时与直接执行现场记录

用户明确授权“增加 60 分钟”，并要求“不要小队模式”。据此主代理直接实现、简化和复核有限接续修复，没有继续委派子代理，也不宣称本轮控制器源码经过独立团队 Review；Symphony 原冻结的独立任务 Reviewer 仍使用 `gpt-6.1-sol`。

固定本地提交 `e33153a45f3534fb67b54835e8e82f0a1e3e8485` 的六项门禁全部通过：667 项测试、0 失败、6 项既有真实平台 E2E 未启用，覆盖率 100%，格式、公开规格、严格 Credo、Dialyzer 和 escript 构建通过。真实原回执和安装后只读预检通过；没有下调阈值、更改冻结检查或增加跳过。

北京时间 2026-10-02 12:30，固定控制器已安装运行，主服务 PID `200567`、API HTTP 200，cwd 对应该 SHA 的 release；安装前后 22943 个原状态和工作区文件摘要一致，原回执及 WORKFLOW 字节不变，受管入口维护暂停保留。仅通过审计入口继续原 #7，没有重新领取其他任务。

原开始时间 `2026-10-02T01:47:29.323954Z` 保留，墙钟上限从 7200000 增至 10800000 毫秒，截止为北京时间 12:47:29。已使用的 4 次模型尝试、1 次返工和第 2 轮历史不归零；第 5 次实际调用进入该轮 coder 第 3 次阶段尝试，真实模型 `gpt-6.1-sol`，会话 `01a0fae0-a77a-7a01-ba33-fab3abf132ab`。主服务 API 的 running 计数不包含独立审计续跑，进度以原回执和调用日志为准。

脱敏制品为 `issue7-budget-resumed/summary.json`，原始审计目录 `/var/tmp/innovation-symphony-v0-rerun1/operator-gh7-budget-1790914174076825547/`。本条只确认修复验证、安装、预算生效和实际启动；最终候选门禁、Windows＋WSL/浏览器验收、独立任务 Review 和 PR 结果仍须按后续真实证据补记。控制器修复没有推送、合并或部署，也没有切换 View 运行服务。

北京时间 12:38，在当前固定候选 `3960c9064e9a5b45bf148be74bfdfc883bc6418a` 的 Git 归档副本完成真实 Windows Python→wsl.exe 脱敏采集：首次运行没有预建缓存，`once` 自然成功，得到一个任务、19 轮、Review 41–44、六个 session 及六页 Viewer HTML。并发不同 glob 的实际采集返回各自数据且无临时脚本残留；Windows 24 项 Python 回归通过。Chrome 153、Playwright 1.62.1、私有 profile、sandbox=true 的七项导航／读取状态／390px 检查通过，无浏览器错误，22 个输入文件未变，自建服务和浏览器均已关闭；主代理查看窄屏截图。报告位于 `issue7-final-collection-3960c9064e9a-1790915874036092700/collection-result.json` 及相邻 `-browser/browser-result.json`。这是该 SHA 的实测证据，整体 Issue 验收仍为 false；正在修复产生新候选后必须重跑，不能以旧 SHA 或准备伪候选的报告替代。

北京时间 12:43:17，第 5 次 coder 实际完成，控制器提交新候选 `32ae9429da84ddc02132317f05d1ed4ed83eab79` 并开始原正式检查。Coder 只修复迁移测试的路径插入／别名配置隔离，并补充验收记录；其候选 Elixir 全检查通过，基线完整复跑 652 项、0 失败、6 项既有跳过，首轮单项失败日志保留。操作者随后对新 SHA 在新的 Git 归档目录重跑真实 Windows＋WSL 采集、自然首次缓存、六页 HTML、并发与临时文件清理、Windows Python 26 项、Windows Node 10 项及 Chrome 七项验收，全部通过。新报告是 `issue7-final-collection-32ae9429da84-1790916280969017300/collection-result.json`、`windows-node-tests.log` 及相邻 `-browser/browser-result.json`；这些是对应新候选的独立外部实测，尚不代表已由原控制器导入、完成全部正式门禁及独立 Reviewer 批准。

北京时间 12:47:29.428，审计操作 `gh7-budget-66` 完成并停止，最终回执摘要 `251462ca1e229c77d2318f1c0433029a98e0050598a6e2adb1db259d612a26c0` 与完成链一致。回执为 `blocked / :mvp_recovery_resource_exhausted`，第一条正式候选检查因剩余墙钟额度耗尽退出 124；后两条正式检查（含独立 View 门禁）及独立 Reviewer 尚未执行，未创建 PR。新候选保留，任务工作区干净，审计执行进程已退出，总模型次数 5、返工 1 和原历史不变。对应新 SHA 的外部实测报告已摘要归档，但尚未导入 Reviewer；不能将其或 coder 自检替代正式门禁。本次没有再加时、重新领取或重写回执；继续原正式检查及独立 Review 需新的明确预算授权，经审计入口处理同一候选。现场报告 `issue7-budget-resumed/budget-stop.json` 保存停点。

### IS-050 两小时续检

所有者随后明确“增加两小时预算”。原墙钟上限经既有 `Executor.resume_recovery/3` 审计入口增加 7200000 至 18000000 毫秒，原开始时间不变，截止北京时间 14:47:29。前序 `gh7-budget-66` 的授权有效政策、完成链、原回执摘要、冻结范围／检查／隔离、干净工作区及基线副本均经预检核验；只恢复原已获准政策，不改运行 WORKFLOW。当前固定 `e33153a` 控制器直接执行，无源码修改、依赖安装或服务重启。

北京时间 13:00:50.626，独立审计续跑 PID `331649` 实际开始同一候选 `32ae9429` 的第一条正式检查；累计模型次数仍 5、返工 1，原历史前缀及其他策略核验一致。原始操作目录 `/var/tmp/innovation-symphony-v0-rerun1/operator-gh7-check-budget-1790917206423565880/`。原对应候选的 Windows＋WSL 和浏览器证据保留，尚须适用入口导入并经独立 Reviewer 判断；此记录不是门禁或 Review 已通过的声明。

截至北京时间 13:34，同一候选的三项正式检查已经实际完成：候选和基线各 652 项测试、0 失败、6 项既有真实平台 E2E 跳过；受信独立 View 门禁返回 `passed=true`、`formal_code_checks=true`，而整体与实机验收仍为 false。第 6 次实际模型调用为独立 `gpt-6.1-sol` Reviewer，会话 `01a0fb05-8928-7e71-864e-e97abe904b09`；其结论为不批准，指出刷新断言未等待完成、生成完整会话页缺少阅读位置回归，并列出外部实机证据要求。原控制器自动进入第 3 轮、第 7 次模型调用的 coder，第 2 次返工；实际会话 `01a0fb0e-92a6-7260-8f44-5053b8ccb04d`，模型仍为 `gpt-6.1-sol`，原开始时间、政策和历史保持。新候选尚未产生，不把旧候选实测记为新候选通过。

北京时间 13:31 的源仓只读远端核对确认 `dailiuyi/innovation-view` main 仍为固定 `d734a087d83243530bd79f40dfbaedaabf8fe677`。本机 `app/symphony_board/wslpull.py` 修改及 untracked `tests/test_wslpull.py` 保留，没有拉取、覆盖或读取真实配置。这是当前远端核对证据，不倒推为实施前远端查询记录。

北京时间 13:36，第 7 次 coder 完成，控制器产生新候选 `2fb9d3f652796af4b95a40df543015b54dcac5ef` 并开始第 3 轮正式检查。其改动包含等待快照进入客户端后的阅读保持断言、真实生成 HTML 的刷新／失败恢复测试及 Linux 验证夹具路径修复。操作者对该 SHA 新建 Git 归档副本，真实 Windows→WSL 首次缓存、六页 HTML、并发隔离、Python 26 项、Node 10 项、JSON／默认配置及不同 cwd／参数入口均通过；实际候选 Python API 的七项独立浏览器检查通过。

原候选 `view/tests/browser-smoke.cjs` 全套浏览器实测没有通过：Playwright 1.62.1 和系统 Chrome 153.0.8010.54、私有 profile、强制浏览器沙箱下，四组断言通过后，`browser-refresh.cjs:142` 在生成完整会话页失败。只读现场复跑记录为 `open=true`、`expanded=true`，但 content 的 scrollHeight/clientHeight 都是 3769，tree 都是 815，两个 scrollTop 均为 0，无法建立测试要求的非零容器滚动前提。失败、取证 JSON 和截图均保留在新 SHA 制品的相邻 `-candidate-browser*` 目录，自建 View/API 和浏览器均已关闭。此证据只确认新增验收测试存在未解决项，不宣称产品刷新本身失败，也不以七项子集通过替代全套浏览器通过；后续由正式 Reviewer 判定并按原流程返工。系统 Chrome 与 Playwright 自带 Chromium 分开记录，没有安装新依赖。

北京时间 13:54，第 8 次独立 Reviewer 结论为 `approved=false`，静态审查未发现可证实代码阻塞，仅列 GH7-A11/A12/A13/A15/A16 外部验收条件；控制器按既有合同创建 [Draft PR #9](https://github.com/dailiuyi/innovation-symphony/pull/9)，任务保持 `awaiting_external`，不是最终批准或完成。已附加 PR 到本聊天，没有合并或部署。

停靠后，对同一 SHA 的私有实际 Python View 启动、运行、停止做了现场对照：主控制器 PID `200567`、cwd/SHA/start_ticks/boot_id 和 API HTTP 200 在前／中／后三次一致，6 份原任务回执字节摘要及 GH-7 Issue／评论状态一致；私有 View/API 与 BoardStore 均正常关闭。报告在该 SHA 制品的 `controller-isolation-result.json`。随后原审计入口已核验并复制五项等待条件的真实外部证据，包含完整浏览器失败和取证，而非一律通过标志；北京时间 13:57:49.805，第一个冻结检查实际开始，操作 `/var/tmp/innovation-symphony-v0-rerun1/operator-gh7-external-1790920606054271530/`，PID `561525`，继续原政策、历史和 PR。最终 Reviewer 必须重新核查证据并将发现的代码缺陷交回返工。

配套浏览器仅完成现有 Playwright CLI 的只读安装预览：1.62.1 指定 Chromium/Headless Shell `151.0.7922.34`（revision 1234）、FFmpeg 1011、Winldd 1007，本机配套 Chromium 文件不存在。因所有者最初明确安装依赖前需批准，已提出只下载到独立验收制品目录的具体安装申请；没有依据异步提问送达就视为已批准，也没有安装或切换现有系统 Chrome／运行服务。

第 9 次独立 Reviewer 已实际读取导入证据并再次拒绝：明确把新增滚动夹具失败及受影响的完整浏览器／CI 验收分类为代码缺陷，确认控制器启停隔离证据已补齐；GH7-A15 则要求历史实施前核查记录或所有者对迟补核查的明确例外决定。原控制器完成第 10 次诊断，并实际进入第 4 轮、第 11 次 Sol 6.1 coder，会话 `01a0fb43-53d5-7100-9342-b87124c6304a`，累计返工 3，原政策／计时／历史保持。其修复改用生成页实际整页滚动，并增加树列表溢出，尚须新候选实机复验。

北京时间 14:12:55，操作者先重新只读查询源 main，再于 14:12:57 完成固定包构建和验证；来源仍为完整 `d734a087d83243530bd79f40dfbaedaabf8fe677`，包摘要仍为 `a6849efb34a88b892a5d8773a301e490be17a85b5153985be33472ba79594bf2`，源仓已有修改不变。这个新来源核验没有重写历史，也没有在该步骤另跑候选门禁。已就 GH7-A15 提交仅适用于 #7 的迟补核查例外申请；所有者尚未答复，不能记录为已批准决定。两项待答复申请与实机失败均保留，Draft PR #9 不代表最终验收完成。

### 所有者人工验收反馈与预算停点（2026-10-02）

所有者在本线程回复“人工验收没问题”，按 IS-051 记录人工验收通过的反馈。用户未指定完整 SHA 或具体覆盖项，因此该反馈不替代机器执行证据，也不自动绑定后续修复版本。

北京时间 15:52 的只读核对显示，PR #9 保持 open、Draft、未合并，远端候选仍为 `2fb9d3f652796af4b95a40df543015b54dcac5ef`；原任务工作区候选已为 `b6c07277c60fe9ab00c1b5acb7648d0bb6a72d39`，尚未更新到该 PR。原回执为 `blocked / :mvp_recovery_resource_exhausted`，累计 12 次 Agent 尝试、4 次返工，墙钟上限仍为 18000000 毫秒。最新已完成的独立 Review 仍是第 9 次、对应旧候选的拒绝，不能据此认定新候选已通过或已被拒绝。准确候选的完整检查、浏览器复验和独立 Reviewer 复审仍未完成；本次反馈没有追加预算或授权安装、时序例外、合并及服务切换，未启动新执行操作。

### IS-052 追加两小时并继续复审流程

所有者随后明确授权再加两小时。操作 `/var/tmp/innovation-symphony-v0-rerun1/operator-gh7-third-budget-1790929189179047797/` 保存原回执、工作区及基线副本。首次只读预检拒绝操作脚本误从外部证据续跑授权直接读取预算政策；原回执未变，失败输出保留。沿该授权的前序加时记录核验政策，确认外部续跑的冻结检查一致后，第二次预检通过，固定源码和服务均未修改。

北京时间 16:22:04，经 `Executor.resume_recovery/3` 启动原任务，独立执行 PID `800015`，固定控制器仍为 `e33153a45f3534fb67b54835e8e82f0a1e3e8485`。原预算增加至 25200000 毫秒；开始时间、冻结合同和历史前缀核验一致。第 13 次实际调用已进入第 5 轮 coder，模型 `gpt-6.1-sol`，接续两项未提交修改，未跳过修复直接伪造 Reviewer 通过。人工验收反馈写入本次授权诊断，未认定未指明 SHA 的人工反馈覆盖新候选或所有机器检查。完整门禁与实际 Reviewer 复审结果须另记，不以启动成功替代复审完成。

北京时间 16:31，coder 完成 tracker 配置匹配／不匹配测试修复，控制器提交新候选 `f5e68a9a964e6c7c1ca32440bccee7d2f462a2f1`，开始原三项正式检查。操作者随即对新 SHA 的独立 Git 归档副本重跑真实 Windows→WSL 脱敏首次采集、自然缓存、六页 HTML、并发隔离及临时文件清理，Windows Python 26 项通过；完整 `browser-smoke.cjs` 八组断言全部通过，包括上次失败的生成会话滚动／展开／筛选／刷新及异常重试检查。另七项实际 API 操作及窄屏检查通过，截图已保留并由主代理查看窄屏任务图；多配置和不同 cwd 的实际入口检查也通过。私有 API／BoardStore／浏览器正常关闭，45 个归档源文件字节均未变。该报告使用现有系统 Chrome 153.0.8010.54 和 Playwright 1.62.1，未安装或宣称验证配套 Chromium；制品 `issue7-final-collection-f5e68a9a964e-1790930003931448900/` 及相邻 `-candidate-browser`、`-actual-api`。本条是新候选的真实外部检查记录，尚未通过外部审计入口导入 Reviewer，不代表整体批准。

第 5 轮的第一项正式候选检查全部通过（652 项、0 失败、6 项原有跳过、100% 覆盖率、格式／规格／Credo／Dialyzer／构建），第二项基线复跑也为 652 项、0 失败、6 项跳过。但第三项受信独立 View 检查在执行测试前失败，明确报错 `candidate worktree is dirty; disk file list differs from HEAD, including ignored files`。只读第 14 次诊断确认三个测试生成的 `elixir/log/symphony.log.*` 污染候选目录，要求将测试日志隔离到临时目录、清理自身产物并覆盖成功／异常／重复运行；不允许修改冻结检查或放宽忽略文件规则。控制器因此进入第 6 轮、第 15 次 coder，独立 Reviewer 尚未启动。

北京时间 16:50:59.073，第 15 次 coder 因累计墙钟上限退出 `:wall_timeout`；最终操作结果为 `blocked / :mvp_recovery_resource_exhausted`，15 次尝试、5 次返工，候选仍为 `f5e68a9a964e6c7c1ca32440bccee7d2f462a2f1`。`elixir/config/config.exs` 未提交的日志隔离修复保留，尚未经完整验证、提交或安装。原回执摘要为 `61696f324c1e6886c33790ad56982dd9f7ea07381bdf626c4d49cb1512bb39f7`，原操作已形成完成链，回执、工作区和二进制差异分别保存在操作目录的 `receipt-after-budget.json`、`workspace-after-budget`、`workspace-after-budget.patch`。本次追加两小时确已生效，但沿用原开始时间累计墙钟，阻塞等待也计入；实际恢复窗口约 29 分钟，并非从恢复时开始的完整两小时。原历史和冻结合同核验一致，没有新独立 Review，不把正式门禁失败伪装为 Reviewer 拒绝或通过。制品 `issue7-third-budget/summary.json`、`budget-stop.json` 保存结果；依赖安装和 GH7-A15 时序例外仍未获明确批准。

所有者质疑“哪跑了两小时，是不是别的原因堵塞”后，只读审计确认：原五小时上限加上已认证的 209720 毫秒外部等待抵扣，旧截止为北京时间 14:50:59.043954；本次实际恢复在 16:22:04.593625，已经超过旧截止 5465.549671 秒（91 分 5.55 秒）。操作者直接给旧累计上限增加 7200000 毫秒，将新截止延到 16:50:59.043954，实际仅余 1734.450329 秒（28 分 54.45 秒），没有提供恢复后完整两小时。这是加时操作的可用窗口计算问题，不是实际运行两小时。另一个直接阻塞是真实受信 View 检查发现测试日志污染：16:41:09 第三条检查拒绝后，16:41–16:46 诊断，16:46:51 再次进入 coder，16:50:59 被墙钟终止。新的 Reviewer 从未调用；不能将它归因于 Reviewer 不同意、服务未启动或已充分执行两小时。`issue7-third-budget/budget-diagnosis.json` 保存原始时间点、实际失败文本及事件链。本次核查未追加预算、启动任务或修改回执。

### IS-053 实际窗口安排与接续入口阻塞

所有者要求“给足够的时间跑”后，操作者按当前时间、原开始时间和认证的外部等待抵扣计算至少四小时可用窗口，预留五分钟启动余量。操作 `/var/tmp/innovation-symphony-v0-rerun1/operator-gh7-available-window-1790933024172666122` 保存原回执、工作区和基线。预检通过仅证明元数据与冻结合同符合条件；实际入口随后返回 `:mvp_recovery_resume_stage_unsupported`，未生效四小时政策，原回执摘要仍为 `61696f324c1e6886c33790ad56982dd9f7ea07381bdf626c4d49cb1512bb39f7`。此前“已实际恢复”的进展表述已纠正，预定截止不作为运行截止证据。

阻塞原因是原 View preflight 在干净源码校验阶段输出失败 JSON，没有生成隔离检查的子进程退出状态，失败记录为 `exit_status=null / {:error, :sandbox_check_evidence_missing}`；旧预算接续入口只接受非零整数退出码。最小修复仅允许绑定原隔离 View 路由、冻结命令、准确失败报告及持久失败记录的审计接续，仍须重跑全部冻结检查和独立任务 Review。

首轮单独 Sol 6.1 CLI Reviewer 对两个控制器补丁文件返回 `approved=false`，指出占位符展开差异、隔离 View 身份绑定和互斥锁内证据复核三项缺陷。主代理直接修复，未使用 Codex 小队；新增占位符路由正例和非 View／非隔离负例，接续前再次核验报告及失败 JSON 摘要。第二轮复审调用被自动审批拒绝，理由为未明确授权向具体外部目的地披露内部源码；只读核实配置目的地为 `https://api.openai.com/v1`，已向所有者提出精确授权请求。该独立控制器补丁审查不等于 GH-7 正式 Reviewer 验收，也不等于运行版本安装批准。运行控制器仍为 `e33153a45f3534fb67b54835e8e82f0a1e3e8485`，原任务继续保持预算停点。

修正后的第二轮隔离构建 `/var/tmp/issue7-window-fix-validation-1790934720541292025` 已通过六项门禁：格式、规格、严格 Credo、完整测试覆盖率、Dialyzer 和可执行构建。完整测试为 669 项、0 失败、6 项原有实机跳过、100% 覆盖率；预算／中断接续专项测试也通过。未修改冻结 View 检查、运行 WORKFLOW、真实任务回执或工作区。第二轮独立补丁复审仍未执行，未本地提交、远端发布或安装该修复，四小时实际执行窗口仍待生效。

所有者随后明确批准上述指定 OpenAI API 的补丁复审。第二轮独立 `gpt-6.1-sol` 复审实际完成，`approved=true / findings=[]`：确认精确隔离 View 预检失败绑定、占位符展开、锁内摘要重验及保留原失败与完整后续检查。报告 `issue7-window-fix/issue7-window-fix-validation-1790934720541292025/independent-review.json` 与六项门禁、源码摘要共同保存。该批准仅覆盖两个控制器文件，不覆盖 GH-7 候选验收或运行安装；此前“复审仍未执行”是审批解除前的历史快照。

本地固定修复为 `43ef95638ca8cca87bdc94c38032187debac0982`，未远端发布。所有者另外明确批准空闲控制器从 `e33153a` 切换到该版本并短暂重启。安装操作 `operator-gh7-window-install-1790941926725875470` 的实际结果：新控制器 PID `1029835`、API HTTP 200；23,606 个原状态／工作区文件摘要一致，原回执字节及运行 WORKFLOW 保持不变，看门狗保留暂停。受信检查、任务隔离工具链和来源仍固定为原 `a63d3fd`，没有用这次控制器源码替换冻结验收合同。

新操作 `operator-gh7-available-window-1790942159439109400` 在切换完成后重新计算窗口，经原审计入口实际续跑。北京时间 19:56:37.816，第 16 次真实 coder 调用开始，模型 `gpt-6.1-sol`，接续第 6 轮及原未提交修复；回执为 `recovering`，预算政策实际从 25200000 增至 51000685 毫秒，本次增加 25800685 毫秒，原开始时间和已认证外部等待 209720 毫秒保留。实际进程启动时可用 14666072 毫秒，截止为北京时间 2026-10-03 00:00:59.728，即约四小时四分钟。全部历史前缀及冻结合同核验一致，未将此前失败操作的预定窗口当作生效证据。独立操作进程 PID `1030178` 的任务执行以回执和模型调用证据确认；主控制器 API 的调度计数为零不代表这个审计操作没有运行。完整正式检查、新候选实机复验和独立任务 Review 结果仍需另记。

第 16 次 coder 完成日志隔离配置及真实 Mix 启动／退出／重试回归，控制器固定候选 `63d47b7b33cf4520b171615a04b3b77514254e7a`。本次自检首次并行运行 candidate／baseline 出现线程资源错误，原结果保留；串行复跑两条入口均通过，没有修改门槛。父操作对该 SHA 的独立归档副本完成 Windows→WSL 脱敏采集、四种 CLI 入口、完整八组系统 Chrome 浏览器检查、七项实际 Python API／窄屏检查，全部通过；45 个归档源文件字节未变，自有 API 和 BoardStore 关闭，窄屏截图已查看。制品根 `issue7-final-collection-63d47b7b33cf-1790943318101080300` 与相应浏览器目录保留完整报告和命令。配套 Chromium 尚未安装或验收，不据系统 Chrome 通过宣称 GH7-A16 完成。

第 6 轮控制器正式候选检查和冻结基线检查随后均通过，分别为 652 项、0 失败、6 项原有实机跳过；候选检查的格式／规格／Credo／覆盖率／Dialyzer／构建均通过。但第三条受信独立 View 检查再次在 preflight 拒绝，仍为磁盘文件清单与 HEAD 不同、含忽略文件。只读核对确认三项旧 `elixir/log/symphony.log.1/.idx/.siz` 留在任务工作区；新测试日志配置防止新的污染，没有清掉旧产物。未人为改动在途工作区或把该失败改报成功，控制器进入第 17 次诊断、随后第 18 次 coder、第 7 轮修复，要求保留原件／摘要后移走旧产物，并补齐遗留日志与启动失败回归。原第 6 轮所有结果保留，独立任务 Review 此时尚未调用，预算仍有余量。

第 18 次 coder 补齐旧日志、helper 失败、应用启动失败、重试及运行前后源码清单／内容回归；旧配置的五次真实 Mix 调用及残留检查均被负例拒绝，新配置通过。还将浏览器夹具默认截图移到独立结果目录，避免浏览器运行污染源码。控制器固定新候选 `8148011a335e21171baa3e7c2a015b8bcd04a917`，真实工作区干净且旧日志文件列表为空；三项旧日志的原件仍在本次 `workspace-before` 快照，`issue7-active-window/old-log-preservation.json` 保存大小和摘要，不输出原日志内容。

父操作对 `8148011` 的新归档副本重新完成真实 Windows→WSL 夹具采集、Windows Python 26 项、Windows Node 10 项、四种 CLI 入口、系统 Chrome 完整八组浏览器检查及七项实际 Python API／窄屏检查，全部通过；45 个归档源文件字节一致，自有服务均已关闭，窄屏图已查看。制品根 `issue7-final-collection-8148011a335e-1790945084945718700` 保留报告、原始输出、环境版本和截图。明确区分系统 Chrome 与尚未安装的配套 Chromium；当前远端查询证明固定来源仍是 `d734a087`，不追认为实施前查询证据，相关时序例外与配套浏览器安装的授权请求仍待答复。

第 7 轮三条冻结检查实际全部退出 0：候选与基线均为 652 项、0 失败、6 项原有实机跳过；独立 `check_view.py` 返回 `controller_view_check=true / passed=true / formal_code_checks=true`，准确绑定 `8148011`。该报告仍明确 `formal_acceptance=false / real_windows_wsl_acceptance=false`，不将离线检查冒充全部外部验收。北京时间 20:52:59，第 19 次真实独立 `gpt-6.1-sol` Reviewer 调用开始，回执为 `reviewing`，累计 19 次尝试、6 次返工，冻结合同和历史前缀核验保留。与此前仅针对控制器补丁的单独 CLI Reviewer 是不同审查；此时任务复审结论尚未完成。

北京时间 21:01:47，第 19 次独立任务 Reviewer 实际完成，`approved=false`，未发现可证实的新增代码缺陷。原任务与操作结果均为 `awaiting_external`，外部交接绑定 `8148011`；剩余 GH7-A11/A12/A13/A16/A17 为外部验证，GH7-A15 为所有者决定。此处停点来自外部证据和决定缺失，不是再次耗尽运行预算。完整结论保存在 `issue7-active-window/round-7/review.json`，不以父操作已完成但尚未导入的实机证据冒充 Reviewer 已审阅或全部批准。

操作完成停驻后，对同一候选的独立 View 执行真实启停对照：前、中、后三次控制器 PID／启动身份／版本一致，API 持续健康，六份回执字节摘要及 GitHub Issue／评论状态均一致；仅自己的看板 API 和 BoardStore 启动后正常关闭，没有写生产回执。`issue7-final-collection-8148011a335e-1790945084945718700/controller-isolation-result.json` 保存命令和对照证据，待通过原外部证据入口交给新的独立复审。

北京时间 21:13 的只读远端核实：PR #9 仍为 open、Draft、未合并，head 为旧 `2fb9d3f`，与最终候选 `8148011` 不同；旧 head 的 make-all 通过、View job 在 Synthetic browser acceptance 失败，不能证明最终候选 CI。现有外部 Draft 入口要求仅剩 verification 条件，且既有交付候选必须一致；本轮有 A15 decision，不能直接发布或改回执绕过。配套 Chromium 安装、仅针对 A15 接受迟补核查，以及以普通快进更新现有 Draft 触发准确候选 CI 的具体请求已提出，尚未获得答复；不合并、不部署、不强推，不修改冻结检查或扩大为平台重构。

### IS-054 外部条件接手（2026-10-03）

所有者明确批准独立目录安装配套 Chromium、仅 GH7-A15 接受迟补核查、普通快进更新现有 Draft 并运行 CI。安装制品 `issue7-playwright-1.62.1-1791006665769005700` 固定 Playwright 1.62.1、配套 Chromium 151.0.7922.34／revision 1234；实际启动版本断言、完整八组候选浏览器检查和七项实际 Python API／导航／窄屏检查均通过，自有服务与浏览器关闭，系统 Chrome 和控制器未改。配套浏览器窄屏截图已由主代理查看，属于脱敏夹具而非真实任务状态；45 个候选归档源文件字节仍一致。对应 `-paired-candidate-browser` 和 `-paired-actual-api` 制品保留原始输出和版本。

普通快进将 PR #9 从 `2fb9d3f` 更新到 `8148011`，没有强推、合并或部署，生产回执字节未变。推送成功后的首次 PR 接口尚返回旧 head，停止元数据步骤保留该断言失败；只读复查确认 GitHub 已索引新 head 后，补完待验收描述，没有重推。`issue7-owner-draft-update-1791006806069511854` 保存发布意图、原描述、成功推送输出和对账结果。准确候选 CI run `37101284043` 的 `make-all` 与 `view` 均成功；完整 View job 包括依赖安装、Python／JS、实际 self_check、固定迁移比较、八种入口及固定浏览器验收，原始日志已脱敏保存于 `issue7-current-ci-1791007221104884999`。

北京时间 13:57:50 迟补只读核查确认来源远端 main、本地 HEAD 与原固定包仍为完整 `d734a087d83243530bd79f40dfbaedaabf8fe677`；来源仓库两项既有修改保留，没有 fetch 或替换版本。所有者决定仅接受 A15 的核查时序例外，保留实施前记录缺失，不追认为历史查询成功或豁免其他标准。

操作 `operator-gh7-external-v2-1791007253446500689` 为六项原等待条目准备 6,834,422 字节脱敏证据，原回执字节、候选、冻结合同及前序完成链绑定。北京时间 14:02:05，已安装 `43ef956` 的 `mvp.external` 实际进入新检查，审计编号 `gh7-external-v2-1791007253535111464`，独立执行 PID `1436685`，其他领取保留暂停。准备时剩余活动额度 10,749,446 毫秒（约 2 小时 59 分钟）；控制器认证累计外部等待抵扣 61,424,513 毫秒，原政策、开始时间、19 次尝试、6 次返工及历史不归零。本条仅确认真实导入和复跑启动，新的正式结果、独立 Reviewer 批准与最终交付状态另记。

本次首条正式候选检查保留一项真实失败：`WatchdogTest` 原有打包／生命周期测试在 `watchdog_test.exs:1390` 记录 1606 ms，上限 1600 ms，超出 6 ms；652 项中 1 失败、6 项原有跳过，检查退出 10。其余格式／规格／Credo／Dialyzer／构建通过；没有将先前 CI 成功或父操作验收代替此失败。控制器按原恢复策略进入第 20 次 `gpt-6.1-sol` coder、第 8 轮。Coder 未修改看门狗实现及时间断言，串行候选／基线自检均 652 项、0 失败；新增并发采集失败后重试的迁移回归，清理缺陷副本被该测试拒绝，View Python 增至 27 项，JS 仍 10 项。

北京时间 14:21:04，会话完成，控制器固定新候选 `9e877df609e67e7c8e54d9ea529e5451b8e47fe9`，仅改 `view/tests/test_migration.py` 和 `docs/VALIDATION_VIEW.md`，开始全部正式门禁。父操作没有复用 `8148011` 的通过标记：为新 SHA 建立 `issue7-final-collection-9e877df609e6-1791008571356480600`，重新完成真实 Windows→WSL 脱敏首次采集／自然缓存／六页渲染／并发清理、27 项 Windows Python、10 项 Windows Node、四种 CLI 入口、配套 Chromium 八组候选检查和七项实际 API／窄屏检查，全部通过；45 个归档源文件字节不变，自有服务关闭，窄屏截图已查看。环境清单中的系统 Chrome 仅为库存信息；实际执行版本由配套 Chromium 报告固定为 151.0.7922.34。

经同一原任务的普通快进更新，PR #9 head 已为 `9e877df`，仍 open、Draft、未合并；没有强推或手改生产回执。准确新候选 CI run `37102868007` 的 `make-all` 和完整 `view` 均成功，日志保存于 `issue7-current-ci-1791009053676794681`。这些新证据须等新候选正式检查及独立 Review 建立新交接后，再经受信入口绑定导入；旧候选导入材料不能作为新 SHA 的验收证明。

第 21 次独立 Reviewer 完成后确认 GH7-A15 的所有者时序决定及 A16 的配套浏览器条件已满足，没有新增代码缺陷；整体仍为 `approved=false`，A11/A12/A13/A17 要求绑定新候选 `9e877df` 的实机、CI 和隔离证据。旧 `8148011` 的导入记录未被追认成新版本证明。原操作结果保留 `awaiting_external`，并记录已有 Draft 交付拒绝 `:mvp_pr_identity_mismatch`：原不可变发布记录仍绑定旧 `2fb9d3f`，实际远端已由所有者授权的普通快进更新。只读核查证明旧意图摘要仍有效，没有手改发布记录或回执。

北京时间 14:43，新 SHA 的独立 View 启停现场对照完成：控制器 PID `1029835`、启动身份、cwd／版本前中后一致，API 三次 HTTP 200，六份生产回执字节和 GitHub Issue／评论状态一致；仅自有 View API／BoardStore 启停，报告位于新候选制品的 `controller-isolation-result.json`。四项新证据包共 4,542,779 字节，通过原 `mvp.external` 入口导入，操作 `operator-gh7-external-v3-1791009822097100857`、审计编号 `gh7-external-v3-1791009822152961145` 保留原开始时间、51,000,685 毫秒政策、21 次尝试、7 次返工及完整历史，准备时剩余活动额度 8,422,229 毫秒。

北京时间 14:44:10，该操作实际开始检查；候选和基线均 652 项、0 失败、6 项原有真实平台跳过，第三项独立 View 检查也退出 0。正式离线检查与父操作真实 Windows＋WSL／配套浏览器验收分别留证，不以离线结果替代实机验收。14:54:12 第 22 次独立 `gpt-6.1-sol` Reviewer 实际开始，三项新正式日志和旁车保存于 `issue7-external-v3/`。本条仅记录复审启动，最终批准及原控制器交付状态须另记。

北京时间 15:02:30，第 22 次独立 Reviewer 实际完成，`approved=true`，GH7-A01 至 A20 全部 `adequate=true`，阻塞数组为空；报告摘要 `e5a5294ace0fac2853cbfb5fb1ae1b5ab2950f6867047dbdf2b4288abb752312`，制品 `issue7-external-v3/review.json` 保留逐项断言强度和失败敏感性结论。它确认当前候选可进入人工评审，实机及 CI 外部条件充分，并明确保留 A15 的历史记录缺口和所有者时序例外。这是实际原任务 Reviewer 的批准，不是父操作自检、安装补丁的 Review 或 GitHub 原生人工 Approve。

随后原交付入口返回 `:mvp_pr_identity_mismatch`，完成链与回执均为 `blocked`；原不可变 Draft 发布记录仍绑定 `2fb9d3f652796af4b95a40df543015b54dcac5ef`，已获准普通快进的远端 head 与当前任务均为 `9e877df`。`ExternalDraft.previous_delivery/4` 在新的远端写入前要求旧候选相等；现有只读对账也要求意图与当前候选相等，不能收编这个已批准的快进。不是缺 Chromium、缺验收、再次 Review 拒绝或活动预算耗尽。没有手改回执、发布意图、冻结合同或重新领取来伪装结案；自动状态仍需适用的可信接管修复，新的运行安装和切换未在 IS-054 中获准。

所有者授权范围内更新 Draft 的完整内部验收正文曾被自动审批拒绝，原因是这份具体内部内容没有外发批准。安全替代仅同步 PR 已公开的 SHA、GitHub CI 链接与状态、保持 Draft；更新与远端 GET 对账成功，生产回执和旧意图字节未变。完整内部正文只保存于本地 `issue7-owner-final-draft-metadata-1791011223514854945/internal-acceptance.md`。PR #9 仍 open、Draft、未合并，不自动关闭 Issue，没有执行部署或 View 生产服务切换。

北京时间 15:09:57 最终只读核验 `issue7-owner-final-audit.json`：实际恢复执行进程已退出，原主服务仍为 `43ef956`／PID `1029835`、HTTP 200，身份与新候选隔离测试一致，新领取保持暂停；其余五份原回执字节一致，原开始时间／政策／恢复事件前缀／冻结合同保留，任务工作区干净且 HEAD 与 PR／CI 均为完整 `9e877df`。GitHub 原生 Review 列表为空，Issue #7 已有 `ready` 且仍 open；重复添加标签不能解决已有回执的交付记账阻塞。当前代码可以对准确新 SHA 人工验收，控制器回执未结案，两者分别报告。
