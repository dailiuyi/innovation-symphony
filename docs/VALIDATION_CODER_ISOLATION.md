# 隔离自主测试验收记录

2026-09-29，实施授权及范围见 IS-033。本文区分实现验证与运行切换；不将测试通过解释为 #5 看门狗已安装。

## 已取得的执行证据

- 在本项目 WSL Ubuntu 环境使用 bubblewrap、cgroup v2 和本机 Codex 0.157.1。模型认证留在宿主受控 AppServer；文件和命令工具经 stdio execution environment 进入任务环境，禁止 local 回退。
- 一次真实 `gpt-6-sol` 会话中，`python3 test.py` 首次退出 1；模型修改源码后复测输出 `SELFTEST_PASS`，再成功绑定任务内 loopback 端口。会话数为 1，执行器退出 0，产物导出及后代清理证明为 true。原始证据目录：`/var/tmp/innovation-symphony-isolation-probe/model-1790687646966745295`。
- 实际 Linux runner 的 4 项集成测试通过，覆盖私有源码导出、只读边界、伪凭据不可见、外网与宿主服务不可达、内部端口、后台管道清理、CPU 配额、内存 OOM、磁盘、进程数、输出上限和总超时。准备复制、依赖缓存复制也计入同一 cgroup 和总时限；坏工具链不会遗留本次 cgroup。
- 离线依赖包含固定 Mix/Hex/Rebar 工具链、预置源码和依赖自行校验的 `lazy_html` NIF 归档；仅将专用缓存复制到任务私有目录，不挂载宿主 HOME 缓存。未开放任意依赖下载。
- 正式 harness 使用冻结基线的 Mix 配置、lockfile、formatter、Credo、WORKFLOW 与 runtime config。候选对门禁文件的修改另行记录，不能直接替换当前门禁。已有逐测试报告增加 skipped/excluded 原因及汇总，不将跳过计作通过。
- 完整隔离 candidate gate 退出 0：格式、规格、Credo、521 项测试（515 通过、6 跳过、0 失败）、100% 覆盖率、Dialyzer 和构建均通过。证据目录：`/var/tmp/innovation-symphony-isolation-probe/candidate-1790693370018879848`。隔离 baseline gate 退出 0，478 项测试、0 失败、6 跳过，证据目录：`/var/tmp/innovation-symphony-isolation-probe/baseline-1790692889690452458`。两次运行均完成导出及后代清理，无 OOM 或进程数越限事件。
- 上述完整隔离运行后，恢复逻辑删除了一处由前置绑定检查保证的冗余判断，并将首次编码中断测试改为真实的空候选状态；12 项恢复测试再次通过，独立审查未发现阻塞问题。最终安装版本另执行完整 `make all`，不将此前隔离运行冒充最终版本的逐字节证明。
- 检查器的 32 项 Python 测试已通过。既有真实平台测试的 6 项条件跳过保留并明确报告，未降低覆盖率阈值或增加测试排除。
- 最终源码的 `make all` 退出 0：521 项测试、0 失败、6 跳过、100% 覆盖率，格式、规格、Credo、构建及 Dialyzer 通过；最终 runner 的 4 项集成测试全部执行并通过。日志：`.local/isolation/full-gate.log`。依赖获取仍报告现有锁定依赖的安全公告，本次门禁通过不代表完成依赖安全升级。

## 实现及运行状态

固定版本安装和 #5 审计续跑仍在本次操作中收口，最终结果在完成后补录。旧任务的 receipt、完整工作区（包含未提交修改）和运行配置已保存快照，恢复不得重置历史用量或改变原始任务范围。快照目录：`/var/tmp/innovation-symphony-v0-rerun1/operator-isolated-gh5-1790686021590747123`。

## 适用限制

这组证据证明当前 Linux 后端及上述受控验收场景，不等于抵御任意恶意内核攻击或完成真实平台验收。现有真实平台测试的跳过必须保留；#5 的无人值守凭据及真实恢复要求不能由 mock 代替。

同会话自检由 Agent 指令组织，目前没有最终源码与最后自检的机器签章。控制器仍对停止写入后的新候选执行完整门禁及独立 Review。效能改善需以实际任务耗时、模型用量和外层返工记录衡量，尚不声明提速比例。
