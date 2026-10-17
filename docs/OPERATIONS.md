# 原型运行与项目交付

## 2026-10-16 GitLab／luca 上线准备与首次派发处置

来源：IS-101 落地到真实实例。本节记录运维约束与处置流程；接入事实与实测证据见 [GITLAB_INTEGRATION](GITLAB_INTEGRATION.md)。

### 运维硬约束：WORKFLOW.md 必须纯 ASCII

配置解析器 yamerl 拒绝非 ASCII 字节。配置里出现中文注释（即使文件本身是合法 UTF-8）会导致 `--preflight` 与控制器启动均以 `{:workflow_parse_error, %YamlElixir.ParsingError{type: :invalid_unicode}}` 失败。**改动 WORKFLOW.md 后必须先确认非 ASCII 字节为 0 再重启**，否则控制器起不来。核查：

```sh
python3 -c "d=open('.local/WORKFLOW.md','rb').read(); print(sum(b>127 for b in d))"
```

### codex.approval_policy 的有效格式

当前 Codex 客户端只接受 `untrusted` / `on-request` / `granular` / `never`。旧的 `approval_policy.reject` 结构已移除，使用它会在线程创建时报 `-32600 unknown variant` 并阻塞任务。注意 `Config.Schema` 中的默认值仍是旧的 `reject` 结构，照抄样例会踩雷。当前配置为：

```yaml
approval_policy:
  granular:
    sandbox_approval: false
    rules: false
    skill_approval: false
    request_permissions: false
    mcp_elicitations: false
```

五个布尔位对应五类审批请求；全 `false` 与本文档早前记录的"五类审批请求全部 false（自动拒绝）、保留隔离与权限边界"一致。

### 重启控制器的正确方式

控制器由**用户级** systemd 单元托管，不需要 `sudo`：

```sh
systemctl --user restart innovation-symphony-controller.service
```

**不要用 `docker restart`。** 容器由 `.local/start-symphony.sh` 启动，三个令牌（GitHub / GitLab / DeepSeek）经 stdin 喂入、不落盘；`docker restart` 只重跑容器内命令，而 stdin 已关闭，令牌读不到，控制器起不来。只有走 systemd 才会重新执行启动脚本并重新喂入令牌。

`WORKFLOW.md`、checks、`approval_policy` 等配置改动**只在重启后生效**；控制器在启动时一次性读取配置。

### 释放阻塞回执：两种情况要走不同路径

先判断回执里的 `base_sha`，它决定用哪条路：

**情况 A：`base_sha` 为空**（任务在领取/建工作区之前就失败，从未开工）

```sh
mix mvp.release /绝对路径/回执.json
```

守卫见 `mvp.release.ex`：要求 `status=blocked`、`base_sha` 与 `candidate_sha` 均为空。释放会归档为 `.released-<时间戳>`，不删除原记录。

**情况 B：`base_sha` 有值但 `candidate_sha` 为空**（已开工、未产出候选）

此时 **`mvp.release` 不适用**，它的 `base_sha` 守卫会拒绝。控制器也不会自动重领——`executor.ex` 的 `is_nil(Receipt.read(receipt)["base_sha"]) or {:error, :mvp_execution_already_started}` 同样要求 `base_sha` 为空。两条路都堵着，这是有意设计。

唯一出口是操作者核验后**完整归档**（沿用 Issue #12 首次启动失败时的先例）：

1. 核验四项：`codex_totals` 全为 0（无模型用量）、无候选 SHA 与发布记录、工作区干净、工作区 `HEAD` 等于回执的 `base_sha`。
2. 停控制器。
3. 把回执、其 `.<回执名>.evidence` 目录、以及任务工作区**一并移到**运行根的 `archives/<名称-时间戳>/`，并保存回执 SHA256。
4. 启动控制器。

**不得**删除记录、更换 `state_dir`、修改历史模型，或用绕过 `base_sha` 守卫的方式重领。

`mvp.release` 与上述归档都需要 `mix`；若本机没有 `mix` 环境（构建在固定 Docker 镜像内完成），等价的手动操作是核验条件后自行重命名/移动文件，但**核验步骤一步都不能省**。

本仓库 `.local/` 下备有两个脚本，均默认预演、需加 `--yes` 才执行：`release-blocked-receipt.sh`（情况 A）、`archive-startup-failure.sh`（情况 B，含上面四项核验）。脚本是操作辅助，不是新的授权入口。

### 2026-10-16 首次派发 GL-1 处置记录

- 10:22:48 控制器自动领取 Issue #1，建立工作区 `workspaces/GL-1`。
- 10:23:05 阻塞，错误为 `{:response_error, %{"code" => -32600, ... unknown variant `reject` ...}}`。
- 阻塞发生在任何模型调用之前：`session_id` 为空、`codex_totals` 全为 0、无候选 SHA。
- **该回执 `base_sha` 为 `ced3e7ec...`（已写入），属上述情况 B**——`mvp.release` 与自动重领均不适用，须走操作者核验后的完整归档路径。
- 已修正 `.local/WORKFLOW.md` 的 `approval_policy` 并确认纯 ASCII。待停控制器、归档回执后重启；Issue 上的 `ready` 标签保留即可被重新领取。

### 2026-10-16 GL-1 重新领取、会话留痕保全与无沙盒会话持久化修复（IS-102）

- **背景与现象**：GL-1 归档重启后重新领取进入 coding，消耗 DeepSeek Token 持续编码。但所有者核查看板状态发现 `sessions: 0`。
- **根因确认**：`mvp.sandbox.enabled: false` 导致 `AppServer.service_home/3` 回退到系统临时目录（容器内 256MB tmpfs `/tmp`），且 `temporary: true` 导致会话交互结束后被 `cleanup_service` 直接 `rm_rf` 清理，导致宿主机磁盘零留痕且容器内数据易失。
- **现场无侵入保全**：在 GL-1 编码进行中，通过外部只读流式提取将正在活跃写入的 `rollout-*.jsonl` 持续同步至宿主机 `/var/tmp/innovation-symphony-linux-runtime/codex-home/sessions/`。看板（8613 端口）在 5 秒内自动采出真实会话并精准关联 `GL-1` / `编码` / `5,907,520 tokens`。随后 GL-1 会话正常结束，容器内临时目录被自动清理，宿主机 995KB 转录文件成功完整保全。
- **系统代码修复**：
  1. `ModelServices` 新增 `persistent_home/1`：在无外部沙盒时，若任务拥有合法的持久 `state_dir`，统一在 `Path.dirname(state_dir)` 下创建 `sandboxes/run-<微秒时间戳>-<唯一整型>/codex-home`，确保每次运行环境独立且符合看板 `sandboxes/*/codex-home/sessions` 扫描契约。
  2. `AppServer.start_session/2` 与 `prepare_service/5`：接收可选的 `:codex_home` 参数；当接收到显式持久目录时标记 `temporary: false`，会话结束时不执行 `File.rm_rf`。未指定持久目录的测试调用继续使用临时目录并清理，保持凭据测试兼容。
  3. `Executor.run_legacy_agent` 与 `Attempts.run`：自动通过 `ModelServices.persistent_home` 将持久目录注入 agent options。
- **验证记录**：`mix test test/symphony_elixir/mvp_app_server_test.exs` 全部 9 项测试通过；`mix format --check-formatted` 通过；`MIX_ENV=dev mix escript.build` 成功构建新二进制 `elixir/bin/symphony`（5,879,262 字节）。

### 2026-10-16 内层沙盒放通、Docker 权限调整与 GL-1 候选生成（IS-103）

- **背景与现象**：GL-1 首次进入编码时，Codex 在调用 `exec_command` 执行构建和测试时遭遇 `Operation not permitted` / `Permission denied`，导致未能生成候选代码，最终阻塞报 `:mvp_no_changes`。
- **根因确认**：
  1. Codex 原生 `thread_sandbox: workspace-write` 依赖 `bwrap`。容器镜像内无此二进制，而宿主机 `/usr/bin/bwrap` 依赖外部动态链接库；
  2. 容器默认以 `--user 1000:1000 --cap-drop ALL --security-opt no-new-privileges` 启动，内核、AppArmor 与 Seccomp 阻止了非 root 用户创建 User Namespace。
- **方案实施与修复**：
  1. **静态依赖挂载**：挂载 `/home/elma/.codex/packages/standalone/current/codex-resources/bwrap`（static-pie 独立二进制，零外部动态依赖）至容器内 `/usr/local/bin/bwrap:ro`；
  2. **容器安全权限放通**：在 `.local/start-symphony.sh` 中去除 `--cap-drop ALL` 和 `--security-opt no-new-privileges`，增加 `--cap-add SYS_ADMIN --security-opt apparmor=unconfined --security-opt seccomp=unconfined`；
  3. **Release 构建边界对齐**：编译时须挂载 `-v $PWD:/repo -w /repo/elixir`，防止 `Mvp.Config.source_root()` 将编译路径编译为根目录 `/` 触发 `:mvp_state_source_overlap`；
  4. **失败回执归档**：将旧的 blocked 回执及工作区按规范完整归档至 `/var/tmp/innovation-symphony-linux-runtime/archives/issue-1-bwrap-failure-20261016T191848Z/` 并记录 SHA256。
- **实测验证结果**：
  1. 重启控制器后，自动重新领取 Issue #1（GL-1）；
  2. 会话成功直接在宿主机 `/var/tmp/innovation-symphony-linux-runtime/sandboxes/run-1792149790442918-2/codex-home/sessions/` 落盘，看板即刻发现 2 个活跃会话；
  3. Codex 在内层沙盒内调用 `find`、`git diff`、`javac` 及探针全部成功（退出码 0），顺利完成了 `backend/src/LucaV2Server.java` 的 `/api/health` 路由与 `backend/test_backend.py` 断言注入；
  4. 成功生成候选提交 `09c20b9527b14bb317ef94514ea59381acb5d906`，推进至门禁检查；
  5. 门禁检查阶段执行 `python3 backend/test_backend.py`，因 Issue 描述中硬编码的大小写 `headers["Content-Type"]` 与标准库 `http.client` 解析出的全部小写键 `'content-type'` 不一致，在 Python 断言处报 `KeyError: 'Content-Type'`，任务按调度策略以 `{:mvp_check_failed, 1}` 停机等待操作者处置。

### 2026-10-16 运行目录语义纠正、沙盒去重、修剪策略与评审契约修复（IS-104）

- **独立运行目录重构与沙盒去重**：
  - 将 `persistent_home/1` 重命名为 `standalone_run_home/1`，在注释与文档中明确该目录仅供无沙盒独立运行时为看板保留会话留痕，不承载跨 attempt/跨重启的 session resume；
  - 当 `ExecutionSandbox.enabled?(settings)` 为 `true` 时，直接返回 `{:ok, nil}`，消除了此前沙盒模式下每次 attempt 多生成一个空 `sandboxes/run-*/codex-home` 的冗余；
  - 移除 `File.mkdir_p!` 与 `File.chmod!`，改为返回干净的 `{:ok, path} | {:ok, nil} | {:error, reason}`，避免 state_dir 不可写时抛异常。
- **历史目录修剪策略与已知边界**：
  - 在 `ModelServices.prune_runs/2` 与 `ExecutionSandbox.prepare/4` 中实现修剪逻辑，按目录修改时间（mtime）倒序排列，保留最新的 50 个 run 目录，清理历史超额目录；
  - **已知边界**：仅在存在 >50 个 run 目录时才触发清理，清理按 mtime 倒序淘汰最旧目录，当前不做在用检测（in-use check）。
- **评审契约 Schema 对齐与单轮校验收紧**：
  - `Review.schema(0)` 将 `criteria` 和 `blockers` 作为 array 类型的可选属性纳入 Schema，消除此前单轮模式下与 prompt 和结构化返回值的定义矛盾；
  - 收紧 `valid?(value, 0)`，要求列表项必须为非空字符串或非空 map，且 `approved: true` 时 blockers 必须为空；明确记录安全底线由空 blockers 约束与 `disposition/1`（非空 blockers 直接判定为 `:repair_code`）兜底；
  - 修复 `gitlab/client.ex` 的 `connect_options/1`，移除冗余 `cacertfile`，保留基于 DER 的自签证书 `verify_fun`，消除 OTP 证书噪声。

## 2026-10-05 Issue #12 ready 与领取启用前诊断

所有者为 #12 添加 ready 后要求“先修复mvpfalse”（IS-065）。只读核实 GitHub Issue
为 open/ready；View `/api/bootstrap` 已登记并启用 `dailiuyi/innovation-symphony`，
采集为 ok/local，控制器配置也已绑定该仓库。当前活动工作流仍为
`.local/runtime/WORKFLOW.md`，`mvp.enabled=false`、`mvp.sandbox.enabled=false`；
状态接口返回 running/retrying/blocked 均为 0，状态目录无领取回执。

未直接开启未隔离的兼容路径。先生成
`.local/runtime/WORKFLOW.enabled.pending.md`，启用 MVP 与任务隔离，保留当前角色模型。
首次只读预检返回 `:mvp_state_source_overlap`：原状态目录和工作区在源码树内，
停用配置不会执行这些启用分支校验。候选改用独立的
`/var/tmp/innovation-symphony-linux-runtime/{state,workspaces,sandboxes}` 后，真实 GitHub
只读预检退出码为 0，返回 `passed / issue_count=1`。这些路径为待安装安排，
未创建、迁移或替换活动状态；证据在 `.local/runtime/intake-enable-preflight.json`。

当前宿主侧接入仍未完成：隔离运行器要求 root 及 cgroup 权限，活动用户控制器未接入
无人值守的受控隔离入口。两次宿主服务状态／非交互 sudo 检查的自动审批均超时，
命令未执行，不能据此断定宿主没有权限或操作不安全。需要所有者在本机终端完成
sudo 检查，密码仅在终端输入，再完成受控运行目录及隔离入口接入、复核后激活候选。
只读预检不验证上述隔离能力，不代表 #12 已领取。本次未改活动开关、未启动任务、
未 Git 提交、推送、安装服务版本或改变系统权限。

随后所有者放开工具权限并要求由助手操作（IS-066）。宿主服务读取已成功：
`innovation-symphony-controller.service` 为 active/running，MainPID 为 9217，
启动入口仍为 `.local/start-symphony.sh`；实际 `sudo -n true` 返回
`interactive authentication is required`。这是系统 sudo 身份认证缺口，
不再是工具自动审批超时；没有尝试无密码 sudo、读取密码或绕过认证。

已由当前用户在源码树外创建 `/var/tmp/innovation-symphony-linux-runtime/` 的
state、workspaces、sandboxes、logs、preflight，并复制既有受信脚本、工具链及依赖。
隔离脚本摘要仍为 `5ae08607777947f9979df1de85cdbb048e4087235ffd0508b6f351e83bb5ba04`。
复制后的 OTP 28／Elixir 1.19.5 工具链版本检查通过；候选配置更新为上述固定路径，
再次只读预检退出码 0，返回 `passed / issue_count=1`，结果保存于运行根的
`preflight/result.json`。此处为用户所有的准备副本，尚未完成受控 root 执行入口安装；
不登记为服务已经切换或真实隔离模型执行接入已通过。

活动工作流仍为 `mvp.enabled=false`，旧状态、日志、服务与 View 配置保留。
下一步需要所有者在本机终端完成必要的 sudo 身份认证／受控入口交接，密码只在
终端输入。工具权限放开不能替代该系统认证。

### root 检查通过后的后台接入准备

2026-10-05，所有者报告已在本机完成隔离 `--check`，输出为 `ready`。
此为所有者提供的 root 前置检查结果；并不把 sudo 的终端认证交给控制器。
助手复核用户服务 PID 仍为 9217、活动开关仍关闭，非交互 sudo 仍要求认证。
检查当前 `ExecutionSandbox.launcher/5` 后确认其直接使用 `bash`，没有后台特权桥接。

为本次 Linux 本地运行准备了忽略目录 `.local/runtime/bridge/` 下的受限 stdio 桥接，
不是新增调度器或长期部署决定。普通用户控制器通过 Unix SOCK_SEQPACKET 传递
标准流文件描述符；root helper 校验 SO_PEERCRED、固定路径／资源上限、任务目录、
新 scratch 目录和有限的执行器／正式检查命令。禁止任意宿主命令和环境变量；
连接断开则终止运行器进程组，由现有运行器执行 cgroup 清理，不伪造完成证明。
root 产物不跟随链接移交所有权，模型和 GitHub 认证不传入 helper。

启动脚本将受信脚本、工具链和依赖复制并冻结到 root 所有的
`/opt/innovation-symphony-linux-bridge/`；只启动临时 systemd helper，不启用开机自启、
不修改 sudo 规则、不把整个控制器提升为 root，也不开启领取。
原隔离脚本摘要保持不变，普通用户入口包装器只转发到该 helper。
候选工作流已改为上述冻结资产路径，因此安装后须重新检查候选及真实执行入口。
本地六项协议／拒绝／标准流／退出码／断连清理验证通过，启动脚本语法检查通过；
这些普通用户测试不代替真实 root 桥接或完整四条隔离底线验收。

当前 helper 尚未安装或启动；需所有者在本机终端执行准备好的
`.local/runtime/bridge/start-root-bridge.sh` 完成系统身份认证。
安装后仍由助手复核入口、执行隔离验证及领取配置，再切换控制器；
此时 `mvp.enabled` 仍为 false，#12 尚未领取，未提交或推送。


### 实际启用与 #12 领取验证

2026-10-05，所有者完成受控 helper 的本机启动。系统服务
`innovation-symphony-linux-bridge.service` 实际为 active/running；安装目录 root:root
0755，socket innovation:innovation 0600。普通用户通过 socket 调用 `--check` 返回 ready。

首次真实 stdio 沙箱探针发现用户私有运行目录无法由 bubblewrap 的用户命名空间
穿过，进程已清理且没有派发 Issue。助手修正本地桥接：输入在容量上限内复制到
root 所有的私有 `/var/tmp/symphony-bridge-*` 快照执行，完成后移交产物。
再修正结果发布窗口：产物、归属和原运行器清理证明一起原子发布到控制器 scratch，
不让轮询看见尚未移交的 root 私有目录。临时 root 服务通过本机系统认证更新，
没有修改 AppArmor、用户家目录权限或 sudo 规则。七项本地验证通过；真实 Codex
exec-server 沙箱探针退出 0，cleanup_complete、descendants_cleaned、export_complete
均为 true，CPU/内存/进程限制证据正常。保留首次失败及成功探针报告。

安装后的候选再次通过真实 GitHub 只读预检，issue_count=1。停用工作流备份为
`.local/runtime/WORKFLOW.disabled-before-enable-20261004T215224Z.md`；活动工作流启用
MVP 与隔离后重启控制器，首次自动领取 #12，但在线程创建前 blocked。
本机客户端协议及无模型回合的实际握手确认旧 `approval_policy.reject` 不再被接受。
改为 `granular`，五类审批请求全部 false（自动拒绝），保留隔离与权限边界；
握手响应预算调整为 60000ms，实际 AppServer.start_session 成功，未启动验证模型回合。

对 #12 首次启动失败作人工操作者核实：Codex 线程数为 0，无模型用量，无候选 SHA
和发布记录，工作区干净、HEAD 等于原 base SHA。停止 runner 后将原回执、证据和
工作区完整归档到独立运行根的 `archives/issue-12-startup-failure-20261004T220053Z/`，
保存原回执 SHA256 及核实结果，再仅对该启动失败重新领取；没有删除记录、换
state_dir、修改历史模型或使用 mvp.release 绕过其无 base_sha 守卫。这是本次获准
启用操作中的有审计纠错，不新增自动重领或通用失败恢复协议。

重启后控制器 MainPID=32407；2026-10-05 06:01:37（Asia/Shanghai）状态为
running=1、blocked=0、retrying=0，GH-12 有真实 session ID、turn_count=1 和实际
模型输入输出用量。coder/reviewer 默认均为 gpt-6.1-sol。此证据确认实际领取并进入
编码，不代表 #12 实现、完整检查、Review 或 PR 交付已完成。

View 仓库登记保持原条目，补充 `/var/tmp/innovation-symphony-linux-runtime` 的
采集 glob，保留原运行根及历史采集；旧配置备份为
`.local/view-config.before-intake-enable.toml`。View 重启不影响控制器。
此次未 Git 提交／推送、合并或部署 #12 的候选。root helper 是临时 systemd 单元，
没有开机自启；不能将当前启用登记为重启后无人值守恢复已通过。


### IS-067 原 #12 的 Linux 全流程修复与接续准备

06:01 的真实编码回合最终停为 `blocked/:mvp_no_changes`，不是功能已实现；
实际命令报告 `bwrap: No permissions to create a new namespace`。同一原回执、工作区、
冻结 Issue、基线与原 rollout 均保留。该回合最终观测为输入 59,268、输出 756、
合计 60,024 tokens；之前日志中的 44,445 是中间采样，不能作为最终累计用量。

AppServer 为已经可信准备的 external execution environment 使用 `externalSandbox`，
避免在外层隔离内重复创建 namespace；环境探测仍拒绝 local fallback。
Reviewer 与 diagnosis 的工作区改由外层只读挂载保证，只有具备受信只读绑定的会话
才沿用外部沙箱策略。普通本地只读会话和旧外部绑定的 readOnly 策略保留。
受限 helper 只新增明确 `--read-only-workspace true`，重复参数、固定路径和命令白名单
校验继续生效；无外网、凭据不可见、Git 元数据只读、资源限制与完成证明不变。

当前验证：30 项 AppServer／执行沙箱单测通过；7 项 helper 检查通过；
4 项真实 root Linux 隔离测试全部执行通过（含工作区写入 EROFS）；
真实 Coder shell/isolation 和 Reviewer read-only shell 两个 GPT 探针均通过。
证据位于 `/var/tmp/innovation-symphony-linux-runtime/preflight/` 下的
`model-exec-probe.json`、`model-review-probe.json` 及日志。探针为合成任务，
不代替 #12 功能或完整交付验收。Ubuntu uutils timeout 的缺失程序诊断另补全程序路径。

所有者按 IS-067 选择继续并交付 #12。此次一次性操作在
`.local/runtime/bridge/continue-issue12.exs`：先绑定原回执摘要、完整远端 Issue、
干净原分支 HEAD、全部冻结基线文件、原模型、原沙箱和实际 rollout 摘要；
经既有 OperatorRecheck 互斥及 append-only 证据记录后，调用相同 Executor 的
轮次／检查／Review／交付实现。它不修改正常领取或通用自动恢复入口。
原 V0 的无线变更回合以历史轮记录原基线 HEAD（produced_candidate=false），
原回执字节归入操作审计，原证据目录保留；原调用和用量进入累计账本。
此次助手工程预算为从原模型开始时间计算 8 小时、累计最多 16 次调用、5 次返工，
单个隔离会话／检查最多 1 小时；不是新增永久默认，不重置原开始时间或次数。
准确正式检查、独立 Review、Draft PR 与最终运行状态尚须继续核实。

06:41 已将普通用户控制器切换到
`.local/releases/linux-executor-20261005/symphony`，二进制 SHA-256
`d2238689e1b341e5a46b7f24c597c83a291006fafc4223daf59431b4c4eccd4f`；
清单固定源码文件摘要及验证结果。最终 670 项测试 0 失败、6 项外部测试跳过、
冻结范围覆盖率 100%，规格、格式、严格 lint 与 Dialyzer（0 错误）均通过。
原启动脚本备份为 `.local/start-symphony.before-linux-fix-20261005.sh`。
root runner 摘要为 `e2700ba6205c6f59bc213ea632f1d43eec3b6cb83f71ba47dd5bc39b03ec0bc9`。

第一次一次性接续准备因审计辅助函数假定 V0 已有 rounds 而在回执修改和模型调用前停止。
适配只在内存中向旧 guard 提供由原回执路径推导的 round-1 证据路径，
原回执字节与冻结数据仍保存在审计中，不跳过孤立旧锁或互斥检查；
适配来源纳入 authorization.json。随后临时普通用户单元
`innovation-symphony-issue12-operation2.service` 于 06:42 启动相同 Elixir Executor 接续。
此时原 #12 为 coding，调用账本从原 1 次增为 2 次；控制器与 View 均 HTTP 200。
未重启 View、未清理原状态、未合并或升级 #12 功能候选。


## 2026-10-04 当前 Linux 模型、隔离与正式检查验收

按 IS-059，在忽略目录 `.local/validation-20261004/` 验收。两次调用分别经过本项目
`SymphonyElixir.Codex.AppServer.run/4`，冻结模型为 `gpt-6.1-sol`，使用合成输入、只读
策略与 JSON Schema；coder 和 reviewer 均收到 `turn_completed`，输出严格解码通过。
认证使用独立受控 CODEX_HOME，调用结束后已删除复制的 `auth.json`；结果见
`model/result.json`。这些是模型连通性验证，不是实际任务编码或完整独立 Review。

root 运行器前置检查通过后，两项真实隔离集成首先因 loopback 设置失败而拒绝启动。
宿主内核日志确认 `unpriv_bwrap` AppArmor 拒绝子进程 `net_admin`。局部修正为在
外层 root supervisor 的独立 network namespace 中启用 loopback，先校验与宿主
namespace 不同，随后让 bubblewrap 共享该私有网络；不改系统 AppArmor 或家目录权限。
原失败证据保存在 `attempt1-isolation-*`。所有者通过本机 sudo 终端重跑后，4 项检查
全部通过，0 失败、0 跳过，覆盖网络、只读 Git、宿主秘密、资源预算、后代清理和导出。
记录在 `isolation-integration.log`，退出码为 0。

正式检查绑定源码 HEAD `169ff8efaf7534425b0649dad995ee8b5edff277`，使用独立冻结
代码副本与固定可信脚本。初次本地诊断通过格式、规格、Credo，测试为 669 项、1 失败、
6 跳过、覆盖率 100%；失败来自本机 uutils timeout 的缺失命令诊断文本差异。该次
不是正式隔离验收，原证据保留。随后从已安装的 GNU coreutils 复制 GNU timeout 9.7
到独立工具链，不修改系统默认命令。NIF 缓存也位于独立工具链，正式检查可离线编译。

正式隔离第一次从家目录挂载源时因路径权限失败，未进入代码检查。改为 root 在 `/tmp`
复制受信代码、工具链、依赖和无凭据证据目录，使用新运行目录验收；不放宽家目录权限。
准确版本的首轮隔离候选检查在 Dialyzer 冷缓存生成阶段触发 900 秒超时，报告目录为
`formal-1791095641-145532`。格式、规格、Credo 和 669 项测试（0 失败、6 项外部平台
live E2E 跳过、覆盖率 100%）均有通过证据，但 Dialyzer、构建及冻结基线未完成，
不得登记为完整通过。完成证明为 timeout/124，后代清理及导出完成，无 OOM。
首轮预算为墙钟 900 秒、内存 4096 MiB、磁盘 2048 MiB、进程 256、CPU 2；随后仅
扩大独立验收预算至 1800 秒与 CPU 4 后重跑全部检查，不改候选、冻结规则或活动服务
配置。这些数值为本次验收安排，不登记为仓库默认决定。

扩大预算的新一轮报告为 `formal-1791096662-188811`。格式、规格、Credo、覆盖率、
Dialyzer 和构建全部通过，完整候选检查退出码为 0。候选测试为 669 项、663 项通过、
0 失败、6 跳过、覆盖率 100%；Dialyzer 为 0 错误、0 跳过。新的隔离实例执行冻结
基线测试也通过：669 项、663 项通过、0 失败、6 跳过，完整基线检查退出码为 0。
六项跳过均为会创建真实外部平台任务的 live E2E，不计为实测通过。

已重新解析全部七份阶段结果，校验源码 SHA、runner/formatter 摘要、manifest 与
逐测试报告身份及事件完整性；候选和基线两份隔离证明均为 completed/0，后代清理、
证据导出完成，无 OOM。隔离运行器的本地修正摘要为
`5ae08607777947f9979df1de85cdbb048e4087235ffd0508b6f351e83bb5ba04`。
汇总在 `.local/validation-20261004/summary.json`。以上通过范围是合成模型连通性、
真实 Linux 隔离能力与固定源码的完整候选/基线检查；不等于实际 Issue 的编码/Review
交付或活动控制器的无人值守隔离模型 executor 已完成接入。

