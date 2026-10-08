# 宽权限容器与可靠性实验版本

来源：2026-10-07 用户明确要求实施本计划，并确认项目初期先放开沙盒权限、以后根据实际问题逐渐收紧。实现基线是 main `66b9b25fe55ff0f95b7f8e719b740a62e4c6f001`；原脏工作区保留。本文描述代码合同；IS-076 的独立桥安装及实机记录见 VALIDATION_ROOTLESS。桥安装不表示活动控制器已经切换或整体验收通过。

## 新配置和兼容

旧任务缺少 `backend` 时继续使用原 Bubblewrap 参数与冻结合同。新配置必须显式选择 `backend: rootless`、`profile: rootless-open-v1`、`network: public-egress-v1`、带 sha256 digest 的 OCI 镜像及非 root 专用 worker。内存默认 4096 MiB，CPU 4，PID 512，工作盘 20480 MiB；这些是可调整的工程默认，并非用户永久指定参数。新配置不可用时准备失败，没有宿主回退。

```yaml
codex:
  command: /REVIEWED/NATIVE_CODEX_0_160_0 app-server
mvp:
  enabled: false
  sandbox:
    enabled: true
    backend: rootless
    profile: rootless-open-v1
    network: public-egress-v1
    image: REGISTRY/IMAGE@sha256:REVIEWED_64_HEX_DIGEST
    worker: symphony-worker
    root: /var/tmp/innovation-symphony-rootless/sandboxes
    trusted_root: /opt/innovation-symphony-rootless-bridge/trusted
    toolchain: /REVIEWED/TOOLCHAIN
    codex: /REVIEWED/NATIVE_CODEX_0_160_0
    dependencies: /REVIEWED/DEPENDENCIES
    auth_home: /CONTROLLER/MODEL_HOME
    environment_recipe: .symphony/environment.sh
    acceptance_profiles: {}
```

大写字段是必须填写的占位符，不是可执行默认值。领取时仍由现有 Elixir 冻结完整 sandbox 和角色服务。当前配置只接受已登记的固定探针，不从 Issue 评论接受镜像、凭据、地址或提权命令。并发增强任务首期设为 1；宿主桥另以 flock 拒绝并发，不能以多个 worker 规避总限额。

## 权限与环境

受信 root 监督器只负责有界 ext4 工作盘、cgroup、网络 namespace、出口规则和进程清理。Podman/crun 在专用普通用户下运行；容器内 UID 0 可 apt/pip/npm/Mix、管理私有 rootfs、调试和启动临时服务。不使用 privileged，不映射宿主 HOME、SSH agent、认证、管理 socket 或宿主设备。`--network=host` 仅指进入受信桥创建的任务专用 network namespace；启动前核对它与宿主 namespace 不同。

IPv4 规则按数据包最终目标拒绝私网、metadata、特殊地址与返回非已建立连接，任务接口进入宿主 INPUT 的流量全部拒绝。当前实验实现 **拒绝所有 IPv6**；IPv6 公网能力尚未完成，不能声称已满足双栈公网合同。实际 IPv4 出口仍受宿主已有防火墙限制，不修改默认策略或 sysctl。为兼容 Docker 的 FORWARD=DROP，在本次任务的准确 veth 接口加入临时 ACCEPT 规则，内网拒绝的 nft hook 位于更早的 priority -20；回程只允许已建立连接，退出删除例外规则，启动守卫拒绝残留。任务内 DNS 仅监听该网络的 loopback，由专用 worker 通过固定 TLS 校验的 1.1.1.1 DoH 端点解析；不读取宿主代理凭据，不放行 fake-IP 地址段，不使用宿主 DNS 回退。当前只实现有界 UDP DNS 转发，超大响应和上游错误返回 SERVFAIL，完整 DNS TCP 兼容未实现。

