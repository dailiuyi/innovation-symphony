# GH-7 本轮离线验证与外部停点

环境：2026-10-02，离线 Linux `/workspace` 任务沙箱；Python 3.12.3、Node v24.19.0、
codex-transcript-viewer 0.5.0；Elixir 1.19.5／OTP 28.5。无外部凭据、真实服务或 Windows＋WSL。
源码来源完整 SHA、包摘要和迁移差异见 [MIGRATION](../view/docs/MIGRATION.md)。

工作区 base HEAD 为 `d49829488c1cce65c1917b219e428e98ff7050bb`。本轮禁止提交，
所以没有“最终候选提交 SHA”；这是未提交工作区的自检记录，不能把 base HEAD 当作
含 View 的已提交候选。控制器须另行冻结准确候选、执行正式门禁和独立 Review。
本轮没有改 `.git`、可信检查政策、运行凭据、控制器证据或安装可信 View 入口。
按指定命令自动产生的 `.check-evidence/` 结果保留，不作为导入源码。

## 已执行

| 命令／诊断 | 结果 |
| --- | --- |
| `python3 scripts/prepare_view_source.py extract --package /opt/symphony/scripts/view_validation/source/view-source.zip --manifest /opt/symphony/scripts/view_validation/source/source-manifest.json --destination /workspace/view` | 固定包、完整 Git tree、SHA 和逐文件摘要认证后导入36文件；真实配置排除 |
| `/opt/toolchain/view-validation/python/bin/python -B scripts/run_view_checks.py --node /opt/toolchain/view-validation/node/bin/node --output /tmp/gh7-code-checks-final2` | 24项 Python、10项 JS，无 skip；实际 self_check 解析和 HTML 渲染，固定完整 snapshot／contexts／6 HTML 摘要与迁移前等价；8种脚本入口通过 |
| `RUN_MIX_INTEGRATION=1 python3 -B -m unittest discover -s scripts/tests -v` | 55项、0失败、2项原宿主 sandbox integration 未执行，详见下方 |
| `python3 /opt/symphony/scripts/check_isolated.py candidate` | format、specs、credo、652项 ExUnit、100% coverage、Dialyzer、escript 构建通过；6项原 live E2E skip |
| `python3 /opt/symphony/scripts/check_isolated.py baseline` | 首轮看门狗计时断言1629ms超1600ms；独立重跑652项、0失败、6项原 live E2E skip，退出0；不修改门槛或测试 |
| Node `--check` 两个浏览器脚本、Python AST、`git diff --check`、manifest逐文件差异 | 通过；导入代码只修改已登记的6个来源文件；无真实配置或嵌套 Git |

View 原16项 Python及10项JS均保留。新回归覆盖缺缓存目录的第一条有效会话、真实
缓存和 HTML、重复采集复用、两配置并发脚本隔离、生成脚本失败／启动异常／中断／
非零退出／缺JSON／损坏JSON的清理与重试、默认和TOML/JSON配置、缺配置及损坏配置、
原 once／interval／port／config／out 行为、损坏CLI值和真实HTTP静态资源路径。
八种新子进程实际以 `__main__` 执行 `app/run.py`：根／view cwd 各执行默认、TOML、
JSON once与服务循环，外部采集和HTTP启动使用替身；Python API测试另实际使用loopback
socket验证静态页面、CSS、JS、生成页和404。第一条会话的回归实际渲染第三方viewer。
这些检查不证明真实WSL采集或生产控制器启停隔离。

另将两个关键新回归运行于固定原始来源代码：首次写缓存以 FileNotFoundError 失败，
重叠采集把 a 配置读成 b 配置，均准确拒绝原缺陷。这是预期失败的负向诊断，
不是原来源通过声明；修复后相同回归在本轮完整View检查通过。

现有 candidate 自检证据：`.check-evidence/candidate-u3k2g6gv/`；成功 baseline 重跑：
`.check-evidence/baseline-9ucixe_9/`，首轮失败记录也保留。
View输出含 `code-check-result.json`、完整合成 snapshot、contexts、projection 和6份HTML；
所有正式接手证据仍需绑定控制器冻结的候选SHA，不能复用本轮未提交HEAD作身份凭证。

## 未执行与具体失败

