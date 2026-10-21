# 2026-10-16 合并后重新构建记录

来源：用户要求「创建一个 pr，我来处理合并，合并之后你拉取最新的 main，重新构建，我来补足其他的配置」。本次只做拉取与构建，不安装、不切换正在运行的服务，不改用户维护的配置。

## 合并

- PR [#19](https://github.com/daliuyi/innovation-symphony/pull/19)「IS-101: 接入 GitLab 单项目 MVP 交付链路」，2026-10-16T02:52:17Z 合并，合并提交 `e72d4e36c78ae307c875e680e348a67560ecb6fd`。
- PR 上 CI 两个作业都通过：`make-all` 5m19s、`view` 1m16s。`make-all` 会在固定版本 Codex 客户端下跑完整 `make check-clean`，`view` 会跑含 Playwright 的浏览器验收，这两项补上了本机容器缺 Codex 与缺 Chromium 时无法覆盖的证据。
- 本地 `main` 从 `119b13b` 快进到 `e72d4e3`。用户工作区当前分支仍是 `codex/rootless-readiness-and-session-continuity`（未提交的 `docs/OPERATIONS.md`、`README.md.bak`、前两次部署记录都保留），没有切换检出分支。

## 重新构建

新 release 目录：`.local/releases/e72d4e3-20261016T105358/`。

源码快照直接用 `git archive origin/main` 展开，得到的是 main 的干净树；`elixir/mix.lock` 与上一次构建快照 `119b13b-20261012` 完全一致，因此复用了该目录下的 `deps` 与 `_build` 缓存，没有联网取依赖。escript 用同一个固定镜像 `elixir@sha256:c307fd8416a003525e405860a7bd33488433790647dd5ce74c0a7f44ddea2445`（Elixir 1.19.6 / OTP 28）以 `MIX_ENV=dev mix escript.build` 重建。

该镜像里没有 Hex、git、make/gcc，也没有 CA 证书，所以构建时临时安装 Hex 并把宿主机的 `/etc/ssl/certs` 只读挂进容器完成 TLS，构建过程本身完全离线。

产物：`elixir/bin/symphony`，5,877,979 字节，SHA256 `6898aab2055f2a62095f30d6f4edd4b0f058e7cd56394a78315a490701890b0f`（上一版 `0d2b86b4…`，5,867,801 字节）。

## 验证

- 门禁：快照内 `mix format --check-formatted`、`mix specs.check`、`mix credo --strict` 全部通过，Credo 0 issues。
- 启动冒烟：同一个固定镜像里用隔离的临时 WORKFLOW（workspace root 指向 /tmp）把新 escript 起在 4101 端口，token 仍按启动器的方式经 stdin 传入、不落盘。`/api/v1/state` 与首页都返回 200，`blocked/running/retrying` 均为 0；冒烟容器已停止并清理，4000/8613 未受影响。

构建成功不等于已部署：正在运行的控制器和 View 仍然使用 `48fda21-20261014T153540` 那份 release，服务没有重启，配置没有改动，`mvp.enabled=false` 保持关闭。

## 与上一次快照的差异

上次快照是工作区拷贝，夹带了 `view/app/symphony_board/__pycache__/*.pyc`；本次是 git archive，不含这些缓存。另外分支上的 `48fda21`（README 与 `assets/readme/hero.svg` 插图）**没有**合并进 main，所以本次快照也不含该插图；README 插图要进 main 需要单独再开 PR。

## 待办（用户补足后再决定安装）

1. GitLab 实例的可信 CA（PEM）。
2. 一个有读取与推送权限的受限 token，只以环境引用写入配置。
3. GitLab 版 WORKFLOW，可从 release 内的 `elixir/WORKFLOW.gitlab.example.md` 改写，并单独决定是否打开 `mvp.enabled`。
4. 补齐后再决定是否把启动器指向新 release 并重启服务；真实实例的只读预检与一次受控任务仍需单独授权后执行。

机器可读记录：`.local/deployment-20261016T105358/deployment-result.json`。

## 2026-10-16 16:28 执行工具链集成与服务正式上线

来源：用户要求「为docker容器中加入git codex python3这些依赖 然后读一下gitlab这个仓库 安装有必要的依赖 如npm和java」，并在方案出具后明确确认「Implement the plan」。

1. **依赖审查**：通过 GitLab API 遍历 `innovation/luca` 仓库文件，确认后端为单文件 Java（`backend/src/LukaV2Server.java`），需 JDK 17+ 且包含 `javac`；后台测试与脚本需要 Python 3 及 `numpy`；同时按需安装 Node.js 与 npm。
2. **容器构建**：编写 `.local/Dockerfile.controller`，基于现有 Elixir 运行镜像安装 `git`、`python3`、`python3-numpy`、`openjdk-21-jdk-headless`、`nodejs`、`npm`、`curl` 与 `ca-certificates`，生成本地镜像 `innovation-symphony-controller:worker-tools`。
3. **启动器调整**：修改 `.local/start-symphony.sh`，运行镜像切换为 `worker-tools`，只读挂载宿主机静态 `codex`（0.163.0）至 `/usr/local/bin/codex`，挂载宿主机 `~/.codex` 并配置 `CODEX_HOME`；调整 `/tmp` 挂载以满足编译需求。
4. **服务验证**：重启 `innovation-symphony-controller.service` 与 `innovation-symphony-view.service`，实测端口 4000 与 8613 均返回 HTTP 200；在运行容器内实跑全部工具链版本命令验证通过。

## 2026-10-16 16:45 View 看板适配 GitLab 仓库接入

来源：用户指出看板左侧边栏「仓库」显示「看板上还没有仓库数据」，要求接入该仓库并完成适配。

1. **配置接入**：更新 `.local/view-config.toml`，新增 `innovation/luca`（别名 `Luca`），将 `runtime_glob` 调整为 `"/var/tmp/innovation-symphony*"` 覆盖当前的 linux-runtime 目录。
2. **前端侧栏展示优化**：修改 `view/app/web/assets/js/chrome.js` 与 `data.js`，将 `state.boot.repos` 已配置启用的仓库直接纳入侧栏展示；暂无任务时显示数量为 0 并允许点击筛选，不再因零任务状态折叠为「看板上还没有仓库数据」。
3. **Issue 标识支持**：恢复并同步 `common.py` 与 `collector.py` 中对 GitLab `GL-\d+` Issue 编号与提取逻辑的适配。
4. **服务同步验证**：将 `.local/launch-view.py` 指向 `e72d4e3-20261016T105358`，重启 `innovation-symphony-view.service`，实测 `/api/bootstrap` 正常返回两仓库且 `collection.status` 为 `ok`。

## 2026-10-16 20:55 最新 main 分支（caf9d0f）全量上线与验证

来源：用户要求「部署当前最新的main分支的代码 确保前后端都是在线的 能直接领取issue跑完全流程的那种」，并在方案确认后执行「Implement the plan」。

1. **版本与构建**：
   - 源码快照来自 `main` 分支最新提交 `caf9d0f`（包含无沙盒会话持久化、沙盒去重与修剪策略、Review schema 容错以及 GitLab 自签 CA 验证增强）。
   - 快照目录：`.local/releases/caf9d0f-20261016T205328/`。
   - 在 `innovation-symphony-controller:worker-tools` 镜像内离线构建 `MIX_ENV=dev mix escript.build`，产出 `elixir/bin/symphony`（SHA256: `e9eb1cf548d49f5b752a999301f51ba41b15870e5a65437440d734aefc12dd8f`）。
   - 门禁回归：`mix format --check-formatted` 通过；`mix test` 22 项单元测试 0 失败。

2. **启动引用与服务切换**：
   - `.local/start-symphony.sh` 指向新 release 的 `elixir/bin`。
   - `.local/launch-view.py` 指向新 release 的 `view/app`。
   - `.local/start-model-settings.py` 指向新 release 的 `elixir/bin`。
   - `.local/deployment-current-path.txt` 更新为最新路径。
   - 通过 `systemctl --user restart` 重启控制器、View 看板与模型管理三个服务，令牌经 stdin 正常安全喂入。

3. **在线就绪实测**：
   - 控制器（`127.0.0.1:4000/api/v1/state`）：HTTP 200，running/retrying/blocked 均为 0。
   - 看板（`127.0.0.1:8613/api/bootstrap`、`/api/snapshot`）：HTTP 200，Luca 仓库与 GL-1 全流程已正常关联展示。
   - 模型设置服务（`127.0.0.1:8765/`）：HTTP 401（未带 token，鉴权机制生效）。
   - 真实链路预检：容器内执行 `--preflight` 返回 `{"status":"passed","mode":"preflight","issue_count":0}`，GitLab 轮询就绪。

## 2026-10-17 17:21 Review.schema(0) 严格模式修复与全量热重载（8037ec3）

来源：解决单轮审查 `limit == 0` 时调用大模型报错 `Invalid json schema: missing field items` 导致的阻断。
依据：OpenAI Strict Structured Outputs 规范要求数组字段必须包含 `items`，且所有顶层 properties 必须纳入 `required`。

1. **代码与契约修复**：
   - 修改 `Review.schema(0)`：为 `criteria` 补全 `@criterion`，为 `blockers` 补全 `@blocker`，并将 `["criteria", "blockers"]` 纳入 `required`。
   - 同步更新 `mvp_review_external_test.exs`、`mvp_executor_test.exs` 与 `mvp_rework_contract_test.exs` 单元测试。
   - 门禁回归：`mix format --check-formatted` 通过；针对性审查与执行器回归用例 108 tests 全部通过。
   - 本地提交：分支 `fix-review-schema-items`，Commit `8037ec3`。

2. **构建与服务切换**：
   - 快照目录：`.local/releases/8037ec3-20261016T213700/`。
   - 容器离线构建：`MIX_ENV=dev mix escript.build`，产出 `elixir/bin/symphony`（SHA256: `7d070edf8961e82c1f2bd3ee6ff0cbfc0e21ae5210c9dcaab4e6ab6e35474bfb`）。
   - 启动引用切换：`.local/start-symphony.sh`、`.local/launch-view.py`、`.local/start-model-settings.py` 及 `.local/deployment-current-path.txt` 全部切到新目录。
   - 通过 `systemctl --user restart` 重启三项服务。

3. **在线就绪实测**：
   - 控制器（`127.0.0.1:4000/api/v1/state`）：HTTP 200，running/retrying/blocked 均为 0。
   - 看板（`127.0.0.1:8613/api/bootstrap`）：HTTP 200，Luca 与 Symphony 两仓库 collection 状态为 `ok`。
   - 模型设置服务（`127.0.0.1:8765/`）：HTTP 401（未带 token，鉴权拦截生效）。
   - 真实链路预检：容器内执行 `--preflight` 返回 `{"status":"passed","mode":"preflight","issue_count":1}`，GitLab 自动发现链路正常。

## 2026-10-17 17:52 前端独立热重载与 GitLab MR 状态真实拉取验证

来源：用户要求部署 main 分支最新前端更改，且后端任务不中断。
依据：`view/` 服务独立运行，具备自身采集与缓存，启停不影响控制器（`AGENTS.md`）。

1. **改动同步与发布**：
   - 同步 `view/app` 核心改动：`derive.py`（增加 `fetch_gitlab_mr` 真实查询 GitLab MR 状态、安全重定向与 CA 支持）、`rounds.js`（修复单轮控制器任务会话关联）与 `wslpull.py`。
   - 保留运行中发布目录 `.local/releases/a8ef726-20261017T172900/view/` 下的 `build/` 数据库与缓存，仅同步前端代码。
   - 仅重启前端服务：`systemctl --user restart innovation-symphony-view.service`，后端控制器服务 `innovation-symphony-controller.service` 持续运行未受任何干扰。

2. **在线就绪实测**：
   - 后端任务零中断：后端控制器持续运行，GL-2 全生命周期成功推进完毕，Reviewer 审查通过并已成功在 GitLab 创建 Draft MR #2，状态转为 `awaiting_human`。
   - 前端接口（8613 端口）：`/api/bootstrap` 返回 HTTP 200，`/api/snapshot` 实测成功拉取并关联 GitLab 真实 MR 状态：
     - GL-1 MR #1：准确解析为 `state: "merged"`、`draft: false`、完整标题。
     - GL-2 MR #2：准确解析为 `state: "open"`、`draft: true`、标题 `'Draft: GL-2: feat: add public /api/version endpoint, method rejection and update API.md'`。
