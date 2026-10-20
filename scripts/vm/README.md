# Local VM operations

2026-10-20，来源：用户批准的独立虚拟机实施方案。这里说明可重复使用的运维入口；实际安装和验收状态见 `docs/VM_DEPLOYMENT.md`。工具不触发模型调用或 Git 发布。

固定合同：Ubuntu 24.04 amd64，8 vCPU、12288 MiB、独立 50 GiB qcow2；宿主目录 `/data/symphony-vm`。QEMU 使用 KVM 与 user-mode NAT，只将 SSH 映射到宿主 `127.0.0.1:22220`，没有共享目录、宿主 Docker socket 或网桥。guest 正常 reboot 可用。

## 宿主前置条件

Python 3.11+（使用标准库；guest 是 Python 3.12）、QEMU x86/system 与 qemu-img、cloud-image-utils 的 cloud-localds、gpgv、受信 Ubuntu cloud image keyring、OpenSSH client、util-linux flock、systemd user manager、可读写的 /dev/kvm、宿主可用空间至少 15 GiB。操作者 安排安装这些依赖和用户 linger；工具不调用宿主 sudo、不自动安装或启用 unit。

预先由操作者准备专用于此 guest 的 ed25519 私钥和公钥，私钥权限 0600。操作者核对公私钥匹配。工具只复制既有身份，不生成身份、不调用 SSH agent，seed 只有 guest 公钥；guest elma 锁定密码，guest 内有 NOPASSWD sudo。

第一次 SSH 前，通过可信控制台/现有受信连接核对 guest SSH host key，再将已核对条目写入 `/data/symphony-vm/known_hosts`（端口地址为 `[127.0.0.1]:22220`）。工具始终 StrictHostKeyChecking=yes；不采用自动接受首次密钥的方式。串口输出存 console.log。

## 现有部署接管及命令 API

现有 deployment.json 要求 vm_uuid、image_sha256、vcpus=8、memory_mib=12288、disk_gib=50。文件名采用 操作者已建立的 noble-server-cloudimg-amd64.img、SHA256SUMS、SHA256SUMS.gpg、ssh_ed25519、ssh_ed25519.pub、user-data、meta-data、seed.img、system.qcow2。

下列命令省略 --apply 时只检查/显示计划，不落盘；adopt 会只读核对签名和镜像。以下为重复使用入口；本轮实际执行状态见 `docs/VM_DEPLOYMENT.md`：

```bash
python3 scripts/vm/operations.py --root /data/symphony-vm command qemu
python3 scripts/vm/operations.py --root /data/symphony-vm command ssh
python3 scripts/vm/operations.py --root /data/symphony-vm command staging
python3 scripts/vm/operations.py --root /data/symphony-vm command production
python3 scripts/vm/operations.py --root /data/symphony-vm adopt --signature-verified-externally
python3 scripts/vm/operations.py --root /data/symphony-vm adopt --signature-verified-externally --apply
```

外部签名选项是一项**明确操作者声明**：已用独立可信 Ubuntu cloud image signer 核对 SHA256SUMS.gpg 对 SHA256SUMS 的签名。工具仍比对 manifest 的唯一镜像条目、deployment 固定 SHA256 和镜像实际摘要，并保存外部声明；不会声称自己做了 gpgv。没有该声明时，必须指定 `--keyring /absolute/trusted/cloudimage-keyring.gpg --signer-fingerprint FULL40HEXFINGERPRINT`，工具执行 gpgv 并核对 VALIDSIG 的 signer/primary fingerprint。不能同时选择两种方式。不因镜像来源 URL 包含 current 就重新下载或改变固定摘要。

adopt 只新增 generated/ 与工具自己的 .operations.lock；不覆盖原 deployment、seed、镜像、qcow2 或迁移备份。活动磁盘仅 qemu-img info --force-share 读取元数据，不摘要或转换它。generated 已存在则拒绝覆盖，包括上次失败留下的目录。guest 配置示例位于 generated/guest/vm-operations.example.json。

