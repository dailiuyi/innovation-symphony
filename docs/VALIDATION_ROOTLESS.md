# Rootless 实验实现验证记录

日期：2026-10-07。基线 main `66b9b25fe55ff0f95b7f8e719b740a62e4c6f001`，分支 `codex/rootless-open-reliability`。实现保存于独立工作树，未提交或发布。原工作区与原部署保留。

本记录区分源码验证和真实能力验证；实现合同及安装前提见 [ROOTLESS_OPEN.md](ROOTLESS_OPEN.md)。这是实验交付，不是完整计划完成或上线批准。

**最新状态**：本轮纯净 `make all` 已通过，764 tests、0 failures、6 skipped，冻结统计范围内覆盖率 100.00%，Dialyzer 0 errors。最终运行源码的冻结基线回归为 736 tests、0 failures、6 skipped；新增改动经独立代码审查。该源码门禁阶段实机前提尚缺；后续 IS-076 已补齐并安装独立桥，最新实机结果见末节。下文保留早期失败轮次，最终证据见末节“继续验收”。

## 已验证

| 范围 | 结果 | 证据 |
|---|---|---|
| 外部接续和预算回归 | 55 tests, 0 failures；随后预算代码仅作复杂度拆分，最终完整回归另列 | `.local/validation-rootless/rootless-budget-final.log` |
| 最后修复后的沙盒及类型检查 | 30 tests, 0 failures；严格 Credo 通过，Dialyzer 0 errors | `.local/validation-rootless/rootless-final-type2.log` |
| 最新沙盒、导入恢复、失败分流及恢复 Executor | 50 tests, 0 failures；含内容或权限被修改时拒绝恢复 | `.local/validation-rootless/rootless-import-final.log` |
| Rootless 无特权合同测试 | 9 tests, 0 failures；规则生成、原生客户端拒绝包装器、导出与发布失败保留、worker 私有 staging 权限、输出超时限制 | `.local/validation-rootless/rootless-contract-current.log` |
| 最新 Python 回归 | 99 tests, 0 failures, 20 skipped；跳过项不登记为通过 | `.local/validation-rootless/rootless-python-current.log` |
| Python 执行入口集成 | 98 tests, 0 failures, 2 skipped；该轮早于最后新增的 staging 合同与 journal 元数据，不冒充最终全量集成 | `.local/validation-rootless/rootless-python-integration.log` |
| 最新 View 完整代码检查 | passed；Python 35、JS 10、固定迁移比较、Linux 本地集成 10，源数据不变 | `.local/validation-rootless/view-final-current/code-check-result.json` 及 `rootless-view-final-current.log` |
| 语法与补丁 | Python 编译、shell 语法、JS 语法和 git diff --check 通过 | 本机定向检查 |

View 检查明确 `formal_acceptance=false`、`real_windows_wsl=false`，浏览器未执行。合同测试不需要 root，不证明 nft、Podman、cgroup 或实际 apt 能力已经可用。

## 完整门禁（早期轮次）

使用明确的原生 Codex 0.160.0，经 `clean_check.py` 的私有 HOME/CODEX_HOME/TMPDIR 执行原有 `make all`。最新完整轮次格式、specs.check 和严格 Credo 通过；全量结果 **742 tests, 1 failure, 6 skipped**，覆盖率 **97.90% < 100%**，因此 `make all` 失败。失败用例是 GNU timeout 不可用时，失败记录再次调用 Git 导致异常；已改为绑定回执中的准确候选，交由后续完整性检查判定。修复后两个失败边界的定向测试通过（2 tests, 0 failures），最新沙盒回归 30 tests, 0 failures，严格 Credo 和 Dialyzer 0 errors。最后一轮预检也修正了 Commands.run 返回文本的匹配，并要求受信 ready/rootless JSON。不能把修复前全量记录改写成通过，最终源码尚未重新完成全量门禁。

新增 AutomaticAcceptance 覆盖率 13.25%、ExecutionSandbox 93.07%、Executor 99.30%，仍需补齐行为回归。阈值未降低，未新增忽略模块。完整失败日志见 `.local/validation-rootless/make-all-failed.log`。此前非法预算计数与函数复杂度问题已修复。

完整门禁未通过前，不登记 release-ready。冻结基线全套与独立 Review 尚未完成。

