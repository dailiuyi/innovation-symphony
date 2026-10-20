# 独立虚拟机部署与闭环验收

日期：2026-10-20。来源：所有者逐项选择并明确批准完整实施计划；授权与替代关系见 DECISIONS 同日条目。本文随实测更新，不用部署配置代替验收证据。

## 固定部署

主机 `elma-ubuntu-pc`，仓库 `/home/elma/文档/Code/innovation-symphony`，本地分支 `codex/vm-deployment-direction`。开始 HEAD 为 `edb77dbce1a5ae172a6fb86e6e451c8dd87d56b6`，原两份未提交的需求/决策文档保留。

VM 使用 QEMU/KVM，8 vCPU、12 GiB 内存、50 GiB 按需增长的 QCOW2 系统盘，目录 `/data/symphony-vm`。Ubuntu 24.04 官方镜像 SHA256 为 `04e8f2461a16a44e78a370284471f29616cdd9baf1893df25807b71f985b6c94`；`SHA256SUMS.gpg` 已由本机 Ubuntu cloud image keyring 验证为 Good signature。VM UUID 为 `e95ff885-dd31-4ad7-b894-35d1a0102429`。

NAT 只向宿主 loopback 转发 SSH 22220；页面通过 SSH 隧道连接 VM loopback 4000/8613/8765，准备阶段宿主使用 14000/18613/18765。专用 SSH 主机密钥指纹与可信本机串口记录匹配后才保存，不禁用主机密钥校验。没有共享宿主文件系统、设备、Docker socket 或 SSH agent。

工具链固定为 OTP 28.5.0.7、Elixir 1.19.6（源码编译）、Codex 0.163.0、Node 24.21.0、JDK 21、Python 3.12。官方 Codex 归档 SHA256 `beb339e8ecd9ba057a6bb2dc81ad8ca474812edfbf0fc5056ca818797648dde4` 已核对官方 release asset digest，解压原生程序与当前宿主实际客户端逐字节摘要一致。Node 归档摘要已核对官方 SHASUMS256；其余安装归档与软件包版本在本机安装清单中记录。

## 基线保全

操作证据目录 `.local/vm-deployment-20261020T090218Z`；其中 baseline 保存原工作流、启动入口、服务单元、HEAD 及回执 SHA256。运行根初始归档保存在 VM 目录的 `migration-runtime-20261020T090218Z.tar.gz`，它是预复制，不替代切换时的一致性备份。原运行 release 为 `a8ef726-20261017T172900`，旧服务在新环境门禁通过且空闲切换前保持运行。

## 当前状态（2026-10-21）

源码门禁通过。guest 纯净环境执行 `sudo bash scripts/vm/check-native.sh /home/elma/symphony-install/source`，完整 `make all` 返回 0：996 项测试零失败、6 项显式跳过，总覆盖率 100%，格式、public spec、严格 Credo 及 Dialyzer 通过。此前失败日志保留，当前 Git 修订日志为 `.local/vm-deployment-20261020T090218Z/full-gate-git-deadline.log`。所有新增忽略和降低门槛的方案均未采用。

scripts 原生完整回归 189 项、20 项显式跳过通过（含停止边界、启动缓存及 TCP 探针修订）。View 为 Python 55 项、JavaScript 15 项、本地 Linux 集成 11 项，以及浏览器夹具和迁移等价检查通过。源码经分域独立审查、简化及修改后独立复审；旧清理的真实权限回归 13 项通过。

VM 已实际运行，sudo 安装、临时 loopback HTTP、真实 Docker build/run/按归属清理探针通过；原生 escript preflight 曾通过。固定工具链已安装，Docker Engine 29.1.3，宿主 linger 和 VM/staging 隧道的 systemd 已启用。VM 三项原生服务已安装启用，正常 reboot 后自动恢复。原端口已切换到 VM，旧服务停止并禁用自启；临时隧道已停用。领取关闭且有暂停和维护标记。已创建 GL-4 并添加 ready；首次领取在 Git fetch 阶段超时 blocked，尚无模型调用或 Draft MR。

