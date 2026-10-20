# 领取前执行环境就绪检查

## 2026-10-20：独立 VM 执行后端

所有者已批准整套 Symphony 进入独立 VM、VM 内完全放权。新配置通过 `required_backend: vm`、固定 `vm_uuid` 和管理员 argv `capability_probes` 显式启用；`sandbox.enabled: false` 在此配置下表示使用外层 VM，而非 rootless 沙箱故障后的宿主回退。实际 systemd 虚拟化身份、DMI UUID、sudo、Docker、项目工具、角色服务及持久磁盘空间均须核验。准备报告仍不是候选正式验收。

本地维护通过 `<state_dir>/intake-paused` 仅暂停新领取，不改 `mvp.enabled`，不撤销在途任务权限；文件不可读取或归属不明时保留暂停。VM 执行、源码门禁和真实交付状态分别见 [VM_DEPLOYMENT](VM_DEPLOYMENT.md)。下文 rootless 合同保留，不能将旧冻结任务自动转换为 VM 任务。

备份/关机另使用 `<state_dir>/maintenance.json` 的 nonce 维护围栏，同时阻止新领取与尚未启动的重启接续，不中止已运行任务。`GET /api/v1/state` 的 `maintenance` 字段由 Orchestrator 串行快照产生，绑定 nonce、BEAM OS PID 和 boot ID；只有 running/retrying 为空且轮询未在进行，才返回 drained。运维工具必须取得同 nonce、同服务进程与启动周期的排空确认后才停服务，不能把一次普通空闲快照当成维护锁。

来源：2026-10-09 所有者选择“让实际任务使用已批准的执行环境，并在领取前确认编码、正式检查和真实验收所需条件都已准备好”，要求“补齐这个措施”（IS-100）。

## 执行合同

`mvp.execution_readiness` 显式启用后，`required_backend: rootless` 禁止把旧 bubblewrap 或未开启隔离的环境当成已批准的宽权限环境。旧冻结任务不迁移；未启用本门槛的历史配置保留原执行合同。

调度器刷新 ready Issue 后，在启动 worker 和加入内存 claimed 集合前进行只读就绪检查。失败仅记录具体原因并跳过本次派发，下一次轮询可重新检查；不发送 GitHub 写请求、不运行 workspace hooks、不创建回执或模型调用。worker 在 `Receipt.claim` 前再次解析作者授权与角色选择并检查，抵御调度后配置或凭据变化；成功使用这次检查的同一组角色快照，不在领取后重新解析模型评论。原 Executor 每个模型阶段的预检、授权和完整性检查继续保留。

`--preflight` 在新门槛开启时检查当前仓库默认双角色的准备条件；显式 Issue 评论覆盖在派发及实际领取前单独核验。CLI 保持只读，不启动调度、创建任务文件或执行真实模型推理。

检查包含：

- 编码和 Review 的当前授权、实际凭据存在性及身份、认证方式与连接兼容性，以及原生 AppServer 入口与沙盒客户端一致。
- 控制器可访问且互不重叠的已有 state/workspace/sandbox 目录、只读文件系统与单次执行最低盘空间；无目录创建或 root 权限造成的可写假阳性。
- 受信执行脚本、正式 Python 挂载 inventory、工具链与原生客户端版本、依赖目录、worker/subuid/subgid、IPv4 转发、cgroup 及所需宿主程序。
- 配置中的镜像 digest 与受信桥固定策略一致。任务有独立 Podman 存储，不要求无关的 worker HOME 镜像缓存。
- 正式命令使用现有 `ExecutionSandbox.check_kind` 识别；声明 View 检查时，额外核验固定 Python、Node、Playwright、Chromium、View 来源 ZIP/manifest 及打包器摘要。
- `required_acceptances` 中每个确切名称都有已登记 profile、当前 runner 摘要、可支持的角色及已启用恢复流程。固定 GPT 探针只支持 GPT；其他账号/内网验收不能冒用它。