## 实机前提与剩余范围

当前主机缺少 Podman/crun，没有已审查的 digest-pinned 基础镜像，管理员认证未提供。安装器只实现预览/独立安装路径，未安装或启动新桥。真实 apt、公网、浏览器/数据库、活跃宿主与内网隔离、OOM/PID/磁盘故障、断连和全后代清理均未验收；真实 GPT 探针没有执行或扣费。

源码仍需补齐：IPv6 公网策略、依赖安装清单与可复现环境锁、整任务累计存储配额、导出失败的自动产物恢复、控制器重启后的验收 job 扫描接续，以及完整故障注入矩阵。新的可信 formal Python 与 View 工具链组合也需实际 ABI 和安装材料验证。不得把这些缺口登记为已实现。

只读确认原 controller 和 View 仍运行，原 runtime WORKFLOW 的 `mvp.enabled=false`。未派发真实 Issue、调用真实模型探针、推送代码、切换运行服务或部署实验版本。

源码绑定记录为 `.local/validation-rootless/source-manifest.json`；日志在同目录保留。只有针对同一准确最终候选重新执行的完整门禁和独立 Review 才能支持后续安装切换。


## 三项审查修复后的全量结果

详见 [ROOTLESS_REVIEW_FIXES.md](ROOTLESS_REVIEW_FIXES.md)。真实 Mix 集成 14 tests 和 rootless 合同 12 tests 通过；Python 104 tests、0 failures、22 skipped，View 完整代码检查通过。

最新纯净 `make all` 为 **742 tests, 0 failures, 6 skipped**，覆盖率 **97.84% < 100%**，所以仍失败。本轮未到 Dialyzer 阶段；没有修改 Elixir 源码，前述类型检查记录保留，不能据此宣称本轮完整门禁通过。真实 rootless 验收未执行，安装和服务状态保持不变。完整日志位于 `.local/validation-rootless/review-fixes/rootless-review-full.log`。

## AutomaticAcceptance 补证行为回归（2026-10-07）

用户要求补齐完整补证链、失败和预算测试。本轮只扩展 `mvp_external_handoff_test.exs` 的测试与辅助夹具，没有修改运行实现、放宽覆盖率门槛或加入忽略模块。九组新增测试从真实 Git 候选、冻结模型服务及等待回执开始，覆盖自动接续与显式补证接续、Linux/GPT Coder/GPT Reviewer 固定探针、准确候选及环境绑定、nonce/错误 JSON/错误候选/模型失败/导出缺失、凭据撤销、证据写入冲突和重复执行拒绝，以及历史探针计数、独立 Review 预留额度、剩余时间截断、耗尽/非法计数/在途不确定状态。接续成功必须重新检查并独立 Review，更新同一 Draft PR，不增加 Coder 或返工次数。

桥及模型连接使用已有本地测试适配器；Git、冻结合同验证、证据文件及哈希、预算记账、审计接续和 PR 状态流程按真实实现执行。未调用真实模型账号或派发 Issue；这些结果不替代 Podman/crun 实机和公网/内网边界验收。初轮定向覆盖率执行为 **48 tests, 0 failures，AutomaticAcceptance 100.00%**；定向执行包含其他未完整运行模块，整体覆盖率 47.78%，仍按 100% 门槛返回失败。最终夹具整理后格式、specs.check、严格 Credo 通过，完整门禁结果另附本轮日志。

最终纯净环境 `make all`：**751 tests, 0 failures, 6 skipped**，AutomaticAcceptance **100.00%**，总覆盖率 **99.67% < 100%**；格式、specs.check、严格 Credo 通过。剩余缺口为 ExecutionSandbox **96.42%**、Executor **99.65%**，完整门禁在 coverage 阶段失败，未进入本轮 Dialyzer。最终源码与日志摘要保存于 `.local/validation-rootless/automatic-acceptance/source-manifest.json`；本轮没有安装、提交、推送或切换服务。

## 继续验收（2026-10-07）

本轮新增 13 组行为回归，覆盖真实普通子进程的 preflight、冻结原生角色入口、结构化环境报告与 OOM/PID 事件分类、导入恢复的失败保留及成功审计、同一 SHA 的完整检查重跑、阶段次数上限、导出和完整性失败停止、未知失败禁止代码修复、补证登记不足及模型/探针累计调用额度耗尽。沙盒、模型和平台执行使用本地适配器；Git、回执、冻结服务、证据摘要、预算和审计按实际实现执行。

