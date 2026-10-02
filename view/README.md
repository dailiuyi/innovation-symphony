# innovation-view · Symphony 独立只读看板

`innovation-view` 把 Symphony 运行时中的任务回执、检查证据和 Codex 会话整理成一个 Linear 风格的只读工作台。它用于查看进度和上下文，不启动或控制 Symphony 任务，也不编辑运行时配置。

现以固定源码快照放在 innovation-symphony 的 `view/` 下，仍独立运行。`elixir/`
负责调度、编码、检查、Review、恢复、交付和 AppServer；View 负责采集与只读展示，
维护自己的数据库、缓存、日志，启停不影响控制器。来源、迁移差异、夹具预期、
数据保留和回退见 [迁移说明](docs/MIGRATION.md)，本轮结果见
[验证记录](../docs/VALIDATION_VIEW.md)。完整数据合同和状态语义演进不在 GH-7 范围。

> **Demo 与安全边界：**服务没有身份认证，并监听本机所有网络接口。只在受信任的本机或局域网环境运行。会话上下文可能含内部材料；产品化前需要补上身份与权限控制、敏感信息脱敏和数据保留策略。

## 当前功能

- **任务看板：**四列为“需关注、进行中、待人审、已交付”，并保留状态统计。搜索可匹配任务标题、Issue、仓库和关联 Agent 角色；“仅需关注”筛选与看板/紧凑列表切换保存在本机浏览器。点卡片打开轮次与任务详情，也可直接使用 `#/story/<id>` 深链接。
- **Agent 列表：**会话按时间排序，可切换最近优先或按发生顺序，并按角色筛选。文本搜索覆盖角色、会话 ID、Issue、仓库、运行时、模型、指令和最近输出等已采集摘要。卡片展示会话摘要；缺少的资料按未记录处理。
- **Agent 上下文：**原生侧栏概览提供关联任务、会话记录的下发指令、最近可见输出、源模型和上下文来源。会话记录支持类型筛选、关键词搜索和有界分页；结果节选会明确提示。可复制指令、复制深链接或下载 Markdown 摘要。完整记录仍可通过“完整记录”链接打开旧的 `context-<id>.html` 页面。
- **采集与连接状态：**没有发现运行目录时，状态栏会明确提示，看板各列显示空态。页面分别显示看板服务断开和运行时采集失败，并保留最近一次成功快照；数据过期会单独提示。浅色/深色主题和窄屏布局均可使用。
- **设置：**只读显示本地配置摘要和待接入仓库。

更多字段、读取上限、未知值语义和产品边界见[Demo 范围与接口草案](docs/DEMO-SCOPE.md)。接口只服务当前原型，不是 Symphony 的稳定契约。

## 运行

真实采集需要 Windows + WSL（可访问配置的 Symphony 运行目录）；Windows Python
通过 `wsl.exe` 调用 WSL Python 3 读取文件。Python 语法最低 3.11，实际离线验证
组合为 Python 3.12.3、Node 24.19.0、`codex-transcript-viewer==0.5.0`。
准备阶段 Windows 曾验证 Python 3.12.5 的代码检查；本轮没有真实 WSL 条件。
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

[[repos]]
name = "dailiuyi/innovation-symphony"  # 与回执中的 repository 字段一致
alias = "Symphony"
enabled = true
```

不配置 `[[repos]]` 时显示回执中发现的仓库。配置后，未登记的仓库会出现在“待接入”提醒中；`enabled = false` 会隐藏对应任务。修改配置后重启服务生效。

## 验证

从主仓根目录运行完整的仓库内代码检查（输出目录必须不存在）：

```sh
python -B scripts/run_view_checks.py --output view/build/checks
```

它执行全部 Python unittest、10 项 JS 轮次测试、实际 self_check 会话解析与第三方 HTML
生成，以及迁移前固定结果的逐值比较；首次目录、配置路径、重叠采集及异常清理回归
包含在 Python suite 中。缺依赖、零执行、skip、解析或渲染失败均返回非零。
该命令只证明代码与固定夹具检查，报告明确列出未执行的浏览器和真实 Windows＋WSL。
主仓 CI 独立 View job 另执行下述浏览器检查，不改变 Elixir 或隔离门禁。

浏览器固定依赖为 Playwright 1.62.1 与其配套 Chromium，需 Node 24.19.0：

```sh
npm install --prefix view/build/browser --no-audit --no-fund playwright@1.62.1
view/build/browser/node_modules/.bin/playwright install --with-deps chromium
NODE_PATH="$PWD/view/build/browser/node_modules" node view/tests/browser-fixture.cjs view/build/checks/fixture
```

上述 Linux 命令对应 CI；Windows 可安装同版本 Playwright 后设置 `NODE_PATH`（如
PowerShell `$env:NODE_PATH = (Resolve-Path view/build/browser/node_modules).Path`），再运行
相同 Node 命令。准备阶段已核实 Playwright 1.62.1 和 Chrome 153.0.8010.54，但浏览器
启动被受限环境拒绝，未通过 UI 断言。本离线沙箱也未预置 Playwright／Chromium，
本轮浏览器检查失败原因和未执行项见验证记录；不把安装命令当作已验证组合。

夹具入口只在随机 loopback 端口服务脱敏固定数据及本轮实际生成的 HTML，调用原
browser-smoke 检查任务／会话深链接、前进后退、关闭重开、刷新阅读保持、浅深主题、
服务断开恢复及 390px 窄屏，缺浏览器、缺依赖或任一断言失败都判失败。不能用它
替代真实 Windows＋WSL 采集和看板启停不影响控制器的实机证据。

也可在 `view/` 内单独运行 Python API 和 JS 测试：

```bash
python -m unittest discover -s tests -v
node --test tests/rounds.test.mjs
```

浏览器烟雾检查需要 Node.js、本机 Playwright、Chrome，以及至少一条任务和一条已采集的编码会话。先在一个终端启动服务，再在另一个终端运行脚本；把 `<Chrome 可执行文件路径>` 替换为本机路径：

```bash
python app/run.py --port 8614
node tests/browser-smoke.cjs --url http://127.0.0.1:8614 --chrome "<Chrome 可执行文件路径>"
```

脚本截图保存到 `build/_screenshots/`。运行烟雾检查后还要按[手工检查清单](docs/DEMO-SCOPE.md#手工浏览器检查)核对交互和窄屏表现。清单是待执行步骤；这里不代表浏览器验收已经完成。

## 代码结构

```text
app/run.py               采集循环与 HTTP 服务入口
app/symphony_board/      运行时读取、数据派生、SQLite 状态与只读 API
app/web/                 页面壳、原生 ES modules 与 CSS
tests/                   Python API 测试与浏览器烟雾检查
docs/DEMO-SCOPE.md       Demo 边界、接口草案与手工验收清单
data/board.db            本机运行时生成的 SQLite 文件（gitignored）
build/rollouts/          会话文件本地缓存（gitignored）
prototypes/              旧版完整会话 HTML（gitignored）
```

配置更改后需重启看板。数据库、rollout 缓存、生成页、截图、日志及依赖均为本地数据。
不自动删除旧数据库或搬移旧配置；保留、切换及回退须按迁移说明操作，不自动切换服务。
