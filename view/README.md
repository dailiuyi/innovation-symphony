# innovation-view · Symphony 独立只读看板

## 当前 VM 安装（2026-10-21）

活动 View 位于 guest `/var/lib/innovation-symphony/view`，配置 `/var/lib/innovation-symphony/view.toml`，独立 venv 为 `/var/lib/innovation-symphony/view-venv`；由系统级 `symphony-view.service` 管理。宿主 production SSH 隧道提供 `http://127.0.0.1:8613/`，快照入口 `/api/snapshot`。当前三个入口仅本机可达，下文局域网访问是其他获准部署的说明，不表示本机已对内网开放。不要启动旧宿主 View，也不要把整个 view_root 覆盖为开发目录；源码更新保留数据库、缓存、历史和日志。

实际采集包含迁移历史及 GL-4 的 4 次会话、正式检查和批准 Review。guest 标准 `scripts/run_view_checks.py` 已通过 Python 57、JavaScript 15、Linux 集成 11 项及浏览器合成/迁移检查；环境为 Python 3.12.3、Node 24.21.0、Playwright 1.62.1 与配套 Chromium 151。下文旧环境的浏览器失败保留为历史，不能覆盖这次 guest 结果；真实 Windows/WSL 与用户页面体验仍分别验收。

View 随成功日备份纳入 config/runtime/View 受管归档，SQLite 使用 backup 接口合并 WAL。2026-10-21 的宿主归档清理未删除 View 数据或 VM 内恢复目录；现存成功日备份早于 GL-4，不能当成交付后快照。固定版本、数据与备份位置见 [VM_DEPLOYMENT](../docs/VM_DEPLOYMENT.md)。

`innovation-view` 把 Symphony 运行时中的任务回执、检查证据和 Codex 会话整理成一个 Linear 风格的只读工作台。它用于查看进度和上下文，不启动或控制 Symphony 任务，任务数据仍只读。GH-16 在设置页提供受控仓库双角色默认模型管理，配置写入由 Elixir 负责。

现以固定源码快照放在 innovation-symphony 的 `view/` 下，仍独立运行。`elixir/`
负责调度、编码、检查、Review、恢复、交付和 AppServer；View 负责采集与只读展示，
维护自己的数据库、缓存、日志，启停不影响控制器。来源、迁移差异、夹具预期、
数据保留和回退见 [迁移说明](docs/MIGRATION.md)，本轮结果见
[验证记录](../docs/VALIDATION_VIEW.md)。完整数据合同和状态语义演进不在 GH-7 范围。

> **访问边界：**旧只读模式保留其监听行为；启用模型管理时 View 强制监听 loopback，管理读写均需管理员令牌。获准内网访问通过受控代理并限制来源及仓库范围，配置见 [GH-16 方案](../docs/VIEW_MODEL_SETTINGS.md)。只在获准的本机或内网环境运行。会话上下文可能含内部材料；产品化前需要补上身份与权限控制、敏感信息脱敏和数据保留策略。

## 当前功能

- **任务看板：**四列为“需关注、进行中、待人审、已交付”，并保留状态统计。搜索可匹配任务标题、Issue、仓库和关联 Agent 角色；“仅需关注”筛选与看板/紧凑列表切换保存在本机浏览器。点卡片打开轮次与任务详情，也可直接使用 `#/story/<id>` 深链接。
- **Agent 列表：**会话按时间排序，可切换最近优先或按发生顺序，并按角色筛选。文本搜索覆盖角色、会话 ID、Issue、仓库、运行时、模型、指令和最近输出等已采集摘要。卡片展示会话摘要；缺少的资料按未记录处理。
- **Agent 上下文：**原生侧栏概览提供关联任务、会话记录的下发指令、最近可见输出、源模型和上下文来源。会话记录支持类型筛选、关键词搜索和有界分页；结果节选会明确提示。可复制指令、复制深链接或下载 Markdown 摘要。完整记录仍可通过“完整记录”链接打开旧的 `context-<id>.html` 页面。
- **采集与连接状态：**没有发现运行目录时，状态栏会明确提示，看板各列显示空态。页面分别显示看板服务断开和运行时采集失败，并保留最近一次成功快照；数据过期会单独提示。浅色/深色主题和窄屏布局均可使用。
- **宿主中断：**仅在编码回执的摘要与已闭合操作者完成链一致且没有执行锁时，显示“宿主中断 · 历史编码状态”和等待受审计接续。原回执状态保留；缺失证明或仅时间过旧不会标记中断。
- **设置：**显示本地配置摘要；启用受控管理时读取和保存按仓库 coder／reviewer 默认预设、模型及渠道支持的思考控制。未保存修改、取消、切换提示、失败和版本冲突保留配置，不触发任务。

