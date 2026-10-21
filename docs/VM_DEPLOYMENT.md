# 独立虚拟机部署与闭环验收

2026-10-21 当前摘要：活动固定 release 为 `37fa886b7cf7-20261021`，本地 main 的后续 `6bedb1f` 仅补充部署记录。三个原生服务在 guest 内运行，旧宿主三服务禁用，ready 正常开启。经所有者明确授权，宿主已删除 11 个旧归档、释放 20.52 GiB；当前保留和已删除的恢复源见文末“存储清理与现存恢复源”。下文分阶段记录保留其发生时的状态，不能把历史快照路径当成当前仍存在的文件。

日期：2026-10-20。来源：所有者逐项选择并明确批准完整实施计划；授权与替代关系见 DECISIONS 同日条目。本文随实测更新，不用部署配置代替验收证据。

## 固定部署

主机 `elma-ubuntu-pc`，仓库 `/home/elma/文档/Code/innovation-symphony`，本地分支 `codex/vm-deployment-direction`。开始 HEAD 为 `edb77dbce1a5ae172a6fb86e6e451c8dd87d56b6`，原两份未提交的需求/决策文档保留。

VM 使用 QEMU/KVM，8 vCPU、12 GiB 内存、50 GiB 按需增长的 QCOW2 系统盘，目录 `/data/symphony-vm`。Ubuntu 24.04 官方镜像 SHA256 为 `04e8f2461a16a44e78a370284471f29616cdd9baf1893df25807b71f985b6c94`；`SHA256SUMS.gpg` 已由本机 Ubuntu cloud image keyring 验证为 Good signature。VM UUID 为 `e95ff885-dd31-4ad7-b894-35d1a0102429`。

NAT 只向宿主 loopback 转发 SSH 22220；页面通过 SSH 隧道连接 VM loopback 4000/8613/8765，准备阶段宿主使用 14000/18613/18765。专用 SSH 主机密钥指纹与可信本机串口记录匹配后才保存，不禁用主机密钥校验。没有共享宿主文件系统、设备、Docker socket 或 SSH agent。

工具链固定为 OTP 28.5.0.7、Elixir 1.19.6（源码编译）、Codex 0.163.0、Node 24.21.0、JDK 21、Python 3.12。官方 Codex 归档 SHA256 `beb339e8ecd9ba057a6bb2dc81ad8ca474812edfbf0fc5056ca818797648dde4` 已核对官方 release asset digest，解压原生程序与当前宿主实际客户端逐字节摘要一致。Node 归档摘要已核对官方 SHASUMS256；其余安装归档与软件包版本在本机安装清单中记录。

## 基线保全

操作证据目录 `.local/vm-deployment-20261020T090218Z`；其中 baseline 保存原工作流、启动入口、服务单元、HEAD 及回执 SHA256。运行根初始归档曾保存为 VM 目录的 `migration-runtime-20261020T090218Z.tar.gz`，它是预复制，不替代切换时的一致性备份；该归档已在下述授权清理中删除。原运行 release 为 `a8ef726-20261017T172900`，旧服务在新环境门禁通过且空闲切换前保持运行。

## 当前状态（2026-10-21）

源码门禁通过。guest 纯净环境执行 `sudo bash scripts/vm/check-native.sh /home/elma/symphony-install/source`，完整 `make all` 返回 0：996 项测试零失败、6 项显式跳过，总覆盖率 100%，格式、public spec、严格 Credo 及 Dialyzer 通过。此前失败日志保留，当前 Git 修订日志为 `.local/vm-deployment-20261020T090218Z/full-gate-git-deadline.log`。所有新增忽略和降低门槛的方案均未采用。

scripts 原生完整回归 200 项、20 项显式跳过通过（含停止边界、启动缓存、TCP 探针及 Codex 组件修订）。View 为 Python 57 项、JavaScript 15 项、本地 Linux 集成 11 项，以及浏览器夹具和迁移等价检查通过。源码经分域独立审查、简化及修改后独立复审；旧清理的真实权限回归 13 项通过。