Python API（均不隐式启动进程）：

```python
from pathlib import Path
from scripts.vm.operations import qemu_command, ssh_command, host_units, deployment
root = Path("/data/symphony-vm")
qemu_argv = qemu_command(root)
ssh_argv = ssh_command(root, ["python3", "/var/lib/innovation-symphony/vm-tools/guest.py", "check"])
staging_argv = ssh_command(root, tunnels="staging")
unit_text_by_filename = host_units(root, deployment(root))
```

生成宿主 unit 后，由操作者审阅并安装 generated/host/ 中的文件到自己的 systemd user unit 目录；保留 generated/tools/（unit 引用其绝对路径）。先对临时 daemonized QEMU 执行正常 poweroff 并确认退出，再启动托管 unit。原 QMP 连接与生命周期 flock 双重阻止托管重复启动；QEMU 自身仍锁定磁盘。陈旧 QMP socket 不会当成活 VM，但超时/权限错误会拒绝启动，不猜测其归属。

QEMU unit 使用 flock --no-fork 持有 qemu.lock，Restart=on-failure。systemd 的正常停止回调为内部 guest-poweroff 命令，KillMode=none、SendSIGKILL=no、TimeoutStopSec=infinity。回调只请求 guest 正常关机；120 秒超时/拒绝关机后 QEMU 保持运行。此时 unit 可能是 failed/inactive，但残留 QEMU 仍被 QMP/锁识别；不得据 unit 状态启动第二个实例。崩溃后由 systemd 重新拉起，仍需满足磁盘与身份/互斥门槛；没有硬杀死路径。

宿主 systemd-analyze --user verify 对临时生成的全部宿主 unit 返回 0。它提示 KillMode=none 已弃用；当前使用它是为满足关机超时不能向 QEMU 发信号的明确合同，未来 systemd 移除此选项时需要重新验证该合同。验证还报告宿主既有 spice-vdagent unit 的无关字段警告，本工具不修改它。操作者 只 enable 选定的隧道模式；该 unit 的 WantedBy=symphony-vm.service，使已启用的隧道随托管 VM 启动。

```bash
python3 scripts/vm/operations.py --root /data/symphony-vm start --tunnels staging --apply
python3 scripts/vm/operations.py --root /data/symphony-vm check
python3 scripts/vm/operations.py --root /data/symphony-vm check --apply
python3 scripts/vm/operations.py --root /data/symphony-vm stop --timeout 120 --apply
```

staging 转发 14000/18613/18765 到 guest loopback 4000/8613/8765；production 转发宿主 4000/8613/8765 到相同 guest 端口。宿主隧道绑定 127.0.0.1，ExitOnForwardFailure=yes，专用 SSH identity、IdentityAgent=none、ForwardAgent=no。操作者 选择一个模式，生产端口有占用时不会抢占旧服务。

## 新 VM prepare

仅用于**尚不存在**的目标目录，绝不覆盖现有目录。输入目录含上述 deployment（作为镜像摘要/资源输入）、固定镜像和签名文件，以及操作者已有的 guest SSH 身份。prepare 创建新 UUID、最小 cloud-init、standalone qcow2 并扩容为 50 GiB；不会创建或启动 QEMU。失败保留局部目录供审阅，不自动删除重做。

```bash
python3 scripts/vm/operations.py --root /data/new-symphony-vm prepare --inputs /absolute/reviewed-inputs --signature-verified-externally
python3 scripts/vm/operations.py --root /data/new-symphony-vm prepare --inputs /absolute/reviewed-inputs --signature-verified-externally --apply
```

## Guest 原生服务与配置

操作者 将 generated/tools 中的 guest.py、artifacts.py 放入 `/var/lib/innovation-symphony/vm-tools/`。配置清单位于 `/var/lib/innovation-symphony/vm-operations.json`；从生成的 example 复制后填写实际路径，不能猜测实际 state_dir。所有字段必须存在：

