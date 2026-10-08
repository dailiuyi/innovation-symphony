# View agent guidance

先读根仓库指导及 `README.md`、`docs/MIGRATION.md`、`docs/DEMO-SCOPE.md`。

`view/` 是独立 Python 采集与展示服务，任务保持只读，可维护本地 SQLite、缓存、HTML 和日志。
GH-16 唯一配置写入口通过受控 loopback 管理接口转发仓库双角色默认选择；
授权、校验、CAS 持久化及执行快照由 Elixir 管理。不得在 View 直接写 WORKFLOW／注册表。
调度、编码、检查、Review、恢复、交付与 AppServer 属于 `../elixir/`。
不得增加任务控制入口、写控制器回执或 GitHub 状态，也不得用展示测试证明真实接入。

GH-7 使用固定净化源码快照，来源和差异见 `docs/MIGRATION.md`。保留原状态语义、
文本解析、UI 和参数路径语义。真实配置、数据库、缓存、HTML、日志、截图和依赖不入库。
相对 `--config`、`--out` 按调用 cwd 解析，默认文件与资源按源码位置解析。

使用根目录 `scripts/run_view_checks.py` 执行 Python、JS、self_check 和固定夹具比较；
浏览器检查使用 `tests/browser-fixture.cjs`，原 `browser-smoke.cjs` 仍可用于获准的真实环境。
缺依赖、skip、零执行或渲染失败不得报告通过。真实 Windows＋WSL 验收另行记录准确候选 SHA。
源码保存、提交、发布、安装、合并及服务切换分别确认；禁止自动移动或删除旧数据。
