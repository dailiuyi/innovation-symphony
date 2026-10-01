# View 独立验证器前置准备

`validator.py` 是保留前置准备接口的独立检查实现。IS-045 的可信入口为
`../check_view_isolated.py`，由控制器的 `ExecutionSandbox.check` 在真实隔离环境
中路由调用；`../check_view.py` 仅为配置标记，host 直接运行会失败。
验证器自身仍固定标记 `formal_acceptance: false`；可信包装器另报告
`formal_code_checks`，不能据代码检查声称 Issue #7 或真实 Windows/WSL/UI 全部验收。

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
PR #8 的受限上下文启动使用 `chromiumSandbox: true`，但 Chrome GPU 子进程返回
`0xC0000022`，随后浏览器退出，UI 断言尚未执行。失败记录保留在
`artifacts/view-browser-run1/browser-result.json`；自建夹具服务已关闭，未重试或
改变安全设置。IS-045 授权后改用正常桌面用户上下文，并修正私有 AppData 目录
布局；保留 Chromium sandbox。完整七项夹具浏览器检查已经执行通过。
Linux Python 3.12.3、Node 24.19.0 和 Viewer 0.5.0 已独立安装到固定工具链；
实际 bubblewrap 中已验证离线读取、源码包解包及 evidence 只读。详见
`docs/VIEW_PREPARATION.md` 的当前准备记录。

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
在满足 B1/B2 的独立环境中执行。worker 在首次候选导入前捕获可信测试与渲染
入口，并对入口、测试框架和冻结测试输入的完整性进行校验；这针对已复现的
同解释器入口替换问题，不构成任意恶意 Python 的完整防伪证明。

证据保留逐命令 argv、cwd、超时、退出码、原始 stdout/stderr、依赖版本、
源码包与 manifest 摘要、验证器全部文件摘要、候选前后身份以及渲染 HTML。
任何候选、验证器或输入包变化都会拒绝复用本次通过结果。PR #8 的前置准备
不安装门禁或修改 `check_kind`；IS-045 单独授权安装并实际验证可信 View 路由。
两个阶段均不领取或执行真实任务、不访问真实会话。

浏览器输入另绑定网页、六个 HTML、snapshot 与 contexts 的完整文件清单、字节数
和 SHA256。浏览器脚本在读取前及结束后核对，只服务验证后缓存的字节；新增、
删除或修改均失败。清理错误也保持失败，并仍尝试关闭自建服务和写报告。
以下命令只核对合成输入，不启动浏览器；目录必须是当前成功准备证据及新输出：

```powershell
node scripts/view_validation/browser_fixture.cjs `
  --validation-root <当前positive-evidence> `
  --output <新的browser-input-evidence> --verify-only
```