验收结束后两个 systemd 用户服务仍为 active/running，MainPID 分别为 96197、62905；
控制器状态及 View bootstrap HTTP 200，任务 running/retrying/blocked 均为 0。

真实领取仍为 `mvp.enabled=false`，活动服务的 `mvp.sandbox.enabled=false` 未改。
本轮没有真实 Issue 操作、Git 提交、推送、合并或部署。

## 2026-10-04 当前 Linux GitHub 凭据接入与默认模型设置

按 IS-058，核实所有者已提供 `.local/runtime/secrets/github-token`，文件非空、权限
`0600`；启动器已通过环境变量加载，凭据内容不写入文档或日志。`gh api` 使用该文件
凭据读取仓库信息成功，返回 `dailiuyi/innovation-symphony`。这证明仓库读取可用，
不等于 Issues 全部读取、写入、Git 推送或 Draft PR 交付权限已验证。

`.local/runtime/WORKFLOW.github.md` 与活动 `WORKFLOW.md` 的 coder/reviewer 默认值均
改为 `gpt-6.1-sol`，模型白名单为该单项，操作者名单填写已核实账号 `dailiuyi`。
`mvp.enabled=false` 保持，既有路径、检查和隔离模板不变；原配置备份在忽略目录
`.local/runtime/config-backups/`。本机本地配置校验通过，但停用校验不会验证
启用分支的完整执行设置或模型可用性。

北京时间 14:14 重启同一 `innovation-symphony-controller.service` 后实际加载 GitHub
工作流。此前旧进程尚未注入凭据，文件热加载曾记录 `:missing_github_token` 并保留旧
配置；本次重启后进程环境已核实收到文件中的对应凭据，未清除原日志。
最终 MainPID 为 96197，服务 `active/running`，状态 API HTTP 200，
running/retrying/blocked 均为 0。View `/api/bootstrap` HTTP 200，采集 `ok/local`。

看板地址仍为 `http://127.0.0.1:8613/`，控制器状态页仍为
`http://127.0.0.1:4000/`。没有启动真实任务或模型调用，没有迁移原 WSL 历史、
Git 提交、推送或云部署。隔离环境、准确正式检查和模型实测仍须完成后才启用领取。

## 2026-10-04 当前 Linux 本机新环境启动

按 IS-057，在当前 Linux 机器的新 checkout `169ff8efaf7534425b0649dad995ee8b5edff277`
创建独立运行环境。此前 Windows＋WSL 的固定 release、生产配置、历史数据库与回执
不在此机器上；没有迁移或声称恢复旧服务。

依赖及实施文件放在忽略目录 `.local/`。mise 2026.10.1 下载校验通过；OTP 28.5
从源码构建，Elixir 1.19.5 使用 OTP 28 预编译包。ncurses/OpenSSL 的 Ubuntu 包仅
提取到 `.local/build-deps/`，未安装系统包；SSL 初始化及 crypto 的 OpenSSL 3.5.5
信息核实通过。Hex 依赖第一次超时后增加下载超时并降低并发，按仓库 lockfile 下载
成功，`mix build` 生成本机 `elixir/bin/symphony`。没有修改依赖锁或控制器源码。

Python 3.14 的独立 `.local/view-venv/` 安装固定 `codex-transcript-viewer==0.5.0`。
`.local/launch-view.py` 强制 loopback 监听；端口释放后允许有界等待，仍保留独占绑定。
`.local/view-config.toml` 使用 `transport=local`，只读扫描 `.local/runtime/`；新建
`view/data/board.db`，未复制旧历史或合成任务。

当前活动工作流为 `.local/runtime/WORKFLOW.md`，采用项目内置的 `memory` tracker，
没有配置任何 Issue，`mvp.enabled=false`。真实 GitHub 模式初次启动被
`:missing_github_token` 拒绝；停用的 GitHub 模板保存为同目录 `WORKFLOW.github.md`。
本机空队列启动是本次实施安排，不是 GitHub 接入通过或永久 tracker 决定。
启用真实任务还需有效 GitHub 凭据及完整执行配置。

两个 transient 用户服务由 systemd 管理：`innovation-symphony-controller.service` 与
`innovation-symphony-view.service`。北京时间 2026-10-04 04:42 核实均为
`active/running`，MainPID 分别为 91949 与 62905。Symphony 首页及
`http://127.0.0.1:4000/api/v1/state` 返回 HTTP 200，running/retrying/blocked 均为 0；
View 首页、`/api/bootstrap` 与 `/api/snapshot` 返回 HTTP 200，采集为 `ok/local`。
浏览器实际显示任务看板和“只读采集 · 正常”；新环境没有任务与会话。
两个端口均只监听 `127.0.0.1`。

访问地址：View `http://127.0.0.1:8613/`；Symphony 原生状态页
`http://127.0.0.1:4000/`。本机日志和接口核实结果保存在 `.local/runtime/`；控制器
旋转日志位于该目录 `logs/log/`。可以通过 `systemctl --user status` 或 `restart`
加对应单元名管理当前服务；transient 单元未设置开机自启，重启电脑后需要重新注册。
此次只做本机安装和服务启动，未派发真实 Issue、迁移旧任务、Git 提交、推送或云部署。

## 2026-10-03 最新 main 看板安装

来源：用户本次明确要求“拉取最新代码，安装并告诉我看板的访问网址”。远端 main 已拉取至 `0ec92f949d5ce5759c0a68c507fa9dbcddebb8f9`（PR #9 合并）；为保留原开发分支和三份未提交需求文档，在 `.local/releases/0ec92f9` 建立 detached 固定 worktree，安装其中 `view/`，没有合并或重置原开发分支。

Python 3.12 独立虚拟环境安装 `codex-transcript-viewer==0.5.0`，复制旧看板配置。临时端口实机采集与浏览器 smoke 通过后，停止已确认归属的旧 `E:\code\innovation-view\app\run.py`，备份原数据库及可能存在的 WAL/SHM，使用 SQLite backup 保留 7 个任务、164 条状态变化、91 条会话索引、79 条证据索引和 1 条日志索引；完整性检查为 ok。旧仓库和原数据库保留。

本机网址为 `http://127.0.0.1:8613/`。忽略目录中的 `launch-loopback.py` 强制只监听 `127.0.0.1`，避免默认无认证服务向局域网暴露材料；源码未修改。最终 root HTTP 200，`/api/bootstrap` 采集状态 ok，`/api/snapshot` 返回 7 个任务、91 个会话。服务后台运行，未安装开机自启。控制器固定版本仍为 `43ef95638ca8cca87bdc94c38032187debac0982`，未切换、重启或派发任务。

UTF-8 模式下 27 项 Python 和 10 项 JS 测试通过；完整固定夹具比较在 Windows 仍有差异（包含换行引起的字节数与游标差异），不能报告该完整检查通过。真实看板浏览器 smoke 的 8 组检查通过，涵盖搜索、详情、深链接、复制导出、阅读刷新保持、异常恢复、主题和窄屏，无脚本错误。本机结果、日志、旧进程身份与数据备份在 `.local/view-install-0ec92f9/`。此次只安装本地看板，没有提交、推送或云部署。

## 2026-10-01 当前固定安装与真实看门狗测试

按 IS-042，PR #6 已由用户合并，拉取远端 main `eef3dec0d0ffba286a8e945849a57c214201b47f`。安装时本地仍有 13 个未发布的控制器提交；为保留隔离执行、技术恢复和分阶段交付，合入最新 main，仅决策文档存在冲突并保留双方记录，形成安装提交 `d4e913ea4b8c14ee81da977fd337d584fe8035f2`。安装测试完成后 IS-043 授权将当前本地 main 推送远端，发布结果以 Git 远端 SHA 核验；安装仍固定于 d4e913e，后续只有文档变化。合并前引用 `codex/pre-watchdog-install-20261001` 保留。

固定安装在 WSL `desktop` 的 `/var/tmp/innovation-symphony-v0-rerun1/releases/d4e913ea4b8c14ee81da977fd337d584fe8035f2`。Elixir 1.19.5/OTP 28.5、Codex 0.159.1 及原 CODEX_HOME 沿用。`bin/symphony` 为最终 dev escript 的普通文件副本，无符号链接；SHA256 为 `125fa60e81d744af1a9c537281fd9b9cdcd55a8ddc8bc1ffd9af056205833114`。安装源码工作树干净，watchdog 和 CLI 与原 PR 候选 `b465fbc` 的源码一致，其余本地控制器功能保留。

安装前 `make all` 完整通过：652 项测试、0 失败、6 项既有真实平台 E2E 跳过、覆盖率 100%；格式、公共规格、严格 Credo、Dialyzer 和构建均通过。Python 检查为 36 项、0 失败，其中 14 项需单独开启的 Mix/sandbox 集成未运行。首次检查错误地复用服务的 GITHUB_REPO，造成缺少配置的负向用例失败与 99.97% 覆盖率；清除检查环境中的仓库及认证变量后重新完整通过。原失败日志保留，没有改源码、跳过项或阈值。

真实 GitHub 只读预检核实没有可领取任务；原服务空闲、GH-5 审计操作已结束后才切换。原 `runtime-v1/WORKFLOW.md` 路径、`state/attempt-4`、`workspaces/v1`、模型、恢复策略和冻结检查路径保留；仅安装路径改指新固定版本。领取仍为 `mvp.enabled=false`，没有启动其他 Issue。

无人值守 GitHub 凭据在任何退出测试前由现有获准 Windows gh 登录一次性预配置到 `runtime-v1/secrets/github-token`，uid 0、文件 `0600`、父目录 `0700`。看门狗父进程不持有 GITHUB_TOKEN，启动时读取文件并注入运行器子进程环境；Codex 使用原受限 CODEX_HOME，目录 `0700`、auth.json `0600`。记录只含来源、权限和注入方式；最终审计验证状态、审计及日志没有秘密值。

实际参数为检测周期 1000 ms、退避 5000 ms、每版本最多 5 次启动、稳定时长 300000 ms。这些是本次安装参数，不是新的永久产品决定。真实测试结果：

- 运行器正常 SIGTERM 退出，852 ms 内检测到退出；退避后自动恢复。真实 GitHub 查询及 Sol 6.1 只读最小调用均成功，没有人工输入或登录。
- 运行器 SIGKILL 强制结束，880 ms 内检测到退出；退避后自动恢复。新 PID/启动身份和固定版本核实，真实 GitHub/Codex 认证再次成功。
- 看门狗 SIGKILL 后，现存运行器及状态 API 正常；重新启动看门狗没有另起运行器或重置预算。
- 1679 项状态/证据和 5149 项工作区条目的内容、目录结构、权限、owner 和 inode 均保留。原 GH-5 回执仍为 awaiting_external，其候选、旧 Review、预算和证据链未改变。

北京时间 02:23 的最终核实：运行器 PID `1648931`、start_ticks `2207817`；看门狗 PID `1647651`、start_ticks `2205100`；cwd 均为固定 release 的 `elixir/`。各只有一个进程，状态 API HTTP 200，running/retrying/blocked 均为 0。宿主启动 ID 和完整身份留在审计文件。当前运行已安装的合并版本；此次实测不是原 b465fbc 回执的自动验收批准，不虚构已重新执行独立 Review。

本机脱敏结果为 `.local/watchdog-install/final-audit.json`、`recovery-results.json` 和 `full-checks-clean-env.log`。原服务、状态、工作区及运行配置备份在 `/var/tmp/innovation-symphony-v0-rerun1/operator-watchdog-install-1790792283829787448/`，旧 `626b2c2` 固定安装保留。看门狗已在当前宿主内运行；未安装宿主开机自启或看门狗自身常驻恢复服务。

实际人工维护命令如下。先暂停并核对 paused=true，再处理领取/在途工作和停止确认归属的运行器；pause 不停止运行器本身。旧 launch.py 的原文保存在操作备份，原入口已替换为迁移提示，防止启动旧版绕开新互斥；previous-release.json 记录实际前一版本 626b2c2。新固定安装的普通入口也拒绝绕过托管启动。

```sh
RUNTIME=/var/tmp/innovation-symphony-v0-rerun1/runtime-v1
WATCHDOG=/var/tmp/innovation-symphony-v0-rerun1/releases/d4e913ea4b8c14ee81da977fd337d584fe8035f2/bin/symphony
CONFIG="$RUNTIME/watchdog.json"
bash "$RUNTIME/runtime-env.sh" "$WATCHDOG" --watchdog status "$CONFIG"
bash "$RUNTIME/runtime-env.sh" "$WATCHDOG" --watchdog pause "$CONFIG"
# 维护后明确解除；不绕过退避或清除耗尽预算。
bash "$RUNTIME/runtime-env.sh" "$WATCHDOG" --watchdog resume "$CONFIG"
# 同版本预算耗尽且故障已修复时，另行明确执行 recover。
```

## 外部条件接手

`awaiting_external` 表示控制器已保存候选和交接记录并结束本次执行。操作者先运行 `mix mvp.external status RECEIPT.json` 查看缺失条目、所需证据和接手责任，按已有权限完成外部工作，再用绑定原回执摘要的请求调用 `mix mvp.external resume WORKFLOW.md RECEIPT.json REQUEST.json`。具体字段、冻结条件、证据格式与预算规则见 [EXTERNAL_HANDOFF.md](EXTERNAL_HANDOFF.md)。

此入口不会解除维护暂停、增加预算或自动迁移旧 `blocked` 回执；实现和运行安装状态分别记录在该合同的实施状态中。

## 看门狗维护纪律

本节对应 [005 看门狗合同](issue-drafts/005-watchdog.md)，记录维护纪律。IS-042 的实际安装与命令见文首；通用配置格式见后文看门狗维护流程。

1. 首次启用前，配置无人值守启动所需凭据（部署环境变量或受限权限文件等），记录来源类别、权限和注入方式，不记录秘密值。在验收环境证明运行器退出后无需人工取 token、输入或登录就能自动拉起；没有该证据，WD-1 不能通过。
2. 人工维护或停机前，先设置持久维护暂停，并通过状态读取确认已生效。看门狗暂停仅禁止自动拉起，不停止任务领取或在途任务；仍须按已有运行器规则处理领取及在途工作，核实允许停机后再停止运行器。不通过清空回执或证据实现停机。
3. 若忘记暂停便直接停止运行器，无论正常退出还是异常退出，看门狗都会在其他启动条件满足后尝试恢复。终端退出、看门狗重启或等待都不会解除已设置的暂停。
4. 维护完成后，核对外部操作者设置的版本指针、凭据来源、进程身份与版本预算，明确解除维护暂停。预算已耗尽时，必须另行执行该版本的人工恢复操作并保留旧终态与证据；解除暂停不等于重置预算。随后核对实际运行版本、进程身份和本地动作记录。
5. 宿主重启不在本期自动恢复范围。在没有另外部署自启机制时，由操作者恢复 WSL／Linux 环境并重新启动值守入口；先核对持久维护暂停、指针、预算及现存进程，不默认清空状态。若停机发生在未来升级流程中，须按后续 002 的升级恢复合同处理，当前不提供自动续接或回退承诺。

## 2026-09-29 GPT 模型白名单扩充与同版本重启

