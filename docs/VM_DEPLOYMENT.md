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

源码门禁通过。guest 纯净环境执行 `sudo bash scripts/vm/check-native.sh /home/elma/symphony-install/source`，完整 `make all` 返回 0：986 项测试零失败、6 项显式跳过，总覆盖率 100%，格式、public spec、严格 Credo 及 Dialyzer 通过。此前失败日志保留，最终日志为 `.local/vm-deployment-20261020T090218Z/full-gate-native-release-20261021.log`。所有新增忽略和降低门槛的方案均未采用。

scripts 原生完整回归 179 项、20 项显式跳过通过。View 为 Python 55 项、JavaScript 15 项、本地 Linux 集成 11 项，以及浏览器夹具和迁移等价检查通过。源码经分域独立审查、简化及修改后独立复审；旧清理的真实权限回归 13 项通过。

VM 已实际运行，sudo 安装、临时 loopback HTTP、真实 Docker build/run/按归属清理探针通过；原生 escript preflight 曾通过。固定工具链已安装，Docker Engine 29.1.3，宿主 linger 和 VM/staging 隧道的 systemd 已启用。VM 的三项原生服务尚未启动，领取关闭且有暂停和维护标记。旧服务保持运行。新 Issue、真实模型调用与 Draft MR 尚未开始。

准备备份的独立恢复已通过，下文记录准确归档与校验。固定 release 安装、最终一致性迁移、原端口切换及真实交付闭环仍待执行。

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