每个实际操作都读取清单指定的 WORKFLOW，将其中 `mvp.state_dir` 与清单严格比对；不匹配时在写标记或停服务之前拒绝。支持 ASCII YAML front matter 的直接、唯一、字面量 mvp 字段和 JSON front matter；YAML 的 aliases、merge、重复/带引号的键、相对 state_dir 等未支持表示会明确拒绝。配置路径必须为规范绝对路径；runtime/config/release 相互独立，View 只能是 config 的子目录或独立目录，不能落入 runtime/release；服务配置必须归 config_root，state 必须归 runtime_root。

- config_root：/var/lib/innovation-symphony；workflow、model_settings、view_config 分别指定实际 WORKFLOW.md、管理清单和 View TOML。
- runtime_root：/var/tmp/innovation-symphony-linux-runtime；state_dir 指向其中实际的 receipt 状态目录。
- release_root：/opt/innovation-symphony/release；固定 native escript 为 elixir/bin/symphony。
- view_root：/var/lib/innovation-symphony/view，包含独立 View 源码、app、data 和 prototypes；源码从固定 release/view 复制，由操作者维护。View DB 随 view_root 纳入备份。
- view_venv：/var/lib/innovation-symphony/view-venv，Python 3.12 venv；操作者 按固定 release 的依赖清单安装依赖。
- environment_file：/var/lib/innovation-symphony/runtime.env，由操作者在 guest 本地提供，文件权限 0600；不放入 seed。
- auth_paths：所有凭据文件/目录的绝对路径；备份无条件排除此列表、environment_file，以及 .ssh、auth.json、credentials.json、secrets.env、runtime.env。其他可能含密钥的 Codex 配置必须由操作者加入清单。
- credential_inventory_reviewed：默认 false；操作者 核对完整凭据清单后显式改 true，备份才允许运行。这个声明不等于内容扫描或自动脱敏。

`guest.units(settings)` 根据该清单生成文本模板。adopt 的默认模板使用上述路径，操作者 可编辑后安装。控制器、模型设置与 View 是独立 systemd **system** service，均 User=elma、Group=elma。runtime-paths.env 提供 PATH=/usr/local/bin:/usr/bin:/bin、持久 TMPDIR/MIX_HOME/HEX_HOME/CODEX_HOME 和 guest Unix DOCKER_HOST。没有陈旧的 /opt/symphony-toolchain 引用。model-settings 的 loopback 8765、来源、令牌引用，以及 View 的 loopback/来源必须由操作者配置；源代码/配置生成不证明真实接入。

symphony-runtime.conf 安装到 guest /etc/tmpfiles.d/；x 规则递归排除 runtime，防止系统 tmpfiles 按时间清除活动和 recovery 文件。没有 prune runtime、工作区、回执或历史的命令。操作者 将服务和 guest symphony-disk.timer enable，正常 guest reboot 后服务重新启动。

## 磁盘暂停与备份恢复

磁盘门槛：宿主可用空间 15 GiB、guest 的 runtime/config/View 所在文件系统 5 GiB。宿主 symphony-vm-disk.timer 与 guest symphony-disk.timer 每 15 秒检查。只写 **state_dir/intake-paused**，对应 ExecutionReadiness.intake_pause_path；不改变 WORKFLOW 的 mvp.enabled，不撤销在途授权。控制器 ExecStartPre guard 即使暂停也返回成功，允许 staging 状态页、View 和模型管理运行。空间恢复后不会自行删暂停标记。宿主低空间另有 /data/symphony-vm/admission-paused，下一次可达时向 guest 传播；SSH 不可达会报失败，不声称 guest 已暂停。周期检查是准入检查，不是硬磁盘配额。

发生真实磁盘压力（guest 低于门槛或 host_paused=true）时，guard 原子替换 intake 标记，取得新的 inode 所有权；即使原标记由每日备份创建，备份后续的 busy/成功清理也不能删除这条磁盘暂停。标记创建、磁盘接管与所有权检查/删除共用短时 .vm-intake.lock，不阻塞整个备份期间的 guard。健康 guard 只读取已有暂停，不接管备份标记；磁盘恢复也不自动解除真实磁盘暂停。