准备备份的独立恢复已通过，下文记录准确归档与校验。固定 native release 已安装，最终运行数据已复制并核对；实际每日备份及其恢复、真实交付闭环仍待完成。

## 接续与运维补充验证（阶段记录）

2026-10-20，原生 VM 内本地夹具的模型和交付回调为合成实现，不调用外部账号、不向平台写入。真实 Git、回执、正式检查和 OS 所有权检查均运行。检查进行期间对独立夹具控制进程执行 systemd restart 后，候选 `0ef42d5c1fbd738e6b190cd848c39d5e3ecf16e9` 与原预算起始时间保持不变，尝试数由 coder 的 1 增至加上后续 Review 的 2，恢复代数为 1。正常 VM reboot 的第二夹具同样通过，候选 `baf3c4eab449d927e7630d0a46a5822b08530d9d` 不变，boot ID 从 `e4c70bd5-0c2b-46d8-8992-d534efb17ef7` 变为 `e86cd440-48fd-4184-8fec-742b6ea342f9`。宿主 QEMU NRestarts=0，SSH 隧道自动恢复。此夹具验证恢复引擎；正式 Orchestrator 的平台发现和准入仍由回归及之后真实 Issue 验证，不把它记作真实模型任务重启通过。

View 完整检查：Python 55 项、JavaScript 15 项、本地 Linux 采集 11 项、浏览器夹具及迁移等价检查通过。scripts 最新原生检查 176 项、20 项显式跳过；VM 运维定向 48 项通过。全量 Elixir 预跑 936 项中有 6 项失败，覆盖率 98.29%；其中旧人工接续事件格式已修复并通过对应 16 项回归，其他缺口补齐后仍须重新跑原有 100% 门槛。严格 Credo 和 public spec 检查当前通过，不代表最终全门禁通过。

启动时先从当前平台、仓库对应的显式新合同回执对账，通过平台 ID 读取现状。旧回执、终态、awaiting_external 和已有停止记录均不进入恢复。尚有中断任务时先处理它们；原执行者仍活跃或身份无法核实时阻止新领取。ready 撤销或任务关闭会保存独立停止记录，原回执字节不改；恢复重新核对 ready 事件操作者，冻结模型不随管理员默认值变化而替换。

可重复准备、检查、启动、停止、备份及独立目录恢复入口见 [运维工具说明](../scripts/vm/README.md)。所有生成副本必须与最终固定 release 一起核对；`--apply` 的授权已包含在本次实施计划内，默认无该参数仅检查或显示计划。备份和维护使用单独的 nonce/PID/boot 排空握手；磁盘 guard 不与长时间备份共用操作锁，不因备份清理而撤销并发磁盘暂停。

VM 模式分配新模型会话目录时保留全部历史，不调用旧的“仅保留最近 50 个目录”清理入口；旧 rootless 和未启用 VM 的合同保持原行为。这对应本次完整历史保留要求，与磁盘不足时暂停领取配合，不靠自动删历史释放空间。

## 2026-10-21 准备备份与门禁修复

准备备份 `/data/symphony-vm/migration-prepared-20261021-v2.tar` 已通过独立目录恢复，SHA256 为 `0cfded9a1c5f883186f5313a55e8f4a587875c7aa92649a4b5d090638b634092`。恢复目录 `/home/elma/symphony-restore-20261021` 未激活领取；恢复前后历史回执摘要一致，View SQLite integrity_check 为 ok，含 3 个任务、71 条状态变化及 10 个会话。此备份来自准备副本，正式切换仍须停止旧服务后完成最终一致性复制。

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

Git 传输修订的完整纯净 `make all` 已通过：996 项零失败、6 项显式跳过、100% 覆盖率、Dialyzer 零错误。之后仅加强开始时间断言，VM 原生单项 fresh/resumed 测试再次通过，生产代码与全门禁相同。新旧 escript 中 RestartRecovery/Executor/Attempts/Recovery 四个 BEAM 逐字节一致，证明无需改变 GL-4 冻结核心摘要。安装与显式准备重试仍待执行。