回归证实合法 JSON 数组会使报告分类抛出 `ArgumentError`。已通过对象和嵌套身份模式绑定、整数 outcome 校验以及 OOM/PID 计数形状校验修复；非法形状保留原始报告与原失败结果。沙盒定向初轮 35 tests、1 failure 保留于日志，修复后 35 tests、0 failures，新增嵌套形状和 journal JSON 拒绝边界由最终全量验证。

全量中间轮为 764 tests、0 failures、6 skipped、覆盖率 99.98%；唯一未覆盖行是已经由 `external_budget_credit` 验证的重复整数预算校验。独立审查确认只有一个私有调用点、两个公开入口均先校验相关计数为非负整数。已将累计次数直接与上限比较，保留非法计数、在途不确定和时间预算拒绝；没有降低阈值、扩大排除或加入跳过。

| 最终检查 | 结果 | 证据 |
| --- | --- | --- |
| 原生 Codex 0.160.0、私有 HOME/MIX_HOME 下的完整 `make all` | passed；764 tests、0 failures、6 skipped；覆盖率 100.00%；格式、specs.check、严格 Credo、构建及 Dialyzer 0 errors | `.local/validation-rootless/continuation-acceptance/make-all-final.log` |
| main `66b9b25` 的完整冻结测试对最终候选运行源码回归 | passed；736 tests、0 failures、6 skipped，730 passed、0 excluded、0 invalid；固定 formatter `child_exit=0`、`outcome=0` | 同目录 `baseline-final.log`、`baseline-evidence/baseline_test-8a614206c26644a28fa03e32c0eccd1a-nc161iao/result.json` |
| 新增报告分类、恢复行为及预算简化的独立代码审查 | 无新增可达缺陷；适配器证据不登记为实机故障注入 | 同目录 `independent-review.json` |
| 门禁配置和源码绑定 | `mix.exs`、lockfile、formatter、Credo 与冻结基线一致；最终两套检查期间 311 个源文件摘要未变 | 同目录 `gate-policy-comparison.json`、`source-before-final-gates.json`、`source-manifest.json` |

基线使用 `git archive 66b9b25` 的原始测试及配置、候选 `lib/priv` 和独立临时构建目录。首轮误加外层 `clean_check`，使双重私有 TMPDIR 超过已有 PATH_MAX 用例的准备目录上限，得到 736 tests、1 failure；移除多余包装后由固定 runner 自身隔离 HOME，完整回归通过。原失败与预算简化前通过轮次分别保留为 `baseline-initial-double-home.log`、`baseline-before-budget-simplification.log`，没有修改冻结测试。预算简化后的最终源码已再次完整回归，不借用前一源码的通过结果。

六项跳过均为已有真实 Asana、GitHub、Jira、GitLab 和两项 Linear 端到端用例，未启用真实平台开关；不计作执行通过。完整门禁先前的 Credo/覆盖率失败轮次也保留。

实机前置检查确认 Podman、crun、newuidmap/newgidmap 和新桥尚未安装；IPv4 forwarding 已为 1，cgroup v2 可用，但当前无管理员非交互认证。用户本轮确认没有已审查的基础镜像及 digest，故继续保留该输入缺口。真实容器、apt/公网、宿主和内网隔离、资源故障、断连及后代清理仍未执行，前述未实现范围保持未完成。

代码仍为分支工作树的未提交改动，以源文件 SHA256 绑定验收，不把基线 HEAD 当作候选提交。最新记录写入后只有验收文档变化，运行源码与最终门禁一致。没有提交、推送、安装、派发 Issue、调用真实 GPT 探针或切换服务；原 runtime 的 `mvp.enabled=false`。本轮完成代码门禁，尚不能登记 rootless 整体验收通过或 release-ready。


## IS-076 实机配置与独立桥安装（2026-10-07/08）