宿主 `check --apply` 不获取长时间 operation_lock，允许在 daily-backup/backup/restore 持锁期间继续运行。宿主暂停 latch 用独占创建，并发检查遇到另一个检查已建的标记仍会继续传播 host_paused；guest 再通过自己的短时 intake flock 接管标记。持锁并发回归覆盖宿主剩余 14 GiB、guest 仍有 10 GiB 的场景：CLI 检查成功，备份 finally 不会误清这次磁盘暂停。备份/恢复/关机之间的原有互斥保留。

guest 操作示例：

```bash
python3 /var/lib/innovation-symphony/vm-tools/guest.py pause --apply
python3 /var/lib/innovation-symphony/vm-tools/guest.py quiesce --apply
python3 /var/lib/innovation-symphony/vm-tools/guest.py idle
```

维护使用独立的 `state_dir/maintenance.json`，内容为 `{nonce: 32hex, reason}`。它与只阻止新领取的 intake-paused 分开：native Mvp.Maintenance 同时拦截新派发和 resume admission；在途执行仍保留授权。guest 的 quiesce、每日备份与 shutdown 写入/沿用维护标记后，必须等 `/api/v1/state` 的串行 Orchestrator 维护确认，要求同一 nonce、acknowledged=true、drained=true，并与当前 systemd 控制器 MainPID 及 `/proc/sys/kernel/random/boot_id` 匹配。drained 包含零 running/retrying 且没有 poll check；只看零 running/retrying 的快照不足以停机。PID/boot/nonce 不匹配、旧 native 没有该 API 或确认超时都会拒绝停服务/关机。停机时保留维护标记；已有标记不会被覆盖。

手工 backup 要求 intake-paused 和有效 maintenance.json，三服务已停止或明确未安装，cgroup 无进程，控制器 4000 端口没有未知进程监听。每日动作自动完成维护握手、停止原 active 服务、导出和 finally 恢复。如果收到匹配身份的 acknowledged=true、drained=false，视为 busy 跳过：不停止服务、不改授权，只删除本次新建且 inode/内容仍归本次操作的维护和 intake 标记，使未来任务不被这次跳过堵住。所有原有标记及其内容保持不变。确认异常、导出或重启失败则保留标记；已停止服务仍在 finally 尝试恢复，只恢复原 active 的服务。成功恢复健康后只清除自己新建的维护标记；guest 空间仍足够才清除自己的 intake 标记。

```bash
python3 scripts/vm/operations.py --root /data/symphony-vm backup --destination /absolute/backup.tar --apply
python3 scripts/vm/operations.py --root /data/symphony-vm daily-backup
python3 scripts/vm/operations.py --root /data/symphony-vm daily-backup --apply
python3 scripts/vm/operations.py --root /data/symphony-vm restore --archive /absolute/backup.tar --target /var/lib/symphony-restore-20261020
python3 scripts/vm/operations.py --root /data/symphony-vm restore --archive /absolute/backup.tar --target /var/lib/symphony-restore-20261020 --apply
```

每日宿主 timer 为本地时间 03:00，加最多 15 分钟随机延迟，Persistent=true；操作者 安装/enable 后才生效。归档放在 /data/symphony-vm/backups。完整校验后才写带 vm_uuid+摘要的成功回执，仅轮换本工具的 daily 命名且回执和摘要匹配的成功归档，保留最近 3 份；.tar.keep 可钉住老归档。其他文件、迁移备份和 .partial 不删除。无 --apply 时可检查轮换候选。主机操作锁与 guest 维护锁阻止同一套工具的恢复/关机/备份并发。

归档同时包含 config、runtime 和 View 三棵树，逐文件校验摘要；SQLite 识别文件头，使用 sqlite3.Connection.backup 合入 WAL，关联 WAL/SHM 不直接复制。保留迁移备份、活动/recovery 回执、工作区、转录与日志。venv 可重建，不备份；认证明确排除。固定 release 和工具链工件由操作者独立保留，不伪称这里备份了整个 VM 磁盘。跨这些备份根之外的符号链接会拒绝备份，要求补齐依赖清单，不静默遗漏。

