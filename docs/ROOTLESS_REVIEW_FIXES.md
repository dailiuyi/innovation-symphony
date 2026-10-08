# 三项审查问题修复记录

本轮来源：用户报告基于 main `66b9b25` 的分支未提交改动存在两个 P1、一个 P2，并表示目前不建议合并。修复仍在 `codex/rootless-open-reliability` 独立工作树，未修改原工作区或运行服务。

| 问题 | 修复 | 针对性验证 |
|---|---|---|
| P1 环境配方的 Mix 用户配置能降低正式覆盖率门槛 | 正式阶段的 Mix 缓存来源改为受信只读工具链；固定 runner 真正用独立 HOME/CODEX_HOME/MIX_HOME 启动每个子进程 | 真实 Mix 先用污染配置把低覆盖率候选跑成 exit 0，再用固定 runner 在相同污染环境中得到 child exit 3、outcome 10、100% 门槛失败；配置不被加载或改写 |
| P1 安装包遗漏 formatter | 抽出真实安装 payload 复制入口，将 `.exs` 与 Python/JSON/Shell 文件和 View 验证目录共同复制 | 实际复制到临时安装目录，固定 runner 可导入并计算摘要；从安装副本加载 formatter 启动真实 ExUnit，保存完整 suite_finished 报告 |
| P2 桥拒绝既有 View 正式检查 | 只接纳准确解释器、`-I -B`、受信脚本和 40 位候选 SHA；不接受附加参数、近似路径或任意 Python 代码 | 桥参数合同正反例通过；同时在配方准备后删除任务 veth，让 View 保持既有 loopback-only 离线检查合同，并适配已删除接口的清理路径 |

最新针对性结果：rootless 合同 12 tests、实际 Mix/ExUnit 集成 14 tests，均无失败。Python 全套 104 tests、无失败、22 skipped；Mix 的跳过项另以 opt-in 实际执行验证。View 完整代码检查 passed，包含 Python 35、JS 10、固定迁移比较和 Linux 本地集成 10；浏览器、真实 Windows/WSL、rootless 实机验收仍未执行。操作记录型网络合同测试不等于真实 nft/Podman 的网络边界证明。

纯净环境完整 `make all` 已执行：严格格式、specs.check、Credo 通过，全量 **742 tests, 0 failures, 6 skipped**；覆盖率 **97.84% < 100%**，所以完整门禁仍失败，尚未进入本轮 Dialyzer 阶段。当前覆盖率缺口集中于 AutomaticAcceptance（13.25%）、ExecutionSandbox（92.24%）和 Executor（99.30%）。阈值未降低，仍不能登记为可合并版本。

日志保存在 `.local/validation-rootless/review-fixes/`；对应 View 代码检查结果在 `.local/validation-rootless/view-review-fixes/code-check-result.json`。未安装、提交、推送、派发 Issue 或切换运行服务。

后续 IS-076 已授权并执行独立桥安装和本地提交准备。上述“未安装／提交”的描述保留为本轮修复当时状态；最新结果见 [VALIDATION_ROOTLESS](VALIDATION_ROOTLESS.md) 的实机安装节。