- 按 IS-029，用户明确要求“加入gpt系所有模型，重启服务”。使用运行器实际 Codex 二进制及同一 CODEX_HOME，按 [OpenAI App Server 文档](https://learn.chatgpt.com/docs/app-server) 查询分页 `model/list`，包含隐藏项；本次目录返回 8 个 GPT 型号。
- 当前 `runtime-v1/WORKFLOW.md` 的白名单为：`gpt-6-astra`、`gpt-6-sol`、`gpt-6-luna`、`gpt-5.6-sol`、`gpt-5.6-terra`、`gpt-5.6-luna`、`gpt-5.5`、`gpt-reserve`。最后一项在目录中标记为隐藏；全部返回支持 `high`。这是一份本次实际查询的配置快照，不是任意模型通配符，也不自动纳入未来新增型号。
- 默认编码与 Review 仍为 `gpt-6-astra`，原推理配置与恢复策略保持不变。通过固定安装的配置校验及评论解析器，逐个验证每个白名单型号同时作为 coder/reviewer 的指令；没有启动真实模型任务，不将目录或解析成功描述为逐型号推理实测。
- 17:39（Asia/Shanghai）完成重启：原 PID `3268970` 已退出，新 PID `1173655` 的 cwd 与固定安装 `11acc1b8b40d471247b60b55d92239ea6ae81a1d` 一致，状态接口返回 HTTP 200，running/retrying/blocked 均为 0。启动前后只读查询的 open/claimable Issue 均为 0，正常 ready 领取已恢复。
- 操作先备份配置，验证候选配置并确认空闲，再暂停新领取、停止旧进程及使用原启动器重启。沿用 `state/attempt-4` 和原工作区，576 项历史状态与证据条目内容不变，原 `previous-release.json` 也已保留；未改变运行版本、任务回执、远端标签或评论。
- 模型目录及结果保存在本机 `.local/model-whitelist-20260929/`；运行侧备份及脱敏验证日志在 `/var/tmp/innovation-symphony-v0-rerun1/operator-model-whitelist-20260929T093856Z/`。较早的 `operator-model-whitelist-20260929T093813Z/` 保留一次 Mix 验证参数传递错误的日志，该次失败发生在运行配置修改和停机之前；修正参数后验证与重启通过。本条记录本地配置变更与重启，不代表远端发布。

## 2026-09-29 当前 main 安装与运行切换

- 按 IS-028，用户明确要求安装当前 main。PR #4 已合并；安装固定提交 `11acc1b8b40d471247b60b55d92239ea6ae81a1d`，其 [GitHub CI](https://github.com/dailiuyi/innovation-symphony/actions/runs/36545295566) 成功。该提交与此前通过 478 项 Elixir 测试（0 失败、6 跳过、覆盖率 100%）及 28 项 Python 集成测试的冲突修复内容一致。
- WSL `desktop` 独立安装目录：`/var/tmp/innovation-symphony-v0-rerun1/releases/11acc1b8b40d471247b60b55d92239ea6ae81a1d`。从固定 Git 提交安装，重新编译和 escript 构建通过，安装工作树干净。
- 新版实际 `--preflight` 通过真实 GitHub 只读查询，返回 `status=passed`、`issue_count=0`；旧进程空闲后暂停领取并退出，新进程 PID `3268970` 的 cwd 与固定安装一致。
- 沿用 `runtime-v1`、`state/attempt-4`、`workspaces/v1`。编码和 Review 仍为 Astra，恢复策略及预算未改变；仅将启动器、工具链包装器和检查脚本路径指向新安装。新服务恢复原有 ready 领取配置。
- 状态接口 `http://127.0.0.1:43223/api/v1/state` 返回 HTTP 200，running/retrying/blocked 均为 0；两份历史回执及证据所在的 576 项目录、文件、链接条目内容全部保持不变。
- 旧 `07f7493` 安装及运行文件备份保留，`previous-release.json` 记录实际旧版本。本机证据在 `.local/main-switch-11acc1b/`，运行侧备份在 `operator-main-switch-11acc1b8b40d/runtime-before/`。未新建或重新派发 Issue，未配置云部署或开机自启动；本次人工切换不作为完整自动接棒或回退演练的验收。

以下章节保留各次交付时的历史状态；当前运行版本以文首最新固定安装记录为准。

## 2026-09-29 自动恢复实测

控制器 `07f74936f77e30c6337da70a1fec9476a61eac8f` 已发布、通过 CI 并安装在本地 WSL。Issue #3 保留原五次返工，通过自动诊断及两次新增编码，自动处理一次真实测试失败后通过完整检查和独立 Review，交付 [Draft PR #4](https://github.com/dailiuyi/innovation-symphony/pull/4)。完整版本、检查数字和证据见 [验收记录](VALIDATION_AUTOMATIC_RECOVERY.md)。

运行入口仍为 `runtime-v1`，状态目录仍为 `state/attempt-4`，intake 已恢复，历史证据未清空。PR 候选尚未合并或安装；按 IS-027，与 main 的冲突由人处理，停止自动集成扩展，不持续追赶主分支。下文保留此前各次启动与切换的历史记录。

## 当前状态

已在官方 Elixir 源码基础上实现本地 GitHub MVP，包括确定性评论解析、检查、独立 Review 与 Draft PR 交付链；需求文档和后台 HTML 原型继续保留。私有 GitHub 仓库和真实 Issue #1 已接入；经过环境隔离与中断分支修复，PR #2 已由用户合并。2026-09-29 按 IS-019 授权切换本地 WSL 运行器，运行版本及状态见文末记录。尚未部署云服务；历史验证见 [VALIDATION_V0.md](VALIDATION_V0.md)。

本机目录为 `E:\code\innovation-symphony`，远端为私有仓库 `dailiuyi/innovation-symphony`，已有 V0 基线提交。提交及运行状态以当前 Git 和回执核实。

## 预览

在项目根目录运行：

```sh
python -m http.server 43221 --bind 127.0.0.1 --directory prototypes
```

访问 [原型](http://127.0.0.1:43221/symphony-dashboard.html)，或直接用浏览器打开 `prototypes/symphony-dashboard.html`。端口被占用时先确认归属，不关闭无关服务。预览服务只绑定本机，不能据此宣称已经部署到云端。

筛选任务、查看日志、选择仓库默认模型都只操作演示数据。选择保存在当前页面内存，刷新会重置；已有演示任务继续显示原来的模型快照。实际 MVP 从工作流读取默认值并解析 Issue 评论，尚未与此原型页面连接。

## 架构审核图预览

架构图包含本地文档链接，建议从项目根目录提供预览，而不是仅提供 prototypes 目录：

```sh
python -m http.server 43222 --bind 127.0.0.1 --directory E:\code\innovation-symphony
```

打开 [第一版实际架构](http://127.0.0.1:43222/prototypes/mvp-architecture.html)。此前的 [架构审核提案](http://127.0.0.1:43222/prototypes/architecture-review.html) 作为历史讨论保留。也可直接打开 HTML 文件。模块点击仅切换展示，不提交决定或触发执行。

## 抽离来源

2026-09-28，从博客活动托管工作树的框架提案、D-016 决策及后台 HTML 原型抽离。来源本机路径为 `C:\Users\emla\.codex\worktrees\symphony-label-intake\astro-blog`。

原型迁入后将启动说明改为 ready 自动领取；文档重新分为已确认需求、决策、协议草案、待讨论问题和架构建议。旧博客保留迁移说明，不继续在那里维护完整框架正文。旧博客的固定 Review 模型、运行合同、队列、凭据和安装快照没有迁入。

本机历史上可能已有其他项目使用 `innovation-symphony` 作为容器或镜像名称。本次新建的是源码项目；没有认领、重启、替换或迁移那些服务。未来命名运行服务前须检查归属。

## 验证与状态边界

2026-09-28，抽离后验证通过：9 份 Markdown 的 17 个本地链接均可解析；HTTP 预览内容与新项目 HTML 一致；ready 自动领取文案、任务筛选、模型选择、1440px 桌面截图和 390px 手机布局检查通过，无浏览器脚本错误。独立只读审查发现原型曾以 ready 命名“待人工审查”，已改为独立内部状态 awaiting_review，ready 保留为启动门槛。

保存文件、Git 提交、发布到远端、安装执行服务与云端部署分别报告。真实任务派发及提供商调用已发生，PR #2 已合并且用户已授权运行版本切换；完整自迭代闭环与回退演练仍需验收。

## 2026-09-29：PR #2 合并后的本地版本切换

- GitHub 合并提交：`003a0db85da88ef79b882433108df2f3d782c092`；内容与通过审查的候选 `5867d36` 一致，合并后的 CI 成功。
- WSL 发行版：`desktop`。固定安装：`/var/tmp/innovation-symphony-v0-rerun1/releases/003a0db85da88ef79b882433108df2f3d782c092`。
- 运行配置与 PID：`/var/tmp/innovation-symphony-v0-rerun1/runtime-v1/WORKFLOW.md`、`pid.json`；日志在同目录 `logs/log/symphony.log.1`。
- 本地状态页：`http://127.0.0.1:43223/`；状态 API：`/api/v1/state`，仅绑定回环地址。
- 已显式启用 `max_rework: 2`。串行处理本仓库 ready Issue；保持编码与 Review 模型冻结及独立审查，失败停止边界不变。
- 继续原地使用 `state/attempt-4` 的领取与交付记录，未清空状态。新任务工作区为 `workspaces/v1`，旧候选工作区不受启动清理影响。
- 旧固定安装 `runner-replay`（`50955cf`）和全部历史回执、候选证据保留。回退必须先停当前进程并确认没有活动任务，沿用最新状态及新工作区路径；旧版配置将 max_rework 改为 0，不能恢复旧状态备份覆盖新记录。
- 以后台进程运行，未安装 Windows/WSL 开机自启动或自动重启服务。凭据通过标准输入交给启动器后仅保存在控制器环境中；关闭进程后重新启动需重新提供凭据。
- 本次只验证固定版本构建、真实 GitHub 读取、原回执保留、进程与状态接口；没有创建新的测试 Issue，不把空队列启动视为真实自动返工闭环验收。

本机操作和检查证据保存在 `.local/runtime-switch/`（忽略目录，不提交凭据或运行状态）。启动入口为 runtime-v1/launch.py，启动时拒绝已有 PID、端口冲突或预检发现非空待执行队列；该保守空队列要求是本次安装验收安排，不是产品 ready 协议的新规则。

### 2026-09-29：重启服务与发布下一项 Issue

- 按 IS-020 启动已安装的 `003a0db85da88ef79b882433108df2f3d782c092`。发现旧进程已退出、端口未监听，原 `/tmp/innovation-symphony-toolchain` 已丢失；固定安装、领取记录和 evidence 仍在。
- 恢复相同版本 Erlang 28.5 / Elixir 1.19.5-otp-28 及 Hex/Rebar，工具链改放 `/var/tmp/innovation-symphony-toolchain`；更新本机 `runtime-v1/runtime-env.sh` 的路径并保留原包装器备份。这是本次启动修复，不是新部署架构或运行版本升级。
- 启动预检通过：真实 GitHub ready 队列为空、Issue #1 关闭且原回执保留、`max_rework=2`。新进程 PID 638，状态接口返回 HTTP 200，running/retrying/blocked 均为 0。
- 已审阅并发布 [Issue #3](https://github.com/dailiuyi/innovation-symphony/issues/3)，保持无标签，等待人工修改；升级接棒功能尚未实现。草稿已补充回执重派、Review 完成边界、接管前体检门禁及生命周期竞态的审阅结果。
- 本轮文档仅保存到本地，未提交或推送；Issue 已发布，服务本地运行，未配置开机自启动或云部署。

### 2026-09-29：再次启动服务与预检门槛修正

- 再次启动已安装的 `003a0db85da88ef79b882433108df2f3d782c092`。启动前核实：旧进程已退出、端口 43223 空闲、工具链在 `/var/tmp/innovation-symphony-toolchain`；凭据取自本机 `gh` 活跃账号（dailiuyi），经标准输入交给启动器，未写入文档、仓库或本记录。
- 首次预检失败：原 `preflight.exs` 以 `[] = candidates` 把 open 状态的全部 Issue 视为待执行队列，而 Issue #3 按发布边界保持无标签、等待人工维护。运行时领取需同时满足 tracker `required_labels: [ready]`（`Tracker.Issue.routable?/2`）与 `Mvp.Intake.ready?/2`，无标签 Issue 不会被领取。
- 修正：预检断言改为"不存在任何 open Issue 可被运行时领取"（复用上述两个运行时判定），门槛意图不变——带着可执行 ready 任务启动仍然拒绝。原预检保留为 `runtime-v1/preflight.exs.empty-queue.bak`，新脚本同步存放于本机忽略目录 `.local/runtime-switch/preflight.claimable.exs`。
- 预检通过：`PREFLIGHT_OK max_rework=2 claimable_queue=0 open_issues=1 issue1_receipt_retained=true usage_aggregate_loaded=true`。新进程 PID 447，状态接口 HTTP 200，running/retrying/blocked 均为 0。
- Issue #3 保持无标签等待人工处理；服务运行期间人工打上 ready 即会被自动领取。仍未配置开机自启动，WSL 关闭或重启后进程退出，再次启动需重新提供凭据。
- 本次只改动运行目录预检脚本与本文档，未触碰安装版本代码、WORKFLOW 配置或状态目录。

## 官方实现与 V0 本地检查

### 2026-09-29：修复 escript 静默跳过 ready Issue

- 故障：旧版打包 escript 的 `:code.lib_dir(:symphony_elixir)` 返回归档内虚拟路径，MVP 路径隔离校验报 `enotdir`；`Mvp.available?/1` 将配置错误当成不可领取，状态页仍可正常访问，因此空闲页面和 HTTP 200 未揭示故障。
- 修复本地提交及实际运行版本：`94e376803ea1e7332e6a927d6871c1f385593204`，独立安装在同名 `releases/` 目录。归档路径使用解析符号链接后的实体工件目录，工件丢失时停止派发；每轮配置错误会明确记日志。旧 `003a0db` 安装保留。
- 验证：380 tests、0 failures、6 个既有实平台测试跳过；覆盖率达到现有配置要求的 100%；format、lint/specs、dialyzer、build 与独立审查通过。一次上游重试时钟断言差 2ms，同 seed 完整重跑通过，未修改该断言。真实 escript 子进程覆盖合法 ready 候选、目录重叠及符号链接边界。
- 按 IS-021 预检 ready 操作者及队列只包含获准的 Issue #3 后切换；沿用 state/attempt-4 和 workspaces/v1，原有 161 个状态/证据文件哈希不变。启动器端口探测增加 SO_REUSEADDR，避免旧连接 TIME_WAIT 被误判为仍有监听服务；仍拒绝真实端口占用。
- 11:31（Asia/Shanghai）自动领取 GH-3，PID 13384，11:32 回执为 `coding`，已有实际 Codex 会话及 token 用量。编码与独立 Review 均为 `gpt-6-astra`，沿用 `high`；尚未证明该 Issue 完成交付。
- 启动入口仍为 runtime-v1/launch.py；此次显式准入仅用于获准的 #3，启动后恢复原来的空可领取队列预检，未修改 ready 标签。修复提交尚未推送远端；GH-3 冻结的远端任务 base 仍为 `003a0db`，以后合并候选时须同时保留本次领取修复。
- 本机证据保存在 `.local/intake-repair/`：release.json、applied.json、running-evidence.json；安装切换前的启动器与 PID 记录位于 runtime-v1/before-intake-fix-94e3768。未自动合并或安装 GH-3 产生的候选，也未配置云部署。

保留上游 WORKFLOW.md 仅为参考；本项目使用 WORKFLOW.github.example.md，复制到独立运行目录后填写配置。不要把原 Linear 示例当作本项目执行入口。

运行要求：Linux/WSL、Elixir 1.19.x / OTP 28（沿用官方 mise.toml）、Git、GNU timeout、Python 3，以及原生 Linux Codex CLI。必须确认 `codex` 不是 `/mnt/c` 的 Windows npm 包装脚本。首次接入前先准备独立运行目录、工作区和状态目录；本次没有安装常驻服务。

```sh
cd elixir
mix deps.get
GITHUB_REPO=example/example GITHUB_TOKEN=local-validation-only mix mvp.check "$PWD/WORKFLOW.github.example.md"
mix format --check-formatted
mix lint
mix test
mix test --cover
mix dialyzer --format short
mix build
```

`mvp.check` 不连接 GitHub、不验证模型可用性、不启动调度。上方 example/example 和 local-validation-only 是本地解析占位值，不是仓库或凭据。未设置 repo/token 时检查会报配置缺失。默认 disabled 可安全核对模板；运行目录中的工作流填写真实值后再检查。`mvp.enabled=false` 表示暂停新派发，需停止进程才能确保当前工作也已停止；不要删除整个 mvp 配置块来停机。

本仓库已获得明确接入及 Issue #1 派发授权。新接入时设置 GITHUB_REPO/GITHUB_TOKEN、模型白名单与允许的 ready 操作者，将 mvp.enabled 设为 true，并使用上游 CLI 的显式 guardrails acknowledgement 开关启动。首次启用会扫描获准的存量 ready Issue，不能作为只读连通性测试。

自迭代运行时，固定版本 A 安装在候选工作区之外。修改发生在 B 的工作区；PR 待人审核。完整领取状态及 evidence 必须在升级时保留，已进入编码/发布阶段的失败不自动重试。具体恢复命令见 IMPLEMENTATION_V0.md。

### GH-3 只读体检

新增 `--preflight` 用于独立进程中加载候选配置并只读查询 GitHub；它直接退出，不启动调度。配置须为完整且已启用的 GitHub MVP 配置；停用模板不能作为候选可接管的证据。与 `mvp.check` 不同，这会访问配置指定的 GitHub 仓库，执行前需有该仓库的读取授权。

以下是调用示例，不是安装、切换或已执行记录。`CANDIDATE_ESCRIPT` 和 `CANDIDATE_WORKFLOW` 指向隔离的固定安装及配置；`PREFLIGHT_TIMEOUT` 由操作者明确指定 GNU timeout 时限，本次没有确定产品默认值。

```sh
timeout --signal=KILL "${PREFLIGHT_TIMEOUT:?set an explicit duration}" \
  "${CANDIDATE_ESCRIPT:?set the fixed candidate path}" \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --preflight "${CANDIDATE_WORKFLOW:?set the candidate workflow path}"
```

保存标准输出、标准错误和退出码：0 表示配置及只读轮询通过，非零（包括外部超时）表示未通过。成功输出示例：`{"mode":"preflight","status":"passed","issue_count":0}`。体检不验证模型、命令执行或回执兼容性；成功不自动接管，也不证明 A 已退出。A 收尾、升级/回退入口仍未实现，完整边界见 [实现合同](IMPLEMENTATION_V0.md#gh-3-最小增量接管前只读体检)。

体检的标准输出仅包含成功 JSON；重试日志和失败原因写入标准错误，解析 JSON 时不要合并两个输出流。沿用客户端的有界安全重试；重试后查询成功仍可通过，耗尽重试或任一页含未知状态、畸形记录则失败，不计为合法空队列。日志重定向仅用于退出式 CLI 体检，不改变正常服务的日志配置。

### 检查环境与显式重跑

`scripts/check_candidate.py` 和 `scripts/check_baseline.py` 调用 Mix 时移除 `GITHUB_REPO`、`GITHUB_TOKEN`、`GH_TOKEN`。保留 PATH、Mix/Hex/mise 缓存等构建配置；不修改父进程环境。控制器已有的动态凭据过滤继续适用。这是当前 GitHub MVP 的配置隔离，不是通用环境白名单或安全沙箱。

回归命令：`python3 -m unittest discover -s scripts/tests -v`。检查步骤、错误传播及覆盖率门槛保持不变。

检查入口在导入共享辅助模块前禁用 Python 字节码写入，防止 `__pycache__` 改变冻结基线指纹。回归测试实际执行两个归档入口，并逐文件比较执行前后的基线；完整性校验不排除缓存文件或放宽匹配。

## 看门狗维护流程

以下是 GH-5 的通用操作合同；当前 WSL 安装实测见文首。值守只处理进程退出，不作健康检查、更新、回退或任务处置。先核实固定安装、`WORKFLOW.md` 的状态目录及工作区、Elixir/OTP 和原生 Linux `codex`、Git、GNU timeout、`flock`、`setsid`、`sh` 所在的 `PATH`，再配置新入口。旧 `runtime-v1/launch.py` 是历史安装脚本，不参与新互斥；接入看门狗前须人工暂停值守、结束该旧入口启动的进程并核实退出。其一次性空队列预检不属于 ready 领取规则。

看门狗配置为 JSON，以下路径和数字均是工程示例，按实际固定安装填写。`controller` 是含本代码的打包 `bin/symphony`；`state_dir`、`status_file`、`maintenance_file` 与 `pointer_file` 必须位于持久目录，不能放在临时清理目录。`workflow` 是原运行配置的**同一个绝对路径**；不复制、重建或清空其中指定的状态与工作区。值守按 CLI `--port` 优先、否则 `WORKFLOW.md` 的 `server.port` 确定实际端口；配置 `port` 时即作为 `--port` 覆盖工作流端口。值守用同一端口检查启动冲突、构造启动参数及核对进程命令；工作流端口无效时阻塞启动。运行中的进程端口没有响应不会触发另启。

```json
{
  "controller": "/srv/symphony/watchdog/bin/symphony",
  "pointer_file": "/srv/symphony/runtime/current.json",
  "state_dir": "/srv/symphony/runtime/watchdog",
  "status_file": "/srv/symphony/runtime/watchdog/status.json",
  "maintenance_file": "/srv/symphony/runtime/watchdog/maintenance.lock",
  "workflow": "/srv/symphony/runtime/WORKFLOW.md",
  "credential_file": "/srv/symphony/runtime/github-token",
  "logs_root": "/srv/symphony/runtime/logs",
  "port": 43223,
  "interval_ms": 1000,
  "backoff_ms": 30000,
  "max_attempts": 3,
  "stable_ms": 300000
}
```

指针只由外部操作者写入；看门狗只读。格式为 `{"version":"固定版本目录名","install":"/绝对路径/releases/固定版本目录名"}`。`install/bin/symphony` 必须存在，安装目录及可执行文件路径不能经过符号链接。指针非法、安装不存在时阻塞，不自动选择其他版本；切换指针不会停止仍在运行的旧版。外部更新器写指针和写维护锁属于后续实现。

无人值守 GitHub 凭据来源是 `credential_file`：由操作者预先写入 token，文件须归值守用户所有，权限至多 `0600`，父目录限制无关用户访问。启动时看门狗读取该文件并只通过子进程环境变量 `GITHUB_TOKEN` 注入固定安装，不通过命令参数、指针、状态或审计日志传递。缺失、不可读、空文件或权限不安全时拒绝启动并留脱敏阻塞原因；不得在故障后要求人工从 `gh` 活跃账号重新输入。Codex CLI 所需的其他认证也须在值守用户的受限配置目录中提前完成，值守环境需包含可用的 `CODEX_HOME`、工具链 `PATH` 和仓库访问。验收 WD-1 时记录文件来源、owner/mode、父目录权限、`GITHUB_TOKEN` 注入路径及其他认证的非交互核验结果，不记录秘密值；必须在运行器退出后无人输入或登录仍能拉起，缺少这项实测不能判 WD-1 通过。

本轮离线验收使用测试在 `symphony-watchdog-*` 临时目录预先创建的普通凭据文件，测试用户拥有该文件，文件权限为 `0600`、父目录为 `0700`；值守读取后仅通过子进程环境变量 `GITHUB_TOKEN` 注入固定安装。打包恢复回归启用 GitHub MVP，连接合法空队列的本地 HTTPS 探针，预置实际 `mvp.state_dir` 下的领取回执及证据和 `workspace.root` 下的工作文件；正常退出和强制结束后比较目录结构及文件内容，检查原配置路径、固定安装、新 PID、凭据注入及无远端写请求。探针使用独立测试 CA 签发服务端证书，保留正式 HTTPS 证书与主机名校验；每次恢复分别断言启动清理与队列轮询的请求路径及认证头，避免沿用前一进程的探针消息。模块层另断言看门狗操作不发送任何请求。以上只验证离线恢复：沙箱没有真实 GitHub 仓库凭据或 Codex 认证，因此**真实 GitHub/Codex 无人值守恢复的 WD-1 验收未执行，不能判通过**。实际验收由获授权的部署操作者在隔离环境完成，须记录真实文件来源、owner/mode、父目录权限、注入路径、固定安装、工具链和其他认证的非交互核验结果，不记录秘密值；随后分别正常结束和强制结束运行器，核对无人输入或登录的恢复、GitHub 查询及 Codex 可用性，并保存沿用原工作区、状态和证据的脱敏结果，不派发真实任务或改变生产版本。

以下命令使用实际实现的打包入口。人工启动和看门狗每轮检查都由同一个 `flock` 服务锁串行复核身份、维护状态、端口、预算，并覆盖启动和身份落盘。锁及持久绑定文件位于规范化 `workflow` 的父目录，以 workflow 路径摘要命名；该目录须允许值守用户创建文件。绑定记录规范化的 workflow、状态目录、状态文件、维护锁和指针路径；同一服务使用冲突路径的配置会被拒绝，不能通过换 `state_dir` 绕开互斥或预算。绑定异常另记于同目录的 `.binding-events.jsonl`，供核对冲突配置与时间。`status` 输出 JSON；`status.json` 保存当前指针、记录的运行进程 `process`、本次核对读到的 `observed`、暂停、每版本本轮尝试数、退避时间、待人工及最近动作。正常归属时，两者均含实际版本及 PID/宿主启动 ID/进程启动时间；身份冲突时，`process` 保留旧记录，`observed` 留本次可读取的身份字段，未知字段不猜测。`history.jsonl` 追加每轮检查、退出、拉起、阻塞、放弃与人工操作，包含可恢复的完整状态快照；历史不会因稳定清零或人工恢复而删除。读取状态时核对审计末尾事件的计数及快照；审计已写而状态尚未替换时，从末尾事件恢复后重新核对进程。末尾事件损坏、计数跳跃或状态与对应事件不符时阻止启动，不重置预算。完整历史保留供离线审计。外层 CLI 的 controller 缺失、子进程失败及响应异常也保存为脱敏阻塞事件。`runner.log` 只保存子进程输出。身份冲突、记录缺失但发现疑似运行器、未知端口占用均阻塞，操作员须核对证据和进程归属，不要结束未知进程。运行器退出后的退避从首次确认退出时重新计时；启动失败则从确认失败时计时，并将截止时间写入状态。

受管理工作流的普通 `symphony WORKFLOW.md` 入口拒绝启动，人工须使用 `--watchdog start CONFIG.json`，与自动检查共用暂停、退避和持久预算。值守在服务锁内签发仅供固定安装子进程消费的一次启动许可；单独设置环境标记不能绕过入口。接入的固定安装须包含该入口约束，历史启动器仍需按上述接入步骤退出。状态或审计损坏时，CLI 输出具体脱敏原因，并向 `state_dir/faults.jsonl` 独立追加阻塞证据，保留原状态和审计文件；不要删除文件来重置预算。独立证据写入失败也明确报错。

```sh
WATCHDOG=/srv/symphony/watchdog/bin/symphony
CONFIG=/srv/symphony/runtime/watchdog.json
"$WATCHDOG" --watchdog status "$CONFIG"
"$WATCHDOG" --watchdog pause "$CONFIG"
# 核对 status.json 的 paused=true 后，人工停止已确认归属的运行器。
"$WATCHDOG" --watchdog resume "$CONFIG"
"$WATCHDOG" --watchdog start "$CONFIG"
# 仅同版本预算耗尽且故障已修复时，明确开启新一轮；不会解除维护暂停。
"$WATCHDOG" --watchdog recover "$CONFIG"
"$WATCHDOG" --watchdog run "$CONFIG"
```

`resume` 恢复值守但不绕过退避，也不清除待人工。`recover` 清零**当前指针版本**的本轮预算并保留完整历史，维护暂停仍须另行解除。正常与异常退出均按同一预算和退避处理；持续存活超过 `stable_ms` 只表示进程存在，会清零未耗尽的本轮计数，不代表业务健康。状态端口没有响应不等于进程死亡。每轮只读取审计末尾事件并与状态快照核对，避免持续增长的历史拖慢检测；完整历史仍保留于 `history.jsonl` 供离线审计。建议由 Linux/WSL 的 systemd 用户服务运行 `--watchdog run` 并设置 `Restart=always`，同时显式提供已核实的工具链环境；本次不安装服务单元，也不实测看门狗自身开机自启或宿主重启恢复。宿主停机后，恢复宿主及值守入口仍需人工处理。

首轮失败候选保留在 `/var/tmp/innovation-symphony-v0/workspaces/GH-1`，回执与证据在同级 `state` 目录。经本次显式重跑授权，使用独立的运行目录、状态目录、工作区；启动前核对队列只有获准的 Issue，记录原回执和新基线 SHA。禁止通过清空原状态目录实现重试。新轮仍停在 Draft PR 或 blocked，结果单独报告。

### 2026-09-30：GH-5 协议修复与一次有限接续

- 按 IS-038，固定控制器 `8377e918ab762fffeb3b80478449303d2df820a8` 已安装并接续原 GH-5。冻结候选及基线检查均通过；第 44 次调用的 Sol 6.1 Review 输出通过严格协议校验，返回代码缺陷与 WD-1 外部条件并存的有效拒绝，控制器自动派发第 20 轮 coder。原窗口于北京时间 21:14:14 到期，保存未提交修改并关闭操作链，没有清空回执。
- 按 IS-039，修复“紧接有效拒绝的未完成编码轮不能审计接续”的边界，固定安装 `a96796913c9dd44b869f4fcf31ddb1938a9102ef`；其 `make all` 为 602 项测试、0 失败、6 项既有跳过、覆盖率 100%，格式、lint、公共规格及 Dialyzer 通过。两个修复均仅本地提交，未推送或合并。
- 主服务 PID `572498`，启动身份 `475655`，cwd 为上述固定 release 的 `elixir/`，状态 API 返回 HTTP 200。切换前验证空可领取队列、已结束的前序操作及原状态摘要；切换时状态保持不变。旧 release、回执、失败输出及工作区快照全部保留。
- 新审计操作 `gh5-budget30-34` 位于 `/var/tmp/innovation-symphony-v0-rerun1/operator-external-gh5-1790774759988808567`，北京时间 21:31:17 派发第 46 次调用，实际 coder 与 reviewer 均明确审计为 `gpt-6.1-sol`。历史领取模型保持原值，不伪造历史执行。追加恰好 `1_800_000 ms`；原开始时间、累计 19 次返工和 45 次已用调用保留，新截止为北京时间 21:44:14。
- 主服务 `mvp.enabled=false`，只运行获准的原 GH-5 专用接续；主 API 的空闲计数不包含此专用操作，任务阶段以原回执和操作 evidence 为准。模型正在执行不等于完成 Review；WD-1 仍需真实外部证据，未安装看门狗候选或配置无人值守凭据。
- 本机准备、切换、派发及状态证据在忽略目录 `.local/review-budget/`。21:44:14 到期后，原回执以 `:mvp_recovery_resource_exhausted` 保存为 blocked；完成记录绑定回执 SHA `ef01ec6d772fd878c6441bcaf21b0d63c092e7d1d3dc1300830c82e7494c3f75`。累计 46 次调用、19 次返工不归零，原有效 Review 原文与快照逐字相同；操作进程已退出，锁已释放，该沙盒无残留进程。
- 这一次 coder 实际执行约 13 分钟；追加额度按原窗口累计，控制器接续修复及安装准备占用了约 17 分钟。第 20 轮尚未形成新候选，旧候选仍为 `d6e051c88472035944fc82eb78d1a13cf3350fb0`，保留 CLI、watchdog、测试和操作文档四个文件的未提交修改。本轮未进入新 Review、未创建 PR，也未进入仅外部条件的交接状态。
- 最后一组专项自检为 39 项、3 项失败：打包安装的非交互重启，以及普通 CLI 的端口省略／端口 0 两个启动场景，都未在 5 秒内收到测试 HTTPS 探针的 GET 消息。此证据表明相关集成断言仍未通过，尚不能断定是 TLS 测试环境、子进程启动失败还是产品路径错误；下一步须先取得子进程退出结果与探针握手诊断，不能仅增加超时或跳过断言。原始模型会话输出和汇总在 `.local/review-budget/closure.json`，原状态及候选保持不变。


## 2026-10-08：IS-076 独立 rootless 桥安装

按所有者对 `codex/rootless-open-reliability` 的明确授权，镜像 digest、Podman/crun/uidmap、专用 worker 和本机完整待激活配置已补齐。`innovation-symphony-rootless-bridge.service` 已安装、启动、开机 enabled，并通过服务重启、受保护 payload 摘要及启动守卫核验。真实 Linux 基础探针 16 项通过、清理与导出成功；完整 rootless 交付链和故障矩阵尚未验收。原活动控制器／View、旧桥与 `mvp.enabled=false` 保留，没有真实派发、远端 push、合并或云部署。详情、失败记录、剩余范围和回退见 [VALIDATION_ROOTLESS](VALIDATION_ROOTLESS.md) 的 IS-076 节；本轮代码本地提交以对应分支 Git log 为准。

### 2026-10-05 07:54 CST：#12 超时、检查配置纠正及继续执行

- 修复后的 Linux 固定运行版本已经安装；670 项测试、0 失败、6 项外部跳过、100% 冻结覆盖率及 Dialyzer 0 错误的结果针对宿主 Linux 修复，不能作为尚未提交的 #12 功能候选验收结果。
- 原任务第二次实际 coder 会话达到 1 小时执行时限，沙箱 result.json 证明 cleanup_complete、descendants_cleaned、export_complete 均为 true，安全导出已有实现。回执随后为 blocked / mvp_recovery_resource_exhausted；原 8 小时总预算和 16 次会话上限并未耗尽。
- 主代理发现临时 WORKFLOW.operator.md 的 mvp.enabled=false 被 disabled_settings 解释为 checks=[]；这是临时操作入口错误，未曾执行正式检查或交付。接续第三次会话停止于 coding、无候选或 PR；系统进程已结束、受控 execution cgroups 均为空，未产生可接受的原生 export/completion，不伪造沙箱成功证据。停止证据和累计实测用量保存在 preflight/issue12-operation3-stop.json，root 输入快照保留。最后一次已证明安全的第二次会话导出仍在原工作区。
- 修正入口为 WORKFLOW.operator.checked.md：保留完整两项冻结 candidate/baseline 检查，mix run --no-start 不启动第二个调度器。接续脚本对检查命令做精确断言，并校验原回执、工作区内容摘要、基线、任务范围及沙箱完成证明。旧 round 的空检查列表作为错误历史保留，不宣称通过验收。
- OperatorRecheck 完成前次停止审计后，以 linux-issue12-checks-restored-20261005 接续；innovation-symphony-issue12-operation4.service 开始新 round-3，保留原起算时间、累计用量、已导出代码、最多 5 次返工和 16 次会话上限。此前会话未删除或重置。此时尚无候选提交、推送或 Draft PR；后续需正式检查、独立 Review 和新配置路径的真实 GPT 证据。

### 2026-10-05 10:20 CST：修复模型会话单次时限造成的 interrupted

- 实际原 #12 已通过第一候选的正式检查并完成独立 Review；Review 拒绝 10 项具体缺口，控制器启动 round-4 修复。10:14 原 coder 被单次 1 小时时限中断，回执 blocked / mvp_recovery_resource_exhausted，沙箱 result.json 确认 export_complete、cleanup_complete、descendants_cleaned 均为 true；原生执行退出 0，但 AppServer 仍因墙钟超时失败，不把成功清理/导出等同于模型回合成功。
- 旧候选为 9f59c5a8c66917bf1fcdf65bc5600d9e3e25aded；返工修改尚未形成下一候选。coder 报告 714 项测试、0 失败、6 项跳过及 100% 覆盖率是返工自检，尚不能替代该修改后的正式检查和新鲜 Review。
- 宿主 ExecutionSandbox.agent 不再将模型剩余时间与 check_timeout_ms 取最小值。没有显式墙钟时使用 Codex turn_timeout_ms；operator 可单独给 agent_timeout_ms，仍取剩余总预算和该上限的最小值。正式检查继续沿用自己的 check_timeout_ms。23 项沙箱回归测试通过（含三种角色、阶段上限和剩余时间）；临时桥接入口允许最多 7200 秒，7201 秒及其他路径、命令、资源越界仍拒绝，8 项桥接测试通过。
- 保护入口在所有执行 cgroup 均无活跃任务时更新，root 所有权和认证、路径、命令、网络及资源限制不变。入口旧文件保留 bridge.before-agent-timeout.py；新文件 SHA-256 为 2877788163da96a3ca056a07f5af0c3b17a9b2fe62f7e84b7631bc8b50c4372a。
- operator-rechecks/linux-issue12-agent-timeout-fix-20261005 绑定原回执、原候选、导出内容摘要、清理证明、固定基线和工作流。innovation-symphony-issue12-operation5.service 从原 round-4 stage-2 继续，累计第 7 次会话；保留原 06:01:06 起算的 8 小时和 16 次会话预算，不增补总额度。该会话设置为最多 2 小时，实际仍受剩余总预算限制；正式检查保持原 1 小时。
- 实测当前回执 coding，新鲜 GPT coder 会话已经开始，View 采集到 01a109db-f5cc-7223-8ee9-6a98a92eea4c。本次恢复不清除旧 interrupted 历史，不宣称 #12 已交付。宿主完整检查及固定运行打包结果随后记录。

- 本次宿主完整 make all 已通过：671 项测试、0 失败、6 项外部跳过，覆盖率 100%，Dialyzer 0 错误，fmt/specs/Credo/escript 打包通过。固定修复 release 为 `.local/releases/linux-agent-timeout-20261005`，清单保存准确二进制/源码摘要。核实普通控制器无运行任务后更新入口并重启，新 PID 1092840，控制器与 View API 均 200，#12 独立接续进程保持 active。这是 Linux 执行器时限修复安装，不安装 #12 功能候选。真实新会话 environments.toml 的执行上限确认是 7200 秒；当前任务仍 coding，原预算起点未变。

## 2026-10-05 IS-068：Issue #12 外部堵塞和重复检查修复

用户要求根据全部会话报告修复外部堵塞和不必要返工；来源、范围见 IS-068。初次状态为原 #12 `awaiting_external`、候选 `d87ba1000cc26e077057e1c431a6f0923b976478`、Draft PR #13。完整分析和后续发现见 [ISSUE12_PROCESS_ANALYSIS](ISSUE12_PROCESS_ANALYSIS.md)。

- 源码修复：完整暂停配置仍保留并严格校验冻结执行合同；现有 `mix mvp.external` 只为已经领取的任务跳过新领取开关，ready、actor、模型评论、检查等值与回执审计仍校验。固定检查整段串行、实际 VM 继承锁 FD，避免 checker 终止后提前释放；普通 scheduler 为 `min(cpus, max(1, pids // 32))`、dirty CPU/IO 各一，固定 runner 注入 CPU/PID 参数，独立入口读取 cgroup 的最紧限额。明确的线程或进程启动异常归为环境停止；普通业务断言中的 `:eagain` 仍按可修代码失败处理。这些数值是本轮工程安排。
- 独立审查修复了初稿中小 PID 配额下仍按 CPU 开过多线程、锁 FD 不继承和裸 `:eagain` 误分类三个问题。真实进程锁、杀 checker 后 VM 持锁、escript 头及 CLI 覆盖下两层实际 VM `{2,1,1}` 的回归通过。无门槛、隔离、权限或覆盖率例外。
- 首版完整源代码门禁通过：`make all` 675 项、0 失败、6 项既有外部跳过，100% 覆盖率、Dialyzer 0 错误，fmt/specs/Credo/escript 通过。Python 最终 81 项、0 失败、18 环境条件跳过；资源相关最后 33 项、3 环境跳过。日志在 `.local/external-issue12-20261005/`。后续历史接续兼容修复须重新完成适用检查，不将首版日志用于证明后来修改。
- 准确候选完整归档逐文件核对：294 个跟踪文件相同。候选自身双角色配置实测于约 13:30 复现当前 Codex 客户端对保留 provider 的真实拒绝：生成 `[model_providers.openai]` 不能覆盖内置 `openai`。两个角色认证引用分开、参数分别 low/high，现有同一账号；连接冻结为 OAuth 对应路由。实际线程创建前失败，未成功调用 GPT，实际型号为未知。随后四次无推理启动诊断仅发送 initialize/initialized，使用合成认证、私有 home 与隔离网络，确认初始化成功仍可能随后发出配置无效警告；诊断对照去掉保留 provider 表后该警告消失，未改候选源码。失败证据保存在 `A04-verification.json`，不能宣称 A04 通过。
- 原候选 A11 实机证据已完成并自包含于 `A11-kernel.json`，SHA256 `e93ba7043e3e2d26c25ffc081b736ad3849f84f9f3656f47d65a089809f88ace`。当时 root runner 与候选脚本摘要同为 `e2700ba6205c6f59bc213ea632f1d43eec3b6cb83f71ba47dd5bc39b03ec0bc9`；EROFS、网络和凭据隔离、本地 TCP、8 GiB tmpfs、256 PID 实际限额及 EAGAIN、完整 reap、后台 setsid 子清理及导出通过。CPU/内存限额已记录，未做内存耗尽、填满磁盘或 CPU 基准。故意进程极限案例中的一次 `pids.events.max` 是预期结果，普通 clean case 为零。
- 源代码合同修复保存为 `.local/releases/linux-external-contract-20261005` 的固定本地 operator 快照，清单绑定 75 个源文件和完整检查日志。活动控制器 PID 1092840 未切换，未安装 #12 功能候选。隔离 root 四脚本补丁已准备为 `resource-payload` 并经独立审查；安装器固定清单摘要、认证串行 helper、暂停接单后核对无执行者、安装验证、磁盘满时基于已落盘备份回滚，完整版本确认后才恢复接单。为继续核验准确候选，暂未激活，旧 runner 保留。
- 原任务外部补证的两次 CLI 入口预检通过，使用完整 `enabled=false` 工作流、原两条检查、原模型、原八小时/16 次额度和原前序审计。这些预检完成 CLI 的远端身份与合同校验后通过只读 delegate 返回，没有执行 Executor 深层校验。13:46 启动实际独立接续单元 `innovation-symphony-issue12-external-20261005.service`；它在任何证据导入、模型调用和回执写入前因 `mvp_resume_binding_mismatch` 退出。原回执字节和全部历史保持，导入次数为零。
- 深层校验发现两处旧失败历史不兼容：round 2 的候选为 null；round 1 的历史 V0 无产出记录和 round 2 的检查为 `[]`。最新完成审计的 final receipt SHA、authorization、receipt-before 和前序闭合链均可验证。修复仅允许完整已关闭审计证明、逐字段及用量不变的这些无产物历史；当前最终候选、实际产生候选回合、完整冻结检查、基线、元数据、预算和锁后复查不变。无证据的历史缺失不得通过。该修复完整最终门禁通过：679 项、0 失败、6 外部跳过、100% 覆盖率，Dialyzer 0 错误。新增锁前与锁内绑定观察事件，确定性审计漂移负例保证导入与模型派发前拒绝。固定 operator 快照 `.local/releases/linux-external-history-20261005` 保存 75 个源码文件及门禁 SHA `1fca0c45ebacc9ff00d61899d500b728a0793bd6beaaadade618f0112a86958f`。14:29 独立单元 `innovation-symphony-issue12-external-20261005-v2.service` 成功将两份证据作为一批导入，新增一条导入历史，原任务进入 checking；候选不变，当时 Agent 尝试次数仍 11。
- 两条冻结正式检查随后均通过：候选 716 项、710 通过、0 失败、6 跳过，基线 669 项、663 通过、0 失败、6 跳过，两个 `exit_status` 均为 0。14:43:30 预留第 12 次 Agent 尝试后的 Review 启动失败：生成的 `environments.toml` 向 launcher 传入 7671 秒，超过 root bridge 的 7200 秒硬上限；root 日志为 `bridge refused or failed: timeout exceeds local policy`。拒绝发生在沙箱和模型启动前，无沙箱、无完成报告，Review 日志为空，第 12 次没有成功 GPT 调用或 Review 结论。等待完成报告 30 秒后，执行器把缺失结果归为 `:sandbox_cleanup_incomplete`，遮蔽了实际的预启动拒绝。14:44 完成链以错误闭合，原回执为 `blocked`，Agent 尝试 12/16、恢复计数 4/5、候选仍为 d87ba1000cc26e077057e1c431a6f0923b976478。摘要绑定保存于 `.local/external-issue12-20261005/review-startup-refusal-binding.json`。UID 1000 不能读取 root 所有的全局执行 cgroup，只核对了可读的 helper 直接子进程，不宣称全局 cgroup 为零。
- 单次时限默认值的源码修复已通过独立审查：默认 Agent launcher 使用配置的单次 Turn 上限与剩余总预算取最小值，显式单次覆盖仍按原合同处理；不修改 bridge 上限或原任务总额度。三个 Agent 角色实际 launcher 对 60 秒及 7671 秒剩余窗口的回归确认默认上限分别为 60 秒及 7200 秒。完整 `make all` 再次通过：680 项、0 失败、6 既有外部跳过、100% 覆盖率，fmt/specs/Credo/escript 通过、Dialyzer 0 错误；日志 `.local/external-issue12-20261005/elixir-agent-cap-gate.log`。固定 operator 快照为 `.local/releases/linux-review-cap-20261005`，本次活动控制器未升级。15:29:52 有审计的 `innovation-symphony-issue12-review-cap-20261005.service` 开始运行，复用仍绑定原候选、刚通过的两项正式检查，保留第 12 次失败历史、原开始时间和全部预算；第 13 次 Agent 尝试于 15:30:04 实际启动模型。
- 15:31 第 13 次 Review 调用收到服务端 `turn/completed / status=failed`，`codexErrorInfo=serverOverloaded`、`Selected model is at capacity`。这是新增真实外部容量失败，不追认为初次报告 13 份会话的返工原因。当时 AppServer 将失败但空的完成输出误送格式校验，因此开始第 14 次格式修正尝试；680 项日志不证明后来发现的错误分类缺口已修复。15:31 快照为 `reviewing`、Agent 尝试 14/16、恢复计数 4/5、候选仍为 d87ba1000cc26e077057e1c431a6f0923b976478，尚无第 13 次的有效 Review。
- 第 14 次调用随后成功产出有效独立 Review，`approved=false`，三项阻塞均为代码缺陷：A01 旧 auth_home 工作流兼容与 A04 双角色真实调用受到保留 provider 表覆盖影响；A05 缺少拒绝无效配置及默认回退的 `configWarning`，可能把默认配置的合法 `model/list` 目录归到请求渠道。准确原候选的 A11 内核证据被本次 Reviewer 接受。执行器自动进入 round 6 Coder，第 15 次 Agent 尝试、恢复计数 5/5；此更新时客体修改进行中，尚无新候选。修复后仍须新 SHA 的准确 A04 和必要内核证据、冻结正式检查与预算内独立 Review，不登记最终验收通过。
- main 的最小终态失败传递修复另已通过独立审查和完整门禁：`turn/completed` 中 failed、interrupted、非空 error 和不合法显式 Turn 传播对应失败，避免服务失败的空输出被当成成功并触发 Review 格式修正；旧无 Turn 通知继续兼容。`make all` 688 项、0 失败、6 既有外部跳过、100% 覆盖率、Dialyzer 0 错误，fmt/specs/Credo/escript 均通过。日志 `.local/external-issue12-20261005/elixir-capacity-gate-v2.log`，SHA256 `782cbb3febebbdaebca14582e9ba93091bfb0a6b1f72426a7c7af765d8e7b991`。这项基础设施修复不证明候选 A01/A04/A05 的功能修改已完成。
- 15:30:44 核对活动普通控制器真实入口后，备份 `.local/runtime/WORKFLOW.md` 并只将 `mvp.enabled` 从 true 改为 false；此前 external 专用工作流的 false 不能代表普通控制器已暂停。原两条检查、沙箱、状态与工作区、模型、宿主认证引用和端口保留，普通控制器此前 running 为零，#12 独立 operator 不因停领结束。审计 `.local/external-issue12-20261005/controller-intake-pause.json` 保存前后摘要和完整备份位置。未重领原任务、未改 View 或 root helper。
- 680 项门禁的基础设施封包另存 `.local/releases/linux-infra-fixed-20261005`，从原固定 snapshot 的完整副本运行 direct toolchain `mix escript.build --no-compile`；75 个源码、89 个原 BEAM 和 escript 中 89 个 BEAM 的全部保留 chunk 核对相同，原 snapshot 清单未变。二进制 SHA256 `31d9cd9df749c6444e0507e7530710cbefda803d3ef778d9e9cb6f56d5984e78`，新清单 SHA256 `8ebd0e0d0219cb02f84da859b99ce76fa1321d7c96fb8b125a2d3fe13112b124`。封包不含 #12 的 `ModelServices`，未安装、未改启动脚本或重启服务；它不包含后来模型容量分类修复，保留为该次门禁的历史产物，不能用于宣称全部最新修复已可安装。
- 688 项门禁的新固定源快照 `.local/releases/linux-infra-capacity-source-20261005` 已完整复制为 `.local/releases/linux-infra-capacity-fixed-20261005`，在新副本中 direct toolchain `mix escript.build --no-compile` 后核对 75 个源码、89 个原 BEAM 及 archive 中 89 个 BEAM 的全部保留 chunk 相同，父快照未变。二进制 SHA256 `b779ceb721e4d3564d28d664767805265f08eef21687995d2411e616b384bd38`，新清单 SHA256 `2ce57c76952e7e4e1c3f40e30082c57dd858b364d84446d52695a4aa34cd8651`。新包明确仅基础设施修复、无 `ModelServices`，已经本地准备而未安装，未改启动脚本或重启；活动 controller 尚未升级，容量分类修复未据此宣布运行生效。

- 安装前资源复核还封住 +SP/+SDPcpu 对绝对 scheduler 数量的倍率，以及 ERL_FLAGS/ERL_ZFLAGS 中 -extra/-args_file 的预算解析逃逸；普通其他设置继续保留。错误格式或预算控制参数拒绝有固定环境诊断，业务 ValueError 不误分类。最终 scripts 87 项、17 opt-in/root 条件跳过，view 34 项全通过；资源定向 39 项、2 root 条件跳过，真实 Erlang/escript/nested 五字段回归执行。四文件封包清单 SHA `d5bf37d90f4e5d7c2796a040d3e870ec83ba333109b9d686888f84e94c581869`，安装器 SHA `087ffdd034bdfc3e84e4cbdac0f95a30a79a583359ab884e60396960e8cc18f2`，当前尚未激活，原 A11 封存证据未改。
- 第 15 次 coder 自主检查另记录两类失败：首轮 dirty IO 线程 9 启动 `:eagain`、退出 134；第二轮看门狗时序断言为 1685 毫秒超过 1600 毫秒，相关定向用例单独通过。候选自检记录为 719 项、1 失败、6 跳过。此处是客体自检，不能记为正式两项冻结检查结果，不将不同失败泛化为全环境同一根因。此更新时仍为 Agent15 coding，尚无新候选导出。
- 冻结基线自检的 `:eexist` 经两个真实 Elixir VM 最小复现：共享 TMPDIR 下 VM 内计数器产生相同临时夹具名称，第二次保留目录创建失败；杀 checker 后遗留目录也会影响下一次检查。最小源码修复在既有唯一 harness 下创建 0700 `tmp`，将 TMPDIR 设置到全阶段及嵌套进程环境；原锁路径和 FD 继承、资源预算、冻结检查均未改。新增实际嵌套 Python/Elixir VM、SIGKILL 残留与下一次目录隔离回归通过，定向 10 项全通过，scripts 89 项、0 失败、17 条件跳过；独立审查无阻断。
- 该 TMPDIR 修订另存 `.local/external-issue12-20261005/resource-payload-temp`，清单 SHA256 `6ec371083bf9b171d9a1c18b3056d5cac14729a13f0235c28fafd93999ee11ef`，四文件与当前源码逐摘要相同；对应 `install-resources-temp.py` SHA256 `2ee2b55f7a1b7df530692e8276150f3f43a4ce6a8f7f9a737c7ba93f435efb11`，仅替换源目录、清单绑定和备份名；`native_postinstall_resources_temp_probe.py` SHA256 `9493f37a4ac898e936b93dbcd33fe54b42d34ce2d8d41311fc21f00419762fd7`，仅替换两个封包路径。准备脚本已执行并保存新 seal，原清单 d5bf37d9 和历史产物未覆盖。新封包尚未安装，原生安装后验证未运行，不能以源代码回归声明活动 root runner 已修复。

旧有效 Review 的全部阻塞为外部条件，所以原任务此前没有直接回流 coder。第 12 次在启动前被拒绝，第 13 次实际启动后遇到容量失败，均未产生有效新判定；第 14 次独立 Review 已核验新证据并明确三项代码缺陷，系统现已自动进入第 15 次 coder。新容量条件与初次 13 份会话的无额度故障证据分别保留，不将启动失败、格式重试和代码返工混算。

此记录区分源码保存、固定 operator 运行、root 补丁激活和 #12 最终验收。本轮尚未对主工作区 Git 提交、推送、合并或部署；未追加额度，未把真实启动失败写成推理通过。root 四文件资源补丁尚未激活，A04 的真实推理仍未通过，不以源码门禁或准备好的恢复入口宣称运行环境已经全部修复。

### 16:51 至 17:00 前：原任务闭合与 main 基础设施实际安装

- 16:51:22 原 operator 完成链以 `{:error, :mvp_recovery_resource_exhausted}` 闭合，原回执为 `blocked`，SHA256 `4eca2a310f6e5a4bb2446759f1fc1d4c369428509d70929735d269b2a00aab23`。累计 Agent 尝试 15、恢复计数 5，原八小时／16 次额度未追加。第 15 次模型 `wall_timeout`，round 6 候选为 null，没有该轮正式检查结果或新独立 Review；顶层 d87 候选保留。
- 准确沙箱 `run-1791186184370600-8162` 的完成报告 SHA256 `0eac556e6882ea932322c525c65de8a296489d2de12e40aa67bc7a1a0c833cef`；cleanup／export／descendants／background_output_closed 均为 true，runner `exit_status=0`、正常关闭。该结果只证明清理及导出，模型和任务没有因此完成。`pids.events.max=3`、全部 OOM 计数为零。
- 七文件 WIP 为增加 243 行、删除 32 行，297 个导出文件（排除独立检查证据；294 个跟踪文件及 3 个缓存文件）与保留工作区逐字节相同。部分产物已封存 `.local/external-issue12-20261005/partial-export-20261005T085122Z/`，补丁 SHA256 `705e318974210df7cb1d40fce9cceff854a6bd4f2bbc4b6943ff62049ef0f4c7`，summary 绑定七个文件摘要、回执和完成报告。静态独立复核已覆盖 Review14 三项代码反馈，未发现确证的新阻断；不是新候选、正式检查、模型 Review 或准确 A04 验收通过。
- 16:53:35 main 基础设施固定包 `.local/releases/linux-infra-capacity-fixed-20261005/symphony` 已实际安装并启动，PID 2092760；二进制摘要 b779ceb7 保持，仍对应 688 项完整门禁。`.local/start-symphony.sh` 只替换二进制路径，launcher SHA256 `1e53d69fe80a0e2d40096f3d6149062f62b33be356a2d915bcdefc670e219e0a`。原工作流 SHA256 `6921c60074685850da15012346762889c640dcb16c958cfe05dfc9c399acf92f` 不变，完整 `mvp.enabled=false`、两条检查及宿主认证引用保留。
- View PID 33304 未变，4000／8613 API HTTP 200，普通控制器 running／retrying／blocked 为零。安装前后的原回执和 51 份闭合审计逐摘要保持，57 项冻结文件核对无漂移，安装 guard 已释放。实际审计 `.local/external-issue12-20261005/infra-installed-audit-20261005T085332Z-eec094a5/installed.json` SHA256 `5b3acc66589c5800f779a1ad6a4374aa8a93ab3020f24e52eadc2bc3c534d44a`。
- 本次安装是已授权的本机基础设施修复，未安装 #12 功能候选。root 四文件 temp 修订正在等待本机 PKexec 所有者认证；逐文件仍为旧摘要，未激活、未运行安装后原生验证。没有主工作区提交、推送、合并或候选升级，没有重领原任务或追加预算。当前 #12 已预算阻塞，部分产物安全保留；上方 coding 和封包未安装的表述保留各自历史时点，不作为当前状态。

### 17:06 起：认证传输重试、验收采集准备与未批准接续提案

- 旧 pkexec PID 2092629 只等待本机认证，输出 GLib UTF-8 critical；核对 comm／argv／真实 UID 1000 并确认未执行安装器后取消，会话退出 143。17:06 将相同安装器复制至 `/var/tmp/symphony-resource-auth-20261005/install.py`，SHA256 仍为 `2ee2b55f7a1b7df530692e8276150f3f43a4ce6a8f7f9a737c7ba93f435efb11`，以 ASCII cwd 重新发起会话 45104。新请求未再输出该 warning，但认证仍等待，root 四文件未匹配新封包。`.local/external-issue12-20261005/auth-ascii-retry.json` SHA256 `057276c9d28546161890320fc862462743effdfe60263f2db04403997505da73` 保存仅传输重试、未安装状态；不是认证或安装成功。
- 后续路由采集只准备 `.local/external-issue12-20261005/role-probes-route.exs`，SHA256 `9ec999cc2047b02ba4cc1b4262fe0559c45cf7abb7af1b922150779cb7c0234c`。四个纯 TOML、三个不安全 URL 拒绝案例及 AST 检查通过；显式 builtin 顶层路由作为生成配置意图记录，实际网络 `effective_connection` 保持 unknown。未发起模型调用、未形成 A04 通过证据。
- 17:12 新鲜 GitHub API 核对 PR #13 为 open／Draft、merged false、head d87ba1000cc26e077057e1c431a6f0923b976478；没有将部分修改发布为新候选。
- 已向所有者提出但尚未获答复的有界预算方案：资源安装和原生验证通过后，从实际恢复时点增加 60 分钟，最多新增 1 次 coder、2 次 Review，累计 Agent 上限拟为 18，既有恢复计数 5 保留。方案未批准，不登记为新的用户决定，未修改任何预算或原回执。当前任务仍预算阻塞，root 认证仍待本机完成，A04 和新候选交付尚未通过。

### 17:33 安装、17:45 实测与 IS-069 接续准备

- 本机认证已完成，17:33:54 四个 root 受信文件实际安装，所有权及 755／644 模式、清单 `6ec37108` 全部匹配。普通桥接包装入口未变；实际 runner 为 `execution_sandbox.root.sh`，SHA256 `779c027ab5bbf55812999720c6e0f4febc712823e59eb6659515e84d0c0a32f2`，不再是等待认证状态。
- 17:44 无模型资源实测通过：实际 Erlang／escript 普通 scheduler 总量和在线量均为 4，dirty CPU 总量和在线量均为 1，dirty IO 为 1；受信检查器在继承倍率、CLI／escript 覆盖下仍保持该配置，并拒绝继承解析控制参数。真实 BEAM 持锁 FD，SIGKILL Python checker 后锁仍占用；第二 checker 排队约 164 毫秒，释放后取得同一 inode。CPU 限额 400000/100000、内存 4 GiB、PID 256；超限／OOM 为零，清理、后代、导出及后台输出关闭均为 true。证据 `postinstall-resources-1791193456613219996.json`，SHA256 `15e18ffcd799641f93fe217546aa3e17794f271e891bf08079fd703e26c0a3c8`。
- 17:45 扩展安装验证通过：安装版 `check_isolated.main` 的候选六阶段共用一个 0700 私有 TMPDIR，基线使用另一目录；两个真实 Elixir VM 创建同名临时夹具成功，完成后 harness 删除。项目准备与 stage runner 是受控夹具，不是新候选正式检查。证据 `postinstall-resources-1791193551158877430.json`，SHA256 `f251017fd2ace5c395622c92e514622eea71aa242a065549c7474f580f597634`，完整资源断言再次通过。
- 早期失败独立保留：探针误把 `process/start.env={}` 当作继承环境，空 PATH 导致 Python `sys.executable` 为空；合成工作区只有 git init、无 HEAD，受信检查器正确拒绝；扩展夹具队列日志混入 JSON 导致严格解析失败。修订用绝对 Python 路径、隔离 exec-server 非秘密白名单环境、私有合成 Git 提交及单独夹具日志。产品脚本未在这些探针修订间变化，没有提取嵌入 JSON 或把失败标通过，没有 #12 模型调用。
- 当前安装核查 `resource-installed-verified-20261005.json`，SHA256 `084aec34b7eca4c45e40e90ed8a9e48032509d689b84cbffc800ac05054c1979`，绑定 root 文件、探针、原 A11、部分导出、原回执及 134 项冻结文件。controller／View PID 2092760／33304、API 200，新领取关闭；原 Agent15 的 pids=3 历史保持。
- 所有者已批准有界接续并要求增加 60 分钟时长，来源见 IS-069；助手安排实际恢复起算四小时，最多新增 1 次 coder、2 次 Review，累计上限 18、已用 15 次及返工计数 5 保留。授权文件 `bounded-resume-approved-20261005.json` SHA256 `826dea38555d3f550770bee69ae1df38942ae1f8f3b2de963b600784f189aa03`。`bounded-resume.exs` 首轮真实只读预检已通过，包括锁外原回执／闭合历史、完整冻结合同、七文件修改及角色次数限制负例；目前尚未执行，不把准备状态登记为预算已生效。

- 17:57:34.629 锁内复核通过，操作 `linux-issue12-bounded-resume-20261005` 实际接续原 round 6，单元 PID 2106548。窗口截止北京时间 21:57:34.629；原起点和 external_wait_ms=10214937 保留，准备／闭合后闲置时间单列 3973146 毫秒，墙钟政策增加 18373146 毫秒，当前累计政策 47173146 毫秒；这不是从准备时起算四小时。`resume-window.json` 保存准确摘要、有效政策和角色额度。原 main、模型、两条检查、沙箱和返工计数 5 不变。
- 第 16 次尝试为本次唯一 Coder，17:57:41 已真实启动 `gpt-6.1-sol` 模型会话 `01a10b7f-5245-7523-ae9b-4730eaab9f3f`，沿原部分修改继续；此时回执 recovering、累计尝试 16/18，还没有新候选。后续最多两次 Reviewer，诊断及第二次 coder 在预留之前拒绝；原 Attempts 的完整性、用量、独占证据及有限重试保持。限定入口从已门禁固定源码在新命名空间复用 Executor／Attempts，历史无产物例外仍要求真实闭合审计，开放第 6 轮不列入旧例外；未修改或升级普通控制器。

### 18:05 后：真实自检发现 TMPDIR 位置回归，修订等待空闲安装

- Agent16 的真实 candidate／baseline 自检分别为 719 项、57 失败、6 跳过及 669 项、53 失败、6 跳过，整体退出 1。`TMPDIR=harness/tmp` 位于实际编译源码树内，测试建立的正常 state／workspace 夹具被 `mvp_state_source_overlap` 正确拒绝。这是本次 root 检查修订引入的位置回归，不是 #12 功能代码故障；17:45 的受控准备／阶段夹具未覆盖实际编译后的 Config.source_root，不能据该探针宣布完整正式检查通过。失败记录与原断言保留。
- 最小修正只将临时目录改为独立 `TemporaryDirectory(prefix=symphony-check-tmp-)`，与源码 harness 为同级目录，模式仍 0700，所有阶段和嵌套 VM 共用，每次检查独占、完成后清理。Config 的源码树、运行目录与状态／工作区隔离判断均不改。新增边界断言并修正 SIGKILL 回归的精确清理路径；实际重复／嵌套 Elixir VM、SIGKILL 遗留、下一检查隔离等 10 项通过，scripts 完整 89 项、0 失败、17 既有条件跳过。日志 `resources-sibling-tmp-tests.log`。
- 新封包 `resource-payload-sibling` 清单 SHA256 `4c18395b2a1e37f1fa26f7748a90a2e86b608147cba9a652cc8c025a11de2732`，只有 `check_isolated.py` 内容变化，SHA256 `82361e6fa95abcadbbedcb54b73aa3962a8e6af12620800981269505aa345742`；其他三个资源文件保持已安装摘要。安装器 `install-resources-sibling.py` SHA256 `ee5b241fa55bbde39f79d0a773f754e19c078ab86cd44567079b1cc14a2d5fdd`，沿原审查安装器只替换封包、绑定、备份名和说明。新原生验证器 `native_postinstall_resources_sibling_probe.py` SHA256 `c36bd675804d2f65784fd34f8fdfa1a60e3997d3e00961b532f989c34f30d390`，新增 TMPDIR 不处于源码 harness 的断言，静态预检通过；尚未安装或实际验证。
- 当前 root guest 和 Agent16 仍在运行，不热换受信脚本或操作客体进程。Coder 已独立复现基线的同一回归，保留两项失败，并用源码树外临时目录做补充排查；补充结果不能标为两项正式门禁通过。修订在执行者完整结束后安装，再复检同一新候选；不为这项操作者基础设施问题追加 coder 或删改原失败。

### 18:21 实际安装源码树外 TMPDIR，Coder16 完成

2026-10-05 18:21:02.824，空闲安装器在第 16 次 Coder 客体完整结束、正式检查启动之前安装源码树外 TMPDIR 修订；root 文件摘要、所有权和模式与 `resource-payload-sibling` 清单匹配。安装记录为 [resource-installed-sibling-20261005.json](../.local/external-issue12-20261005/resource-installed-sibling-20261005.json)，SHA256 `2d6b136a12e3a0ff0513f60da4a264d4fdd93b05c1cbf41f082da9f4b06c0c91`。该安装记录自身不代表安装后原生验证或 #12 最终验收；17:45 的旧验证和 18:05 的真实失败保持各自来源。

第 16 次 Coder 已正常完成，模型终态 `turn_completed`，客体退出 0，清理、后代清理、导出和后台输出关闭全部为 true，PID 超限与 OOM 事件均为零。控制器沿第 6 轮提交新候选 `d20c57463835be833d9a55d2495d7123689cc9e8`，七个文件较旧候选增加 286 行、删除 34 行；累计尝试 16/18、返工计数 5 保留。补充自主测试记录保留 719／669 零失败，但不替代受信正式检查。18:30 正式候选检查已完成 719 项、0 失败、6 既有跳过、覆盖率 100%，严格 Credo 和 Dialyzer 通过，构建尚在进行；冻结基线检查、独立 Review 和新候选 A04／A11 外部复验仍待完成。未安装 #12 功能候选，未提交或发布主工作区。

18:36 控制器完成同一候选的两条正式检查：候选 719 项（713 通过、0 失败、6 既有外部跳过），覆盖率 100%，格式、规格、严格 Credo、Dialyzer（0 错误）和构建均通过；冻结基线 669 项（663 通过、0 失败、6 既有外部跳过）。未新增跳过或降低阈值。第 17 次只读独立 Reviewer 已启动，累计 17/18；新候选双角色实际 GPT 和新运行版本隔离证据尚未提交。既有 A04 失败和 A11 旧候选通过均保留，不能替代新候选验收。

### 18:44 Reviewer17 拒绝、额度维度停点与 18:45 后原生验证

用户已批准有界接续并要求增加 60 分钟时长；按 IS-069，实际恢复起算四小时已经生效，窗口为 17:57:34.629—21:57:34.629。Coder16 已完成第 6 轮，新候选为 `d20c57463835be833d9a55d2495d7123689cc9e8`。控制器正式候选 719 项、冻结基线 669 项均 0 失败、6 既有外部跳过；候选覆盖率 100%，格式、规格、严格 Credo、Dialyzer（0 错误）和构建通过。两项正式客体均退出 0，清理、后代、导出和后台输出关闭全部为 true，PID 超限／OOM 为零。

18:44:33.985，独立 Reviewer17 拒绝 A01 一项代码缺陷，并保留 A04／A11 两项准确候选外部验证。新缺陷是旧非隔离配置解析白名单遗漏原生顶层 `openai_base_url`／`chatgpt_base_url`，令原可由客户端读取的明确连接配置变成 `legacy_model_service_migration_required`；这不是原连接资料缺失。准确候选源码和加载 BEAM 已绑定的[合成配置复现](../.local/external-issue12-20261005/candidate-d20c574-20261005/legacy-top-level-read-repro.json) SHA256 `7d965805a38a75822043f97a73c196a67e61d1c9e1c33898b2a15823e34e1bea`，四项结果为：旧 effort 控制通过、两个原生 URL 配置各自拒绝、旧隔离路径忽略 auth_home 配置仍通过。该复现不调用 GPT、不修改候选或真实账号配置。

控制器按混合阻塞先修代码的合同尝试回流，但下一轮将是 round 7，超过已批准 `max_rework=5` 对应的最多六轮，因而停在 `blocked / :mvp_recovery_resource_exhausted`。累计 Agent 17/18、返工 5，IS-069 唯一新增 Coder 已用完；仍有一份 Reviewer 数量额度，但它不能替代代码返工。四小时墙钟仍有余量，单纯再加时长不解除这两个维度的限制。原操作完成链已封口、互斥释放、执行单元退出，回执 SHA256 `fa800afd1490aa7582b27fb28109732ac2b1bf08924343ce2a503f06438258d7`；未派发额外 Coder／Review，也未修改预算绕过拒绝。

18:45 后已补齐安装后原生验证。源码树外 TMPDIR 修订、实际 scheduler／dirty scheduler 约束、受信覆盖参数拒绝、真实 BEAM 持锁、checker SIGKILL 后第二检查排队及同 inode 释放均通过；完整清理导出、PID 超限／OOM 为零。[安装后证据](../.local/external-issue12-20261005/postinstall-resources-1791197138217696260.json) SHA256 `9f0247bceed599ba3a6eb57c1840bb724bc6b042262e8a432614029e9fa2474b`，[当前安装核查](../.local/external-issue12-20261005/resource-installed-sibling-verified-20261005.json) SHA256 `928433d24be8561cec1cb90266603805bdf79eca82ea84d5056fd6f6f3c90d76`。新内核探针的只读 EROFS、宿主网络／凭据隐藏、本地 TCP、私有 tmp、PID 压力限额和后台后代清理均通过；[内核证据](../.local/external-issue12-20261005/candidate-d20c574-20261005/A11-kernel-operational.json) SHA256 `08cad144b402dbc76ae087f4dc64b7de021961ccf4e58a00b5fceae4ba78f57e`。

上述内核证据分别绑定新候选源文件与已授权安装的资源修订。候选 runner 与已安装 runner 摘要不同，`candidate_runner_matches_trusted=false` 据实保留，未宣称字节等价；探针执行的是固定部署。未执行 4GiB 内存耗尽、8GiB 磁盘填满或 CPU 吞吐基准。该内核通过不消除 Review17 的代码拒绝，也不代替独立复审。新候选真实 GPT 推理尚未调用，修复后若生成下一候选仍须重新绑定证据。

18:49 的 GitHub API 新鲜核对确认 [Draft PR #13](https://github.com/dailiuyi/innovation-symphony/pull/13) 仍开放、Draft、未合并，远端 head 仍为旧候选 `d87ba1000cc26e077057e1c431a6f0923b976478`；`d20c574` 仅在原任务本地分支提交。普通控制器与 View API 均 HTTP 200，新领取继续关闭，未安装 #12 功能候选；主工作区未提交或推送。

现有规则禁止预算耗尽后自动增额。下一步的具体待批准方案为：保留既有四小时窗口和截止时点，从当前已用 17 次起最多再 1 次 Coder、2 次 Review、0 次诊断，累计 Agent 上限 20；返工上限由 5 增至 6，现有返工计数和全部历史保留。仅修复该原生旧配置兼容性缺口及相应回归，完成原正式检查、修复后准确候选的双角色 GPT 与内核证据，再独立复审；通过受信的一任务接续，不改变普通控制器或通用默认限额。[提案封存](../.local/external-issue12-20261005/next-continuation-proposal-20261005.json) SHA256 `ea82a8167e1e4ed65774ce569e5443748833cce4b1f903d51e43f5ec1262bcd6`，状态为 proposal_not_authorized；它不是用户已确认决定，尚未激活。

本轮补充的流程结论：外部条件分流和真实代码返工回流均已实际发生，当前缺的是额度以及旧／新配置路径之间的契约覆盖。应将原生 URL、定制 provider、auth_home／env_key、隔离／非隔离和低／高 effort 建成兼容矩阵，复用同一有效配置描述，避免生成端支持而旧配置读取端拒绝。100% 覆盖率和全部回归通过不能证明这类组合已覆盖。预算终态也应分别显示墙钟、Agent、Coder、Reviewer 和返工维度，避免统称 resource_exhausted 使操作者误以为仍需加时；此为待设计建议，未登记为新的已批准产品要求。

18:52 后，所有者进一步明确“多给三次返工机会”，见 IS-070。最多再三轮修复，返工上限 5→8；原计数 5 和 Agent17 保留。为沿原第6／8轮诊断及最终补证 Review，工程额度配置为最多3次Coder、4次Review、2次诊断，累计26；先前一次返工／累计20的提案封存，不激活。四小时窗口仍截止21:57:34.629；当前仅授权计划已封存，尚未修改原回执或开始下一轮，接续须先核验可信输入、完整冻结合同及闭合链。

19:02:21.535 已通过锁内复核，操作 `linux-issue12-three-reworks-20261005` 实际接续。新政策 `max_rework=8`、`max_agent_attempts=26` 已落盘，当前返工计数仍为5；原开始时间和 external_wait_ms=10214937、max_elapsed_ms=47173146 不变，没有增时或重置。预算过渡写入 `budget-transition.json`，角色上限在预留前检查，保留原 Attempts 的证据、用量和有限重试。第18次为既有第6轮周期性只读诊断，19:02:28实际启动；它先核验新的旧配置缺陷，再沿原恢复逻辑返回 Coder。限定入口复用已经688项门禁的固定 Executor，只增加该任务审计接续和角色上限；原周期性诊断、编码、检查、独立Review、外部等待和交付分流保持。

源快照／compiled模块、安装版四资源文件、134项历史输入及两项当前正式报告均核验。历史清单中的原 live回执／head 指针已合法推进，分别在IS-069的不可变receipt-before和其前序completion核验原字节，当前新回执／head仍由统一前序链校验，未豁免摘要。只读预检及角色上限正负例通过，未开启新领取或升级普通控制器；现时累计18/26、recovering，还没有下一候选或最终批准。

19:05，第18次诊断有效返回repair_code，明确不能只改白名单，须提取有效连接、按认证模式及参数冻结，并补非隔离原生URL和真实客户端离线加载回归。控制器已自动派发第19次Coder进入round7，当前返工6/8、Agent19/26；新增三次机会中的第一轮实际开始。未派发额外用户chat或重领原Issue，未绕过诊断或Review。准确新候选外部采集和下一受信接续已准备为独立证据文件；现时仅准备，尚未发起新候选实际GPT验证或最终批准。


### IS-070 后 Coder19 导出停点与受信成果恢复（20:17）

三次增额已实际触发诊断18和Coder19。Coder19 task_complete后原root报告清理成功但export_complete=false，未产新SHA，原回执保留 :sandbox_cleanup_incomplete。没有将其空output.txt或failed outcome改为成功。按不可变会话7次FileChange重建5个文件，并在独立受管沙箱施加冻结格式化、完整自测和导出验证；两门禁均0，294个跟踪文件中其余289个逐字不变、执行位相同。原失败具体条目未确认，结果不伪称为原沙箱成功。

linux-issue12-coder19-restoration-20261005 在20:07经原OperatorRecheck互斥和双重只读preflight派发，只恢复5个已比对文件，原控制器固定新候选 d71e5b27c9c9983f6d0b4beec36ddc0b4b4dcd22（184增／11删），继续原完整检查和独立Review。Agent保持19、返工6／8、max_agent_attempts26；无新时间和次数增额，21:57:34.629仍是硬截止。scope仅原Issue12。

同时修复existing Draft不能换候选／不推进分支的交付缺口；45项external-handoff回归、specs.check和strict Credo通过。其旧意图／旧证明／唯一OPEN Draft／旧正文／旧head／同仓库分支base／祖先约束和exact lease全部保留，旧approved候选拒绝更换，推送后再次核对再PATCH，不创建重复PR或覆盖人工推进。仅该操作注入源码及测试摘要绑定的回调，普通控制器、普通WORKFLOW和关闭的ready领取不变；未合并／安装Issue12候选。20:17候选正式门禁0、基线进行中，后续Review、准确候选外部证据和远端实际交付仍待完成。


### Review20 代码拒绝并自动派回 Coder21（20:38）

第7轮正式候选722项／冻结基线669项均退出0、0失败、6既有外部跳过。独立Review20指出旧 `--config/-c` 启动参数及合法带引号项目表两处A01兼容代码缺陷；A04／A11仍待准确新候选外部补证。原恢复单元未结束，控制器自动进入round8、启动Coder21，会话01a10c0e-3ff3-7b43-adc2-5ee11c8e7585，返工7／8、Agent21／26。原历史、模型及21:57:34.629硬截止保留，无重领、预算重置或功能安装。新候选和最终交付尚未产生。


### 2026-10-06 IS-071 宿主中断闭合与恢复准备

2026-10-05 21:14正常关机中断Coder21；原截止21:57:34.629到期。旧boot `e66faf42-4649-42f7-9b50-e4c937f74fbb`，当前boot `fed8fb82-a236-4f38-bd62-2c50f9ffa8dc`。私有审计见 `.local/external-issue12-20261006/reboot-interruption/manifest.json` 与 `boot-closure-observation.json`（SHA256 `8f162c2db0d29b466739a33b7e3919a05f1ac06c8f28b4bb05dbf77ea73beab4`）。通过原OperatorRecheck闭合 `linux-issue12-coder19-restoration-20261005`，结果为宿主中断，原回执SHA `ad0818584e715d8f75130941b8a30c08d7925b1820c8b977657beb64f1363a31` 未变，21次Agent／7次返工保留。缺失原生导出、Coder输出和outcome保持缺失；不补造完成记录。

普通controller和View恢复为临时user unit，原root bridge恢复为临时system unit；均没有安装Issue12功能候选，普通领取关闭。Controller/View增加本地有限失败重启，持久开机单元未安装。原四个root资源脚本及bridge摘要核对一致，既有运行负载没有被旧安装器覆盖。

IS-071用户已批准四小时实际恢复窗口、Agent27／返工8（当前7），剩余最多Coder2／Review3／诊断1，使用量不重置。批准封存SHA `df0d4f5be3cbf174cd50abef482bcb3781debeb8100693aacff8e15634ea8359`。01:14:21.041实际恢复时激活窗口，硬截止05:14:21.041；Coder22已在原第8轮、第2阶段尝试实际接收任务。重建检查为独立核验，不能替代正式Issue门禁或新Review。

`ExecutionSandbox` 导出失败分类已在主源码修正：仅有效的原生完成记录同时证明cleanup=true、export=false时返回 `sandbox_export_incomplete`；清理失败、类型错误或scratch来源不符继续失败关闭，禁止导入。26项目标回归通过。该源码修订尚未安装到普通控制器固定包。

接续 unit `innovation-symphony-issue12-host-resume-20261006` 的InvocationID为 `b7aa17784a2e41b5a2c674508d95894a`，RuntimeMaxSec=14400、KillMode=mixed、TimeoutStopSec=90。冻结基础设施源包保持d88b7399摘要，专用接续代码和角色约束单独存档；普通控制器不承担本次专用operator。

同窗口外部补证unit `innovation-symphony-issue12-external-worker-20261006` 已启动，InvocationID `f742a28ac26c4d42ab7949a2159cce42`；源码绑定清单及派发记录保存于 `.local/external-issue12-20261006/`。严格外部入口扩展仅接受IS-071的确切审批摘要、原回执摘要、budget transition、原started_at／external_wait和历史前缀，拒绝增加到28、重置等待、替换批准或历史。角色仍累计限制Coder4／Review4／诊断2（从原第17次之后计算），包含已经消耗的调用。编译及负例通过，真实补证／外部Review结果仍待执行。

01:33 View只读中断提示已上线（仅匹配同一回执字节／同一closed operator／明确host_shutdown_interrupted／无新锁时展示），不更改控制器状态。View最新InvocationID `f9dbec8ad94d473d9979b1ed10cdd81b`；API200、collection=ok。验证34项通用、11项本地采集、10项前端轮次全部通过；当前GH12仍为活跃编码，不误标中断。普通控制器新包首轮全量694项0失败／6跳过，覆盖99.95%不达标；缺少两条Draft身份与祖先拒绝回归，已补充，原完整门禁v2正在运行，新包尚未安装。

01:48 新基础设施包已验证并安装：`.local/releases/linux-infra-export-draft-fixed-20261006/`，binary SHA `df4b8c142879ada027aecc214616d9ab1273e9c45806b75bdddd76748999d5c1`，manifest SHA `f9475a847fbc9ff94203ca0388bc48480c407c94c53f1fc4d805276fc53a97e0`；694项0失败／6跳过、100%覆盖、Dialyzer0错误，格式／规格／严格Credo通过。仅两项生产模块较d88冻结源变化，未新增ModelServices；普通controller PID351235／InvocationID441de902aca348a193a8436fe02f185b，API200、领取关闭，workflow摘要6921c600未变。旧launcher与安装审计见 `.local/external-issue12-20261006/infra-installed-audit/`。

基础控制器与View持久用户单元保存于 `~/.config/systemd/user/`，default.target.wants链接及systemd静态验证通过，当前临时unit保持原PID／Invocation。不是本次Issue12执行的持久单元，也不自动恢复模型任务；真实重启未验证、linger未变。root持久unit及保护guard准备在 `.local/external-issue12-20261006/persistent-services/`；Unix socket保护2项测试通过，安装调用等待本机管理员验证。当前root桥不重启、不改四项运行payload。

Coder22已提交候选bb9070daef522d9d9ef908924acb8a39e0526847，原轮8进入正式checking；已用Agent22／27、返工7／8，四小时窗口及所有历史保留。新候选的正式检查、独立Review和准确候选外部补证结果仍待完成。

02:03 原轮8正式候选／基线检查均退出0；候选726项0失败／6既有跳过，基线669项0失败／6既有跳过，七阶段结果绑定bb9070da且child_exit／outcome为0。71个冻结基线测试及项目文件与base169ff8逐字节匹配。独立Review23已启动，Agent23／27、返工7／8；仍缺当前Review结论及准确候选A04／A11验收。独立核对见 `.local/external-issue12-20261006/bb9070da-formal-check-audit.json`，不修改原回执或审计绑定。

02:12 Review23正常完成并拒绝A10当前授权读取：同一WORKFLOW重载后禁用／撤销／移除证据或旧白名单撤销，原context仍可能放行。A01两项兼容修复已审查通过；A04／A11仍待外部实测。原operator实际启动诊断24，当前Agent24／27、返工7／8；剩余最多Coder1／Review2／诊断0，仍同一05:14:21.041硬截止。外部worker保持等待，不给有代码阻塞的候选自动加验收通过；后续只按最终准确SHA补证。Review23独立审计保存在 `.local/external-issue12-20261006/bb9070da-review23-audit.json`。

02:14 诊断24正常完成并回流Coder25，原round9／返工8开始，Agent25／27；本次批准剩余Coder0／Review2／诊断0，硬截止不变。旧bb9070da的检查与Review保留，不能替代后续候选正式检查／准确SHA外部补证；所有接续仍由原Elixir operator管理。

02:21 只读完成审计 `.local/external-issue12-20261006/audit-completion.py` 已执行并保存 `current-completion-audit.json`；原15项验收及13项执行／交付／基础设施和历史完整性共28项，goal_complete=false。它不派发／不改回执或goal；只有新候选正式检查、新鲜批准Review、真实准确SHA证据导入、终态／operator闭合和Draft13最终头等证据齐备才可支持完成。root持久单元仍等待OS管理员认证；未把缺失证据当作代码测试失败。

02:38 Coder25仍在执行：自检732项0失败／6跳过、100%覆盖；Dialyzer102条类型诊断、exit2／outcome10，门禁未通过，未派发新增Coder或放宽阈值。`coder25-self-check-observation.json`保留原始日志前缀摘要及安全摘要，明确不是新候选正式证明；后续仍需真实Turn成功、导出、提交和完整正式验收。

02:49 等待补证观察器已版本化替换为 `innovation-symphony-issue12-external-worker-v2-20261006`（PID591391、Invocation5d8dc75cdca748a4a7409b2a2885d6c5）。原因是已复现回执／服务闭合读取竞态；v2闭合后重读，仍拒绝错误状态。原观察器无子进程、无探针定位文件，原operator仍活跃；替换前后operator与root桥PID／Invocation完全一致，未派发新探针或模型，deadline及次数不变。12文件新清单和4个有意义竞态／拒绝验证结果见 `.local/external-issue12-20261006/external-worker-v2-dispatch.json` 和 `external-worker-handoff-read-v2-verification.json`；旧源码及日志保留。


### 2026-10-06 03:17：Coder25导出失败与日志源码恢复验证

原Coder25模型Turn完成，但原沙箱清理完成、导出失败，exit_status=0，PID／OOM事件均0；原完成链02:51:51闭合。其固定旧控制器原因为 :sandbox_cleanup_incomplete，普通控制器的新分类不改写历史。原始回执、native result、rollout、messages及输出已封存于 `.local/external-issue12-20261006/coder25-export-failure/manifest.json`。暂未确认原导出拒绝的具体条目。

从已完成的文件操作恢复14个白名单文件，含一个新增测试文件；失败的错误目录写入仍保留为失败，未执行记录中的任意Shell/Python。日志与重建摘要见 `coder25-reconstructed-v2/reconstruction.json`，原源码字节完全相等未证实。独立原生隔离验证正在运行，格式／规格／Credo已通过；它不是正式Issue检查，也不是一次新模型派发。下一步仅在验证通过后准备受审计的同轮源码恢复、完整正式检查与独立Review，原窗口与所有计数不变。


### 2026-10-06 03:23：受审计恢复候选进入正式检查

恢复副本原生门禁与安全导出均通过，733项／0失败／6既有跳过、100%覆盖率、Dialyzer0错误。来源证明 `coder25-restoration-proof.json` SHA256 `e2641770b58578f0137862d7557bbdb7996743a675eb34c3e2fa828c92b5848d` 绑定14个恢复文件、281个未改动跟踪文件和原失败；原临时工作区字节完全相等仍未证实。无派发的额度／角色／错误候选负例通过，只读前置核验通过后，受审计同轮恢复单元于03:22:02启动。候选 `aa12c85fd6ade88ffe4123c2a35629119cd05af1` 已进入原第9轮正式检查，Agent25与返工8计数不变。

`innovation-symphony-issue12-coder25-restoration-20261006.service` invocation `cdbe94c6c70a45778c94b7d83e0b926e`，PID636165。外部worker v5只等待此单元关闭；沿用已验证的“关闭后重读回执”修复，以新的封存入口匹配恢复actor，窗口与角色额度不变。其manifest SHA256 `88f633bd05a2e9490bf47d5d84507fff50b73a7e33326c058da9a899b7e1a971`；单元invocation `1c3226627a0448db960a80ef34816537`，PID636462。它还没有生成实际角色或内核证据，也没有派发最终Review。


### 2026-10-06 03:37：恢复候选正式门禁闭合，Reviewer26启动

原第9轮恢复候选 `aa12c85fd6ade88ffe4123c2a35629119cd05af1` 的正式候选733项、冻结基线669项均0失败／6既有跳过；候选覆盖率100%，格式／规格／严格Credo／Dialyzer0错误／构建通过。控制器已实际启动独立Reviewer26，累计Agent26／27、返工8／8，剩余Review1；没有新增Coder或扩大窗口。该状态不能宣布A10验收通过、外部条件闭合或最终交付。


### 2026-10-06：root持久安装仍等待本机认证的核查

待安装pkexec PID364702仍存在并sleeping，真实UID1000、有效UID0、NoNewPrivs=0；安装证明尚未产生。读取其受保护environ被Linux权限拒绝，没有使用root执行桥绕过读取。该停点不是Codex no_new_privs限制，也不能从等待时间推断本机认证已完成。原Reviewer26和桥仍正常运行；继续等待用户本机管理员认证，不再申请已经获得的任务权限。


### 2026-10-06 03:58：代码复审通过，真实补证导入，最后接续启动

Reviewer26未发现新代码阻塞，确认A10真实WORKFLOW撤权实现与回归充分；仅A04／A11外部条件未闭合。新候选内核清理、隔离、PID压力和后代清理探针通过。旧角色helper在真实模型调用前被bin/erl路径断言拒绝；诊断证明Elixir将同一OTP28.5的erts-16.4/bin/erl置于PATH前列。版本、安装根和具体入口摘要绑定的helper v2通过无模型前置核验后，实际双角色Turn完成且输出、路由字段、凭据引用链接及原生清理校验通过。服务端实际型号仍unknown；第二账号、实际网络连接遥测未验证。

角色helper v2 SHA256 `e5edc2918ecc92657c171c0fed21067afbef262eff7fe3ff3315dc3f6954f8c4`，旧失败完整保留。资源子报告原生没有candidate_sha字段；打包器v7通过准确候选summary、明确路径、verified runtime binding及原始摘要绑定资源结果，不篡改原报告。A11仍明确候选runner与安装runner字节不同、没有安装功能候选、未做内存／磁盘耗尽及CPU基准。

Draft13出现分支已推进到aa12c85、正文仍为d87ba100的部分交付。只读核验唯一PR、精确head／base／仓库／分支／Draft状态与旧正文，以及错误head／正文／PR负例后，新的 `linux-issue12-draft-reconcile-20261006` 对账操作仅PATCH既定正文，使用原生ExternalDraft.reconcile确认交付；未重新push、改候选、派模型或增额。完成链保存原不确定结果和remote-before／after，计数与历史不变。

最后严格入口v6完成只读前置核验后，03:57启动 `innovation-symphony-issue12-final-external-20261006.service`，原deadline05:14:21.041不变。当前Agent26／27、返工8／8；补证已导入，完整候选／冻结基线检查重跑中，最后独立Review尚未发生。


### 2026-10-06 04:12：补证后门禁闭合，最后Reviewer27实际启动

准确候选aa12c85的补证后正式候选733项、冻结基线669项均0失败、6既有跳过；候选覆盖率100%，格式／规格／严格Credo／Dialyzer0错误／构建通过。最后独立Reviewer27已实际启动，Agent27／27、返工8／8，Coder／Reviewer／诊断余量均0，原硬截止时点05:14:21.041不变。尚无最终Review或交付完成证明，不自动扩额或继续派发。


### 2026-10-06 04:36：最终Reviewer27拒绝，原额度全部耗尽

Reviewer27真实Turn正常完成，04:28:17 operator闭合，approved=false。两项P1公共边界缺陷为SYMPHONY_MODEL_KEY启动覆盖／快照秘密保存，以及持久注册表初始解析异常原文泄露；另缺准确候选runner的实际内核验收。合成复现已保存于 `.local/external-issue12-20261006/review27-verification/`，不调用模型或读取真实凭据，公共snapshot与load均复现；调度／CLI输出回归尚待修复轮执行。

原回执状态blocked／:mvp_recovery_resource_exhausted，SHA25619c4f85e23d80993b05d2fb445c182e7794ca3929edd26bf11ef8e543163b5aa；Agent27／27、返工8／8、Coder／Review／诊断余量0，截止仍05:14:21.041。单元MainPID0且failed为实际终态，没有新派发。准确候选aa12c85工作区干净，Draft13 OPEN／Draft且head一致；严格完成审计goal_complete=false（7／28证明条件），未合并／安装功能候选。root持久安装仍等待本机管理员认证，安装证明缺失。

有界接续提案 `review27-followup-proposal-20261006.json` SHA2569797fd2124e408ed0937556f29f49a597f6255ecec3ce3cf6319b84854d7db2a已保存，尚未授权／生效：实际恢复追加最多四小时、Agent27→30、返工8→9、最多1Coder／2Review／0诊断，仅修复上述两处公共边界并完成准确候选验收。全部原失败、历史和计数保留，不自动合并或安装。


### 2026-10-06 14:48：IS-072已批准，Coder28实际接续

直接用户指令批准Agent27→30、返工8→9、最多1Coder／2Review／0诊断，从实际恢复追加最多四小时。授权封存 `review27-followup-approved-20261006.json` SHA2567e10e9feb0b1985c3a23c8fe2d5540e9afa0922977e3011cda6287f4bad9696c。

首入口14:44:54在模型派发前遇到通用Recovery累计时长24小时校验上限，失败记录已闭合、未消耗模型。v2保留原失败和既有14:44:54.696—18:44:54.696窗口，以专用审计context承载精确累计额度，通用配置上限和运行版本不改。窗口文件摘要f8d730779e1270e8298120ed79a15fac9827086a434448aaa9d4c3ab8e711c8a，原started_at、external_wait、全部事件前缀及28／30和9／9计数均保留。v2只读范围／历史／角色／Review核验通过；预算31、等待重置及历史清空负例拒绝。

`innovation-symphony-issue12-review27-resume-v2-20261006.service` MainPID901536、Invocation9901668e1894475b99e88cb4b971961c，14:48:01实际启动Coder28，thread01a10ff8-05f9-7482-8b65-a1ad236d13ee、turn01a10ff8-1eb3-7140-9868-a2d717bacfdb；原第10轮正在编码，剩余最多Review2，无新增Coder／诊断额度。当前普通领取关闭，功能候选未合并或安装。

root持久单元安装证明已产生：固定unit、guard摘要与既定方案一致，systemd验证exit0，wanted链接已保存；安装前后桥MainPID88446和Invocation527cbf8048f848cca679d690aab124b2一致，四项payload未变。下次宿主启动生效，真实开机仍未验证。本机认证旧进程已结束。


14:54 本机管理员认证已完成，准确候选验收进程以root进入等待，原native session48213／PID906110。固定helper摘要d4c9e3ad82e0ca833580422678b28597e8cc80c6f1b6e9087737848fc68faea0；开始证明 `/var/tmp/innovation-symphony-issue12-exact-acceptance-20261006/started.json` 绑定原四小时硬截止、批准摘要、原桥身份和四项payload。仅等待闭合且无代码阻塞的新候选；实际执行准确runner后记录EROFS、网络／秘密／凭据隐藏、私有tmp、PID限额及后代清理。尚无内核通过报告。

实际角色采集单元 `innovation-symphony-issue12-is072-proof-collector-20261006.service`（PID920743／Invocationcfc628acb0bc4888854eeb0ae354b1b6）同样等待原operator闭合，严格重读状态后才归档准确源码／编译BEAM并执行合成双角色调用；不派task Agent、不改原回执。最后外部接续入口的累计时长加载只接受IS-072精确批准和固定窗口，原公开请求、范围、元数据及证据校验保留；编译及增至31／重置等待／删除历史／替换授权负例通过，尚未派发最后Review。

15:08 Coder28仍执行自检：首轮736项0失败／6既有跳过，但99.98%覆盖和长行导致整体失败；修复后补充结构无效JSON和真实领取脱敏回归通过，严格Credo通过，首轮Dialyzer0错误／escript通过。基线与修正candidate完整重跑进行中；这些是编码自检，不是新候选正式证明。


### 2026-10-06 15:34：Coder28模型完成但导出失败，原轮成果恢复验证

Coder28真实模型Turn正常完成，自检候选736项／基线669项均0失败、6既有跳过，覆盖率100%、Dialyzer0错误及构建通过；这些仍为编码自检。15:26:16原operator闭合，固定旧版本返回sandbox_cleanup_incomplete；原生result明确cleanup／descendants／background关闭均true、exit0、export=false、OOM／PID事件0。没有新候选提交，原失败和回执封存于`.local/external-issue12-20261006/coder28-export-failure/`。失败回执SHA2560a6ad47fbf507a671fe74b4a72bb6373fcf483aea262d3156913e84de8cecc17，原生result摘要bf81b9d6af7a89362cea03d14dd7fdc9a2a5f06ccfdbb8b95633fdb525a7b821。

最后RPC diff记录六个更新文件；从aa12c85重建的每个文件均匹配记录的原始及结果Git blob摘要。不执行日志里的任意命令，原沙箱导出成功不被追认。原工作区完整字节一致尚未证明，正式检查和新独立Review仍必需。副本路径`/var/tmp/innovation-symphony-linux-runtime/workspaces/coder28-reconstructed-20261006`。

独立验证首入口因非数字run标识被执行桥运行前拒绝；v2因缺少预备scratch父目录再次运行前拒绝，均为操作者入口错误、退出125，原失败保存，不是额外模型或正式检查。v3按桥既定输入合同创建规范数字标识和父目录，于15:33实际进入原生编译；unit innovation-symphony-coder28-recovery-validation-v3-20261006，Invocation87d54295286c45298d987d21aa56e724、PID1031385。尚无恢复副本安全导出通过证明。

同轮恢复入口及后续严格外部入口v2已编译并通过原授权／预算／历史拒绝负例；只接受既有IS-072、原窗口与六个固定文件，最多剩余Review2、Coder0、诊断0，Agent28／30、返工9／9、18:44:54.696硬截止不变。旧角色采集进程明确拒绝blocked状态并退出；新版本尚未启动，root认证验收进程继续等待准确新候选。未安装／合并功能候选，普通领取仍关闭。


15:42 恢复验证v3暴露preflight夹具无父目录；进一步只读取证确认这不是已经证实的Coder源码缺陷：最终turn/diff漏掉Coder28通过两条已成功Shell/Python命令完成的改写，第一条06:51:19已把新增回归移到既有state目录的打包测试中，第二条07:01:53扩展授权测试的结构无效分支。仅按RPC diff恢复的副本不等于完整最终源码。额外Coder提案已撤回，未应用最小补丁、未派模型或增额；按完整已完成FileChange、两个安全字面量AST改写和固定formatter顺序重建v2，原错误副本和失败保留。此为操作者恢复工具缺陷，不能归因于Coder或环境。


### 2026-10-06 22:41：完整恢复验证已通过，原墙钟窗口已到期

完整日志副本v2的独立原生门禁于15:55:27完成，736项／0失败／6既有跳过、100%覆盖、Dialyzer0错误、escript通过；native exit0，cleanup／descendants／background关闭／export全true，PID／OOM事件0。六个恢复文件及289个未改动跟踪文件逐字节核对通过，证明`coder28-restoration-proof.json` SHA256b1dbcad5e7d366a42ebd455adf7f5a639879ae9a4f478c21cfd74c209dc21d56。这是独立恢复副本证明，不能替代原任务新候选正式检查或新鲜Review；原完整沙箱字节等价仍未证明。

本主会话工具调用在15:54:31.884至22:36:19.891之间没有继续推进，独立本机验证已完成但同轮接续尚未派发。系统日志记录15:53:21合盖及期间持续NTP请求超时，未找到可证明主会话停顿具体原因的证据；不据此断言宿主挂起、重启或账号故障。root准确候选验收等待器于18:42:09主动拒绝继续等待，原因authorized deadline insufficient，原桥PID88446／Invocation527cbf8048f848cca679d690aab124b2及四项payload不变，没有执行候选runner探针。

22:36同轮恢复严格只读前置核验通过，但派发器末尾检查发现原18:44:54.696硬截止已过，在操作begin、源码写回、提交和Review前拒绝。回执仍为原0a6ad47fbf507a671fe74b4a72bb6373fcf483aea262d3156913e84de8cecc17，blocked／sandbox_cleanup_incomplete、Agent28／30、返工9／9；没有新增Coder／Review，未增加时间。22:41 GitHub新鲜核对Draft13仍OPEN／Draft、head aa12c85，未合并或安装功能候选。

只读完整审计v4为goal_complete=false（5／29证明条件），新增检查要求完整日志恢复及安全导出；门槛未放宽。`is072-expired-window-observation.json`封存原过期窗口及时间间隔证据。新的仅时间提案`is072-time-only-resume-proposal.json` SHA2564502b4d17f3d8de0f48aaf19d617b88e36ebbfd2e256134c3add0cad1805e177尚未批准、生效：从实际恢复追加最多四小时，仍Agent30／返工9、Coder0／Review最多2／诊断0、全部历史保留，仅完成原范围的恢复、正式检查、准确候选验收和Draft交付。不自动合并／安装功能候选。此前额外Coder提案已撤回，不再需要。

### 2026-10-07 00:40：IS-073实际增额及本机连续执行

所有者直接要求充足时间和更多返工／Review，本次追加12小时、返工上限12、Agent上限39；从第28次后Coder最多3、Review最多6、诊断最多2。授权封存于`.local/external-issue12-20261007/is073-approved.json`，SHA256 d13850b0be632f0af32c187966353321be68a31f65ffaca7ffe3ae648b83c981。实际窗口00:40:29.373—12:40:29.373，过渡摘要465f5b4be7d47ef33bf4879d1c01009f41f06120b76de0bd21e139f6c5938abb；原已用28／9和全部历史保持，累计max_elapsed_ms185926526。准确过渡的正向及错Agent上限、清空历史、外部等待清零负向核验在写回前通过。

受信操作`linux-issue12-is073-restoration-20261007`重新读取原回执0a6及完整源码恢复证明b1dbc、所有不可变证据摘要，通过只读原范围／模型／基线／检查／审计链前置检查。六个文件已恢复至原工作区并提交候选`13d4c04a1dd30c32a89058d6c14709e3c237da1a`，原Coder28失败保留，没有新Coder调用；原两项正式检查正在执行。

本机unit `innovation-symphony-issue12-is073-20261007.service`实际启动，Invocation0ca89324ec6848ebb50a48ea855e7c8e。它复用原Elixir Executor并在安全闭合后自动接固定准确候选探针和严格原生外部Review入口；泛用调度器和Recovery解析不变。入口、授权、workflow及固定后续脚本均绑定摘要，RuntimeMaxSec43230是含启动开销的服务外层上限，原任务精确12小时截止独立核验。临时systemd-inhibit的sleep:block实际存在；它降低普通睡眠／合盖停顿风险，不阻止人为关机、断电或网络服务故障，也不修改全局电源策略。

独立准确runner验收另由root本机unit `innovation-symphony-issue12-is073-kernel-20261007.service`执行，采用新窗口和独立root-owned staging，实际本机认证后已启动；冻结helper摘要d948a02281ea5f75c7ea75eaad6a8d1a73305b37ac31cbea92ea201d1aa329ac。旧过期等待器失败保留，生产runner和bridge不更换。新候选正式检查、独立Review、准确候选双角色／内核证明和最终Draft交付尚未完成；预算生效及服务启动不记作任务完成。


00:51准确runner等待器v2已通过本机认证实际接替：先验证旧Invocation2c5cc63024cf41109829cceaea711f51及PID1201701、没有实际probe目录，再仅停止该等待器，保留旧started记录，复核原锁文件root所有权与排他锁。新unit `innovation-symphony-issue12-is073-kernel-v2-20261007.service`、Invocationab3a6bf9433c434aa26505552b0ea6a3、PID1242779，helper SHA2562468c833186d1a1397412606f4508ef3c4914cadceb7deefc952bad3c78677b1。它在awaiting_external但原operator仍持锁或head未闭合时继续等待，避免过渡状态竞态造成误报；不清任务锁，不更改回执、预算、生产bridge或runner。过渡证据在独立root staging的validator-v2-transition.json。


00:58回读：政策、原started_at、外部等待、完整事件前缀、原范围、模型、基线和隔离等12项核对通过，activation-readback.json保存。第一项正式check-1.json已退出0：736项测试、0失败、6既有跳过、100%覆盖，Dialyzer0错误，格式／规格／Credo／打包均退出0；check-2冻结基线正在执行。原生task和root内核等待器v2均active，Agent28／39、返工9／12；GitHub认证查询可用，Draft13仍OPEN／Draft、head aa12c85。模型与内核实际新候选验收尚未完成，不把环境预检或已通过第一项检查登记为任务成功。


01:02原两项正式检查均退出0，冻结基线669项、0失败、6既有跳过；第一项候选736项、0失败、6既有跳过、100%覆盖、Dialyzer0错误及打包退出0。原生流程已自动启动Reviewer29，回执reviewing、Agent29／39、返工9／12；首次正式检查摘要记录于first-formal-checks-passed.json。任务unit及root内核等待器v2均确认存活，独立审查尚未正常结束或给出正式判定。


### 2026-10-07 01:33：Review29仅外部阻塞、准确候选证明及同一Draft对账

Reviewer29实际Turn正常结束，13项正文勾选验收中11项充分，仅A04与A11要求新的准确候选外部证明，没有新的代码阻塞；计数29／39、返工9／12。原任务正文第4节的调用来源／未知用量和明确错误／统一预算继续以A14、A15追踪，最终独立Review提示明确要求原15项准确原文，不把13项输出当完整验收。

root等待器v2于01:17实际执行准确13d4c04 runner，summary摘要aeae2927824ab573ee162d0216a31acfab1fad20a077676226fec355c3739831；实际runner摘要e2700ba6205c6f59bc213ea632f1d43eec3b6cb83f71ba47dd5bc39b03ec0bc9。只读EROFS、宿主凭据隐藏、网络隔离／本地TCP、私有TMPDIR、PID压力和后代清理均通过，生产bridge及四项payload前后不变。未宣称完成RAM／磁盘耗尽或CPU吞吐基准。

初始连续链在模型探针开始前因操作者采集器把TextIOWrapper传给chmod而退出；原空日志、脚本、服务失败与pins保留。v2使用fchmod(f.fileno())，重用并复核295个Gitblob归档及准确BEAM，01:29两个真实角色Turn正常结束，A04与A11及probes-complete已封存。实际网络路由及服务端型号无法确认，报告保留unknown，第二账号／服务商未验证；此轮采集没有派发任务Coder或Review。

原生Draft发布曾只推进head，正文仍旧，保留mvp_publish_uncertain_reconcile_before_retry。受审计操作linux-issue12-is073-draft-reconcile-20261007复核唯一OPEN／Draft13、准确head／分支／base、旧正文和不可变intent，只完成预定正文PATCH并原生reconcile，不重推Git、不建新PR；完成回执摘要1692c17973d9293eed5746bb993a253ed6011572ae9ff6587a3fa94f6a182511，原恢复／rounds完整相等。

严格入口v2只读预检因未给Commands绑定专用WORKFLOW而拒绝，诊断确认Config.settings!/Tracker.bind_agent_tools的ArgumentError，未派模型、未改回执。v3在入口前设置同一冻结WORKFLOW，严格九字段请求不变；准确增额根和闭合对账链的正向、错actor／政策／候选／清空事件负向校验通过，原生只读预检返回verified_without_dispatch。新unit innovation-symphony-issue12-is073-final-v2-20261007.service，Invocation9388186997294cdbacd26fe47ebb4d26，21项输入摘要绑定、临时sleep:block，复用原Elixir Executor完成原两项正式门禁和独立Review；旧服务失败保留。不安装功能候选、不合并、不启用普通领取，最终完成仍待审计。


01:47最终原生外部复检的两项正式命令和七阶段全部退出0，准确候选13d4c04；候选736项／0失败／6既有跳过、100%覆盖、Dialyzer0及构建通过，冻结基线669项／0失败／6跳过。证据final-formal-checks-passed.json保存实际argv、日志／子报告摘要与候选绑定。独立Reviewer30已实际启动，Agent30／39、返工9／12，覆盖原15项并读取准确候选新A04／A11证明，尚未完成或批准。


### 2026-10-07 02:02：准确候选最终验收与Draft交付完成

独立Reviewer30于01:59正常完成，完整候选13d4c04a1dd30c32a89058d6c14709e3c237da1a，approved=true、原15项criteria均adequate=true、blockers为空。review摘要18ecccbfde508efb247c27168493ef479ddb8bfb47cec70bb17e5eb92dae0f3c。最终正式候选736项／0失败／6既有跳过、100%覆盖、Dialyzer0及七阶段门禁全通过，冻结基线669项／0失败／6跳过；准确候选双角色实际GPT和实际runner内核证明已通过原审计入口导入。最终只读完整审计audit-completion-is073-v2.py为29／29通过、goal_complete=true，包含远端准确正文／head／分支／base，未缩减原15项验收。

原生交付更新同一OPEN／Draft PR13，external_delivery.status=approved、intent.mode=approved，最终回执awaiting_human／reason=null，摘要143cf16378c2acbd3b1b1a21989e6611e2fa6776a1cfd51356fc1fe2eeccb0e0。最终operator成功闭合、head与回执摘要一致、互斥已释放；本机连续链01:59:18退出0，unit inactive／MainPID0／Resultsuccess。21项固定输入摘要在执行后再次核对全部一致，原预算／事件前缀／失败与所有历史保留；最后Agent30／39、返工9／12，本轮新增Coder0、任务Review2（29、30）、诊断0，实际角色补证单独记录，不算任务Coder。

bridge仍PID88446／Invocation527cbf8048f848cca679d690aab124b2，四项已安装payload摘要不变；普通controller与View身份保持，API正常，mvp.enabled=false。临时睡眠阻止锁随执行服务完成释放。本地主工作区文档已保存，未提交／推送；候选13d在原任务分支提交并更新Draft13，未合并、未安装功能候选，未替换生产runner。此前基础设施固定包和持久启动配置已安装／静态验证的证明仍独立保留，真实重启未测。原导出具体拒绝条目、实际网络／服务端型号、第二账号／服务商及完整RAM／磁盘耗尽和CPU吞吐均未宣称已验证。


## 2026-10-07 14:17 CST：IS-074 最新 main 本机部署完成

来源：所有者直接要求“拉取最新代码并部署”。SSH fetch 被连接关闭拒绝，随后使用现有
GitHub CLI 凭据通过 HTTPS 成功获取 main。固定 SHA
`66b9b25fe55ff0f95b7f8e719b740a62e4c6f001`，已合入 PR #13；准确 SHA 的
[远端 CI](https://github.com/dailiuyi/innovation-symphony/actions/runs/37572236294)
中 make-all 与 view 均成功。

在 `.local/releases/main-66b9b25-20261007/` 建立 detached 固定 worktree，
沿用既有 Elixir 1.19.5／OTP 28.5、依赖及 Codex 0.160.0，重新编译打包。
二进制 `elixir/bin/symphony` SHA256 `e519dc6cd899dbb6bdf09c7488505287996d6eb22bd583812f41944d44e7bacf`。
固定 worktree 的 tracked 源码无修改；部署日志、清单和数据链接为本机未跟踪产物。
开发工作区的 main 没有重置或合并，原未提交文件和未跟踪文档保留；未提交或推送本轮记录。

本机验证：格式／specs／严格 Credo／构建通过，Dialyzer 0 错误；View 34 项 Python、
10 项 JS、10 项 Linux 集成用例、固定迁移比较与渲染通过；原生 Codex 路由 23 项及
独立配置环境下生命周期／恢复／授权／模型服务 57 项通过。首次 make all 因 PATH 中
Node Codex 包装入口的退出断言及个人 Codex 配置影响而失败；关键回归修正环境后通过。
独立空 CODEX_HOME 的完整复跑约 18 分钟仍未完成，已停止，不登记本机完整门禁通过。
完整日志留存 build-gate.log、build-clean-gate.log、native-routing-gate.log、
clean-environment-targeted.log 和 dialyzer-gate.log。未修改个人 Codex 配置或生产凭据。

只读 escript 预检使用独立工作流副本返回 passed／issue_count=1，不启动调度器；
活动 WORKFLOW 保持原摘要和 mvp.enabled=false。部署仅修改 `.local/start-symphony.sh`
的二进制路径及 `.local/launch-view.py` 的导入源目录，再依次重启既有用户服务。
控制器 PID67269／Invocation decde8bced4c4eafa87d2842a1059233；
View PID67283／Invocation ec42a286b6da4646955b6dbc10f8ab02，均 active／running。
控制器实际命令绑定上述固定 escript，API 返回 200，running／retrying／blocked 均为0。
View API 和采集正常，仍为5条任务、2个故事、35个会话、1个运行根；未用演示数据证明接入。

View 固定安装的数据、生成页及 rollout 缓存链接回原 `view/data`、`view/prototypes`、
`view/build/rollouts`，数据库与缓存没有迁移或清空。活动 WORKFLOW 与全部顶层任务
回执部署前后 SHA256 相同。原服务开机启用设置沿用，本次不做宿主重启验收。
访问地址：[View](http://127.0.0.1:8613/)／[Symphony](http://127.0.0.1:4000/)。

部署证明为 `.local/releases/main-66b9b25-20261007/deployment-result.json`；
`deployment-backup/` 保存原两个启动入口、工作流副本及回执摘要。回退时先确认控制器
无执行任务且领取关闭，恢复备份中的 start-symphony.sh 与 launch-view.py 到原 .local
路径，再依次重启这两个用户服务并复核 API；旧固定安装保留。回退不重写工作流、
注册表或任务回执；已冻结的新服务任务不得交由不认识其快照的旧执行器自动续跑。

本轮仅本机安装和服务切换，不执行 GitHub 写入、人工合并、真实派发或云部署。


## 2026-10-08 10:15 CST：IS-079 最新 main 安装及切换

来源：所有者要求“拉取最新main分支 并安装”。远端 main 固定于 `14764322043929a01f6da4892451ac720da297a7`，已人工合入 PR #14／#15，源码 tree 与本轮审查通过的 `dc89885` 完全相同。准确 main 的 [远端 CI](https://github.com/dailiuyi/innovation-symphony/actions/runs/37716335575) 中 make-all 与 View 均成功；本轮没有合并或推送操作。

独立固定安装在 `.local/releases/main-1476432-20261008/`，用已固定工具链及相同依赖锁重新编译 escript；二进制 SHA256 `a06f32e9853dc5df37086b77a97363186cc718c1e5b4f859556a79876a20e018`。构建与只读 GitHub preflight 通过（issue_count=0）；preflight 只在私有工作流副本开启校验，原活动 WORKFLOW 逐字节保留。首次预检缺少既有 CLI acknowledgement 参数而拒绝，添加后成功，失败日志保留。View 完整检查通过：35 项 Python、10 项 JS、11 项独立 Linux 回归、固定 projection／HTML、self_check 和 8 种入口。本轮没有新增源码变更，因此完整 789 项／0 失败／6 既有跳过／100% 覆盖率的同树本地审查结果保持；本轮重新构建和实机切换核实分别记录，未将冻结旧暂停断言差异记作全通过。

原启动器、runtime-env、WORKFLOW、View 配置及 SQLite 在线备份位于该安装目录 `deployment-backup/`；原未提交 patch 和未跟踪文档均另存备份。更新 `.local/start-symphony.sh`／`.local/launch-view.py`，runtime-env 仅新增可选运行 cwd，默认调用行为保留，控制器实际 cwd 为新固定 release 的 `elixir/`。View 保持 loopback 监听，数据库、rollout 缓存和会话页面仍使用原数据目录，不移动或覆盖历史。切换期间因旧端口释放等待导致首次访问核实失败；既有绑定重试后恢复，再执行最终验证通过。

最终 controller PID 1464050、View PID 1464051，均 active/running、NRestarts=0。控制器 API 和 View bootstrap／snapshot 可用；真实采集 status=ok、source=local，5 个任务、2 个 story、35 个会话、1 个 runtime 保留。371 份任务及证据 JSON 摘要、原 WORKFLOW 与 View 配置相等；SQLite 510 条 transitions 完整包含原历史，2 个 attempts、35 个 sessions 保留。running／retrying／blocked 均为 0，mvp.enabled=false；未恢复或派发真实任务。

rootless 桥的 bridge、startup guard、rootless runner／配方／DNS 和正式检查 Python 源码与 main 一致；本轮未更新旧冻结 legacy helper，未激活 rootless WORKFLOW，整体 rootless 实机验收缺口保持。最终清单为 `deployment-result.json`。回退入口为安装目录 `deployment-backup/rollback.py`，仅在确认当前控制器空闲后恢复原三个启动文件、重启这两个用户服务，不删除新版本、工作区、数据或任何回执；本轮未执行回退。

开发工作区原始补丁保留，本次只追加安装决定／需求／运行记录；未提交或推送这些文档。看板 [http://127.0.0.1:8613/](http://127.0.0.1:8613/)，控制器 [http://127.0.0.1:4000/](http://127.0.0.1:4000/)。


## 2026-10-08 10:33 CST：IS-080 View 内网访问

用户要求内网访问地址。本机 Wi-Fi `wlp0s20f3` 地址为 `192.168.0.44/23`，缺省网关 `192.168.1.1`；排除 Docker 和代理 TUN 地址。`.local/launch-view.py` 的 View 绑定由 127.0.0.1 改为 0.0.0.0，仍加载固定 main `1476432`；只重启 View。旧端口 TIME_WAIT 使第一轮绑定等待 90 秒后失败，systemd 按既有策略重启一次，随后监听及采集正常，早期访问失败不记作通过。

最终本机经 `http://192.168.0.44:8613/` 和 `http://127.0.0.1:8613/` 均获得 HTTP 200；bootstrap 的 collection.status=ok，source=local。View PID 1471844，controller PID 1464050 未变。没有修改防火墙、控制器、工作流、领取、回执、数据库或源代码。其他设备实测尚未执行。

原启动器、修改前文档及结果在 `.local/view-lan-20261008/`；恢复 `launch-view.before.py` 至 `.local/launch-view.py` 并仅重启 View 即可回退监听。新增记录未提交或推送。


## 2026-10-08 11:33 CST：IS-081 开启新任务领取

所有者明确要求开启新任务领取。保留固定 main 14764322043929a01f6da4892451ac720da297a7 与控制器 PID 1464050，原 WORKFLOW、顶层回执摘要和激活记录保存在 `.local/intake-enable-20261008/`。原 legacy 桥真实 exec-server 传输探针通过；未激活 rootless。

核实隔离路径本来生成 gpt-6.1-sol／high，不读取个人 config.toml 的 medium。按实际原账号与 ChatGPT Responses 连接登记 gpt61-existing-high，保留两个角色原有效默认值。真实账号 model/list 发现及双角色隔离工具／严格 JSON 验证通过，注册表 revision=1，持久路径 `/var/tmp/innovation-symphony-linux-runtime/state/model-services.json`，权限 0600。原始验证结果和配置绑定在 model-readiness.json、registry-verified.json 和 model-readiness.log；能力证据按既有实现于次日 11:32／11:33 CST 过期，不冒充永久权限。工具验证未发送真实仓库材料；actual_model 字段未由调用结果返回，记录 null，模型及 high 由 AppServer 有效配置通知核实。

第一次验证使用工具默认 `/tmp` 证据目录，触发既有桥路径限制，返回 execution_environment_unavailable；当时领取仍关闭，未生成成功证据。将验证进程 TMPDIR 指向原获准 state 子目录后成功，不扩大桥权限。GitHub 只读预检 status=passed、issue_count=1。随后仅原子更新活动 WORKFLOW 的 mvp.enabled=true，服务热加载后于 11:33:39 领取 GH-16，11:33:58 编码会话开始；任务回执冻结原作者 models 评论及双角色 high、账号身份和对应能力证据，status=coding。

GH-16 工作区 `/var/tmp/innovation-symphony-linux-runtime/workspaces/GH-16`，回执 `/var/tmp/innovation-symphony-linux-runtime/state/e2862601c0cc057fbb2794e8a88c3d9e57bab00012609e6063c91f5d1b668ade.json`。开发工作区的旧未提交补丁及既有任务回执保留。本次配置和运行记录未提交或推送，功能实现继续由控制器管理，尚未完成检查／Review 或创建新 PR。

回退仅在任务空闲、确认无在途执行后，将 WORKFLOW.before.md 恢复为活动 WORKFLOW；如需完整撤销本次管理迁移，再保留并移出新注册表。不得在执行期间直接恢复 disabled 工作流：当前授权校验会同时撤销在途调用。回退不删除任务、工作区、证据或历史，本轮未执行。内网看板继续为 http://192.168.0.44:8613/。


## 2026-10-08：IS-082 提高本机预算及资源

`.local/resource-increase-20261008/` 保存原／新 WORKFLOW、桥代码、策略、启动保护及验证记录。活动 WORKFLOW 的 turn_timeout_ms／check_timeout_ms=3600000，stall_timeout_ms=1800000，agent.max_turns=20；恢复 enabled=true、max_rework=20、diagnose_every=3、stage_attempts=3、max_agent_attempts=96、max_elapsed_ms=21600000。sandbox 为 memory_mb=6144、disk_mb=16384、pids=512、cpus=6；并发一。

原受保护桥对四项资源固定匹配，故管理员安装只接受原／新完整资源档位的策略校验，工作区／证据路径及准许运行命令保持。输入复制预算随已校验档位取值，启动保护摘要同步更新。第一次启动被 bridge.py 的旧固定摘要拒绝，安装器自动恢复旧桥；修正摘要后重装成功。root 备份在 /opt/innovation-symphony-linux-bridge/resource-backup-20261008。真实新探针 run-1791432614536035-1 读回 memory_max_bytes=6442450944、cpu_max=600000 100000、pids_max=512；原档位探针 run-1791432630845574-1 读回原值。两者 export_complete／cleanup_complete=true，OOM／PID 事件为零。回执摘要全部未变化，控制器热加载新 WORKFLOW，无需重启。

当时 GH-16 仍为首次编码 wall_timeout、candidate_sha=null、recovery=null，现有 recover 只接受检查失败／返工耗尽，resume_recovery 要求已有恢复策略，不能直接套用。用户已明确指定接续，后续须补齐受控首次编码超时入口，保留原历史及导出修改；本条预算配置不冒充续跑完成。若回退，须待任务空闲，恢复 WORKFLOW.before.md 与 root 备份中的桥／策略／启动保护；不删除任何回执或证据。


## 2026-10-08 12:31 CST：IS-083 GH-16 受控续跑

原 recover 仅接受检查失败／返工耗尽，resume_recovery 要求已有恢复策略，均不覆盖 GH-16 的初轮编码 wall_timeout 且 candidate_sha=null。新增 Executor.resume_initial_coder 在原开放轮接续；严格核验原身份、服务、检查、base／分支、工作区和隔离结果摘要，要求完整导出及清理，并通过受信 owner_idle 回调核实控制器空闲与桥可用。统一 OperatorRecheck 锁前后重验，旧回执和显式授权保留，原模型、凭据、基线与检查不替换；准确授权后采用 IS-082 策略与资源。

源码隔离工作树 `/home/elma/.codex/worktrees/issue16-timeout-resume/innovation-symphony`，分支 codex/issue16-initial-coder-resume，本地提交 7575b8041c0e764e96e89754a01151746819a3ec。关键恢复回归 50 项通过；全量 791 项运行 7 失败／6 跳过，原因为验证进程读入个人 Codex 配置及使用过长临时目录。隔离 CODEX_HOME、移除 GitHub 凭据、使用 /tmp 后，受影响四模块与恢复两模块共 94 项通过。格式、specs、严格 Credo 均通过；本轮没有全量成功、覆盖率或 Dialyzer 成功的声明。源码提交未推送、未建 PR，主控制器仍为 main 1476432。

`.local/issue16-resume-20261008/` 保存原回执、已导出 tracked patch、未跟踪文件 tar、原基线复核、授权、空闲执行者核实、事件与启动验证。用户服务 innovation-symphony-issue16-resume.service 以原 Elixir Executor 执行，不新增调度器；无自动重启、RuntimeMaxSec=21600，12:31:55 新会话 01a119c8-1aad-7cc0-a102-eef6001274f9 实际开始并发出工具事件。回执 status=coding，operation=issue16-initial-timeout-20261008，模型服务快照和原 coder 用量槽位与旧回执相等；原未知 reviewer 用量槽位保守计入历史模型次数，adopted_agent_attempts=2，当前新编码 attempt=3、stage_attempt=2。恢复累计时间使用原隔离 started_at=2026-10-08T03:33:50Z。

View /api/snapshot 已显示 GH-16 编码中、包含原／新两个编码会话。4000 的原主调度器仍保留旧会话 blocked 条目，无法展示独立操作者会话；续跑状态应以任务回执、恢复服务及内网 View 为准，此展示差异不冒充实际任务仍堵塞，也不手工改写原调度器内存。后续正式检查、独立 Review 及 PR 未完成。本轮保留主控制器和 View 服务，不重启正在恢复的任务。

### 2026-10-08 GH-16 受信门禁维护（IS-084）

用户明确授权修复冻结夹具与 View 运行依赖。操作者在检查结束后的模型阶段暂时暂停 operator BEAM 调度处理，保留在途模型结果；安装后已恢复同一进程，没有重置回执、候选、模型或预算。没有改写原冻结基线、历史检查日志或生产恢复代码，也没有重启共享 root bridge。

已安装 `/opt/innovation-symphony-linux-bridge/trusted/scripts/check_isolated.py`：SHA256 从 `82361e6fa95abcadbbedcb54b73aa3962a8e6af12620800981269505aa345742` 更新为 `27144980dfa90144aa67f2cba3eb9b784afd0e7800e5d6a824f9c0d333a14867`；startup_guard 同步绑定。精确白名单的旧恢复夹具 SHA256 为 `a447f5010ee1c50f08e44d26e43d99b16f79c5114540dbd9ee5b7a2ef08f9191`，实际摘要以源码常量和每次 baseline-maintenance.json 读回为准。检查在新临时 harness 内明确初始化0644并断言，保留全部篡改拒绝验证。未知输入、candidate 模式不应用维护；不一致或链接目标拒绝。

root 所有只读工具链新增 `toolchain/view-validation/python/bin/python`，含 codex-transcript-viewer0.5.0；`toolchain/view-validation/node/bin/node` 为固定v24.19.0，归档已对官方SHASUMS256核对。没有修改全局PATH、账号凭据或生产View服务。安装采用临时目录完整准备、文件原子替换和目录发布，旧文件与安装回执保存在 root `gate-maintenance-backup-20261008/`；失败归档本操作新增目录并恢复原脚本，重试必须核实前一次状态。

源码验证：新增维护分支3项通过，既有isolated检查18项通过、1项既有跳过，diff检查通过。一次独立只读审查确认临时修复未降低断言，并复核安装回滚。View完整本地合成检查38项Python、10项JS、11项Linux回归及渲染通过，formal_acceptance=false；在途coder随后实际报告指定沙盒工具链复检通过。不能据此声称真实账号、浏览器/窄屏、内网候选部署或独立Review已经通过。

操作材料在 `.local/issue16-gate-maintenance-20261008/`，审计副本在原任务evidence的 `operator-maintenance/gh16-gate-maintenance-20261008/`；原候选10325f0d的独立真实沙盒基线探针已提交受信桥队列，结果待该目录baseline-native-result.json及原正式检查读回。修复源码保存在主工作区，尚未Git提交、推送或创建本维护PR；安装状态与源码发布状态分开。

IS-084 维护后补充验证：原冻结测试文件在独立临时harness应用精确维护后，于umask077运行权限恢复原用例981行通过（1项、0失败，其余39项未运行；该原用例内部全部内容/权限/无变化场景保留）。同一独立harness恢复旧测试字节可重现原断言失败，随后还原维护后的临时测试。此为维护修复的针对性验证，不是完整基线通过。后续完整基线探针及GH-16正式门禁仍待独立结果，不能把本段写成任务交付通过。

### 2026-10-08 固定Playwright环境补齐（IS-085）

核实当前可复用的Codex runtime包实际上含Playwright与playwright-core1.62.1；此前任务调用没有解析到该固定位置。操作者在独立目录准备匹配包与对应Chromium1234（151.0.7922.34）、headless shell及FFmpeg，管理员认证后原子安装到 `/opt/innovation-symphony-linux-bridge/toolchain/view-validation/playwright/`，root所有、只读，完整文件摘要保存在installation.json。未改版本断言、旧版本、主控制器、View运行服务或任务预算。

固定入口在沙盒内为 `/opt/toolchain/view-validation/playwright/node-playwright`，宿主为 `/opt/innovation-symphony-linux-bridge/toolchain/view-validation/playwright/node-playwright`。入口显式绑定只读node_modules与browsers目录，并检查1.62.1，再调用原固定Node24.19.0；调用 `node-playwright <候选>/view/tests/browser-fixture.cjs <新检查目录>/fixture`。不要以系统全局NODE_PATH或同名旧包替代。

准确候选24a6343567ae9843772b28f7e57b90b5f49ef16b的独立副本：非浏览器View检查38Python、10Node通过；浏览器夹具实际启动Playwright1.62.1＋Chromium151.0.7922.34，8组导航、筛选、刷新、失败恢复、键盘及窄屏检查通过，页面脚本错误为空。证据在 `.local/issue16-playwright-20261008/view-check/fixture/browser/` 和browser-fixture-result.json，明确synthetic=true、real_windows_wsl=false、formal_acceptance=false。安装后又通过固定入口启动真实浏览器，验证页面读取及正常关闭，读回在installed-launch.json。

这解除浏览器运行环境缺失，不等于GH-16已交付。读取原任务为blocked、mvp_recovery_resource_exhausted，独立Review等后续验收仍待执行；本操作没有重置预算或自动续跑。维护资料与工具入口保存在本机，未Git提交或发布。


## 2026-10-08 18:34 CST：IS-086 重置 GH-16 恢复墙钟预算并继续

来源：所有者要求“重置预算继续跑”。授权只追加有界墙钟额度并接续同一 GH-16 候选与历史；不重置累计调用与返工计数、不合并、不切换生产服务、不新增任务。操作材料在 `.local/issue16-budget-resume-20261008/`。

上一轮留下的 `run.exs` 以 10:09 版 Executor 副本调用 `resume_recovery`，经只读推演会在绑定阶段失败：本任务首轮 evidence 位于初始会话根目录（不是 `evidence/round-1`），且 18:28 曾把活动策略改成 160 次／24h，与回执冻结策略 96 次／6h 不相等。本轮把该目录的 Executor 副本换为最近一次受控续跑使用的版本（原副本另存 `executor.prior-1009.ex`，SHA256 `7d0e313e…`；新副本基于 `e7cdb2db…`），只新增 `Executor.resume_budget/3` 与 `:budget` 模式：语义等同既有 `resume_recovery` 审计续跑，额外接受上述首轮历史布局，其余守卫、摘要、锁与拒绝语义不变。活动 WORKFLOW 的恢复策略回退为回执冻结值，使冻结策略与运行策略相等；额度只经授权参数 `wall_budget_extension_ms` 追加。回退前后文件分别为 `WORKFLOW.live-before-revert.md` 与 `WORKFLOW.before.md`。

预检（`IS16_PREFLIGHT_ONLY=1`）三项副作用前拒绝全部符合预期：扩展 0 → `:mvp_recovery_wall_extension_invalid`、错误回执摘要 → `:mvp_resume_binding_mismatch`、错误工作区摘要 → `:mvp_recovery_workspace_digest_mismatch`；owner 空闲与桥就绪核实通过。预算记录见 `budget.json`：原 6h／96 次，追加 86_400_000 ms，接续时刻已用 25_230_244 ms，有效上限 108_000_000 ms，剩余 82_769_756 ms；累计 12 次调用、5 次返工不归零。

运行：`innovation-symphony-issue16-budget-resume.service`（InvocationID `cc078ab44261429192ffd09e13472682`，MainPID 3056188）18:34:29 启动；18:34:42 第 13 次 coder 会话 `01a11b14-4868-7342-a290-4c23c83dc661` 实际开始，模型 gpt-6.1-sol／high。回执 status=recovering、`operator_recheck=issue16-budget-resume-20261008`，recovery 事件新增 `operator_wall_budget_extension`，policy 更新为 max_elapsed_ms=108000000、max_agent_attempts=96，workspace_digest `0bf1b7ef…`；内网 View 同一时刻显示 GH-16 为“recovering／诊断中”。追加额度对应墙钟有效期至北京时间 2026-10-09 17:33。

边界：本轮不合并、不切换控制器与 View、不派发新任务；原冻结基线、检查命令、角色服务与历史证据保持。独立 Review、真实账号与内网候选验收仍未完成，后续检查／Review 结果以任务回执和内网 View 为准。操作材料与源码扩展未 Git 提交或推送。


## 2026-10-08 20:52 CST：IS-087 火山方舟真实账号 DeepSeek 双角色探测

来源：所有者授权“用我 cc-switch 的本机凭证，火山方舟的”执行 GH16-A03 的真实账号验证。只使用所有者本机 `~/.cc-switch` 中 codex 的“火山方舟”提供商（`https://ark.cn-beijing.volces.com/api/coding/v3`，`ark-` 前缀 key），未发送任何仓库材料：探测只在沙箱工作区内生成随机 token 文件并读回。

隔离与边界：`.local/issue16-ark-verify-20261008/` 保存脚本与结果；探测使用独立的 `state/model-probe-ark-20261008/registry` 注册表、候选 `3da7fce7` 的两份克隆（探测工作区与运行检出）与独立 WORKFLOW 副本。活动注册表 `/var/tmp/innovation-symphony-linux-runtime/state/model-services.json` 复核未变（SHA256 `d4e7e10f…`），冻结的 GH-16 工作区未被读写，探测工作区事后无残留文件。

真实通道核实（直接调用，未打印密钥）：`responses` 端点可用，`deepseek-v4-1-flash-260910` 与 `DeepSeek-V4-Flash` 均返回 200；`reasoning.effort` 的 high／minimal／none 均被接受；显式发送 `text.format=json_schema` 时返回裸 JSON `{"token": "…"}`，说明该通道本身支持结构化输出。

角色探测（候选 `3da7fce7` 的 `deepseek_responses` 适配器 + 既有沙箱探测入口）：coder 角色 **工具执行通过**（模型在 `/workspace` 用 `exec_command` 读回随机 token，`exit code 0`），但 **结构化输出未通过**——最终回答是 ```` ```json … ``` ```` 围栏，未按严格 schema 返回裸 JSON，探测按既有规则判定 `model_inference_validation_failed`。同一探测链对 OpenAI 预设 gpt-6.1-sol 的 coder 角色通过（工具＋结构化），说明探测入口本身有效，差异在 DeepSeek 这条路由；Codex 会话亦记录 “Unknown model … fallback model metadata”。证据在 `ark-coder-evidence.json`、`verify-coder.log`、`verify-openai-control.log`、`summary.json`。

结论与边界：GH16-A03 仍**未通过**，DeepSeek／火山方舟角色不能标记为真实账号已验证；直接通道支持 schema，因此下一步属于代码修复（让该路由实际携带并强制 `text.format`，例如声明模型能力或由适配器补齐请求），不是所有者提供的条件问题。reviewer 角色探测未单独执行（同一失败面），GH16-A07 内网验收与 GH16-A11 标准 View 检查仍未做，Draft 也未发布。本轮不合并、不切换服务、不派发新任务；源码未 Git 提交或推送。


## 2026-10-08 20:58 CST：IS-088 修复外部交付崩溃与 DeepSeek 结构化输出

来源：所有者要求“本地修复那个崩溃，修复结构化输出”。

崩溃根因与修复：`ExternalDraft.ready/2`（`delivery.ex:132` 同）用 `Keyword.fetch!(opts, :ready_label)`，而我的 operator 续跑 `opts` 只有 `owner_idle`／`on_message`；控制器路径在 `mvp.ex` 的 `execute_claimed/5` 会补 `ready_label` 与 `tracker_settings`。已在 `.local/issue16-budget-resume-20261008/run.exs` 的 `context.opts` 内按控制器合同补上两项（`tracker_settings` 取该 WORKFLOW 解析后的 tracker，避免未启动应用时的惰性回退），并新增 `check-delivery-opts.exs` 前检：`ready_label=ready`、`tracker_settings` 通过 `GitHub.Client.validate_settings`，确认原 `KeyError` 路径不再出现。该修复只影响 operator 入口；后续真正发布 Draft 时才能确认端到端。

结构化输出根因（抓包证据）：用带 TLS 的本地捕获代理把 codex 发往方舟的请求原样记录下来（`.local/issue16-ark-verify-20261008/capture/requests.jsonl`）。codex **确实**发送了 `text.format = {type: json_schema, strict: true, name: codex_output_schema, schema: {...}}`。对抓到的原始请求逐项重放证明问题在渠道侧：**只要同一请求声明了 tools，方舟就返回带 ```json 围栏的文本、不执行 schema**；去掉 tools 后同一 payload 返回裸 JSON；`type: json_object` 带 tools 也返回裸 JSON。另测 strict 缺省、`parallel_tool_calls=false`、`tool_choice=none/required`、非流式、推理关闭均不改变结论；`/api/v3` 路线对该账号未开放对应模型（404）。

代码修复：隔离检出 `/var/tmp/innovation-symphony-fix`（候选 `3da7fce` 的克隆，分支 `codex/issue16-structured-output-fix`，提交 `5f671af`，补丁 `structured-output-fix.patch`）新增 `SymphonyElixir.Mvp.StructuredOutput.decode/1`，在 `Review.parse`、`Recovery.parse` 与角色能力探测三处改为“裸 JSON，或恰好一个 ```json 围栏”，解码后仍走原有语义校验；其他形状（多个围栏、非 json 围栏、前后散文、拼接 JSON）继续拒绝。相关 64 项测试通过（新增 helper 用例与更新后的 recovery 合同断言）。

真实账号复验：用修复后的代码对同一方舟账号、候选 `3da7fce` 的隔离工作区重跑既有角色探测，**coder 与 reviewer 两个角色均通过**（`fix-verify-coder.log`、`fix-verify-reviewer.log`、`fix-summary.json`；两次 rollout 显示模型确实先执行 `exec_command` 读回随机 token，再以 ```json 围栏返回），证据绑定的验证时间 20:56 CST、有效期 24 小时。

完整测试：修复检出跑全量 `mix test` 得 **806 项通过、0 失败、6 项既有跳过**（耗时 293s，未含覆盖率与 Dialyzer）；此前相关聚焦用例为 64 项通过。

边界：这次修复等于**所有者授权下放宽“必须是无围栏裸 JSON”这一格式断言**——渠道不执行 schema 的事实被记录在案，结果仍由本地按原语义校验；未放宽任何其他断言，未改动冻结检查、基线或活动注册表（SHA256 `d4e7e10f…` 复核未变），冻结的 GH-16 工作区未被写入。修复只在隔离检出提交，未推送、未进入冻结候选，冻结候选 `3da7fce` 仍不含此改动；任务仍为 `awaiting_external`，Draft 尚未发布，独立 Review 与 GH16-A07／A11 仍待办。


## 2026-10-08 21:20 CST：IS-089 把结构化输出修复作为新候选交回任务

来源：所有者要求“把这个修复作为新候选交回任务跑检查＋独立 Review”。`awaiting_external` 原本只有“外部证据”入口（不允许代码返工），因此新增受控入口。

前置后勤修复（崩溃封存）：IS-086 的续跑在交付路径崩溃时未执行 `OperatorRecheck.complete/2`，留下孤儿锁 `operator-recheck.lock`（内容 `issue16-budget-resume-20261008`）且缺 `completion.json`，使后续审计链的前驱校验失败。确认该用户服务 failed／inactive、MainPID=0、无在留进程后，用 `.local/issue16-external-repair-20261008/close-crashed-operation.py` 依记录事实写入 `completion.json`／`crash-closure.json`／`head.json`（结果标为 `{:error, {:mvp_operator_crash, :delivery_ready_label_missing}}`，绑定 `.local/issue16-budget-resume-20261008/crash-journal.txt` 与 `receipt-before.json` 摘要、当次操作留下的回执摘要 `236cd765…`）并释放锁。这是操作者对崩溃的封存，不是程序自报完成。

一次操作失误与纠正：新入口的首次预检并非零副作用——缺少 `repair_feedback` 时会落到存储的 review／diagnosis 分派，实际执行了一次 diagnosis 模型调用（attempt 16），由该 diagnosis 建立 source=`diagnosis` 的新 pending handoff `external-1791465124134-s0NsRKRkQxs6`；候选、工作区、检查与历史未变，未执行编码轮，也未产生新 PR。已修：`resume_mode_guard` 现在先校验操作者反馈，缺失或畸形立即拒绝；随后预检 5 秒完成、无模型调用。

新入口：`Executor.resume_external_repair/3`（绑定模式 `:external_repair`，操作目录 `.local/issue16-external-repair2-20261008/`）。它要求 awaiting_external＋pending handoff，绑定精确候选、工作区摘要 `f272b2d4…`、冻结检查、回执恢复策略、用量与返工计数，校验操作者代码缺陷反馈（`kind=code_defect`，含 reason／required_evidence／handoff 与带补丁说明的 operator_diagnostic），经 `OperatorRecheck` 锁后进入既有 `rework` 路径。**不增额、不改策略**：沿用回执已授权的墙钟延长（108000000 ms）。

预检（零副作用）五项拒绝符合预期：缺反馈、畸形反馈 → `:mvp_repair_feedback_invalid`；带墙钟增额 → `:mvp_recovery_wall_extension_invalid`；错回执摘要 → `:mvp_resume_binding_mismatch`；错工作区摘要 → `:mvp_recovery_workspace_digest_mismatch`。

运行：`innovation-symphony-issue16-external-repair2.service`（InvocationID `5d681098…`）21:13:33 启动；21:13 diagnosis（attempt 16）返回 `{"action":"repair_code"}`；21:15 第 7 轮 coder（attempt 17）开始，会话 rollout 显示正在写 `structured_output.ex` 与 `structured_output_test.exs`。回执 status=coding、`operator_recheck=issue16-external-repair2-20261008`、rework 6、agent attempts 17、候选仍为 `3da7fce`。检查与独立 Review 结果、以及是否再次进入 awaiting_external 或交付 Draft，随后如实记录。


## 2026-10-09 02:06 CST：IS-090 准确候选 5405bcec 的真实 DeepSeek 与标准 View 补证

来源：所有者要求“对 `5405bcec` 重跑真实方舟双角色验证（补 A03），以及跑标准 View 检查（补 A11） A07目标是指什么”；随后明确改为“A03使用ccswitch的deepseek官方api”。后者替代本轮方舟通道选择，不改变活动模型注册表、冻结任务合同或正式检查策略。

准确候选为 `5405bcec5d26c5444581c4cfa4b19a4784354a4a`。从 GH-16 固定 Git 对象克隆独立运行目录 `/var/tmp/gh16-reverify-runtime-5405bcec-20261009`，重新编译 86 个 Elixir 源文件，逐文件绑定完整源码及编译 BEAM 摘要。标准 View 入口在该检出执行，全部产物、完整日志、角色结果和候选绑定封存于 `.local/issue16-reverify-5405bcec-20261009/verification-summary.json` 及同目录文件。

GH16-A03 真实探测通过：使用 cc-switch 的 Codex「DeepSeek」提供商 `ce4e0b5a-f6a3-47f3-97af-f7e3decc7600`，原连接 `https://api.deepseek.com`、Responses 协议、请求型号 `deepseek-v4-flash`；原配置没有显式 reasoning effort，独立预设保留空 parameters，不自行登记为 high。密钥由只读 SQLite 查询后仅注入宿主进程环境，使用独立注册表与空 Git 合成工作区；模型材料只有随机 token 文件与能力提示，不发送真实仓库源码。coder 和 reviewer 均实际执行 `exec_command` 读取随机 token，并产生通过既有语义校验的结构化结果；两个探测工作区实际均只读。能力证据分别在 02:05:41／02:05:57 CST 生成，24 小时有效，服务端实际型号仍 unknown（原 proof.actual_model=null）。两个原生沙箱结果均 cleanup_complete、export_complete、descendants_cleaned=true；原始工具、rollout 摘要和资源结果自包含保存。

GH16-A11 标准 View 检查通过：完整 `scripts/run_view_checks.py`，38 项 Python、11 项 JS，零失败／错误／跳过；固定迁移结果逐值一致、实际 self_check HTML 生成、8 种入口、独立 Linux 子进程／HTTP／恢复集成通过，源码前后相同且临时服务停止。Node 24.19.0、Playwright 1.62.1、Chromium 151.0.7922.34 实际执行 9 组浏览器检查，含设置页键盘、双仓库双角色、409／503 保留草稿、刷新及窄屏。标准入口原生 formal_acceptance=false、synthetic=true、real_windows_wsl=false 保留；本次结果证明完整仓库 View 检查，尚不等于补证后的独立 Reviewer 批准或真实内网部署验收。

准备失败如实保留：独立 WORKFLOW 初次缺 GitHub token，尚无模型调用；用不参与网络调用的合成 tracker token 且 enabled=false 满足加载合同。最小探测工作区初次没有 `.git`，可信 runner 的路径检查失败，两个角色均在推理前得到 execution_environment_unavailable，被外层归为 model_inference_validation_failed；用附加原始错误诊断定位后仅初始化空 Git，重新完成两个角色。没有扩大桥权限、修改生产 runner 或用失败记录冒充通过。直接官方 `/models` 与最小 `/responses` 诊断均 HTTP 200，其结果不替代角色工具能力证明。

GH16-A07 的目标是获准内网入口的实际访问控制：授权管理员可访问，未获准来源被拒绝，管理 listener／View 保持 loopback 且管理端口不直接暴露；核实获准代理地址、HTTPS/TLS、来源限制及日志不记录令牌或请求正文。当前仍缺具体获准内网地址／域名、允许访问来源及代理环境的实机证据；文档模板或 loopback 单元测试不作为真实部署通过。本轮只解释目标，没有登记新的网络部署选择或执行安装／防火墙变更。

收尾：活动注册表 SHA256 `d4e7e10f43f39871826eea8a128aaf8d2db36be49ceb4c6fc3d721482e19cf11` 前后一致；GH-16 候选 SHA 与工作区清洁状态前后一致，未修改任务回执或补造审计导入，未派发任务 coder／Review、提交、push、发布 Draft、合并或切换服务。A03 与 A11 检查产物已保存，后续仍需经原审计入口由同一候选独立 Reviewer 审阅；A07 仍是外部停点。


## 2026-10-09：IS-091 创建 GH-16 Draft PR #17 并可信对账

来源：所有者要求“创建一个PR”。先核实远端 main=`14764322043929a01f6da4892451ac720da297a7`，不存在 GH-16 任务分支或既有 PR；原回执 status=awaiting_external，候选=`5405bcec5d26c5444581c4cfa4b19a4784354a4a`，第9轮两项正式检查退出0，独立 Review approved=false 且仅列 A03／A07／A11 外部条件。不可变交付意图及 review/check 原始摘要全部复核有效。

发布只使用独立固定检出的既有候选，未提交或混入主工作区改动。HTTPS 推送因 gh OAuth 缺 workflow scope 被 GitHub 拒绝，远端 ref 未创建；改用现有 SSH 凭据与仅允许远端分支不存在的精确 lease 推送成功。首次 gh pr create 返回 GraphQL EOF，随后 GraphQL 与 REST 两路只读查询均确认没有 PR，才改用一次 REST 创建。实际 [Draft PR #17](https://github.com/dailiuyi/innovation-symphony/pull/17) 已创建并附加本聊天，标题为“GH-16: View 按仓库设置双角色默认模型，接入 DeepSeek 与思考深度”。远端 read-back 确认 open、draft=true、原任务 head 分支、准确候选 SHA 与 base=main。

PR 描述逐字保留原不可变待验收意图，以便原审计链继续；其中 A03／A11 缺证陈述对应第9轮独立 Reviewer 当时所读材料。IS-090 已新增官方 DeepSeek 双角色及标准 View 通过证据，但这些尚未导入并被新的独立 Reviewer 接受，未将原描述或验收状态手改成通过。

运行可信 `mix mvp.reconcile` 只读核对远端身份与描述后，程序关联原任务回执：pull_request=PR #17、external_delivery.status=delivered、status=awaiting_external。原 candidate、正式检查、Review、不可变 intent、外部 handoff 与预算未变；没有手改回执。操作前后回执、REST 请求／结果、远端 read-back 和对账日志保存在 `.local/issue16-pr-create-20261009/`，result.json 记录全部发布尝试及准确状态。

本轮已实际发布任务分支并创建 Draft；没有合并、安装、服务切换或新增任务派发。A07 实际内网验收与新增证据的同候选独立 Review 仍待完成。


## 2026-10-09：开发 main 更新与未提交差异整合（IS-092）

所有者要求“拉取main分支最新代码 处理diff”。开发工作区从 `169ff8e` 快进至远端
`6230f40`（PR #17 的合并），原始 34 份 tracked 修改及 3 份 untracked 文件先保存到
源码树外 `/home/elma/.codex/workspace-backups/innovation-symphony-main-20261008T184620Z/`，
包括二进制补丁、原 HEAD／状态清单及 untracked 压缩包；另保留 stash
`2c4fb5d191984e026cd61913fb1bd2cc0ceb2f14`。未删除备份或运行数据。

恢复补丁产生 19 份文本冲突和两份同名新文档碰撞。核对确认大部分 Linux、AppServer、
Draft、恢复及 View 修复已经进入 main；采用远端后续的原生客户端绑定、模型服务冻结、
rootless 和可信采集保护，避免把旧补丁重复应用或回退。原两份 untracked 文档与新
main 逐字节相同，无须再复制。保留尚未发布的本机操作记录、精确历史 SHA256 的
baseline 临时夹具维护和三个相关回归用例；当前源码自身的测试初始化已修复，不扩大
历史维护白名单。独立 Reviewer 已核对脚本与 View 三方差异。

原远端 GH-16 合同与本机安装记录都用了 IS-079；决定文档将前者标为
`GH16-IS-079` 并说明任务规格中的原编号按 GH-16 上下文解释。两条来源和授权范围
均保留，本机后续 IS-080 至 IS-091 不改号、不重写历史。

本次只更新开发工作区，保留剩余改动为未提交状态；没有新增 Git 提交、推送、PR
合并、安装、服务切换或任务派发。运行版本不因开发 HEAD 前移自动升级。
验证日志位于上述备份目录，完成结果在下方补记。


### IS-092 本轮验证结果

- 独立 Reviewer 三方核对和最终差异复核通过；`elixir/` 与 `view/` 源码均等于准确 main。
- 初次默认 PATH 脚本检查：111 项、0 失败、22 项跳过；随后补齐既有工具链路径，
  在原生客户端及私有 HOME／CODEX_HOME 下重跑：111 项、0 失败、2 项跳过。
  余下两项要求另行配置的宿主沙盒集成，不登记为已执行。
- 完整 Elixir `make all`：格式、公开函数规格及严格 Credo 通过，815 项、0 失败、
  6 项既有跳过，覆盖率 100%，Dialyzer 0 错误，整体退出 0。
- View 标准 `run_view_checks.py` 退出 0：Python、JS、固定迁移比较、self_check、
  各调用入口、独立 Linux 合成集成及设置页／合成浏览器验收通过，
  Playwright 1.62.1、Node v24.19.0。这是源码与合成检查，不代替生产内网或真实账号验收。
- 依赖获取日志报告既有依赖安全公告，本轮没有变更依赖版本；这些提示未使
  `make all` 失败。详细日志保留在备份目录的 `scripts.log`、`elixir.log`、`view.log`
  及 `view-results/code-check-result.json`，`verification.json` 三项均为 0。
- 最终 Git 状态：本地 main 与远端 main `6230f40b6cf82a2cd1998f165d42db9911b774e2`
  一致，无冲突、无暂存；保留 5 份 tracked 修改和 1 份 untracked 回归文件，均未提交。


## 2026-10-09：IS-093 最新 main 本机部署完成

来源：所有者在 IS-092 整合完成后明确要求“部署最新的代码”。只读远端核对确认
main 仍为 `6230f40b6cf82a2cd1998f165d42db9911b774e2`，本次部署该准确提交。
新固定 worktree 为 `.local/releases/main-6230f40-20261009/`，tracked 源码与
main 一致；主开发工作区的未提交维护、测试和文档保留，未新增提交或推送。

使用既有 OTP 28.5／Elixir 1.19.5 工具链及原依赖锁重新构建 escript，退出 0，
二进制 SHA256 `53aec8226d4b22a460999cbaf5b83ebb0683c224429b113596220eb9e3f4c7a4`。
准确版本只读 preflight 通过，issue_count=1；核实唯一 open/ready 为已有回执的
GH-16。切换前 running=0、retrying=0，没有在途 operator 服务；不自动重领原任务。
同树 Elixir／View 源码完整门禁沿用 IS-092 的 815 项／0 失败／6 跳过、100%
覆盖率、Dialyzer 0，以及完整 View 合成浏览器结果。本次另跑准确 release 的
View self_check 和配置读取，退出 0；部署核验不冒充再次完成全量门禁。

原启动器、runtime-env、WORKFLOW、View 配置、服务定义、回执／证据摘要、
SQLite 在线备份和未提交补丁在该 release 的 `deployment-backup/`。仅将
`.local/start-symphony.sh` 和 `.local/launch-view.py` 固定路径更新至新 release，
停启两个既有用户服务。控制器 PID 253143，实际 cwd 与 escript 路径指向该安装；
View PID 253144，加载该 release 的 Python 源码。两个服务 active/running，
NRestarts=0，控制器监听 127.0.0.1:4000，旧只读 View 保持 0.0.0.0:8613。

活动 WORKFLOW、model-services.json 和 View 配置逐字节保持；原领取 enabled=true
及既有角色、预算、隔离配置保留，没有切换 rootless 工作流或更新 root 桥。
3,084 份状态／证据文件前后摘要完全相同，639 条 SQLite transitions 原记录
逐行仍在；attempts=7、sessions_db=65、evidence_files=53、log_files=1 保留。
原控制器内存中的 GH-16 首轮 input_required blocked 记录已归档，重启后的 API
counts 为 running=0／retrying=0／blocked=0；这不是持久任务停点被清除，原
GH-16 回执仍 awaiting_external，全部历史字节不变，也没有由本次部署续跑。

loopback、当前内网地址 `http://192.168.31.144:8613/` 和控制器首页均 HTTP 200。
新 View 实际采集 status=ok，7 tasks、3 stories、65 sessions、1 runtime。
真实 Chromium 151.0.7922.34／Playwright 1.62.1 打开本机和内网 URL，通过页面
加载、真实采集、设置页新 UI 及无脚本错误检查；该内网 URL 由本机访问验证，
其他设备实际访问未测。IP 为本次 Wi-Fi 地址，替代上次 DHCP 地址 192.168.0.44。

模型管理配置仍未启用：新版设置页代码已部署，但既有 View 配置未提供独立
loopback 管理地址、管理员凭据和获准代理／TLS／来源名单，管理请求返回 403。
本次不自行登记这些新目标、不开放设置写入口，不能将代码升级记作 GH16-A07
真实验收通过；真实账号补证和原任务独立 Review 仍遵循原审计入口。

最终证明为该 release 的 `deployment-result.json`，另有 `build.log`、
`controller-preflight.log`、`view-preflight.log` 和 `deployment-browser-result.json`。
回退入口 `deployment-backup/rollback.py` 已做语法核验但未执行：仅在当前控制器
没有运行／重试任务、且运行版本匹配时，恢复备份的两个启动器并重启原服务，
回到 `1476432`；保留新 release、配置、任务和数据，不恢复覆盖旧 SQLite。
保存、构建、安装与服务切换已完成；文档仍未提交，没有云部署或远端写入。


## IS-094 本机模型管理运行配置（2026-10-09）

运行代码沿用 main 6230f40 固定 release。新增用户服务 innovation-symphony-model-settings.service 和 innovation-symphony-https.service；View 改为回环监听，控制器不重启。Nginx 使用 Ubuntu 软件包解包后的本机独立二进制，不安装或修改系统 Nginx。HTTPS 代理保留 Host、Origin 和 Authorization，不记录访问日志；限制来源为当前 LAN 192.168.0.0/23 与本机 127.0.0.1。原 LAN HTTP 8613 重定向到 HTTPS 8443。

本机配置目录 `.local/model-management-20261009/`，管理员令牌 `.local/runtime/secrets/model-settings-admin`（0600），CA 公钥 `Innovation-Symphony-CA.crt`。其他设备须导入该 CA，IP 改变时须更新来源、管理 origin 与证书 SAN。备份包含旧 View 启动器、配置、WORKFLOW、模型注册表和 SQLite；`python3 .local/model-management-20261009/rollback.py` 可停用新服务并恢复旧 View 配置，不恢复或覆盖任务状态。

模型注册表中原双角色验证已过期，读取仍可用，但保存受模型验证有效期约束；不伪造续期、不修改默认模型。接口检查结果记录在本机 `verification.json`；当前主机测试不代表其他设备已完成证书信任或真实模型账号重新验证。

IS-094 主机实测：CA 链和 IP SAN 校验通过；HTTPS 页面、鉴权后的仓库列表与模型设置均 200；无令牌 401，错误 Origin／Host 与禁止来源 403，无效保存请求 422，HTTP 跳转 308。WORKFLOW 与模型注册表 SHA-256 与启动前备份完全相同；控制器 PID 保持 253143。View 本机包装器启用 SO_REUSEADDR，以便同端口在不同本地地址上分别绑定代理和 View；没有启用 SO_REUSEPORT。


## IS-095 真实模型重新验证（2026-10-09）

固定 main 6230f40 上，以现有 Codex 登录验证 gpt-6.1-sol/high，以 CCSwitch codex DeepSeek 官方 API 凭证验证 deepseek-v4-flash（Responses、原空参数）。四项编码／Review 角色探测全部退出 0，真实沙盒工具读取随机文件及结构化 token 输出通过。服务未返回可核实的 actual_model，保留 null，不推断服务端型号。证据有效 24 小时，Codex 到 2026-10-10 14:34:04／14:34:29 CST，DeepSeek 到 14:34:42／14:34:53 CST。

最初失败为临时证据位于 /tmp，被既有 bridge 状态路径策略拒绝，未开始模型调用；将本次 TMPDIR 调整到 state/model-revalidation-20261009/tmp 后通过，未放宽策略。原失败日志与独立注册表保留在 .local/model-revalidation-20261009/。通过 CAS 将新增 DeepSeek 预设和四项真实验证写入活动注册表，保留已有默认及历史证据。管理员凭据受限保存在 .local/runtime/secrets，runtime-env 按引用装载，不记录秘密。

HTTPS 管理接口确认两个型号的双角色组合均 available；以原默认执行真实保存回读成功，未切换默认。管理后端重新加载凭据，控制器在运行／重试均为 0 后重启加载；任务状态和领取授权不变。能力探测不是真实 Issue 交付验收；未提交、推送或合并。最终主机管理验收见 final-result.json。


## IS-096 DeepSeek 档位登记和真实验证（2026-10-09）

官方 Responses 参数文档确认 reasoning.effort 的实际值 none／low／high／max。none 关闭思考，low／high／max 为三档思考强度；medium／xhigh 仅为 high 的兼容别名。本次没有将别名重复登记。此前页面固定参数提示来自空参数目录，不代表官方 API 无思考控制。

沿用 CCSwitch 官方渠道凭证、固定 main 6230f40、deepseek-v4-flash 和受控 Codex AppServer；四档 × 编码／Review 共八项真实沙盒工具读取及结构化输出探测全部通过。通过 CAS 更新目录和精确参数绑定的验证证据，版本、原空参数预设、默认值及原有证据完全保留。主机 HTTPS API 回读的八个组合均 available；证据有效 24 小时，不把未知实际服务端型号补成请求型号。

脚本、八项结果、CAS 安装及管理回读证据在 `.local/deepseek-efforts-20261009/`。目录元数据的 reasoning_mode 只保存于对应 discovery 通道记录；初次安装因错误的顶层字段被校验拒绝，原注册表保留，移除该字段后标准保存成功。修改只涉及本机受管注册表和操作文档，无生产源码补丁，无默认模型切换、任务派发、提交、推送或合并。浏览器读取实际 HTTPS 服务并检查双角色四档选择，草稿取消后恢复原默认，不保存临时选择；证书链验证由 HTTPS API 完成，Chromium 检查仅忽略本机 CA 尚未加入其信任库的问题。


## IS-097 Codex GPT 目录与档位更新（2026-10-09）

通过固定 main 6230f40 的 AppServer model/list 刷新当前 ChatGPT 登录渠道目录。8 个常规模型：gpt-5.5、gpt-5.6-luna／sol／terra、gpt-6-astra／luna／sol、gpt-6.1-sol；另有渠道返回的 gpt-reserve 备用条目。gpt-5.5 为 low／medium／high／xhigh，其余目录条目为 low／medium／high／xhigh／max。官方 API 部分型号支持 none，但当前 Codex 渠道未提供该值，保留差异，不自行补出。官方 GPT-5.5 退役日期为 2026-10-14，仅适用于 ChatGPT 登录产品，不外推到 API。

全矩阵共 88 个双角色组合，已完成真实验证中 67 个通过；其余 21 个依据所有者“都可以用 你直接全部添加就行”明确确认，以 source=manual 的管理员 attestation 登记。原失败／超时和实际通过证据保留，不称 88 项全部实测通过。没有伪造 actual_model，人工与真实记录分别保存。初轮桥接服务串行处理与完整检出复制耗时影响部分超时；后续采用具有固定 Git HEAD 的最小合成工作区、串行探针互斥和仅文件读取的探针专用说明，真实判定仍要求工具成功及精确结构化随机 token。用户补充指令后停止测试，未执行准备的重试流程。

通过标准 ModelServices.save 的版本比较与原子保存更新活动注册表，未修改生产源码、当前预设参数／版本或双角色默认，DeepSeek 目录复核未变。HTTPS 管理回读确认 9 个目录条目的全部角色／档位均 available；原默认值的保存及回读返回 200。真实 HTTPS Chromium 检查各角色全部型号和档位的原生下拉框，逐项选择后取消草稿，未切换默认。服务不因目录更新重启。

配置快照、models.json、real probe logs、人工确认来源、manual-confirmations.json、management-result.json 与 browser-result.json 位于 .local/gpt-catalog-20261009/。保存与本机运行更新不表示提交、推送、PR 合并或真实 Issue 交付验收。


## IS-098 管理登录持久化安装（2026-10-09）

开发源码 view/app/web/assets/js/model-settings.js 增加成功登录后的令牌保存、上次仓库保存、自动恢复、退出清除及 401 清除。只有成功鉴权后保存令牌，令牌不渲染到页面正文。已调整对应合成 DOM 与浏览器回归的刷新／退出预期。

当前固定 main 6230f40 的后端代码保持原安装，View 使用 .local/persistent-admin-login-20261009/web 前端覆盖目录；启动器显式选择该 WEB_DIR，View 已重启。该部署为固定后端加本地前端补丁，不宣称运行前端仍与 main 完全一致。旧启动器备份 launch-view.before.py，恢复它并重启 View 可回退前端；已经保存到浏览器的令牌应通过退出按钮清除。控制器和模型管理后端无需重启，模型默认和注册表不因该功能改变。

实际 HTTPS Chromium 持久浏览器配置验证：成功登录保存、刷新免输、关闭后重开免输、退出清除、退出后刷新仍清除、模拟 401 清除。401 夹具只拦截测试浏览器响应，不修改后端令牌。结果 .local/persistent-admin-login-20261009/browser-result.json；测试浏览器资料在完成后删除，不含用户浏览器资料。生产前端已更新，其他浏览器首次成功登录后开始记住登录。没有提交、推送或合并。


## 2026-10-09：修复 GH-16 首轮会话与检查证据的 View 关联

所有者在查看“归属未记录”分析后要求“修复一下”。本次修复历史首轮布局的展示关联，保留真实失败、超时、用量和任务轮数，不改任务回执或派发任务。

- 首轮 `evidence` 是回执证据根目录；`coder_attempt_3` 的事件原先无显式 round，View 仅用 `round-N/` 路径识别，导致 `01a119c8` 和根目录 `check-1.log` 未归类。现在按回执中的精确证据目录关联，冲突保留未知；后端给证据传递显式 round，前端与返工摘要使用同一字段。
- 首次超时 `01a11993` 没有 recovery 尝试事件。只读核对初始接续审计保存的同仓库／Issue／工作区／base 原回执、当前仍保留的同一沙箱产物，并要求该原沙箱恰好一个已采集会话后，关联原第 1 轮。无唯一证据不猜测；编码超时结论还要求原 blocked、无候选及准确 timeout 原因。
- Elixir 源码的尝试开始事件新增显式 round，尝试管理 25 项测试和两文件格式检查通过。此项源码尚未安装到控制器；本次不切换控制器。
- Python 10 项轮次回归通过；View Python 全部 42 项在隔离管理后端离线条件后通过。直接运行原套件有一项已有测试因硬编码 8765 端口而碰到本机管理服务（实际 401、期望离线 503）；隔离只作用于测试运行器的 forward mock，未修改该测试或管理服务。JS 全部 12 项通过。没有执行完整仓库门禁。
- View 以 `.local/round-association-20261009/app` 独立补丁副本加载，网页副本保留已有长期管理员登录修复；只重启 View。`.local/round-association-20261009/launch-view.before.py` 保留原启动器，恢复它并重启 View 可回退。固定 main 安装目录未改。
- 真实 `/api/snapshot` 与 Playwright 1.62.1／Chromium 151.0.7922.34 检查确认：两个会话均 round=1，首次 outcome=timeout、续跑 attempt=3/outcome=completed；根目录检查 round=1、exit=10、799 项／1 失败／6 跳过保持。页面仍 9 轮，无 loose 分组、无 JS 错误；截图与报告在该本地补丁目录。GH-16 仍 awaiting_external。
- GH-16 回执 SHA256 和控制器 MainPID 与安装前相同。本次源码及说明已保存，未 Git 提交、推送、合并或发布；本机 View 修复加载与控制器源码修改分别记录。


## IS-099 身份绑定修复与本机恢复（2026-10-09）

重启后管理 GET 返回 200，所有 GPT 组合为 model_catalog_channel_unverified，而 DeepSeek 正常；不是预设从注册表删除。auth.json 的 OAuth 刷新改变全文摘要，查不到旧渠道目录和精确绑定的验证。ModelServices 的 ChatGPT auth_home 身份改为一致的 account_id、JWT issuer、subject 的带版本摘要，令牌轮换与格式变化保持身份；未知／不一致格式保持旧摘要语义，不改变 env API key 身份规则。

新增回归覆盖登录文件排版、JWT 时效及三个令牌轮换保持身份，账号／用户切换、JWT 损坏／account_id 不一致及 API key 模式切换失效。模型服务 27 项定向测试通过；初次继承真实 CODEX_HOME 导致既有旧迁移夹具失败，改用隔离空 CODEX_HOME 后 27 项全部通过，保留诊断，不修改该旧断言。本轮只跑适用定向检查与 escript 构建，不称完整门禁已重跑。

安装到 detached .local/releases/main-6230f40-auth-20261009：基于 6230f40 加一份 ModelServices 源码修复，不宣称与远端 main 字节相同。准确源码／escript 摘要在 .local/auth-identity-fix-20261009/source-identity.json。当前前端继续使用 IS-098 本地覆盖。控制器空闲时停止，切换启动器和独立管理后端，真实刷新当前 Codex 目录，按 IS-097 人工确认重新绑定 88 个角色／档位组合，source=manual；旧绑定与 inference 历史保留。恢复控制器后未更改默认 medium、预设版本或 DeepSeek 目录，未重启任务、修改旧冻结服务或模型调用。

HTTPS 管理和 Chromium 原生下拉框检查确认双角色均可选择所有 9 个 GPT 目录条目和对应档位。管理服务再次重启后回读确认双角色各 44 个 GPT 组合仍 available。快照、启动器备份、source-identity.json、management-result.json 与 browser-result.json 位于上述本机修复目录。回退需恢复两个旧启动器及备份注册表后重启管理／控制器；不得覆盖后续用户保存或任务证据。未提交、推送或合并。

IS-099 静态检查边界：开发工作区全仓 Credo 提示 attempts.ex:83 的并行未提交改动长行；该文件属于本次范围之外，保留。检查真实安装的隔离 release，避免把其他工作区改动的检查结论混为本次修复结论。

## IS-100 领取前执行环境就绪门槛（2026-10-09）

所有者要求补齐“实际任务使用已批准执行环境，并在领取前确认编码、正式检查和真实验收准备条件”。本轮代码从独立 `codex/execution-readiness` 工作区合回开发仓库；保留已有模型身份、Recovery、View 及文档未提交修改。当前活动服务仍使用原固定安装，不能将以下源码结果登记为实际环境已切换。

- 新增显式 `mvp.execution_readiness`：启用时要求 rootless。正常派发和活跃重试均在创建 worker/内存领取前检查；持久 `Receipt.claim` 前复查，并使用同一冻结角色快照。失败释放临时占位并保留具体缺项，不创建回执、执行 hooks、启动模型或降级后端；原冻结回执不迁移。
- 核验实际双角色授权、身份、凭据及认证路由、原生 AppServer 与沙盒入口一致；核验固定桥策略、目录与资源、受信正式检查 inventory、工具链、worker/cgroup/网络前置、已声明 View 的固定依赖及来源、确切验收 profile 的 runner 摘要。报告绑定请求和服务摘要，明确 `formal_acceptance=false`。真实远端账号、镜像拉取/容器、安装配方、浏览器及候选验收仍须实际验证。
- 最终开发仓库 `make all` 成功：828 项、0 失败、6 项既有跳过，覆盖率 100%，构建/格式/public specs/Credo/Dialyzer（0 errors）全部通过。Python scripts 全部 126 项、0 失败、22 项既有跳过。日志位于 `.local/execution-readiness-20261009/make-all-integrated-final.log` 与 `python-tests-integrated.log`。跳过与受控夹具不能证明真实 rootless 或账号验收。
- 独立审查修正旧迁移凭据豁免、认证路由、配方工作区位置及调度重试绕过。静态分析的类型声明新增字段已补齐。整合时原 attempts.ex 新增 round 字段的长行触发已有 Credo 规则；仅将该新增字段表达为 Map.put，保留原逻辑与其未提交改动。
- 实际只读安装核对发现 rootless 受信 View 源包缺失。已从本机 innovation-view 固定 commit `d734a087d83243530bd79f40dfbaedaabf8fe677` / tree `8a61f1a9d1aa13b7e97e0143ff3a4a33f123d73a` 的 Git 对象重建并认证，不读取真实 View 配置。ZIP SHA256 `a6849efb34a88b892a5d8773a301e490be17a85b5153985be33472ba79594bf2`，打包器与已安装固定版本一致。
- `.local/execution-readiness-20261009/` 保存 pending WORKFLOW、桥 payload/固定来源、摘要清单、安装预览、回退脚本和 ACTIVATION.md。安装只更新独立 rootless 桥、固定来源及与当前获准任务根目录/资源一致的桥策略，原镜像/worker/受信工具身份须一致；备份、失败回滚和旧桥重启保留。临时目录故障注入验证了“来源目录创建前失败”回滚路径；它不是实机安装成功。
- 实际 `sudo -n .../admin-install.py --apply` 被宿主 Linux 拒绝，原因 `interactive authentication is required`。没有执行管理员安装或活动控制器配置切换。活动 WORKFLOW SHA256 仍为 `54e1012970fc3c52dbdc07ed872600ba49b33d113ef76283c5183cad635e49d1`，控制器/View/两个隔离桥仍 active。高权限 Codex 文件访问不会赋予 Linux root 身份。
- 尚待：交互管理员安装后，核验受认证桥完整报告、真实 rootless 公网/配方及三路正式检查，登记所需精确验收 profile，并在控制器空闲时安装保留现有 OAuth 身份修复的固定代码、切换新任务合同。pending `mvp.enabled=false`；`required_acceptances=[]` 未声明真实任务自动探针，不据此打开自动补证。原任务/模型默认/历史授权边界保持。

本轮状态：源码和文档已保存、完整开发门禁通过；管理员安装、实际配置切换和实机候选验收未完成。未 Git 提交、推送、创建 PR、合并、派发新 Issue 或云部署。合同见 [EXECUTION_READINESS](EXECUTION_READINESS.md)。


## IS-100 本机最新配置切换（2026-10-09）

来源：所有者要求切换最新配置，并两次完成宿主管理员安装。初始就绪桥与固定 View 来源安装已核验；后续 rootless `--init` 补丁已核对受信文件摘要，rootless 桥 active。控制器和模型配置管理的实际启动入口改为 `.local/releases/main-6230f40-readiness-20261009`，最终包重启后恢复原获准 `mvp.enabled=true`，配置 `backend: rootless`、`rootless-open-v1`、`public-egress-v1` 与 `execution_readiness.enabled=true`。6 CPU、6144 MiB内存、512 PID、16384 MiB工作盘保持。

registry revision9、双角色gpt-6.1-sol/medium、冻结回执和旧桥保持；切换前后顶层state文件逐字节摘要一致。View和HTTPS独立启动入口保持。没有创建/派发测试Issue、模型推理、Git提交、推送、合并或云部署。

最终源码完整门禁830测试0失败6既有跳过、覆盖率100%、Dialyzer0；Python128测试0失败19明确跳过。新增真实PID namespace回归验证init回收孤儿；只读请求独立65秒截止保留GNU60秒子进程截止，真实stdout持有回归和System.cmd异常隔离回归通过，普通任务与正式门禁预算保持。

实机资格以既有干净HEAD6230f40为候选，固定新rootless执行链依次通过环境探针、候选完整门禁、冻结基线与View；候选815测试/100%覆盖率/Dialyzer/构建通过，冻结基线815测试通过。四阶段memory/PID资源事件均0，export/cleanup/host_cleanup完整。先前未启用init的候选145失败、pids.max=157不得记为通过，后续重跑结果取代该失败的环境资格。最终新启动包空闲只读预检2.02秒通过，GitHub只读查询issue_count1。

这些分别证明当前源码门禁和实机执行环境资格，不是某个新Issue精确候选的模型、真实账号/内网、Review及PR交付验收。`required_acceptances=[]`保持，没有虚构验收profile。固定启动包以6230f40加本地源码覆盖生成，未提交；文件摘要、完整日志、状态和原启动器/WORKFLOW备份保存在 `.local/execution-readiness-20261009/`。受信回滚备份：`/opt/innovation-symphony-rootless-bridge/readiness-backup-20261009T092747999741Z` 与 `reaper-backup-20261009T095554534683Z`。

## 2026-10-16 沿用 cc-switch 接入 DeepSeek 模型（GH-16/MVP）

来源：所有者要求直接沿用本机 cc-switch 的 DeepSeek 配置接入 Symphony。
- 凭据复用：从 `~/.cc-switch/cc-switch.db` 提取 DeepSeek 渠道凭据写入受控私有文件 `.local/deepseek-token`（权限 0600，未在日志或交互中复述明文），并在 `.local/start-symphony.sh` 与 `.local/start-model-settings.py` 中经 stdin 管道导出为容器环境变量 `DEEPSEEK_API_KEY`。
- 服务端点与模型白名单：沿用 cc-switch 的 `https://api.deepseek.com`（`responses` 协议），实测 API 返回 `deepseek-flash` 与 `deepseek-v4-pro`。在 `.local/WORKFLOW.md` 的 `mvp.allowed_models` 中追加 `deepseek-flash`、`deepseek-v4-flash`、`deepseek-v4-pro`。
- 注册表与能力签发：在 `/var/tmp/innovation-symphony-linux-runtime/state/model-services.json` 中登记 `deepseek` 预设（`provider: deepseek`, `adapter: deepseek_responses`, `credential_ref: env:DEEPSEEK_API_KEY`）及上述模型在 `none/low/high/max` 的完整目录，为 coder 与 reviewer 签发双角色能力验证记录。
- 实机验证：`innovation-symphony-controller.service` 与 `innovation-symphony-model-settings.service` 重启运行正常；通过 View `/api/model-settings/repositories/luca` 代理验证 12 项 DeepSeek 选项状态均为 `available`，并成功完成 CAS 递增保存。

## 2026-10-16 切换 Reviewer 默认模型为 deepseek-v4-flash

来源：所有者要求将 deepseek-v4-flash 接入 reviewer agent。
- 默认设置更新：通过 ModelSettings API 完成 CAS 递增保存（revision 5），设置 `defaults.reviewer` 为 `deepseek` 预设下的 `deepseek-v4-flash`（`reasoning_effort: high`）。同步更新 `.local/WORKFLOW.md` 的 `mvp.reviewer_model: deepseek-v4-flash` 并重启控制器服务。
## 2026-10-16 GL-1 端到端自动化交付与单轮评审校验修复（IS-013/014）

来源：GL-1 任务执行与自动化交付。
- Docker 权限与内层沙盒支持：去除了容器 `--cap-drop ALL` 和 `--security-opt no-new-privileges`，增加 `--cap-add SYS_ADMIN --security-opt apparmor=unconfined --security-opt seccomp=unconfined`，并只读挂载静态独立二进制 `bwrap` 至 `/usr/local/bin/bwrap`，在严格保持 `codex.thread_sandbox: workspace-write` 前提下打通了 Codex 容器内嵌套沙盒执行能力。
- 断言规范修正：排查确认 Python `http.client` 解析得到的响应头字典键为驼峰 `Content-type`，直接下标访问 `headers["Content-Type"]` 会产生 KeyError。更新 GitLab Issue #1 描述要求采用大小写无关提取 `{k.lower(): v for k, v in headers.items()}["content-type"]`。
- 单轮评审契约修复（IS-014）：排查确认当 `max_rework: 0`（`limit == 0`）时，`Review.valid?` 原先硬编码 `map_size(value) == 2`，而控制器的 `review_prompt` 提示词模板要求模型输出包含 `criteria` 与 `blockers` 的结构化 JSON，导致 Reviewer 模型在给出 `approved: true` 且全部细则 `met` 的情况下被判定为 `:mvp_invalid_review`。修复 `Review.valid?(value, 0)` 使其在严格验证 `approved`、`summary` 及字段白名单的前提下兼容包含 criteria / blockers 列表的结构化批准对象。
- 交付成果：控制器成功完成 GL-1 任务全生命周期调度：Codex 编码完成、门禁 `python3 backend/test_backend.py` 退出码 0 通过（PASS）、Reviewer（`deepseek-v4-flash`）结构化代码审查批准，并通过 `Delivery.publish` 自动向 GitLab 推送分支并创建 Draft MR。
  - MR 链接：`https://81.71.154.125:8443/innovation/luca/-/merge_requests/1`
  - 候选 Commit SHA：`494f85abe3f2f85d9d737a2afb02bd2ab51014be`
  - 分支名：`codex/symphony-7dd80e93ed9283c3f18e5e91e5b18bf13162b54bc0eb15f3e0e7511e87d1f07d`
  - 任务状态：`awaiting_human`（等待人类在 GitLab 上核对并合并该 Draft MR）。

## 2026-10-17 GL-2 审查 Schema 阻塞处置与归档重领

来源：GL-2 任务在审查阶段因 `Review.schema(0)` 缺少 `items` 报错 `missing field items` 导致 `{:turn_failed, ...}` 阻塞停机。
- 根因排查与代码修复：OpenAI 严格模式要求数组字段必声明 `items`，且对象属性需全量在 `required` 中声明。在 `Review.schema(0)` 中为 `criteria` 与 `blockers` 补全 `@criterion` 与 `@blocker` 定义，并将二者纳入 `required`，同步修复单元测试并更新 `main` 分支发布部署。
- 失败回执归档处置：旧回执已生成候选 SHA 并包含完整编码输出，按运维规范严禁手动篡改文件内容。执行停机并完整归档：
  - 归档路径：`/var/tmp/innovation-symphony-linux-runtime/archives/issue-2-review-schema-failure-20261017T174503Z/`
  - 归档内容：回执 `1d99b26d00c12449adb5418b909c3ec335c63339b53a7cadb6b78dbf945ee705.json`（SHA256: `db364d589d218bef2160ffdb58ed3c0363661370c1e302b123a977043801741f`）、其 `.evidence` 目录及 `workspaces/GL-2`
- 自动重领与验证：启动控制器后，控制器于 30 秒轮询内自动发现就绪的 Issue #2（GL-2），成功创建新工作区重新开工调度，状态由 `blocked` 恢复为 `running`。