root-owned bridge 接收固定四字段请求 `sandbox/state_dir/workspace_root/checks`，沿用控制器 UID/GID 与三路 FD 认证。未知、重复、超限、策略不匹配字段拒绝。报告绑定原始请求 SHA256、完整且准确的检查名称集合，并始终 `formal_acceptance=false`；成功领取保存报告及服务快照摘要。合法的环境缺项通过完整 JSON 返回 blocked，传输成功不意味着准入成功。

## 配置

```yaml
mvp:
  execution_readiness:
    enabled: true
    required_backend: rootless
    required_acceptances: []
```

`sandbox` 仍使用 ROOTLESS_OPEN 中的完整合同：backend/profile/network、digest-pinned image、非 root worker、受信路径、资源额度与可选环境配方。`required_acceptances` 是操作者明确配置的验收名称列表，必须与 `sandbox.acceptance_profiles` 的 key 逐字相同，不从 Issue 文字生成任意命令，也不虚构任务验收名称。空列表表示没有配置自动外部探针准备门槛，不表示真实账号或内网验收已完成。需要自动补证的任务应先登记确切 profile，再开放其领取。

Coder 仍可首轮创建任务内配方；允许空声明和安全相对路径。领取前只核验声明安全，不把 `trusted_root/recipe` 误当成实际 `workspace/recipe`；配方执行、正式阶段缺失配方拒绝及源码不被准备阶段改写，由现有 rootless runner 负责。

## 激活与验收边界

本检查是静态及只读运行前置检查，**不证明真实容器链已验收**。registry 连通、独立任务盘的镜像 pull、容器启动、apt/公网、任务配方安装、浏览器启动、正式候选/基线门禁、准确候选外部探针与独立 Review，需要激活前的独立实机检查。模型能力证据的实测与人工确认来源保持原样。

安装新检查代码及受信桥后，应先保持新配置 `mvp.enabled=false`，准备固定模型/验收 profile，执行桥就绪检查和真实隔离的正式检查。全部通过且控制器空闲才切换新任务配置并恢复原获准领取状态；原 state、回执、冻结模型、预算、工作区和旧桥保持。失败恢复原 launcher/WORKFLOW 和桥备份，不让旧执行器接管新合同。

只读 `task_roots` 空间阈值是单次工作盘加既有192MiB预留，不证明整任务累计存储配额。当前 IPv6 公网、断连/持久盘自动恢复等既有未完成事项继续按 ROOTLESS_OPEN 记录，不通过新的 ready 报告追认。

代码保存、完整门禁、受信安装、活动环境切换、真实 Issue 派发和最终交付分别报告。本轮无提交、推送、合并、公司代码外发或云部署。

## 2026-10-09 最新配置切换与子进程回收

所有者要求切换最新配置。当前已完成受信就绪桥安装、六项静态 inventory、真实 rootless 环境探针与 View 门禁；就绪报告仍为 preparation，不是正式任务验收。以既有干净 HEAD 6230f40 进行的实机完整候选门禁出现 `pids.events.max=157` 和进程创建失败，候选未通过，冻结基线未运行。这是环境资格检查，不能作为本轮源码的精确候选验收。

rootless runner 的准备及执行容器共用 Podman `--init --init-path=/usr/bin/catatonit`，使用 root-owned、原生 ELF、可执行且父目录受保护的固定宿主 helper。领取前 inventory 同时验证 helper。真实独立 PID namespace 回归在相同双重 fork 场景下复现无 init 的180个孤儿僵尸，并确认加 init 后为0；它证明回收机制，不证明完整门禁的所有失败都由僵尸导致。保持512 PID、6 CPU、6144 MiB内存及16384 MiB工作盘，不放宽断言、覆盖率或超时。

新控制器安装保持 `mvp.enabled=false`，待固定受信补丁安装并重跑真实容器候选、基线及所需任务验收后，才能恢复领取。双角色 registry、冻结回执、既有 OAuth 身份修复和独立 View 入口保留。CLI 的默认命令清理使用这次已加载的 tracker 凭据名称快照，避免未启动 WorkflowStore 的只读进程误读默认 Linear 配置。