浏览器实际尝试：

```sh
/opt/toolchain/view-validation/node/bin/node view/tests/browser-fixture.cjs /tmp/gh7-code-checks1/fixture
```

返回1：`Error: Cannot find module 'playwright/package.json'`，`code: 'MODULE_NOT_FOUND'`。
本沙箱未预置Playwright和Chromium，离线且未安装新依赖。仅Node语法检查通过，浏览器
UI断言未执行。新增CI另强制安装Playwright 1.62.1及配套Chromium，使用固定夹具运行
原smoke；缺依赖、缺浏览器或任何断言失败均使job失败，没有跳过后报告通过。
远端CI本轮未触发，安装和浏览器兼容性仍待该环境实际验证。

原隔离脚本的两项宿主测试 `test_isolated_command_exports_source_and_proves_cleanup` 与
`test_timeout_output_pids_memory_and_disk_limits` 因未设置 `SYMPHONY_SANDBOX_INTEGRATION=1`
按原条件skip。该沙箱中 `/sys/fs/cgroup` 与 `/sys/fs/cgroup/innovation-symphony-execution`
不存在，不能完成需要宿主授权cgroup与挂载的集成；未改skip条件或申请宿主权限。
Mix真实集成已开启且通过。原6项live E2E分别是GitHub、GitLab、Jira、Asana及两个
Linear测试，需要真实平台、凭据和显式环境变量；本轮未开启，不算真实平台通过。

未运行需干净已提交候选及受信挂载的正式View runner，也未安装或改变其入口；
本轮只运行仓库内自检，控制器分别负责最终完整验证和Review。

## 验收合同逐项状态

| 验收项 | 本轮状态／限制 |
| --- | --- |
| 固定来源整体纳入view且差异可追溯 | 通过；远端最新提交核查因离线未执行，使用明确获准的固定包 |
| 无本机配置、数据、凭据、依赖、嵌套Git进入导入源码 | 通过源码清单诊断；本轮没有提交任何文件 |
| 根目录及view cwd的配置、资源路径 | 离线脚本与真实loopback HTTP检查通过；真实WSL启动另验收 |
| 默认、显式TOML/JSON及原启动参数 | 通过；保留显式缺文件时默认行为和相对cwd语义 |
| 干净首次采集缓存和HTML | 固定会话及实际viewer渲染通过；真实采集待外部 |
| 临时文件唯一、异常清理与重试 | 通过，含重叠配置与中断 |
| Python、JS、self_check及迁移回归 | 通过，无必测View项skip；准确提交候选仍由控制器冻结复验 |
| 原Elixir及隔离检查 | 所列本地门禁通过；原live与宿主集成skip据实保留 |
| 看板、详情、轮次、重试、会话既有行为等价 | 固定完整数据／HTML结果通过；交互浏览器待外部 |
| 固定脱敏夹具迁移前后明确结果断言 | 通过；不改变awaiting_external或PR语义 |
| 深链接、前进后退、关闭重开、刷新阅读保持和窄屏 | 测试已接入夹具CI；本轮浏览器缺依赖，未验收 |
| Windows＋WSL真实采集与浏览器 | 待外部验收 |
| 看板启停不影响控制器、不写控制器回执或GitHub状态 | 职责与来源实现保持；本轮未接触真实控制器，实机启停证据待外部 |
| 准确候选SHA、环境、命令、结果、未执行项 | 环境、命令和未执行项已记录；本轮无提交，最终SHA由控制器提供 |

接手人是项目所有者或其明确指定的View正式验收负责人。须在准确冻结候选SHA上，
使用独立数据目录和端口完成Windows Python→WSL真实采集、第一条缓存与HTML、全套
浏览器交互、数据库保留及看板启停隔离，保存环境、命令、结果、原始日志、截图和摘要。
发现代码问题回到原任务修复；只剩外部证据时按既有外部停点合同保留未完成项。
本轮没有提交、push、PR、合并、安装、部署、删除旧仓库或切换运行服务，不宣布GH-7全部完成。

## 导入副作用修复续跑（2026-10-02）