所有者授权补齐配置、安装服务及本地提交，并确认 `codex/rootless-open-reliability`。本机管理员认证已完成；Podman 5.7.0、crun 1.21、uidmap 与专用 worker `symphony-worker`（UID/GID 1001，subuid/subgid 165536:65536）已安装。官方 Ubuntu 26.04 amd64 manifest 固定于 `88a381d5b5eeb2b35d3ad70925a362c37ce569daf43ede89ff818ec20e4d3794`；索引原文与 SHA256 复核证据在 `.local/rootless-install-20261007/image.json` 和 `ubuntu-index.json`。

受保护独立桥安装于 `/opt/innovation-symphony-rootless-bridge`，systemd unit `innovation-symphony-rootless-bridge.service` 已 active/running 且 enabled；实际停止／重启后 socket 与启动守卫通过。宿主重启未测。本机完整待激活配置安装到 `/var/tmp/innovation-symphony-rootless/WORKFLOW.md`（0600、innovation 所有），并在安装目录保留副本；镜像、工具链、依赖、worker、4 CPU／4096 MiB／512 PID／20480 MiB 与桥策略一致，`mvp.enabled=false`。原控制器和 View 没有切换，原活动 WORKFLOW 和旧桥保留。

安装中实际暴露并修复五项环境问题：复制文件继承组写权限；任务内无法使用宿主 loopback DNS；宿主 FlClash fake-IP 与内网拒绝合同冲突；Docker FORWARD=DROP；`ip netns exec` 重挂 `/sys` 导致 Podman 错认 cgroup v1。另修正 Podman commit 裸 64 位镜像 ID 的规范化。采用任务内 TLS 验证的固定 DoH、准确接口的临时转发规则与只切网络的 nsenter；未关闭内网／metadata／fake-IP 拒绝、未改全局代理、未修改宿主默认防火墙策略。全部早期失败、管理员拒绝及一次相对路径安装入口错误保留为日志，不冒充通过。

最终 Python 回归：108 tests、0 failures、22 existing skips；rootless 合同 16 项通过。Elixir 与 View 的运行及测试源文件逐字节匹配此前完整 764 tests／100% coverage／Dialyzer 0 errors 与冻结基线 736 tests 的通过源码，因此没有借用其他 Elixir 源码的旧结果；本轮变化的 Python 安装与执行路径重新验证。语法及 git diff 检查通过。

实机 probe 8 的原 14 项和 probe 9 增补版本校验后的 **16 项全部通过**：容器 root、apt hello、公网 HTTPS、任务内 TCP、toolchain／.git／evidence 只读、无宿主认证、无 NET_ADMIN/SYS_ADMIN、四个目标连接拒绝、IPv6 拒绝、Elixir 1.19.5／OTP 28 与原生 Codex 0.160.0。实际资源 cgroup v2、环境配方安装、私有 rootfs 提交及受信 formal Python 均经过运行；配置绑定固定 OTP 28.5 安装路径。probe 9 的退出、后代清理、宿主清理和源码导出均成功，OOM/PID 事件为 0；任务后 worker 无进程，iptables 规则与诊断基线除计数外完全一致，启动守卫确认无任务 nft/netns/cgroup/转发残留。

这是真实执行路径的基线源码夹具：`candidate_sha=66b9b25`，不是尚未提交的 rootless 功能候选 Git SHA。被测 runner／探针／配方及整个已安装 payload 按 SHA256 与当前源文件绑定；实验代码提交后仍不以此声明完整候选正式验收通过。最终报告 `installation-result.json`、`installed-manifest.json`；探针实际目录 `/var/tmp/innovation-symphony-rootless/sandboxes/run-20261008-9/sandbox`，其中 `environment.json`、`result.json`、`export-report.json` 和导出的 `.check-evidence/linux-probe-*/summary.json` 保留。

**rootless 整体验收仍未完成**：浏览器／数据库、活跃宿主服务与内网的阳性对照、OOM／磁盘／PID 故障注入、控制器断连和持久盘恢复，以及完整正式检查／自动补证／独立 Review 的真实容器链未执行；未调用真实 GPT。源码原有 IPv6 公网、依赖锁、累计存储配额及自动恢复缺口仍保留。未打开领取、切换活动控制器、推送、合并或云部署。本轮本地提交记录以分支 Git log 为准。

回退本次独立安装可在确认桥空闲、没有 task 资源后停止并禁用该 unit，保留新配置、安装目录和所有工作盘；由于未切换原控制器／View，无需重写其工作流、数据库或任务历史。不要让旧执行器接管新的冻结 profile。