普通文件只打开一次：在同一未缓冲 FD 上识别 SQLite 头、fstat 获取权限/长度、计算摘要、seek 回开头并交给 tar。guard 原子替换 intake-paused 时，导出保持旧 inode 的完整快照，不将旧长度/摘要与新路径内容拼接。SQLite 先用 backup() 生成快照，保留原 FD 的权限，再从该快照的同一 FD 完成上述导出；按排序遇到数据库后才跳过其对应 WAL/SHM，不提前重开每个普通文件。没有重试读取、跳过文件或吞掉 IO 错误；摘要与读取之间的原地同长度改写仍被归档校验拒绝，截短仍直接抛出 unexpected end。

恢复仅新建独立目录（已存在的空目录也拒绝）。验证 manifest 必需字段、三个源根的关系、归档路径与根映射、库存、摘要与链接后，恢复为 target/config、target/runtime、target/view。workflow_path 必须为 config 下的普通文件，state_path 必须为 runtime 下的目录。**恢复时强制**保存、重映射该 workflow 并设 mvp.enabled=false，不受 editable_configs 缺失或空列表影响；最后再次解析，确认 disabled 且 state_dir 正好指向恢复 state，并保留其 intake-paused。其他明确列出的配置才按可选清单重映射。没有活动配置、unit 或服务切换；RESTORE-NOT-ACTIVATED.json 保留激活停点。失败的 .partial/独立恢复目录保留。归档完整性摘要不能替代受信备份来源。

## Guest bootstrap（已有工具链的当前 VM 不需要重跑）

bootstrap-guest.sh 是另一个一次性、明确 --apply 的 guest-only 入口。必须 root、Ubuntu 24.04 amd64、KVM/QEMU，且 cloud-init 的 /etc/symphony-vm 标记匹配；不会在宿主安装东西。现有工具链目录、符号链接或 receipt 会阻止覆盖。

输入 JSON 必须有 otp、elixir、node、codex 四项；每项包含 version、绝对 path、sha256 和操作者已验证来源的 provenance。精确版本依次 28.5.0.7、1.19.6、24.21.0、0.163.0。Codex 支持实际发行的根目录单文件 tar，例如文件名 codex-x86_64-unknown-linux-musl；此时 entry 就是该文件名，不剥掉文件。带共同目录包装层的归档只去掉那一层，entry 指向规范化后的 native 文件。校验阶段会打开 Codex 归档，确认 entry 对应非空、可执行的普通文件，拒绝缺失、链接和穿过链接的入口，早于 apt 或解包写入。没有 latest、联网拉取源码或 npm 隐式解析版本；SHA 来自 操作者独立验证的官方发行工件。OTP/Elixir 输入是源码 tar，Node 为 linux-x64 发行 tar。

```bash
sudo bash /var/lib/innovation-symphony/vm-tools/bootstrap-guest.sh --apply /absolute/verified-artifacts.json
```

脚本先验证所有摘要，再 apt 安装发行版 Docker、JDK21、Python3.12 venv 与编译依赖；OTP/Elixir 从源码构建。工具实际路径为 /opt/symphony/{otp-28.5.0.7,elixir-1.19.6,node-24.21.0,codex-0.163.0}，入口 /usr/local/bin；OTP 包括 erl、erlc 和原生服务 shebang 必需的 escript。/opt/codex 直接链接到 /opt/symphony/codex-0.163.0/bin/codex **文件**，不链接目录；既有 runtime_identity.native_client 的 ELF、执行权限和固定版本检查保持原样。toolchain-receipt.json 记录实际安装目标及 binary_sha256。apt 包来自 Ubuntu 24.04 软件源；操作者 保留 apt 版本记录。Hex/Rebar、项目依赖及正式检查依赖另由操作者使用固定工件准备；脚本不会偷装 latest。