每次从固定基础镜像重新建立实例。声明的环境配方运行在私有可写副本，结束后源文件 manifest 必须保持一致，准备容器停止后由宿主提交私有 rootfs，再运行该阶段。准备后的镜像、基础镜像、配方 SHA、runner SHA、原生客户端 SHA 记录在 `environment.json`。镜像保存于任务有界工作盘。Coder 首轮可以创建尚不存在的声明配方；正式检查与只读角色遇到缺失配方会停止。正式 Python 使用受信安装目录复制的解释器、标准库和共享库，`-I -S` 禁用 guest 配置，并覆盖 preload 入口；不信任配方修改后的 Python 检查入口。

正式 Elixir 检查的 Mix 工具缓存取自受信只读工具链，各阶段通过 `check_home` 在独立 HOME/CODEX_HOME/MIX_HOME 中启动实际子进程，不加载环境配方留下的 Mix 用户配置。Coder 仍可使用私有 Mix HOME。安装包同时复制 `check_formatter.exs`，确保结构化报告入口完整。

桥仅接纳现有 View 正式入口的准确解释器、`-I -B`、受信脚本和候选 SHA；近似路径、附加参数和任意 Python 代码继续拒绝。View 环境准备可以联网，准备结束后受信监督器删除任务 veth，在只有 loopback 的新实例运行固定检查；正式检查的离线合同保持不变。

当前环境身份记录不等于跨实例包版本完全相同。未实现 apt/pip/npm 解析依赖锁及完整安装清单的可信收集；可重复性与候选/基线/Reviewer 环境对应仍需实测验收，不能仅凭配方 SHA 宣称环境一致。

## 持久产物和导入恢复

工作盘 `work.img` 从每个 attempt 开始即持久保存。当前上限按 attempt 落实，整任务多 attempt 的累计产物配额与宿主 staging/导出的空间预留尚未落实；不能把单盘上限当成整任务总存储限制。退出后先清除 cgroup 后代，再导出普通文件，报告 SHA256、权限、删除记录、拒绝路径和容量/I/O 原因。失败的 `.export-pending` 与源盘保留；导出失败独立于模型完成、进程清理和候选接受。桥发布采用 rename；发布或 ownership 失败不会删除持久盘。不确定清理的 staging 保留在 root 保护目录中。

导入 journal schema 2 包含原/新源码 manifest 和工作区身份，各阶段 fsync 后发布。`ExecutionSandbox.recover_import(context, journal_sha256, authorization)` 只接受 blocked 回执，在原 OperatorRecheck 互斥/审计链中验证现场后回滚完整旧源码，并归档 journal。摘要不符、路径链接、重复路径、第三方更改均停止保留现场。schema 2 记录内容摘要、权限与文件大小，以及事务身份和 prepared/staged/backed_up/published 阶段；恢复同时核验这些字段。自动恢复导出失败产物的调度入口尚未完成，当前保留产物后停止，不能假称已自动恢复。

## 失败、预算与补证

正式 exit 10 表示已有受信修复判据的代码缺陷；结构化环境报告和 OOM/PID 事件走同候选阶段重试；导出和完整性异常停止；未知失败进入只读诊断，不能由诊断改为代码修复或直接判通过。选择新编码轮时才检查返工额度；模型预算与阶段次数继续各自约束，不重置开始时间和用量。旧反馈缺少分类字段保留既有兼容。

`acceptance_profiles` 是控制器登记的 `acceptance名称 -> {kind, runner_sha256, timeout_ms}`，kind 仅 linux/gpt_coder/gpt_reviewer；默认空、不调用真实账号。Linux digest 取固定 `probe_rootless.py`；GPT digest 取已加载探针、ModelServices、AppServer 模块。timeout 首期上限 60000 ms。只有冻结 handoff 中全部 acceptance 都已登记才建立 job。

job 保存在 `receipt.evidence/acceptance-jobs/<handoff_id>`，绑定准确候选、冻结 sandbox、服务及 runner。Linux 用固定容器探针；GPT 只请求随机 nonce 与候选 SHA 的固定 JSON，使用冻结账号，模型实际型号没有 telemetry 时仍保持未知。探针预算预留入 `external_probe_calls`，实际消息/结果单独保留；`external_probe_ms` 计入有效运行时间，并为后续独立 Review 留一次 Agent 额度。中断中的 `external_probe_inflight` 阻止审计接续，不以未知调用归零。