更多字段、读取上限、未知值语义和产品边界见[Demo 范围与接口草案](docs/DEMO-SCOPE.md)。接口只服务当前原型，不是 Symphony 的稳定契约。

## 运行

真实采集支持 Windows + WSL，以及 Linux（包括直接在 WSL 内运行 Python）。
`board.transport` 默认 `auto`：Windows Python 通过 `wsl.exe` 调用 WSL Python 3；
Linux Python 使用同一解释器启动固定只读扫描脚本并直接复制配置运行根内发现的 rollout。
显式 `local` 仅支持 Linux，显式 `wsl` 仅支持 Windows；无效值或不支持的组合报错，
不会静默改用其他来源。缺少该项的旧配置无需修改。Python 最低 3.11；本轮 Linux
合成集成使用 Python 3.12.14、Node 24.19.0、`codex-transcript-viewer==0.5.0`。
这组历史环境的真实 Windows＋WSL 和浏览器 UI 未完成验收；当前 guest 的合成浏览器检查见文首。
如需 PR 状态，另需可用的 `gh` CLI；没有它时看板仍可运行，但 PR 状态可能未知。
Node 用于 JS 和浏览器检查，正常 Python 看板启动不需要 Node。

以下命令从 `view/` 执行。Windows 可用 `py -3.12` 代替 `python`，建议创建本地
虚拟环境并使用其 Python；依赖目录不入库。

```bash
python -m pip install -r requirements.txt
python app/run.py                 # 默认 8613 端口，按配置周期采集
python app/run.py --port 8614     # 临时更换端口
python app/run.py 10              # 临时将采集间隔设为 10 秒
python app/run.py once            # 执行内置自检后采集一拍并打印摘要
python app/run.py once --out snapshot.json --config app/config.example.toml
```

从主仓根目录使用 `python view/app/run.py`、`python view/app/run.py once`。
默认配置定位 `view/app/config.toml`，不存在时回退 `view/app/config.json`，再回退内置
默认值；静态资源、数据库、缓存和生成 HTML 同样按源码目录定位，与启动 cwd 无关。
显式 `--config PATH` 和 `--out FILE` 保留原语义，按调用 cwd 解析；从主仓根目录传配置
示例时使用 `--config view/app/config.example.toml`。显式不存在的配置仍采用原默认行为，
语法损坏的 TOML/JSON 会失败，不当作有效配置。

首次有效会话无需手工创建 `build/rollouts`，正常采集循环会生成缓存及 HTML。
`once` 保留原行为：自检、采集、数据库更新及可选 JSON 输出，不发布该次会话 HTML、
不启动 HTTP 服务。服务模式在采集后生成完整会话页；CI 单独实际验证此路径。

在本机打开 `http://127.0.0.1:8613/`。局域网访问使用 `http://<本机IP>:8613/`，请确保网络与主机防火墙只允许可信访问。运行参数也可通过 `--config PATH` 指定配置文件。

### 配置

复制 [`app/config.example.toml`](app/config.example.toml) 为 `app/config.toml`，或复制
[`app/config.example.json`](app/config.example.json) 为 `app/config.json` 后按需修改。
两个真实配置均忽略，不提交凭据或本机路径。没有配置文件时使用默认值。示例中的关键项：

```toml
[board]
title = "innovation-view"
interval = 5
port = 8613
runtime_glob = "/var/tmp/innovation-symphony-v0*"
transport = "auto"  # Windows -> wsl；Linux/WSL 内 -> local

[[repos]]
name = "dailiuyi/innovation-symphony"  # 与回执中的 repository 字段一致
alias = "Symphony"
enabled = true
```

不配置 `[[repos]]` 时显示回执中发现的仓库。配置后，未登记的仓库会出现在“待接入”提醒中；`enabled = false` 会隐藏对应任务。修改配置后重启服务生效。