本节追加本次续跑结果，不替代上面的初轮记录。当前只读 HEAD 是此前被拒绝的
`3960c9064e9a5b45bf148be74bfdfc883bc6418a`；修复尚未提交，不能将它作为修复后的候选 SHA。
控制器失败日志确认迁移测试无条件插入已预置的 app 路径，触发
`worker integrity changed after candidate test import: module search path`。

保留此前导出的修复：仅在 app 路径缺失时添加；回归分别断言预置路径（位于列表中间）
完全不变和缺失路径仅添加一次、模块仍解析到正确源码。入口测试也恢复配置加载修改的
仓库别名，避免影响同进程后续夹具。没有改首次缓存、临时文件、固定预期或受信检查。

| 本次命令／诊断 | 结果 |
| --- | --- |
| `/opt/toolchain/view-validation/python/bin/python -B scripts/run_view_checks.py --node /opt/toolchain/view-validation/node/bin/node --output /tmp/gh7-repair-view` | 26项 Python、10项 JS，无 skip；实际 self_check、迁移前后完整结果比较及8种入口通过 |
| `/opt/toolchain/view-validation/python/bin/python -I -B view/tests/test_migration.py -v` | 新解释器直接运行10项迁移回归通过，验证普通入口无需预加载 app 模块 |
| 直接运行 `/opt/symphony/scripts/view_validation/worker.py` 的冻结／候选私有副本 | 各26项 Python、10项 JS通过，完整性保护未改；冻结阶段实际 self_check 与6份 HTML渲染通过；命令及结果见 `/tmp/gh7-repair-trusted-worker-2/` |
| 在 `/tmp/gh7-repair-negative/` 副本恢复旧的无条件插入 | 新回归明确失败；受信 worker准确复现原完整性错误。这是预期负向诊断，未修改工作区源码 |
| `RUN_MIX_INTEGRATION=1 python3 -B -m unittest discover -s scripts/tests -v` | 55项、0失败，保留原2项宿主隔离集成 skip；原因与初轮相同 |
| `python3 /opt/symphony/scripts/check_isolated.py candidate` | 退出0；format、specs、Credo、652项 ExUnit（0失败、6项原 live skip）、100%覆盖率、Dialyzer及 escript构建通过；结果在 `.check-evidence/candidate-dbcxgsrn/` |
| `python3 /opt/symphony/scripts/check_isolated.py baseline` | 首轮652项、1失败、6 skip，退出10；完整复跑652项、0失败、6原 live skip，退出0；首轮和复跑分别保留于 `.check-evidence/baseline-z0rbeu9i/`、`.check-evidence/baseline-g_56khlq/` |

基线首轮失败为 `MvpExternalTaskTest` 的默认 tracker 绑定断言（419行用例、427行断言）：
预期 `{:error, :tracker_binding_mismatch}`，实际 `{:error, {:mvp_awaiting_external, "bound"}}`。
相同命令的新完整运行通过；没有改 Elixir代码、冻结测试、seed、过滤、覆盖率或权限，
也不以复跑成功抹除首次失败或宣称该既有用例绝无偶发问题。

受信 worker 的命令记录包含 argv、环境、stdout/stderr 与逐项报告。首次临时编排因重复
创建 `private-home` 失败，改为每阶段只创建一次后重新运行全部阶段通过；未改受信程序。
以上是未提交源码的自检，不能代替正式候选身份核验、完整门禁或独立 Review。

实际调用正式入口：

```sh
/opt/toolchain/view-validation/python/bin/python -I -B \
  /opt/symphony/scripts/check_view_isolated.py \
  --candidate-sha 3960c9064e9a5b45bf148be74bfdfc883bc6418a
```

退出1，环境核验报 `GateError: /workspace/.git is not one verified read-only sandbox mount`。
没有改变挂载、Git、检查或证据来绕过此要求；正式 View 门禁仍须由控制器在受信挂载和
新冻结候选上执行，不能把上述受信 worker 自检报告成该门禁通过。

浏览器再次实际调用 `/opt/toolchain/view-validation/node/bin/node view/tests/browser-fixture.cjs /tmp/gh7-repair-view/fixture`，
退出1，`Cannot find module 'playwright/package.json'`（`MODULE_NOT_FOUND`）；UI断言未执行。
Windows＋WSL真实采集、浏览器交互和真实控制器启停隔离继续保留外部验收项。