VM 已实际运行，sudo 安装、临时 loopback HTTP、真实 Docker build/run/按归属清理探针通过；原生 escript preflight 曾通过。固定工具链已安装，Docker Engine 29.1.3，宿主 linger、VM 与 production 隧道的 systemd 已启用，staging 隧道已停用。VM 三项原生服务已安装启用，正常 reboot 后自动恢复。原端口已切换到 VM，旧服务停止并禁用自启；临时隧道已停用。收尾核对 ready 只有已有回执的 GL-3/4 后，已解除本轮临时领取暂停，恢复按可信 ready 自动领取。GL-4 已交付 Reviewer 批准的 [Draft MR !3](https://81.71.154.125:8443/innovation/luca/-/merge_requests/3)，状态 awaiting_human。候选 `267aa8f24c57d857f4bdc651099c7e5d903a22c3` 的两项正式检查通过，独立 DeepSeek Reviewer 批准全部 20 项验收。原开始时间、4 次模型调用和一次返工完整保留；前段 Git 抓取和缺失原生组件需要两次人工审计接续，因此不登记“首次 ready 后全程无人干预”通过。修复后的编码、检查、Review、推送和 MR 创建自动完成，没有人工补 Docker 证据。

准备备份的独立恢复已通过，下文记录准确归档与校验。固定 native release 已安装，最终运行数据已复制并核对；实际每日备份及其独立目录恢复已通过，见后文；每日 timer 已启用，当前下一次为本地 2026-10-22 03:13:48；真实交付闭环已通过上述候选与 MR 对账。

## 接续与运维补充验证（阶段记录）

2026-10-20，原生 VM 内本地夹具的模型和交付回调为合成实现，不调用外部账号、不向平台写入。真实 Git、回执、正式检查和 OS 所有权检查均运行。检查进行期间对独立夹具控制进程执行 systemd restart 后，候选 `0ef42d5c1fbd738e6b190cd848c39d5e3ecf16e9` 与原预算起始时间保持不变，尝试数由 coder 的 1 增至加上后续 Review 的 2，恢复代数为 1。正常 VM reboot 的第二夹具同样通过，候选 `baf3c4eab449d927e7630d0a46a5822b08530d9d` 不变，boot ID 从 `e4c70bd5-0c2b-46d8-8992-d534efb17ef7` 变为 `e86cd440-48fd-4184-8fec-742b6ea342f9`。宿主 QEMU NRestarts=0，SSH 隧道自动恢复。此夹具验证恢复引擎；正式 Orchestrator 的平台发现和准入仍由回归及之后真实 Issue 验证，不把它记作真实模型任务重启通过。

View 完整检查：Python 55 项、JavaScript 15 项、本地 Linux 采集 11 项、浏览器夹具及迁移等价检查通过。scripts 最新原生检查 176 项、20 项显式跳过；VM 运维定向 48 项通过。全量 Elixir 预跑 936 项中有 6 项失败，覆盖率 98.29%；其中旧人工接续事件格式已修复并通过对应 16 项回归，其他缺口补齐后仍须重新跑原有 100% 门槛。严格 Credo 和 public spec 检查当前通过，不代表最终全门禁通过。

启动时先从当前平台、仓库对应的显式新合同回执对账，通过平台 ID 读取现状。旧回执、终态、awaiting_external 和已有停止记录均不进入恢复。尚有中断任务时先处理它们；原执行者仍活跃或身份无法核实时阻止新领取。ready 撤销或任务关闭会保存独立停止记录，原回执字节不改；恢复重新核对 ready 事件操作者，冻结模型不随管理员默认值变化而替换。

可重复准备、检查、启动、停止、备份及独立目录恢复入口见 [运维工具说明](../scripts/vm/README.md)。所有生成副本必须与最终固定 release 一起核对；`--apply` 的授权已包含在本次实施计划内，默认无该参数仅检查或显示计划。备份和维护使用单独的 nonce/PID/boot 排空握手；磁盘 guard 不与长时间备份共用操作锁，不因备份清理而撤销并发磁盘暂停。

VM 模式分配新模型会话目录时保留全部历史，不调用旧的“仅保留最近 50 个目录”清理入口；旧 rootless 和未启用 VM 的合同保持原行为。这对应本次完整历史保留要求，与磁盘不足时暂停领取配合，不靠自动删历史释放空间。

## 2026-10-21 准备备份与门禁修复

准备备份 `/data/symphony-vm/migration-prepared-20261021-v2.tar` 当时通过独立目录恢复，SHA256 为 `0cfded9a1c5f883186f5313a55e8f4a587875c7aa92649a4b5d090638b634092`；该 tar 已在后续授权清理中删除，不再是可用恢复源。恢复目录 `/home/elma/symphony-restore-20261021` 未激活领取；当时恢复前后历史回执摘要一致，View SQLite integrity_check 为 ok，含 3 个任务、71 条状态变化及 10 个会话。此备份来自准备副本，正式切换随后另做最终一致性复制。

第一次准备归档因 guest 引导时留下、未被运行配置使用的 `runtime/venv` 外部符号链接而失败，失败归档 `.tar.partial` 保留。该目录已移至 guest `/home/elma/symphony-install/unused-runtime-venv-20261021`；活动 View 独立环境不变。没有为绕过校验而放宽归档链接规则。

用户明确批准最小整理旧 ModelServices 清理代码，同时保留 100% 覆盖率门槛。独立审查指出读取回执、恢复日志及进程描述符失败不能证明资源闲置；当前修复在读取无法确认时保留历史。最新完整门禁还暴露新测试删除当前目录后未隔离 WorkflowStore 配置，造成应用退出及后续级联失败，正在修复测试隔离；该轮门禁失败，不登记通过。旧服务继续运行，VM 领取仍关闭。

后续 984 项测试零失败（6 项显式跳过），覆盖率 99.97%，尚未达到门槛。完整套件中的孤儿僵尸进程曾使清理测试全部保留：独立 PID namespace 的 PID 1 已改用安装随 Docker 提供的 tini 回收子进程。新的真实权限回归共 13 项通过，覆盖不可读回执、不可读 journal、不可遍历 import 父目录及嵌套工作区；恢复发现不再用会隐藏权限错误的 wildcard，逐目录读取并用设备/inode 去重，符号链接别名和循环另经独立复现通过。最终完整门禁仍须使用此版本重跑。

另一次门禁止于 Hex 注册表网络超时；离线尝试明确因注册表缓存不完整而失败，未跳过依赖解析。保留原有联网锁定依赖流程，所有失败日志保留在证据目录。

最终源码的控制进程重启夹具复验通过：检查期间重启后，候选 `af226793b961c65fe5dd06d3374ec77b0cabcb95`、原预算起始 `2026-10-20T17:29:30.976956Z` 均保持，agent_attempts 从 1 增至 2，generation 为 1。仍为合成模型及交付回调，不计作真实模型闭环。

## 固定安装及空闲切换实测（2026-10-21）

本地实现提交 `337f00f0cb55b40345921dca52276ed9fd84f7a7`，未推送。首个固定 native release 为 `/opt/innovation-symphony/releases/337f00f0cb55-20261021`，escript SHA256 `241216c25fa2c4cbe3fbbf68d17dcf26e4d5fa6c550de23cd431ab9e8feb46e2`。安装前核对构建源码与提交，安装清单保存工具链及归档摘要。最初复制 escript 因归档不含 Git 忽略的 bin 目录而失败，补建目录后完成；未覆盖已有 release。

该 release 的真实只读 preflight 返回 passed、issue_count=1。正式模型端点的无凭据网络探针分别返回 405 与 401，仅证明网络可达。三服务均只监听 guest loopback，Docker 无 TCP 管理监听。View 实际采集 3 个历史任务、10 个会话。正常 VM reboot 的最终夹具候选为 `f3278fa5088ec50bc09ede72319f780b1234b733`、原起始时间 `2026-10-20T18:01:40.060253Z` 不变，调用次数 1→2、generation=1；boot ID 变为 `bceb69da-a605-4322-889c-493f79b131d1`，服务和隧道自动恢复，QEMU NRestarts=0。该夹具仍不调用外部模型。

切换前再次确认旧控制器 running/retrying 为 0、ready 只有已有回执的 GL-3。停止旧控制器和模型设置后，最终运行根归档 `/data/symphony-vm/migration-final-runtime-20261021.tar`，SHA256 `bd20e5d123da46617af5ee9ed03717f60e5b7523b77676f96580bdbb02c754c6`。最终复制的回执和证据摘要全部一致，SQLite backup API 生成的快照 integrity_check=ok，3 个任务、97 条状态变化、10 个会话、9 个证据文件记录。另保留旧 `.local/runtime` 与三个旧服务的完整用户 journal 到 guest runtime 的 `archives/host-services-20261021/`，避免遗漏旧启动入口放在运行根之外的日志。

无使用者的引导重复配置已移至 guest `/home/elma/symphony-install/unused-bootstrap-configs-20261021`，保留摘要；活动 WORKFLOW/模型设置/View 配置只使用 `/var/lib/innovation-symphony`。原 4000/8613/8765 端口已转到 production SSH 隧道，旧三服务禁用自启，staging 隧道停用。4000 的 boot ID、8613 的真实采集结果和模型管理认证读取均通过。

首次实际 daily backup 因正常停止后的控制器 unit 标为 failed 而拒绝，0 字节 `.partial` 保留，三服务由 finally 恢复，领取仍关闭。根因是原 CLI 把 Supervisor 的 shutdown 退出映射为 1；不改旧 CLI，也不将任意退出码 1 标为成功。备份边界改为同时核验已停止状态、MainPID=0、整个 cgroup 树无进程及端口空闲；日备份开始前已有 failed 状态仍拒绝。该修复的测试、复审和再次实机备份另行记录。


备份停止边界修复已通过 58 项运维回归及独立正确性审查。新增 7 项保留原 inactive 合同，并验证已死亡 failed、活主进程、嵌套进程、IO 错误、端口占用及实际归档恢复。Elixir 源码与先前 100% 完整门禁版本相同，未改旧 CLI。


后续实机备份在写入约 3.2 GiB 后因 Codex 版本探针的外部启动助手链接而拒绝。失败文件 `/data/symphony-vm/daily-backup-diagnostic-20261021.tar.partial` 保留，三服务已恢复。拒绝定位到 `codex-home/tmp/arg0-linux`，目标为固定 Codex 安装；工程修订只排除此可重建启动缓存及受管 run home 中对应目录，其他外部链接规则不变。修订的回归及最终实机结果待记录。

启动缓存排除修订经独立复审，60 项运维回归及 VM 原生 scripts 完整 188 项（20 项跳过）通过。会话/metadata/其余 tmp/项目同名目录的实际归档恢复完整，12 类非指定外部链接仍拒绝。Elixir 源码及 escript 摘要不变。


常规入口的后续 0 字节归档失败经精确脚本追踪确认为 `require_stopped` 绑定 4000 返回 errno 98。该次失败没有记录重启前的 TCP 状态；真实内核回归复现了 TIME_WAIT 的同样误判，并验证 SO_REUSEADDR 可处理它，故端口探针增加该选项。活动 listener 的 loopback/wildcard × 复用开关四组合均仍拒绝。其作用是探测活动监听，受管进程退出由 MainPID/完整 cgroup 树证明；不能据此断言不存在非受管的未监听 socket。独立审查及 61 项运维回归通过，VM scripts 完整 189 项、20 项跳过通过。最终常规日备份和恢复仍待实测，不把诊断方式成功导出记为该入口通过。


## GL-4 真实验收：首次准备失败与传输修复

唯一新 Issue 为 [GL-4](https://81.71.154.125:8443/innovation/luca/-/work_items/4)，创建前以持久 marker 对账避免重复；原 GL-3 未修改。ready 列表核对为 GL-3 和 GL-4，旧回执阻止 GL-3 再次领取。GL-4 领取后只暂停追加领取，当前合同仍可执行；首次 Git fetch 到固定 120 秒后返回 124，Root 状态为 blocked，模型调用为 0、无候选或远端推送。GitLab statistics 报告 repository_size=394325415 bytes，现场 .git 为约 197 MiB；此数值不等于完整网络传输量，下载与索引耗时未细分。

原回执保存在本机 `gl4-initial-fetch-blocked.json`，SHA256 `a9108134ff15a6ca1a698bc5714274d335e31bd537142a6b71d05382a3a3dc35`；预算原始起点 `2026-10-20T19:16:52.173839Z`，四小时截止点为 `2026-10-20T23:16:52.173839Z`。冻结核心摘要 `109939488f78dafa6f175e0d2351e630c56d264f746d036f4e92ee6f7b45a9c1`、coder/reviewer 与检查/恢复配置不变。修复期间创建独立维护围栏并关闭领取，不把 blocked 纳入通用自动恢复扫描。

工程修订仅在显式 VM restart 合同尚未初始化 Recovery 时，为调用进程内的 Git fetch 设置绝对截止点：冻结 started_at + max_elapsed_ms，单次上限 30 分钟，过期不启动命令。其他 Git 命令、旧路径 120 秒和通用命令取整不变；嵌套和异常退出恢复原作用域。四个冻结执行模块无源码改动，安装前还须对比构建摘要。新任务及准备阶段接续的定向回归通过，含原预算已用 59 分钟、只剩 60 秒时的真实 Git 抓取窗口；完整门禁正在重跑。

同一 GL-4 的准备重试是此次已授权验收中的显式运维动作：保留原 blocked 原文及原因，在确认旧执行者退出、核心摘要一致、未启动模型、工作区绑定和剩余预算后，记录审计再交回原恢复入口。不会替换模型、重置起点或抹掉失败记录；此项尚未执行，须等修复门禁通过。


常规日备份已在 `72a66022dc55bddb727e88a55ecaad471637fbc5` 固定版本完成：`/data/symphony-vm/backups/daily-20261020T190632300613Z-90591e7de9cd4f23aa74033661e3fffd.tar`，SHA256 `d49c53e67ad715796d681e4942bfbe313174ed329f5231c185f68e52b1199f3e`。恢复至 guest `/home/elma/symphony-restore-final-20261021` 已验证未激活、WORKFLOW.enabled=false、state_dir 指向恢复副本、暂停标记存在；5 个状态 JSON 摘要与活动源一致，SQLite integrity_check=ok（3 个任务、99 条状态变化、10 个会话、9 个证据记录）。备份服务自动停启和健康恢复通过；本机备份定时器待真实验收任务结束后启用，磁盘定时器已启用。

Git 传输修订的完整纯净 `make all` 已通过：996 项零失败、6 项显式跳过、100% 覆盖率、Dialyzer 零错误。之后仅加强开始时间断言，VM 原生单项 fresh/resumed 测试再次通过，生产代码与全门禁相同。新旧 escript 中 RestartRecovery/Executor/Attempts/Recovery 四个 BEAM 逐字节一致，证明无需改变 GL-4 冻结核心摘要。`08f5d9975822` 已安装，准备重试审计通过且完成 Git 抓取；预算及冻结核心绑定保持原值。

## 2026-10-21 原生客户端组件故障与显式接续

本阶段固定控制器为 `/opt/innovation-symphony/releases/08f5d9975822-20261021`，escript SHA256 `e2f461a97dc5481e5dc707feb9fe77e15956a37f1c44310591591c3ce07d625f`。VM 初次 Git fetch 使用 30 分钟上限并受任务原剩余墙钟约束；原 120 秒 fetch 失败的完整回执和审计日志保留。此次变更未改变冻结的四个恢复核心模块，原 source SHA256 绑定仍有效。

真实 GL-4 的第 1 次 coder 和第 2 次 diagnosis 均已正常结束并完整记账，但工具启动失败：初次安装的单二进制 Codex 归档缺少同版 `codex-code-mode-host`。此前 `codex --version` 与 AppServer 启动探针不足以证明执行工具可用，不能据此登记编码实测通过。项目工作区未改变，尚未调用独立 Reviewer。

已从宿主实际安装的同版本完整包中，仅复制所需原生 helper 到 VM，与主程序同目录；未复制宿主整个 `.codex`。主程序 SHA256 为 `399ff69c431c066e40de318fba45c2b07f45a76b19939d247ee4828fc70c4215`，helper 为 `8724d73ec190536233ab4628d24a071bfbcf27e5124f08fe35129f26fe48b916`。Ubuntu 24.04 guest 内安装 `apparmor-profiles`、`apparmor-utils` 并加载系统提供的 bubblewrap userns profile；没有修改宿主或关闭 guest 全局 userns 限制。原生 `codex sandbox -c 'sandbox_mode="read-only"' -- /usr/bin/true` 已返回 0，读取 `/etc/os-release` 成功，写 `/var/tmp` 实测因只读文件系统被拒绝。配置依据：[OpenAI Linux sandbox 文档](https://developers.openai.com/pt-BR/docs/sandboxing)。这些无模型探针不替代真实工具调用验收。

接续必须保存原始 blocked 回执、restart stop、两次调用及其完整用量。原开始时间 `2026-10-20T19:16:52.173839Z`、4 小时截止、30 次返工和 96 次调用上限不变。部署故障修复后的人工审计接续与控制器自动 recovery 分开记录；不能宣称首次 ready 后已经无人干预闭环通过。

运行组件修复的显式接续审计已完成：旧控制器通过维护 nonce/PID/boot 排空确认后停止，MainPID=0、cgroup 为空；原 blocked 回执与 restart stop 原文保存于 `.runtime-repair-retry-1.json`，停止记录归档为 `.restart-blocked.runtime-repair-1.json`。原调用 2 次与完整用量不变，新增第 2 轮消耗一次返工，再交回正常 RestartRecovery。随后实际第 3 次 coder 调用已能读取 luca 源码并执行项目命令，未再发生 helper 启动失败。新领取暂停标记保留，旧 GL-3 不变；当前编码尚未完成，不登记正式检查或 Review 通过。

本次组件修订的完整 scripts 回归：宿主 200 项零失败、22 项跳过；VM 原生 200 项零失败、20 项跳过。独立审查与简化已完成，实机执行新增 bootstrap 只读探针片段通过，完整一次性 bootstrap 未在现有 VM 重跑。曾因 root PATH 缺少 sbin 而找不到 runuser 的失败日志保留，修复后原片段实跑返回 0。重建工件清单 `/data/symphony-vm/verified-artifacts-v2.json` 与 guest `/home/elma/symphony-install/artifacts/verified-guest-artifacts-v2.json` 均实际校验通过；同版 helper 在宿主工件目录保留。

## 2026-10-21 真实交付与最终 View 修订

[GL-4](https://81.71.154.125:8443/innovation/luca/-/work_items/4) → [Draft MR !3](https://81.71.154.125:8443/innovation/luca/-/merge_requests/3)。GitLab 只读 API 已核对项目/源项目/目标项目均为 10，目标 main、draft=true、state=opened、merged_at=null；远端分支 HEAD 与 MR SHA 均为 `267aa8f24c57d857f4bdc651099c7e5d903a22c3`。Reviewer approved=true、blockers=[]、20 项 adequate=true。两项控制器正式检查均退出 0，候选、轮次 2、attempt 1 绑定一致。Docker 原始响应在两次请求及同容器重启后均为 commit=267aa8f、version=dev、buildTime=2026-10-20T21:11:21Z；镜像/容器按本 attempt 归属清理。没有运行通用平台 live 套件，没有合并或部署 luca。

View 两份运维审计日志原本因顶层 issue 字段被当作额外任务。采集现在识别同时包含 action 和 receipt_before 的审计记录，保留日志原文，仅从主任务列表排除；local/WSL 两个真实嵌入扫描分支和旧回执名字均回归覆盖。完整 VM View 门禁通过：Python 57、JS 15、本地 Linux 11、浏览器夹具、self_check 与迁移逐值比较。宿主完整命令先暴露旧 8765 端口假设，随后因缺 Playwright 仍未通过；未把这些宿主失败登记为通过，最终使用已固定依赖的 VM 完整入口。503 测试改为持有自己绑定但不监听的随机 loopback 端口，原断言不变，不联系真实服务。

## 最终安装、运行状态与交接（2026-10-21）

首次收尾固定 release 为 `/opt/innovation-symphony/releases/005474a4a67e-20261021`，后由文末 main 升级记录中的 `37fa886b7cf7-20261021` 替代。该首次收尾源码提交 `005474a4a67e9425cd87ae1dc80b0be579bd3237`，源码归档 SHA256 `a36af1c8a34819f443dfa87949c7d5c1cb2b559648df3704441c429a24795f0d`，escript SHA256 `e2f461a97dc5481e5dc707feb9fe77e15956a37f1c44310591591c3ce07d625f`。Elixir 源码与 996 项全门禁版本相同；组件和 View 修订分别本地提交 `2442618`、`005474a`。View 安装快照同属后者，升级前的三个源文件另行保留，数据库、缓存和历史未删除。原三个宿主服务 disabled，只有 VM 的控制器消费队列。

准确工具链：OTP 28.5.0.7、Elixir 1.19.6、Codex 0.163.0（主程序与同版 helper 摘要见前文）、Node 24.21.0、OpenJDK 21.0.12.1、Python 3.12.3、Docker 29.1.3、Buildx 0.30.1。准确发行版包修订、Git/coreutils/bubblewrap/AppArmor 版本及摘要保存在 guest `/var/lib/innovation-symphony/toolchain-final-005474a.json` 和本机证据目录的同名副本；没有跳过 native client 检查。

后续新任务的管理员能力探针增加 `codex_component`（实际同版执行组件可执行）与 `codex_readonly`（原生只读沙箱启动 `/usr/bin/true`），提前阻止已知缺件/沙箱启动失败。只修改当前工作流的新领取能力配置，原 GL-4 冻结合同不变，不做每轮 Docker 构建或真实模型调用。实际完整准入返回 ready、blockers=[]；这仍不是候选验收。

独立本地能力夹具另外实际调用默认 coder 一次：成功执行 `sudo -n apt-get install jq`（包已存在，本次没有新增包）、构建有唯一归属标签的 scratch Docker 镜像并清理、启动并请求 loopback 随机端口的临时 HTTP 服务，再通过 jq 验证 JSON 并停止服务。原始 argv、退出码、响应和资源身份留在 runtime `workspaces/LOCAL-CAPABILITY-20261021/capability-result.json`；此一次调用与 GL-4 的四次分开报告。最初夹具放在 archives 被工作区路径边界拒绝，未启动模型，该失败也保留。没有为此创建其他平台 Issue。

最终正常 VM reboot 后，boot ID 从 `bceb69da-a605-4322-889c-493f79b131d1` 变为 `5cdac192-689d-469e-95a0-3b407baefc36`。三服务、production 隧道与只读沙箱恢复；宿主 QEMU NRestarts=0。GL-1/2/3 的原回执 SHA256 与切换前一致，GL-4 的回执 SHA256 `dbef03da4ad652b10990f114707bcd0ac637d32f86bc668f465cc57acd3aacf0` 在此次 reboot 前后不变。仅解除本轮拥有且摘要匹配的临时 intake-paused；ready 列表只有已有回执的 GL-3/4，当前 running/retrying=0。恢复正常可信 ready 入口，旧 GL-3 不会重领。

本机 4000 状态 API、8613 View snapshot 和经认证的 8765 设置 API 均已实际读取；默认仍为 coder gpt-6.1-sol/high、reviewer deepseek-v4-flash/high。View 为 4 个真实任务，GL-4 关联 4 次真实会话、两轮、正式检查和批准的 Review。宿主可用空间最后核对约 18.5 GiB，guest 约 26.5 GiB，高于 15/5 GiB 暂停阈值。每日空闲备份 timer enabled，已手动验证的同一日备份入口及独立恢复见前文；首次定时触发尚未发生，现有备份来自 GL-4 之前，不误报为新任务的交付后快照。自动轮换保留最近三份成功日备份及迁移备份，工具不会自动删除失败归档；后续一次人工授权清理见文末。

本轮实际通过的主命令与证据：

| 命令或检查 | 结果 | 本机证据目录下文件 |
| --- | --- | --- |
| guest `sudo bash scripts/vm/check-native.sh /home/elma/symphony-install/source` | make all：996/0/6 skipped，100%，Dialyzer 0 | full-gate-git-deadline.log |
| guest `python3 -m unittest discover -s scripts/tests` | 200/0/20 skipped | scripts-final-native.log |
| guest `NODE_PATH=... view-venv/bin/python -B scripts/run_view_checks.py --output ...` | Python 57、JS 15、Linux 11、浏览器/迁移通过 | view-sidecar-native-full.log |
| 两项准确候选正式检查与 GitLab 只读对账 | 退出 0；MR/远端分支 SHA、Draft、目标 main 一致 | gitlab-final-mr-verified.json、gl4-delivery-current.log |
| 最终 OS reboot 与当前执行准入 | 健康恢复，原回执不变，ready | final-reboot-result.json、final-readiness.log |
| `python3 scripts/vm/operations.py --root /data/symphony-vm check` | host/guest disk admitted，未暂停 | final-operations-check.json |

准备、检查、启停、备份、恢复的可重复入口完整列在 `scripts/vm/README.md`，已有 VM 不重跑 prepare/bootstrap。备份位置为 `/data/symphony-vm/backups`，已验证恢复目录为 guest `/home/elma/symphony-restore-final-20261021`，其领取关闭且未激活。运行日志与回执在持久 runtime 根内；现存归档以文末清单为准；失败诊断日志仍在本机 `.local/vm-deployment-20261020T090218Z`，不能据此宣称已删除的失败 tar 仍存在。

回退顺序：先在 VM 暂停新领取并取得维护排空确认，核对活动执行与 GitLab 远端副作用，再保存包含 GL-4 的最新状态/证据。停止 VM 控制器和 production 隧道，旧宿主工作流先设置 enabled=false，旧服务只以关闭领取状态恢复。GL-4 已发布，禁止用迁移前快照直接覆盖当前状态、清回执重领或盲目重发 MR。也可保持 VM 暂停，切回前一固定 native release排查；不要同时启动两套消费者。旧 release、宿主单元、配置备份与原始数据都还在，未执行自动回退。

尚未实际验证的是宿主“未登录冷启动”及首次 timer 触发；配置已确认 linger=yes、VM/隧道/备份和磁盘 timer enabled。由用户选择时间重启宿主，登录后用 `systemctl --user is-active symphony-vm.service symphony-vm-tunnels-production.service`、`journalctl --user -b -u symphony-vm.service` 核对启动早于登录，再打开三个本机入口。真实页面体验和 MR 合并由用户验收；本代理没有重启宿主、推送 Symphony 分支、合并 MR 或部署 luca。

源码与文档已保存并本地提交，固定运行安装和真实交付分别以上述证据为准；本次首次 ready 后完全无人干预未通过，修复后无需人工 Docker 证据的自动交付段通过。


### 2026-10-21：合入本地 main 并更新固定安装

来源：所有者明确要求“合并main分支 然后部署最新代码”。在独立干净工作树中将 `codex/vm-deployment-direction` 快进合入本地 main：`edb77db` → `37fa886`。未推送 Symphony。原工作目录中的 `model_services.ex`、`restart_recovery.ex` 两份未提交修改原样保留，部署前后 SHA256 一致，没有混入安装包。

本次运行固定版本为 `/opt/innovation-symphony/releases/37fa886b7cf7-20261021`，源码提交 `37fa886b7cf77c673f586a796e2bf3f1b3958bf1`，源码归档 SHA256 `6689ec5175e932ec48b74c28a3e8a8a5a550e635a5ffaf61faeb8e57db1a16be`。安装前逐文件核对编译源码与提交，escript SHA256 仍为 `e2f461a97dc5481e5dc707feb9fe77e15956a37f1c44310591591c3ce07d625f`；相对上一固定版本仅增加文档，运行代码及 View 代码一致。因此本次复用前述 996 项、100% 覆盖率完整门禁，没有将旧失败日志作为通过结果，也没有重新发起真实模型调用。

切换先暂停新领取，取得控制器带 nonce/PID/boot identity 的空闲确认，再关闭领取、停止三个 VM 服务、更新固定路径及 systemd 单元并启动。健康检查通过后逐字恢复 WORKFLOW 并仅解除本次拥有的维护标记。四份任务回执摘要不变，ready 自动入口保持启用。运行数据、View 数据库及凭据未重建，旧宿主服务未启动。

本轮实际执行：`git merge --ff-only codex/vm-deployment-direction` 成功；固定源码/二进制摘要核对成功；三个 VM 服务与 production 隧道 active；本机 4000 状态 API、8613 snapshot API 及 8765 鉴权仓库设置 API 返回 200；实际 VM UUID 一致、`docker info` 成功、Codex read-only `/usr/bin/true` 探针退出 0；`scripts/vm/operations.py ... check` 磁盘准入通过。默认仍为 coder `gpt-6.1-sol/high` 与 reviewer `deepseek-v4-flash/high`。未合并 luca MR、未部署 luca、未重启 VM 或宿主。

准确安装与切换证据位于本机 `.local/main-deploy-20261021T030525Z/`，guest 配置及单元备份位于 `/home/elma/symphony-install/main-deploy-20261021T030525Z/`。本条记录随后仅以文档提交合入 main，运行代码与固定安装保持一致；运行源码准确 SHA 以该 release 的 `RELEASE.json` 为准。回退仍须先暂停并排空，再将 guest `vm-operations.json` 和三个单元恢复到保存的上一固定版本并核对健康及回执，最后恢复原领取状态；不能回滚任务数据或同时启用旧宿主消费者。


## 存储清理与现存恢复源（2026-10-21）

来源：所有者先要求核对 `/data/symphony-vm` 的约 50 GB 占用，随后明确选中“13.9 GiB，进一步可清约 6.7 GiB”并要求“清理这些”。本次只删除审计清单中的 11 个普通文件，不建立自动清理政策，不修改工作区、回执、证据、服务或虚拟磁盘容量。

清理在宿主 operations 锁内进行。先核对备份服务 inactive/MainPID=0、文件设备/inode/大小及单链接身份；以 root 扫描 `/proc/*/fd`，11 个候选均无打开的描述符、无不可观察项。最终迁移归档的 SHA256、成功日备份的回执摘要及 3691 项归档清单再次校验通过，才按准确路径逐项删除并记录结果。不能仅凭 `.partial` 扩展名或时间做同类删除。

| 已删除文件（相对 `/data/symphony-vm`） | 实际分配空间 |
| --- | ---: |
| `daily-backup-diagnostic-20261021.tar.partial` | 3.20 GiB |
| `daily-main-diagnostic-20261021.tar.partial` | 3.86 GiB |
| `daily-timewait-proof-20261021.tar.partial` | 3.86 GiB |
| `migration-prepared-20261021.tar.partial` | 2.95 GiB |
| `daily-exact-cli-diagnostic-20261021.tar.partial` 及审计列出的四个 `backups/daily-*.tar.partial` | 0（五个空文件） |
| `migration-runtime-20261020T090218Z.tar.gz` | 3.27 GiB |
| `migration-prepared-20261021-v2.tar` | 3.38 GiB |
| 合计（准确分配字节 22,033,547,264） | 20.52 GiB |

`du -sh /data/symphony-vm` 从约 51 GiB 降到 30 GiB；`df -h /data/symphony-vm` 可用空间从约 19 GiB 增至 40 GiB。`system.qcow2` 实际分配约 21 GiB，虚拟容量仍为 50 GiB，未压缩、转换、扩盘或删除。宿主 QEMU/production 隧道 active，控制器 API 正常，磁盘门槛检查 disk_admitted=true，领取未暂停。

当前保留的恢复源为：

| 文件（均在 `/data/symphony-vm`） | SHA256 | 边界 |
| --- | --- | --- |
| `migration-final-runtime-20261021.tar` | `bd20e5d123da46617af5ee9ed03717f60e5b7523b77676f96580bdbb02c754c6` | 最终迁移时的运行根归档，保留为迁移基线；不是整台 VM 镜像或 GL-4 交付后快照 |
| `backups/daily-20261020T190632300613Z-90591e7de9cd4f23aa74033661e3fffd.tar` 及同名 `.success.json` | `d49c53e67ad715796d681e4942bfbe313174ed329f5231c185f68e52b1199f3e` | config/runtime/View 完整受管归档；先前独立恢复通过，本次摘要及清单重验通过；早于 GL-4 |

日备份恢复入口使用第二行的现存 tar，操作与凭据重建要求见 [运维说明](../scripts/vm/README.md)。初始预复制和准备 v2 的历史恢复结果仍成立，但它们的 tar 已删除，不能再给出可执行的恢复命令。当前没有新生成 GL-4 交付后备份；每日 timer 已启用，首次定时触发与宿主未登录冷启动仍待实测。本轮文档同步不补做备份或重启。

系统盘、固定 cloud image/签名、工具链安装工件、`generated/`、SSH 身份/配置、成功回执及原始运行数据全部保留。源码主工作区私有证据为 `.local/vm-storage-audit-20261021.json` 与 `.local/vm-storage-cleanup-20261021T031707Z.json`，包含全部 11 条准确路径、设备/inode、前后可用字节和删除结果；辅助脚本 `.local/cleanup-reviewed-vm-archives.py` 是本次一次性操作记录，不是允许重复执行的清理入口，也不入库。
