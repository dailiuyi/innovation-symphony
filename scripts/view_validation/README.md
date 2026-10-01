# View 独立验证器前置准备

这是未接入控制器的候选验证代码，不是已安装可信门禁。所有结果固定标记
`formal_acceptance: false`，不能证明 Issue #7 或真实 Windows/WSL/UI 已验收。

冻结来源为 View 提交 `d734a087d83243530bd79f40dfbaedaabf8fe677`。
`frozen/` 保留 16 项 Python 与 10 项 Node 测试的原始文件和摘要；只运行冻结
测试也不足够，因此另外执行候选测试，允许新增用例，记录候选测试变化。
基线测试必须全部执行，零测试、跳过、缺失报告、错误和退出码矛盾均失败。

```powershell
$env:VIEW_TEST_SOURCE_PACKAGE = '<当前已验证包>/view-source.zip'
$env:VIEW_TEST_SOURCE_MANIFEST = '<当前已验证包>/source-manifest.json'
python -B scripts/view_validation/tests/test_validator.py
python -B scripts/view_validation/validator.py `
  --candidate-root <已冻结的候选Git根目录> `
  --candidate-sha <完整候选提交SHA> `
  --view-root <候选根目录>/view `
  --source-package <view-source.zip> `
  --source-manifest <source-manifest.json> `
  --evidence-root <候选之外的新隔离目录>
```

自测必须通过上述两个环境变量显式指定当前已验证的源码包；没有包即失败，
不跳过。包随生成器变更必须重建，不继承旧摘要作为正式有效配置。
不安装依赖。本次实际验证组合为 Python 3.12.5 64 位、Node 24.19.0、
`codex-transcript-viewer==0.5.0`。Python 3.11+ 是源码最低语法要求，
不表示其他兼容版本已经验证。核心流程只需 Node 内置测试模块，无需浏览器。

Windows 夹具浏览器脚本使用现有 Chrome 153.0.8010.54：
`C:\Program Files\Google\Chrome\Application\chrome.exe`，及 Playwright 1.62.1：
`C:\Users\emla\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\node_modules\playwright`。
它只启动新的 loopback 随机端口、私有 profile 和合成数据，不访问现有页面。
本次启动使用 `chromiumSandbox: true`，但 Chrome GPU 子进程返回
`0xC0000022`，随后浏览器退出，UI 断言尚未执行。失败记录保留在
`artifacts/view-browser-run1/browser-result.json`；自建夹具服务已关闭，未重试或
改变安全设置。现有浏览器和库的安装、加载已核实，实际浏览器操作仍未验证。
Windows 已安装依赖不能证明 Linux/bubblewrap 的离线依赖已预置；WSL 保持停止，
Linux Python/Node/Viewer 及挂载路径仍须外部 preflight 确认后才能用于正式 runner。

验证器先认证源码包完整 Git tree、冻结测试字节、候选 HEAD 与普通文件树。
HEAD 的普通 blob、index 和磁盘完整文件清单必须相符，包括 ignored 文件；
`assume-unchanged` 与 `skip-worktree` 不能隐藏磁盘变更。实际文件 SHA256 和
HEAD blob OID 同时绑定。只有固定 HEAD `.gitattributes` 明确允许的纯
CRLF→LF 差异可以归一化；属性在新建隔离 Git 目录中求值，不使用候选工作区、
全局或 `.git/info` 属性，不执行 clean filter。filter、encoding、ident、链接及
submodule 均拒绝。普通 Git status 不作为 SHA 归属证明，避免其运行 clean filter。
源码复制到证据目录的私有 stage，渲染六条固定 UUID 的合成会话，显式调用
`self_check` 与 `viewer_pages`，检查任务、19 轮、四次 reviewer 尝试、未归属
会话、完整 UUID 文件名、实际 HTML 内容、静默刷新及加密 reasoning 不泄漏。
`once` 分支不替代 render。Windows→WSL argv 只使用子进程替身，不执行 WSL。

工作进程清除账号环境，使用私有 HOME/TEMP，拒绝真实子进程与外部网络；
基线 API 用例可以启动并关闭 loopback 内的临时模拟 HTTP 服务。这些措施不
构成针对任意恶意候选的 OS 沙箱。未来正式验收仍须由控制器冻结可信入口，
在满足 B1/B2 的独立环境中执行，并另补真实 Windows/WSL 与 UI 证据。

证据保留逐命令 argv、cwd、超时、退出码、原始 stdout/stderr、依赖版本、
源码包与 manifest 摘要、验证器全部文件摘要、候选前后身份以及渲染 HTML。
任何候选、验证器或输入包变化都会拒绝复用本次通过结果。前置准备不安装
门禁、不修改 `check_kind`、不领取或执行真实任务、不访问真实会话。

浏览器输入另绑定网页、六个 HTML、snapshot 与 contexts 的完整文件清单、字节数
和 SHA256。浏览器脚本在读取前及结束后核对，只服务验证后缓存的字节；新增、
删除或修改均失败。清理错误也保持失败，并仍尝试关闭自建服务和写报告。
以下命令只核对合成输入，不启动浏览器；目录必须是当前成功准备证据及新输出：

```powershell
node scripts/view_validation/browser_fixture.cjs `
  --validation-root <当前positive-evidence> `
  --output <新的browser-input-evidence> --verify-only
```
