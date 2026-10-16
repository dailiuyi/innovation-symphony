# innovation-symphony

<div align="center">
  <img src="assets/readme/hero.svg" alt="innovation-symphony Hero" width="100%" />
</div>

<p align="center">
  <a href="#核心工作流程"><strong>核心工作流</strong></a> ·
  <a href="#四大工程保障机制"><strong>工程保障机制</strong></a> ·
  <a href="#可观测性看板-view"><strong>只读看板</strong></a> ·
  <a href="#工程演进与里程碑契约"><strong>契约与演进</strong></a> ·
  <a href="#原型预览与文档导航"><strong>文档索引</strong></a>
</p>

---

innovation-symphony 是一个面向多代码仓库场景构建的 AI 自主研发任务编排框架。

基于官方 [Symphony](https://github.com/openai/symphony) 的 Elixir 实现构建，旨在实现企业云端无人值守接入 GitHub / GitLab：调度机器人自动监听带有 `ready` 标签的 Issue，自动认领并执行所属仓库的研发任务，通过严格的沙箱编码、测试门禁与独立代码审查，最终以 Draft PR 形式交付成果，由人工进行最终合并与升级把关。

---

## 核心工作流程

```text
在目标仓库创建 Issue (明确需求规格)
  │
  ├─► (可选) 评论区通过约定指令指定 Coder / Reviewer 模型
  ▼
添加 ready 标签
  │
  ▼
Symphony 监听器自动捕获并认领任务 (无须人工指派 Bot)
  │
  ▼
Coder 在 Linux 隔离沙箱中执行编码与同会话自检 (tests / lint)
  │
  ▼
独立环境执行结构化测试门禁 (基于 ExUnit 结构化断言验证)
  │
  ▼
独立 Reviewer 执行代码质量与安全性审查
  │
  ├─► [未通过] 消耗返工预算 (0~5 次) ➔ 退回重新修复并附带反馈
  ▼
[全部通过] 自动提交并发布 Draft PR (附带完整验证回执)
  │
  ▼
由人工工程师进行最终审核、合并与版本升级
```

- **工作流状态**：以 `ready`、`review`、`blocked` 等标签作为基本状态机锚点；
- **模型路由**：每个仓库可单独配置编码与评审的默认模型；用户在 Issue 评论中显式指定具有最高优先级；未指定时自动沿用仓库默认配置；
- **边界原则**：各仓库任务完全独立处理，不进行跨仓库的扩散修改；合并操作与版本发版由人类工程师主导，系统不自动追赶 main 分支。

---

## 四大工程保障机制

### 1. Linux 任务沙箱隔离与同会话自检 (IS-033)
通过显式启用的 Linux 任务隔离环境，允许单元测试、静态分析（Lint）及本地轻量服务在编码阶段直接运行。控制器仍在隔离环境中执行严格的冻结门禁，并调度无污染的独立评审角色。具体规则参见 [Coder 执行规则](docs/CODER_EXECUTION_RULES.md)。

### 2. 有限返工预算与失败自动恢复 (IS-026)
系统引入了可控的自愈循环：因代码缺陷导致的技术失败可交回编码环境或发起只读诊断，普通修复窗口无需逐次请求人工审批。
- 默认 `max_rework=0` 保持严格单次交付；
- 显式配置 `1..5` 启用返工预算，单任务最多经历 5 次修复；
- 完整保留所有检查日志与 Review 拒绝意见；复检流程严格绑定原基线与预算，已消耗次数不可逆，防止死循环刷 Token。详细规则参见 [返工合同与验收对应](docs/REVIEW_REWORK.md) 与 [自动恢复合同](docs/AUTOMATIC_RECOVERY.md)。

### 3. 独立看门狗守护进程 (GH-5 / IS-042)
新增独立于运行器的本地看门狗（Watchdog）进程，负责监控调度器状态；当发生异常崩溃时，依据固定版本指针与持久化预算自动拉起恢复。支持人工暂停、安全解除与预算重置，运维指引见 [OPERATIONS 维护流程](docs/OPERATIONS.md#看门狗维护流程)。

### 4. 真实验收与端到端闭环实据
控制器已成功跑通真实业务链路：从真实 Issue #3 出发，历经自动诊断、测试失败定向返工、完整门禁核对与独立 Review，最终顺利交付 [Draft PR #4](https://github.com/dailiuyi/innovation-symphony/pull/4)，相关证据链归档于 [验收记录](docs/VALIDATION_AUTOMATIC_RECOVERY.md)。

---

## 可观测性看板 (View)

项目在 [`view/`](view/README.md) 目录下集成了基于 Python 标准库构建的独立只读可观测采集与展示服务（可在本地通过 [http://127.0.0.1:8613/](http://127.0.0.1:8613/) 访问）。
- 看板独立维护本地数据、缓存与请求日志，其启动与停止完全不影响 Elixir 主调度控制器的运行；
- 提供 Linear 风格的任务四态看板、会话轨迹查询与只读上下文审查；
- 权限与安全边界明确：仅限内网使用，所有任务修改与执行权限严格收敛于 Elixir 核心。

---

## 工程演进与里程碑契约

- **GH-3（最小增量接管前只读体检）**：提供 `--preflight` 校验模式，严格校验状态机定义与远端 Issue 连通性，防止虚假报告通过。详见 [体检边界](docs/IMPLEMENTATION_V0.md#gh-3-最小增量接管前只读体检)；
- **GH-12（多模型服务路由）**：增加 Coder 与 Reviewer 的多模型预设管理，对任务领取时的完整配置进行参数冻结。详见 [角色模型服务](docs/MODEL_SERVICES.md)；
- **GH-16（看板双角色配置对接）**：在独立 View 设置页增加受控内网的仓库双角色默认选择，并支持 DeepSeek Responses 接入。详见 [方案及检查记录](docs/VIEW_MODEL_SETTINGS.md)；
- **Linux 补丁与审计记录**：详见 [本轮补丁验证](docs/VALIDATION_LINUX_PATCHES.md) 与 [实验性隔离规范](docs/ROOTLESS_OPEN.md)。

---

## 原型预览与文档导航

### 本地架构原型预览
在项目根目录下启动轻量 HTTP 服务即可预览前端控制台设计原型：

```bash
python3 -m http.server 43221 --bind 127.0.0.1 --directory prototypes
```

访问地址：<http://127.0.0.1:43221/symphony-dashboard.html>。

### 核心文档索引
- [文档总入口 (docs/README.md)](docs/README.md)
- [需求规格清单 (docs/REQUIREMENTS.md)](docs/REQUIREMENTS.md)
- [架构决策记录与替代方案 (docs/DECISIONS.md)](docs/DECISIONS.md)
- [运行运维与维护手册 (docs/OPERATIONS.md)](docs/OPERATIONS.md)
- [Issue 协议规范草案 (docs/ISSUE_PROTOCOL.md)](docs/ISSUE_PROTOCOL.md)
- [第三方与官方上游基线对照 (docs/UPSTREAM.md)](docs/UPSTREAM.md)