Node 安装树显式规范根目录为 0755，避免继承解包临时目录的 0700。Node/Codex 的版本检查通过 `runuser -u elma -- env -i ...` 执行，不以 root 能访问证明 elma 可运行。单测用 0700 的模拟解包树验证安装后权限，并在本机 elma 的非 root 身份下运行模拟可执行文件；该单元测试本身不证明真实工具链安装。

bootstrap 还以 elma、清空环境并仅使用服务 PATH，启动一段 `#!/usr/bin/env escript` 的微型程序，检查实际 escript 入口与 OTP 可运行。单测执行脚本中的链接和探针片段，只模拟权限切换与 OTP 解释器；固定 Codex 链接则接入未修改的 native_client 门槛，以 ELF 文件夹具验证路径，并确认 shell wrapper 仍被拒绝。真实 guest 探针结果见部署记录。

Docker 是 guest rootful daemon，覆盖的 guest Docker unit 只监听 unix:///var/run/docker.sock；elma 加入 docker 组，下一次登录/服务启动生效。bootstrap 的 apt/Docker 动作只在操作者实际执行脚本时发生，不属于本次交付已执行步骤。

## 验证与手动验收

实际定向检查命令：

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -W error::ResourceWarning -m unittest discover -s scripts/tests -p test_vm_operations.py -v
bash -n scripts/vm/bootstrap-guest.sh
```

测试在临时目录构造文件和 SQLite WAL，QEMU、SSH、systemctl 等外部动作均模拟；不作为真实 VM 验收。操作者 完成部署后手工路径：staging 18613 查看真实 View → guest reboot → 重连后检查三服务与 loopback 端口 → 设置暂停标记并检查在途任务不被撤销 → 空闲备份到独立目标恢复 → 确认恢复未激活且原 runtime 未变。硬关机、故意杀活动 QEMU 和真实任务派发不包含在此验收路径。

当前定向测试 51 项通过，ResourceWarning 按错误处理。普通文件 FD 修复增加三项真实导出回归：摘要后 guard 替换标记时完整执行 daily backup→库存/摘要校验→独立 restore，检查只打开一次、FD 权限、旧 inode 内容、SQLite WAL/权限、回执及真实磁盘暂停保留；原地同长度改写的摘要失败；原地截短的 IO 失败。第一项在修复前实测报 unexpected end of data，修复后通过；没有 mock backup/export/restore。服务管理、握手 API 与健康检查仍为模拟边界，不属于实际 VM 验收。

此前全部 48 项回归也在本轮重跑通过，包括宿主备份持锁时的 CLI guard、并行检查、维护身份与恢复、Codex/native 门槛及 bootstrap；bootstrap 的 bash -n 在前轮通过，本轮未修改该脚本。

安装时须把同一版本的 operations.py、guest.py、artifacts.py、bootstrap-guest.sh、check-native.sh 同步到宿主 generated/tools；guest 只需后四个文件。helper 必须与含 Maintenance/Presenter 的固定 native release 一起验收；旧 native 无维护确认时，helper 会拒绝停机。无需再次 adopt 覆盖已有 generated 目录。实际安装和服务切换状态统一见 `docs/VM_DEPLOYMENT.md`。

## 完整原生门禁

```bash
sudo bash scripts/vm/check-native.sh /absolute/symphony/source
```

入口只接受有受控 VM 标记的 QEMU/KVM guest，使用 UID 1000 的 elma、纯净环境、一次性 HOME 及固定 native Codex 运行原有 `make all`。独立 PID namespace 使用现有 Docker 软件包的 `/usr/bin/docker-init` 回收孤儿进程，避免完整套件留下的僵尸进程使 `/proc` 检查永久不确定；这不改变运行服务的清理规则。仅门禁使用 Erlang DNS 解析，避免不可观察的 native DNS helper。覆盖率仍为 100%，没有新增忽略模块或降低断言。此入口不会执行显式 opt-in 的平台 live 套件。
