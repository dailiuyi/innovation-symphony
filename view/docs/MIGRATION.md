# GH-7 固定快照迁移

本轮用户明确要求在离线 `/workspace` 实现 GH-7，仅保存源码与检查结果，禁止提交、
push、PR、合并、部署和升级服务。这覆盖 IS-044 的“只准备、不合仓”范围，
不改变真实系统、可信门禁安装和外部验收的权限边界。

## 来源与差异

- 来源仓库：<https://github.com/dailiuyi/innovation-view>。
- 完整 commit：`d734a087d83243530bd79f40dfbaedaabf8fe677`。
- 完整 tree：`8a61f1a9d1aa13b7e97e0143ff3a4a33f123d73a`。
- Issue 核查的 Symphony 基线：`da561affa23b72ea5b3e02a740ebf77e6a050530`。
- 本任务实际 checkout HEAD：`d49829488c1cce65c1917b219e428e98ff7050bb`。
- 获准只读制品：`/opt/symphony/scripts/view_validation/source/view-source.zip`。
- ZIP SHA256：`a6849efb34a88b892a5d8773a301e490be17a85b5153985be33472ba79594bf2`。

[source-manifest.json](source-manifest.json) 保存逐文件原始摘要、Git blob ID 和排除记录。
先由 `scripts/prepare_view_source.py extract` 核验包、Git tree 和完整固定 SHA，再提取
36 个文件到 `view/`。37 个 tracked 文件中的真实 `app/config.toml` 明确排除，
未读取其内容。没有嵌套 Git、凭据或运行数据。离线环境无远端与凭据，未能核查
最新远端提交；使用本任务明确提供的固定版本，不静默采用其他版本。实施前远端
核查的时序要求仍未满足：须由所有者提供当时的带时间记录；若不存在，须由所有者
明确决定是否接受迟补核查及其范围。当前远端查询或切换前补查不能补造历史事实。

原仓库及历史保留。来源 tree 未含独立 LICENSE/NOTICE；主仓 LICENSE/NOTICE
保持原样，OpenAI 的版权声明不作为导入 View 的原创归属声明。会话 HTML 使用
[masonc15/codex-transcript-viewer](https://github.com/masonc15/codex-transcript-viewer)
0.5.0，通过 Python 依赖安装，没有把其第三方源码复制进仓库。

迁移调整仅限：

- `collector.py`：在真实会话缓存路径创建 `build/rollouts/`。
- `wslpull.py`：每次调用独立临时脚本，写完关闭再交 WSL；成功、进程异常、
  非零退出、解码失败和中断均清理本次脚本。
- `app/run.py`：仅在直接执行时设置 UTF-8 stdout，允许回归导入入口而不关闭测试 stdout。
- `.gitignore`：忽略真实 TOML/JSON 配置及生成物。
- README、AGENTS、配置 JSON 示例、依赖固定、迁移测试、CI 与固定浏览器夹具入口。
- 旧浏览器 smoke 增加任务／会话深链接及前进后退断言；`browser-refresh.cjs`
  以 Playwright 路由内的固定更新补强刷新断言，等待真实刷新处理完成，检查正文、
  较早分页、筛选、文本选区和滚动保持；实际打开生成会话页，检查内容更新后的
  展开状态、活动树节点及滚动保持，并覆盖损坏响应、503 与恢复。不改展示源码。

API、状态派生、数据库结构、轮次、重试、UI 静态资源及文本解析保持来源实现。
`awaiting_external` 和 PR 合并展示语义留给后续独立 Issue。

## 固定夹具与明确断言

输入是准备阶段已有的 `scripts/view_validation/fixtures/acceptance.json`：完全合成、
脱敏、固定 UUID 与时间，不来自真实控制器回执或用户会话。一个 GH-7、19 个控制器轮次、
一条 coder、同一第 19 轮的 reviewer 尝试 41/42/43/44（前三个协议失败、最后完成），
以及一条未归属会话。预期保留 stageAttempt 1/2/3/1，未归属会话不猜轮次，
加密 reasoning 和原始 outcome prose 不泄漏，六个完整 UUID HTML 文件不碰撞。

`tests/fixtures/migration-expected.json` 由已验证固定包的迁移前副本实际解析、派生和
渲染所得，保存完整看板／stories／task details／session snapshot、六条上下文响应
及六份 HTML 的 SHA256。比较只将私有 stage 路径替换为 `/fixture-view`，去掉第三方
viewer 的 `Generated YYYY-MM-DD HH:MM` 时间；不删除状态、轮次、重试或用户可见字段。
`scripts/run_view_checks.py` 在新私有副本执行实际解析和 self_check，逐值比较预期，
不是只断言页面存在或不抛异常。预期文件不能以候选输出自动更新来绕过回归。

重建预期须在获准固定来源的独立新目录显式执行（正常 CI 不重建）：

```sh
python -B scripts/prepare_view_source.py extract \
  --package /opt/symphony/scripts/view_validation/source/view-source.zip \
  --manifest /opt/symphony/scripts/view_validation/source/source-manifest.json \
  --destination /tmp/view-before-new
python -B scripts/run_view_checks.py --fixture-stage /tmp/view-before-new \
  --output /tmp/view-before-results-new
```

应独立审查所得 projection 与原预期差异，再决定是否接受，不能静默替换。
Linux 夹具只替换被模拟的 Windows 路径转换，不启动 WSL 或增加 Linux 原生采集。

## 数据保留、切换与回退

1. 新 checkout 安装依赖；用独立端口验证固定夹具，再做真实 Windows＋WSL 验收。
2. 旧配置、`data/board.db`、`build/rollouts` 和 `prototypes` 留在旧仓库。
   不自动迁移。需要保留历史时，先停止旧看板并备份数据库（包括仍存在的 WAL/SHM），
   由操作者明确选择复制到新 `view/data/`；无需复制缓存，允许重新采集。
3. 将旧配置复制至新 `view/app/config.toml` 或 JSON，核对原运行目录 glob、端口、仓库、
   单价，不修改控制器配置。显式相对路径仍以命令 cwd 解析。
4. 合并、安装与本机切换分别获得确认后，停止旧看板，启动新入口。验证原数据库历史、
   会话、任务详情和运行时健康；看板进程与控制器进程独立。
5. 异常时停止新看板，恢复旧入口和原数据。保留新数据供诊断，不覆盖原备份；
   不顺带重启或回滚控制器。

本轮没有执行上述真实切换。服务无认证且监听 `0.0.0.0`，仍仅用于可信本机／局域网。
不因合仓扩大暴露范围或新增任务控制能力。