成功探针通过原 `{acceptance,path,sha256}` 证据接口调用 `resume_external`，继续完整检查和新 Review。未登记、过期、失败或不确定 job 保留等待。当前尚无控制器重启后自动扫描/恢复 job 的入口；已存在 job 不重跑。这是保守停点，不是已经完成的重启接续功能。

View 只读取新回执状态，显示失败类别、返工和 Agent 次数、源码保存/导出/清理、外部等待及最近阶段耗时。旧回执缺失字段保持“未记录”，不推断为通过或零。新增回执的原阶段重试次数独立显示，旧回执缺失时保持未记录。

## 安装与回退

`scripts/install_rootless_bridge.py` 默认只输出 policy 预览。加 `--apply` 才安装 Podman/crun/uidmap 等依赖、专用 worker 和全新的 `/opt/innovation-symphony-rootless-bridge`、受信 Python 及独立 systemd unit。需要管理员认证、已准备的 IPv4 forwarding，以及已审查的 digest-pinned 基础镜像。镜像需 bash/git/python3/apt，并与已登记 Elixir/OTP 工具链 ABI 兼容。安装器包含 View 固定验证模块，但固定来源 ZIP/manifest 不在本仓库中；启用 View 正式检查前需在受信 source 目录准备并核验相应工件，不生成演示替代物。

安装器不覆盖旧桥、不启动新服务、不修改控制器 WORKFLOW、不打开领取。重复安装拒绝覆盖，升级另用经审查版本目录。启用前核实控制器空闲，完成下述实测；回退到旧 workflow/release，保留新 profile 的回执与产物，旧执行器不得接管新合同。

## 验收清单与未完成范围

代码回归与真实集成分别报告。apt、公网、浏览器/数据库、活跃宿主服务隔离、双栈边界、OOM/磁盘/PID、断连、清理及持久盘恢复必须在安装后执行。固定 Linux 探针目前仅覆盖 apt hello、公网 HTTPS、任务 loopback、只读挂载、能力/凭据缺失与连接拒绝；缺少活跃宿主探针、浏览器/数据库和资源故障注入，不能替代全部验收矩阵。

独立 Review、准确最终候选的纯净完整门禁和冻结基线通过之前，不提交发布或切换服务。首次五个获准任务后由人工审阅运行记录，限制只作用于未来任务。


## 本机配置实例（IS-076）

本机使用官方 Ubuntu 26.04 的 `linux/amd64` manifest：
`docker.io/library/ubuntu@sha256:88a381d5b5eeb2b35d3ad70925a362c37ce569daf43ede89ff818ec20e4d3794`。
来源为 [Ubuntu 官方镜像](https://hub.docker.com/_/ubuntu)，索引和平台 manifest 的解析证据保存于本机安装目录。基础镜像保持最小发行版，`environment_recipe: scripts/rootless_environment.sh` 在任务私有 rootfs 中安装 git、Python、证书与构建库，正式 Python 仍由受信安装覆盖。此配方未锁定 apt 包版本，不宣称完全可复现。

独立安装目录 `/opt/innovation-symphony-rootless-bridge`，worker `symphony-worker`；资源参数与桥固定策略均为 4 CPU / 4096 MiB / 512 PID / 20480 MiB。工具链和依赖复用旧桥的 root-owned 只读目录，原生客户端为 `/usr/lib/chatgpt/resources/codex` 0.160.0。生成的本机待激活 WORKFLOW 在 `.local/rootless-install-20261007/WORKFLOW.rootless.pending.md`，领取为 false；不要将它误认为活动控制器已切换。

安装器消除复制文件继承的组/其他用户写权限；安装文件受保护、socket 可连接与预检通过仍不能代替真实容器检查。真实结果及未完成项见 [VALIDATION_ROOTLESS](VALIDATION_ROOTLESS.md)。