本地模式只读取 `runtime_glob` 和已启用仓库追加 glob 匹配的运行根，包含顶层
`codex-home/sessions` 与 `sandboxes/*/codex-home/sessions`；相对运行根 glob 保留调用
cwd 语义。扫描与复制拒绝越界、符号链接和非普通 rollout，不执行回执中的命令。
扫描子进程及复制有 30 秒超时边界；失败显示采集错误，保留上次成功快照和上下文，
下一拍成功后恢复发布。未匹配运行目录才显示空态。

Linux 缓存按 `local` 来源、规范化绝对路径、大小和纳秒修改时间隔离，因此同长度
更新也会重新复制；使用完整临时文件和原子替换。旧 WSL 缓存文件名不变，新扫描的
WSL 列表带纳秒修改时间；WSL 发布前将完整缓存固定为不可变上下文副本，再从该副本
解析摘要。已发布缓存版本保持只读且不被后续失败覆盖，不自动删除旧版本或移动旧数据。数据库结构、页面、接口、隐藏推理过滤、ETag 和分页不变。

## 验证

从主仓根目录运行完整的仓库内代码检查（输出目录必须不存在）：

```sh
NODE_PATH="$PWD/view/build/browser/node_modules" python -B scripts/run_view_checks.py --output view/build/checks
```

它执行全部 Python unittest、10 项 JS 轮次测试及设置页交互测试、实际 self_check 会话解析与第三方 HTML
生成，以及迁移前固定结果的逐值比较；首次目录、配置路径、重叠采集及异常清理回归
包含在新增检查中。浏览器依赖准备见下文；缺失时完整命令失败。跨平台 Python suite 保留原全部用例和新增分流/WSL 模拟回归；
Linux 描述符、符号链接、FIFO 等专用用例仅在独立 Linux 阶段执行，不在 Windows
suite 中加入 skip。缺依赖、零执行、skip、解析或渲染失败均返回非零。
Linux 上该命令另在独立复制目录和解释器执行真实本地子进程扫描、复制、解析、SQLite、
loopback HTTP/context/HTML 合成集成，以及坏 JSON、权限、消失、超时和恢复检查；前后
源文件 SHA256 必须一致，临时 HTTP 服务收尾停止。冻结 worker 继续禁止真实子进程，
没有放宽原门禁或更新迁移预期。该命令不证明真实运行接入，报告标明浏览器使用
合成数据，真实 Windows＋WSL 未验收；非 Linux 平台明确记录未执行 Linux 集成。
同一标准入口及主仓 CI 执行下述固定浏览器检查，包含设置页原生键盘操作、双角色和
双仓库保存、失败／冲突／未保存提示、刷新及 390px 布局。不改变 Elixir 或隔离门禁。

检查准备交给控制器的候选时，将 `--output` 指向仓库外尚不存在的临时目录，
避免包括 ignored 文件在内的候选库存被检查产物污染。固定浏览器夹具的截图与
smoke 报告写入该结果目录的 `fixture/browser/`，不另写源码树。

完整标准检查需要先准备 Playwright 1.62.1 与其配套 Chromium；以下为既有 CI 的 Node 24.19.0 准备方式，当前 guest 已通过的 Node 24.21.0 组合见文首：

```sh
npm install --prefix view/build/browser --no-audit --no-fund playwright@1.62.1
view/build/browser/node_modules/.bin/playwright install --with-deps chromium
NODE_PATH="$PWD/view/build/browser/node_modules" node view/tests/browser-fixture.cjs view/build/checks/fixture
```

上述 Linux 命令对应 CI；Windows 可安装同版本 Playwright 后设置 `NODE_PATH`（如
PowerShell `$env:NODE_PATH = (Resolve-Path view/build/browser/node_modules).Path`），再运行
相同 Node 命令。早期准备阶段已核实 Playwright 1.62.1 和 Chrome 153.0.8010.54，但浏览器
启动被受限环境拒绝，未通过 UI 断言。该次离线沙箱也未预置 Playwright／Chromium，
本轮浏览器检查失败原因和未执行项见验证记录；不把安装命令当作已验证组合。

夹具入口只在随机 loopback 端口服务脱敏固定数据及本轮实际生成的 HTML，调用原
browser-smoke 检查任务／会话深链接、前进后退、关闭重开、刷新阅读保持、浅深主题、
服务断开恢复及 390px 窄屏，缺浏览器、缺依赖或任一断言失败都判失败。不能用它
替代真实 Windows＋WSL 采集和看板启停不影响控制器的实机证据。

