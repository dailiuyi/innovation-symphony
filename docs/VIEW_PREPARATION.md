# Issue #7 无人值守前置准备

本分支只准备固定来源制品、独立检查候选代码和脱敏夹具，不提前执行 [Issue #7](https://github.com/dailiuyi/innovation-symphony/issues/7) 的 View 合仓。`view/` 尚未导入，现有 View checkout、控制器、可信安装和运行配置均不由这些脚本改动。源码保存、本地提交、门禁安装、真实验收和远端发布是不同状态。

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

它拒绝 `.local` 和 `innovation-symphony-v0*` 运行路径，标记 `production_claim=false`、`execution_started=false`、`sandbox_mount_executed=false`、`formal_acceptance=false`。这证明文件级预置时序和 mkdir 保留行为，尚未证明真实 bubblewrap 挂载或正式领取后的端到端行为。未来操作者须在授权的 receipt 根目录中、领取前预置制品；本次没有向真实生产 receipt 写入。

## 独立 View 检查的职责

`scripts/view_validation/` 是供外部验收负责人审核的候选检查实现，未接入、未安装、未激活控制器。已有 `check_isolated.py` 只检查 Elixir，`ExecutionSandbox.check_kind` 也未覆盖 View。新增独立脚本或未来 CI 不等于现有控制器会执行该门禁。

独立检查必须使用冻结基线测试和脱敏固定夹具，实际执行 Python 16 项、JS 10 项基线及 self_check 的解析／HTML 生成；数量是基线而非新增测试上限。必须报告并拒绝必测项零执行、skip、缺依赖、渲染失败和检查期间候选变化。证据绑定候选 SHA、候选树／源码摘要、来源制品、验证器及冻结夹具摘要、依赖、命令和原始结果。固定来源中的 `once` 不调用 `write_context_pages`，不能用一次采集返回成功代替 HTML 生成证明。

未来在实际合仓后，候选的 `view/` 路径、首次运行缺目录修复、唯一临时脚本及异常清理、TOML/JSON/default 配置、原有参数和 cwd 语义必须一起验收。准备阶段的临时伪候选结果不能覆盖未来真实合仓候选。

## 实机环境与外部停点

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
