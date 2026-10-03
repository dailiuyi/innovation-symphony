# Linux 只读采集适配

2026-10-03 用户批准此前审阅的 Linux 采集计划，并指定开发与独立审查均使用
GPT-6.1-sol、两个不同会话。授权只涵盖 dot 云端独立工作区内实现、测试和固定
可审查版本；允许本地提交，不包含 push、PR、合并、生产部署、个人电脑操作或启动
Symphony 领取 Issue。本次基线 main 为 `ca9619cbe64d27b7f6dd1532ba2672b5b6bced8e`。

## 行为和兼容性

- `board.transport` 为 `auto`、`local` 或 `wsl`，缺省 `auto`。Windows 选择 WSL，
  Linux（含 WSL 内）选择本地；显式设置优先，不支持或无效组合直接报错。
- `runtime_source` 统一快照与 rollout 读取。固定本地脚本以同一 `sys.executable`、
  参数数组、隔离 Python 模式执行，复用 `wslpull` 扫描和解析逻辑，没有 shell 拼接。
  旧 WSL 公共入口和 `wsl.exe -e python3 <script>` argv 保留。
- 运行根 glob、显式配置与输出路径保留调用 cwd 语义。只读取匹配运行根中的已知
  产物；目录和文件按描述符打开，不跟随符号链接，拒绝越界和非普通 rollout。
- 本地缓存按来源和规范化路径隔离，大小与 `mtime_ns` 标识版本。完整临时文件写完
  后原子替换；已发布版本保持可读，不被后续失败覆盖。旧 WSL 缓存键不变，
  WSL 在发布前固定不可变上下文副本，并从该副本解析，避免部分失败改变旧上下文。
  本次没有引入缓存清理或数据迁移。
- 出错时不发布新 snapshot 或 context 映射，健康状态为 `error`，保留最后成功时间。
  新一拍成功恢复发布；无运行根匹配是正常 `empty`。不执行回执命令。
- 数据库格式、状态派生、文本解析、页面、HTTP 接口、隐藏推理过滤、ETag 和分页
  保持原合同；未更改控制器与依赖版本。

## 验证边界

`scripts/run_view_checks.py` 保留原 Python/JS/self_check、迁移固定比较和八种入口。
新增跨平台 mocked/synthetic 单元测试可进入冻结 worker；Linux 描述符/符号链接/FIFO
等专用单元用例和真实 Linux 子进程集成均位于独立
阶段 `scripts/view_validation/local_integration.py`，不会解除 worker 的子进程禁令。
迁移预期、冻结测试、基线摘要及 worker 均未修改。

独立阶段只使用自行创建的合成运行根和随机 loopback HTTP 端口，检查真实扫描、
复制、解析、SQLite、HTTP/context、第三方 HTML、故障保留及恢复；比较前后源
SHA256 并停止测试服务。不读取真实 Codex 会话或真实控制器数据。

真实 Windows＋WSL 和浏览器 UI 尚未在本次环境验收。现有浏览器环境的下载/启动限制
不会被报告为通过。代码回归与合成 Linux 集成不能替代生产安装或真实控制器隔离验收。


## 独立审查后的狭窄修复

独立 GPT-6.1-sol 审查复现三项问题：glob 字面 `__LOCAL__` 被模板替换导致采错根；
WSL 第一份缓存更新后第二份读取失败，旧快照引用的上下文被覆盖；新增 Linux
文件系统测试不兼容 Windows 检查。修复只调整模板插值顺序、发布上下文版本保护和
新增测试的跨平台/独立 Linux 分组。精准回归覆盖字面目录与 `True` 诱饵、双会话
部分失败后的旧 HTTP 上下文和恢复、Linux/Windows 分流模拟；不修改冻结预期或降低
原用例门禁。用户曾暂停并要求未来迁移保存云环境，随后明确“继续这边的开发
之后在迁移codex云环境”；本轮继续原工作区，本地候选与未来迁移分别记录。