刷新回归在 Playwright 路由内加入固定长记录和会触发更新的内容版本，不写运行数据：
等待新快照进入客户端后核对正在阅读的正文、较早分页、筛选、文本选区和滚动；
再实际打开生成 HTML，等待 `refreshSilent()` 完成，核对正文更新、折叠展开、
活动树节点及阅读位置，并验证损坏响应、503 和重试恢复。生成页按实际的整页滚动
检查正文位置；120 个匹配树节点保证筛选后列表仍溢出，设置位置前断言两处都有
滚动空间，并保持可见的正文阅读锚点。成功报告和日志记录实际 Node、Playwright、
浏览器版本及可执行文件路径。固定迁移预期保持不变。

也可在 `view/` 内单独运行 Python API 和 JS 测试：

```bash
python -m unittest discover -s tests -v
node --test tests/rounds.test.mjs
node --test tests/model-settings.test.mjs
```

浏览器烟雾检查需要 Node.js、本机 Playwright、Chrome，以及至少一条任务和一条已采集的编码会话。先在一个终端启动服务，再在另一个终端运行脚本；把 `<Chrome 可执行文件路径>` 替换为本机路径：

```bash
python app/run.py --port 8614
node tests/browser-smoke.cjs --url http://127.0.0.1:8614 --chrome "<Chrome 可执行文件路径>"
```

真实环境 smoke 的截图默认保存到 `build/_screenshots/`，可用 `--out <仓库外目录>`
指定输出位置。运行烟雾检查后还要按[手工检查清单](docs/DEMO-SCOPE.md#手工浏览器检查)核对交互和窄屏表现。清单是待执行步骤；这里不代表浏览器验收已经完成。

## 代码结构

```text
app/run.py               采集循环与 HTTP 服务入口
app/symphony_board/      local/WSL 只读来源适配、数据派生、SQLite 状态与 API
app/web/                 页面壳、原生 ES modules 与 CSS
tests/                   Python API 测试与浏览器烟雾检查
docs/DEMO-SCOPE.md       Demo 边界、接口草案与手工验收清单
data/board.db            本机运行时生成的 SQLite 文件（gitignored）
build/rollouts/          会话文件本地缓存（gitignored）
prototypes/              旧版完整会话 HTML（gitignored）
```

配置更改后需重启看板。数据库、rollout 缓存、生成页、截图、日志及依赖均为本地数据。
不自动删除旧数据库或搬移旧配置；保留、切换及回退须按迁移说明操作，不自动切换服务。

## GitLab 任务展示与交付状态

View 同时识别 `GH-<number>` 与 `GL-<iid>` 的任务指令、工作区和会话关联，按完整标识区分同号的 GitHub/GitLab 任务。新回执读取 `issue_identifier`、`tracker_kind`、`issue_url`，仓库缺省时读取 `issue_native_ref.project_path`（支持子组路径）；缺少这些字段的历史 GitHub 回执保持原标识和深链接。

GitLab 的交付链接沿用回执 `pull_request` 字段，`/-/merge_requests/<iid>` 在界面显示为 MR，Issue 详情保留回执提供的原实例链接。View 通过 GitLab REST API 查询 MR 真实状态（`merged`、`opened`、`closed`）。为防止凭据外发或明文传输，私有 Token 仅限在协议为 HTTPS 且目标主机属于白名单（环境变量 `GITLAB_TRUSTED_HOSTS` / `GITLAB_HOST` / `GITLAB_INSTANCE` 或本地受信任实例 `81.71.154.125:8443` 等）时发送，未绑定实例或 HTTP 明文请求不带 Token，重定向限制跨主机并自动剥离凭据；MR 状态缓存按主机地址隔离。状态为 `merged` 的任务正确推进至“已交付”（Done）列。

## 检查证据与 Agent 轮次匹配

- **检查证据**：采集时同时收集 `check-*.log` 与 `check-*.json`，解析退出码、检查类别、错误信息（如超时）与命令输出，支持单轮根目录与子目录 `round-N/` 智能关联。检查结果使用独立字段，不设置 `approved`，避免将检查通过误当作 Review 批准；超时及非通过状态准确判定为失败。
- **无沙盒 MVP 模式会话对齐**：当控制器回执无显式沙盒 attempt 绑定时，前端 `roundsModel` 仅在单一轮次任务中将编码与 Review Agent 会话归入该轮；多轮任务中缺少显式 round 的会话保持未关联，不按会话出现顺序猜测轮次。


