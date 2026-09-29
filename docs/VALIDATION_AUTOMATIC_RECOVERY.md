# 自动恢复验收记录

日期：2026-09-29。范围：IS-026 的基本自动技术恢复闭环，以及 IS-027 的人工合并边界。此记录区分控制器验证、真实候选交付和运行版本，不代表完整自动升级接棒或云部署。

## 控制器版本

- 源码及已发布提交：`07f74936f77e30c6337da70a1fec9476a61eac8f`。
- 本地标准检查：28 项 Python/真实 Mix 集成测试通过；465 项 Elixir 测试、0 失败、6 项既有实平台跳过，覆盖率 100.00%；格式、specs、严格 Credo、Dialyzer 和 escript 构建通过。
- 以 `c31c2b2` 原测试及配置执行冻结回归：415 项、0 失败、6 跳过。115 个源码、测试及检查脚本与验证副本逐文件一致。最终独立审查未发现可操作阻断项。
- [GitHub CI](https://github.com/dailiuyi/innovation-symphony/actions/runs/36539374493) 对同一提交成功。
- WSL `desktop` 已运行固定安装 `releases/07f74936f77e30c6337da70a1fec9476a61eac8f`，沿用 `runtime-v1`、`state/attempt-4` 和原任务工作区。核验时 PID 为 2793206，cwd 与固定安装一致，状态接口健康。

本地控制器门禁在允许 Mix 使用本地 socket 的 WSL 环境完成。编码沙箱仍可能限制 Mix.PubSub；不放宽编码权限，也不以临时测试替代上述标准检查。

## 真实 Issue #3

任务为 [升级前只读体检](https://github.com/dailiuyi/innovation-symphony/issues/3)，范围保持 PF-1 至 PF-5。原 base 为 `003a0db85da88ef79b882433108df2f3d782c092`，迁移前候选为 `96e1e798e11cabd220b6fa5fffa3dd709927c6c8`，原五次返工及六轮证据均保留。编码、诊断与独立 Review 使用冻结的 Astra high 配置。

| 实际阶段 | 观察结果 |
| --- | --- |
| 审计迁移 | 核对旧回执、Review、确认评论及前序操作；保留五次返工，既有 12 个用量槽位保守计入模型尝试预算 |
| 只读诊断，attempt 13 | 确认未知 GitHub state 被当作空队列成功，以及安全重试日志污染 JSON stdout，建议修代码 |
| 第六次返工，attempt 14 | coder 生成候选 `5a42e27`；391 项测试中 1 项断言失败，覆盖率 100%；控制器保存完整日志并自动交回编码，无人工候选补丁 |
| 第七次返工，attempt 15 | coder 修复日志处理，生成 `3a140a50290276eaded98157f6ea02d110c80732` |
| 完整门禁 | 最终候选 391 项测试、0 失败、6 跳过，覆盖率 100%；格式、lint/specs、Dialyzer、构建全部通过；原 `003a0db8` 冻结回归 377 项、0 失败、6 跳过 |
| 独立 Review，attempt 16 | 新只读会话逐项核对验收及测试，对同一候选批准 |
| 实际交付 | 控制器创建 [Draft PR #4](https://github.com/dailiuyi/innovation-symphony/pull/4)，GitHub head 与全部最终检查、Review 的候选 SHA 一致 |

原两个缺陷另用独立临时夹具对现有 escript 复测：未知 state 退出 1、stdout 空且报告错误；503 后重试 200 退出 0、stdout 整体为有效成功 JSON、warning 位于 stderr。探针未改候选或重新构建，无调度启动及回执/工作区写入。

最终回执为 `awaiting_human`、`reason=null`，七次返工、八轮，模型尝试计数 16（含 12 个历史槽位）。恢复进程退出 0，审计 completion 与最终回执摘要一致，执行锁正常释放，intake 恢复。494 项既有目录/文件条目的保存内容未改变；原回执前像和审计链保留。

## 交付边界与证据

PR #4 在最初交付核验时与 main 存在合并冲突，尚未合并，GitHub PR CI 当时尚无通过记录。用户在 IS-027 明确将合并冲突、跟进 main 和最终合并交人处理。因此系统到冻结候选的 Draft PR 交付即结束，不因主分支继续提交而不断重启编码。合并解决后的新提交需要重新检查，不能沿用旧候选的批准。

曾开始准备的自动集成扩展已按该决定停止，未提交、发布或安装；本地补丁归档在 `.local/automatic-recovery/unpublished-integration/`。运行代码保持 `07f7493`，未安装 #3 候选；ready 标签未由系统改动。

本机完整证据位于 `.local/automatic-recovery/`：`issue3-complete-evidence.zip` 保留逐轮检查和模型会话，`receipt-final.json`、`result.json`、`final-audit.json` 绑定最终回执和审计结果，`pull-request.json` 保存远端身份，`review-probe-result.json` 保存原缺陷复测，`validation-*.log` 和 `ci-07f7493.log` 是完整控制器门禁日志。该目录被 Git 忽略，不发布凭据或运行状态。

模拟测试另外覆盖协议纠正、未知检查重跑、评论不确定对账、资源耗尽、热消息超时及完整性破坏。真实 #3 证明实际诊断、自动技术返工、独立 Review 和平台交付；未把模拟故障宣称为实平台演练，也不据此承诺任意 Issue 都会成功。
