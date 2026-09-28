# 官方源码基线

- 来源：https://github.com/openai/symphony
- 固定提交：`be10a1b79df723d6d7612b5651c8522704dafb2e`
- 获取日期：2026-09-28，浅克隆后导入。
- 保留完整 `elixir/` 实现以及根目录 `SPEC.md`、`LICENSE`、`NOTICE`、PR 模板。上游规范和许可证正文未更改。
- 保留原 `elixir/WORKFLOW.md`，另增默认停用的 `WORKFLOW.github.example.md`。README 加入本地扩展说明。
- 原有文档与 HTML 继续保留；没有复制上游的个人 Codex 配置或运行秘密。

## 有意改变的上游接缝

1. Config 增加 MVP 配置入口。
2. AgentRunner 在有 mvp 配置时进入有限交付链；没有此配置仍兼容上游。
3. Orchestrator 候选资格同时检查持久 receipt，不另写轮询器。
4. AppServer 增加会话模型、强制只读、关闭动态工具和结构化 Review 输出。
5. 两个重试计时测试使用消息处理前后的单调时间区间验证 1 秒续跑和 40 秒退避，避免额外 sleep 和调度延迟造成误报。

新增模块集中在 `elixir/lib/symphony_elixir/mvp/`、`mvp.ex` 及 `lib/mix/tasks/mvp.*`。维护时用固定基线比较这些修改；升级上游应重新运行官方及本项目新增测试，不能把整个目录重新生成。

当前工作区尚未提交，也没有远端。用户建库后，可再选择普通仓库或 GitHub fork 以及提交/推送方式；本地导入不声称已建立 GitHub fork 关系。
