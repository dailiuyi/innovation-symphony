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

## 刷新阅读保持回归续跑（2026-10-02）

本节保留并补充此前失败记录。当前 base HEAD 为
`32ae9429da84ddc02132317f05d1ed4ed83eab79`；本轮修复未提交，不能将该 SHA
或工具报告中的 HEAD 当作包含本轮修改的最终候选。控制器另行冻结、验证及 Review。

评审指出的异步断言缺口已补入 `view/tests/browser-refresh.cjs`，由原 smoke 强制调用：

- 路由内使用实际解析的工具记录生成120条固定长记录；检查较早分页与非零滚动。
  新快照改变会话摘要，等待请求完成及客户端接受更新后，逐值核对正文、阅读位置、
  类型、搜索、文本选区、活动标签和分页；断言没有后台重读，再验证显式重读得到 v2。
- 实际打开本轮 viewer 生成的 HTML，保留生产刷新逻辑，补入固定长记录、折叠内容
  和树节点；夹具轮询间隔设为3600秒，逐次等待 `refreshSilent()` 完成，核对新内容
  确实应用且原正文、展开状态、活动节点、搜索、筛选和滚动／阅读位置保持。
  损坏 HTML、503 和后续恢复均有明确结果断言。
- 更新仅存在于 Playwright 路由内，不改原配置、数据、黄金迁移预期或展示实现。
  这些是新增断言设计，本环境未执行 UI，不能据此登记浏览器验收通过。

额外诊断发现验证器的实际 worker 回归只模拟了 `wsl.exe`，Linux 临时路径仍进入
Windows 驱动器转换而产生 `IndexError: string index out of range`。仅在该测试的
非 Windows 子进程模拟路径转换，保持实际 worker、解析、渲染、沙箱限制和全部
正负向断言；损坏候选必须被拒绝。没有修改 worker 或受信检查的有效政策。

| 本次命令／诊断 | 结果与原始记录 |
| --- | --- |
| `/opt/toolchain/view-validation/python/bin/python -B scripts/run_view_checks.py --node /opt/toolchain/view-validation/node/bin/node --output /tmp/gh7-refresh-view-handoff` | 最后代码检查退出0；26项 Python、10项 JS、实际 self_check、6份 HTML、完整迁移比较及8种入口通过，无 skip；`/tmp/gh7-refresh-view-handoff.log`、输出目录 `code-check-result.json`；前次同样通过，保留于 `/tmp/gh7-refresh-view-final/` |
| `RUN_MIX_INTEGRATION=1 python3 -B -m unittest discover -s scripts/tests -v` | 退出0；55项，保留原2项宿主隔离集成 skip，原因与初轮相同；`/tmp/gh7-refresh-scripts.log` |
| `PATH=/opt/toolchain/view-validation/node/bin:/opt/toolchain/view-validation/python/bin:$PATH VIEW_TEST_SOURCE_PACKAGE=/opt/symphony/scripts/view_validation/source/view-source.zip VIEW_TEST_SOURCE_MANIFEST=/opt/symphony/scripts/view_validation/source/source-manifest.json /opt/toolchain/view-validation/python/bin/python -B -m unittest discover -s scripts/view_validation/tests -v` | 修复后退出0；24项、无 skip，包含实际固定源渲染及损坏候选拒绝；`/tmp/gh7-refresh-validator-final.log`。初次未配置 Node／固定包环境失败及修复前路径失败分别保留于 `/tmp/gh7-refresh-validator.log`、`/tmp/gh7-refresh-validator-rerun.log` |
| `/opt/toolchain/view-validation/node/bin/node --check view/tests/browser-refresh.cjs` 及同命令检查 `browser-smoke.cjs` | 各退出0；仅语法检查，不代表浏览器兼容性或 UI 通过 |
| `/opt/toolchain/view-validation/node/bin/node view/tests/browser-fixture.cjs /tmp/gh7-refresh-view-handoff/fixture` | 退出1：`Cannot find module 'playwright/package.json'`，`MODULE_NOT_FOUND`；`/tmp/gh7-refresh-browser-handoff.log`，前次同样失败保留于 `/tmp/gh7-refresh-browser-final.log`。离线工具链无 Playwright／Chromium，UI断言未执行，未降级或跳过后报告通过 |
| `python3 /opt/symphony/scripts/check_isolated.py candidate` | 退出0；format、specs、Credo、652项 ExUnit（0失败、6项原 live skip）、100%覆盖率、Dialyzer及 escript构建通过；`/tmp/gh7-current-candidate.log`、`.check-evidence/candidate-zldbj957/`；有效政策无变化 |
| `python3 /opt/symphony/scripts/check_isolated.py baseline` | 首轮退出10：652项、1失败、6项原 live skip；完整复跑退出0：652项、0失败、6项原 live skip。日志分别为 `/tmp/gh7-current-baseline.log`、`/tmp/gh7-current-baseline-rerun.log`；工具产物分别在 `.check-evidence/baseline-a4p5hj4h/`、`.check-evidence/baseline-twaqs4xm/` |

baseline 首轮为既有 `WatchdogTest` 的 packaged manual starts 用例（1151行）：
1390行计时断言预期不超过 `interval_ms + 100 = 1600`，实际1614毫秒。
原命令完整复跑成功；未修改 Elixir、计时门槛、seed、过滤、覆盖率或跳过政策，
不以成功复跑删除首次失败记录，也不把该既有计时用例登记为从无偶发问题。

真实平台 live E2E 的6项 skip 沿用原显式启用条件，不计作真实平台通过。
最终候选 SHA 的完整正式报告、Playwright 1.62.1／配套 Chromium 的成功运行、
Windows＋WSL 首次真实采集与浏览器、控制器启停健康及只读外部状态对照、
来源远端审计继续待项目所有者或其指定的独立验收负责人接手。本轮没有提交、
push、PR、合并、安装、服务切换或写入控制器证据，不宣布 GH-7 全部验收完成。

## 生成页滚动夹具修复续跑（2026-10-02）

本节追加本次工作区自检，不替代前述失败记录或独立评审。base HEAD 为
`2fb9d3f652796af4b95a40df543015b54dcac5ef`，本轮未提交；该 SHA 不包含本次修复，
不能作为修复候选身份。最终候选仍由控制器冻结并另行正式检查和独立 Review。

生成页实际布局中 `#content` 随正文增高，正文由 document/window 滚动；40 个约20px
树节点不足以使约815px的列表溢出。修复仅调整浏览器夹具：120 个搜索后仍匹配的节点，
设置位置前检查真实页面和树列表均有溢出，按整页滚动将展开输出内的固定阅读锚点
置于视口内。等待滚动稳定和实际刷新完成后，严格比较正文、展开状态、活动节点、
搜索、筛选、页面／树滚动、阅读锚点及 URL。保留版本更新、损坏 HTML、503、恢复及
不导航断言；没有修改生产布局、refreshSilent、黄金预期或状态语义。
smoke 的日志和成功报告新增实际 Node、Playwright、浏览器版本和可执行文件路径。

| 本次命令／诊断 | 结果与原始记录 |
| --- | --- |
| `/opt/toolchain/view-validation/python/bin/python -B scripts/run_view_checks.py --node /opt/toolchain/view-validation/node/bin/node --output /tmp/gh7-scroll-view-final` | 退出0；26项 Python、10项 JS，无 skip；实际 self_check、6份 HTML、完整迁移比较及8种入口通过；`/tmp/gh7-scroll-view-final.log` 和输出目录 `code-check-result.json`；初次同样通过的记录保留在 `/tmp/gh7-scroll-view.log`、`/tmp/gh7-scroll-view/` |
| `PATH=/opt/toolchain/view-validation/node/bin:/opt/toolchain/view-validation/python/bin:$PATH VIEW_TEST_SOURCE_PACKAGE=/opt/symphony/scripts/view_validation/source/view-source.zip VIEW_TEST_SOURCE_MANIFEST=/opt/symphony/scripts/view_validation/source/source-manifest.json /opt/toolchain/view-validation/python/bin/python -B -m unittest discover -s scripts/view_validation/tests -v` | 退出0；24项、无 skip；`/tmp/gh7-scroll-validator.log` |
| `RUN_MIX_INTEGRATION=1 python3 -B -m unittest discover -s scripts/tests -v` | 退出0；55项、0失败，原2项宿主隔离集成 skip（未设置 `SYMPHONY_SANDBOX_INTEGRATION=1`，要求预配置的宿主 runner）；`/tmp/gh7-scroll-scripts.log` |
| `/opt/toolchain/view-validation/node/bin/node --check view/tests/browser-refresh.cjs`、同命令检查 `browser-smoke.cjs`，`git diff --check` | 退出0；语法检查不代表 UI 断言通过 |
| `/opt/toolchain/view-validation/node/bin/node view/tests/browser-fixture.cjs /tmp/gh7-scroll-view/fixture` | 退出1；`Cannot find module 'playwright/package.json'`，`MODULE_NOT_FOUND`；`/tmp/gh7-scroll-browser.log`。本次离线沙箱没有 Playwright／Chromium，完整 UI 断言未执行，CI浏览器步骤未能通过本轮验证；没有降级或跳过后报告通过 |
| `python3 /opt/symphony/scripts/check_isolated.py candidate` | 退出0；format、specs、Credo、652项 ExUnit（0失败、6项原 live skip）、100%覆盖率、Dialyzer及 escript构建通过；`/tmp/gh7-scroll-candidate.log`、`.check-evidence/candidate-ey6h20eb/`；未修改有效检查政策 |
| `python3 /opt/symphony/scripts/check_isolated.py baseline` | 首轮退出10：652项、1失败、6项原 live skip；原命令完整复跑退出0：652项、0失败、6项原 live skip。日志 `/tmp/gh7-scroll-baseline.log`、`/tmp/gh7-scroll-baseline-rerun.log`；工具产物 `.check-evidence/baseline-6pdr7kbm/`、`.check-evidence/baseline-dr4lrmhz/` |

baseline 首轮是既有 `MvpExternalTaskTest` 的默认 tracker 绑定断言（419行用例、
427行断言）：预期 `{:error, :tracker_binding_mismatch}`，实际
`{:error, {:mvp_awaiting_external, "bound"}}`。本轮没有改 Elixir、冻结测试、seed、
过滤、覆盖率或跳过政策；完整复跑通过，不抹去首轮失败。6项 live E2E 的原显式启用
条件保持不变，不计作真实外部平台通过；宿主隔离集成的2项 skip 同样保留。

Python、Node 和 viewer 仍为本页记录的预置固定版本。Playwright 1.62.1 与配套 Chromium
仍是 README／CI 所要求且待实际通过的组合，没有以系统 Chrome 的旧部分结果替代。
GH7-A11、A12、A16、A17 的完整浏览器复验保留未完成：由获准的 View 验收负责人在
准确新候选 SHA 上运行完整 fixture／smoke，并在 Windows＋WSL 上复验真实采集与
完整浏览器流程，保存版本、命令、原始结果、日志及未执行项。缺依赖、渲染失败和
断言失败仍必须非零退出。历史实机采集及局部交互证据不代表修复候选的全部通过。

GH7-A15 单独保留实施前来源远端核查的时序缺口。所有者须提供当时的带时间记录，
或明确决定是否接受迟补核查及其范围；本轮离线核对固定来源不补造历史事实，
也没有把评审材料当作例外授权。本轮不提交、push、PR、合并、部署或升级服务。

## 默认 tracker 绑定测试修复续跑（2026-10-02）

本轮只读 base HEAD 为 `b6c07277c60fe9ab00c1b5acb7648d0bb6a72d39`；修改未提交，
最终候选 SHA 仍由控制器冻结。只读失败日志 `/evidence/round-4/check-1.log`
显示唯一失败为 `MvpExternalTaskTest` 的默认 tracker 绑定断言，其他门禁通过。

原因是该测试用 `WorkflowStore` 进程存在推断 tracker 必然不匹配，而 store 可保留
此前测试最后有效的匹配配置。修复只改变该测试：明确加载匹配和不匹配配置，
分别断言继续恢复及拒绝恢复，核对实际传给执行器的 tracker，且每次调用都不改变
配置路径、进程和不匹配配置。退出时恢复原环境和缓存状态，不依赖测试顺序。
没有改变生产绑定逻辑、覆盖率、检查配置、跳过条件或控制器证据。

负向诊断在 `/tmp/gh7-binding-old-probe_test.exs` 私有副本中保留旧断言，仅预置匹配
配置，稳定复现原错误（1项失败、22项按定向命令排除）；日志为
`/tmp/gh7-binding-old-probe.log`。这是旧测试假设错误的证据，不是通过报告。
新回归同时检查匹配与不匹配，不把原拒绝断言改成宽泛错误或无条件通过。

| 本次命令／诊断 | 结果与记录 |
| --- | --- |
| `MIX_ENV=test HEX_OFFLINE=1 mix test test/symphony_elixir/mvp_external_task_test.exs --seed 699831`（`elixir/`内） | 修复后23项、0失败；`/tmp/gh7-binding-targeted-final.log`。初次新增测试错误地预期绑定校验先于tracker读取，定向运行失败；按既有读取顺序修正该断言后复跑，不改变生产顺序 |
| `/opt/toolchain/view-validation/python/bin/python -B scripts/run_view_checks.py --node /opt/toolchain/view-validation/node/bin/node --output /tmp/gh7-binding-view` | 退出0；26项Python、10项JS、实际self_check及6份HTML、完整迁移比较、8种入口通过，无skip；`/tmp/gh7-binding-view.log`及输出目录 |
| `RUN_MIX_INTEGRATION=1 python3 -B -m unittest discover -s scripts/tests -v` | 退出0；55项，原2项宿主隔离集成skip；本环境无`/sys/fs/cgroup`及授权宿主runner，未改启用条件；`/tmp/gh7-binding-scripts.log` |
| `PATH=/opt/toolchain/view-validation/node/bin:/opt/toolchain/view-validation/python/bin:$PATH VIEW_TEST_SOURCE_PACKAGE=/opt/symphony/scripts/view_validation/source/view-source.zip VIEW_TEST_SOURCE_MANIFEST=/opt/symphony/scripts/view_validation/source/source-manifest.json /opt/toolchain/view-validation/python/bin/python -B -m unittest discover -s scripts/view_validation/tests -v` | 退出0；24项、无skip；`/tmp/gh7-binding-validator.log` |
| 固定包及manifest摘要、36个原始来源文件、3个浏览器脚本Node语法、`git diff --check` | 通过；仅已登记的6个来源文件有迁移差异，无真实配置、数据库或嵌套Git |
| `/opt/toolchain/view-validation/node/bin/node view/tests/browser-fixture.cjs /tmp/gh7-binding-view/fixture` | 退出1：`Cannot find module 'playwright/package.json'`，`MODULE_NOT_FOUND`；`/tmp/gh7-binding-browser.log`；浏览器UI断言未执行 |

本节各项通过仅为工作区自检，不替代正式候选验证或独立Review。来源实施前远端
核查、准确候选上的浏览器交互、Windows＋WSL真实采集及控制器启停隔离继续待
所有者或获准负责人提供外部验收；本轮没有提交、发布、安装或切换运行服务。

## 保留修复后的本会话复验（2026-10-02）

本次续跑保留上述未提交的 tracker 测试修复和验证记录；只读 HEAD 仍为
`b6c07277c60fe9ab00c1b5acb7648d0bb6a72d39`，它不是包含未提交修复的候选 SHA。
生成页滚动修复已经存在于工作区，没有重复改动展示实现或黄金预期。
本节记录本会话实际执行结果，最终不可变候选及独立 Review 仍由控制器负责。

| 本次命令／诊断 | 结果与记录 |
| --- | --- |
| `/opt/toolchain/view-validation/python/bin/python -B scripts/run_view_checks.py --node /opt/toolchain/view-validation/node/bin/node --output /tmp/gh7-resume-view` | 退出0；26项 Python、10项 JS，无 skip；实际 self_check、6份 HTML、完整迁移结果比较、8种启动入口通过。日志 `/tmp/gh7-resume-view.log`，报告 `/tmp/gh7-resume-view/code-check-result.json` |
| `RUN_MIX_INTEGRATION=1 python3 -B -m unittest discover -s scripts/tests -v` | 退出0；55项、0失败，原2项宿主 sandbox 集成 skip，要求 `SYMPHONY_SANDBOX_INTEGRATION=1` 和预配置宿主 runner。日志 `/tmp/gh7-resume-scripts.log` |
| `PATH=/opt/toolchain/view-validation/node/bin:/opt/toolchain/view-validation/python/bin:$PATH VIEW_TEST_SOURCE_PACKAGE=/opt/symphony/scripts/view_validation/source/view-source.zip VIEW_TEST_SOURCE_MANIFEST=/opt/symphony/scripts/view_validation/source/source-manifest.json /opt/toolchain/view-validation/python/bin/python -B -m unittest discover -s scripts/view_validation/tests -v` | 退出0；24项、无 skip；日志 `/tmp/gh7-resume-validator.log` |
| `/opt/toolchain/view-validation/node/bin/node view/tests/browser-fixture.cjs /tmp/gh7-resume-view/fixture` | 退出1，`Cannot find module 'playwright/package.json'`（`MODULE_NOT_FOUND`）；日志 `/tmp/gh7-resume-browser.log`。环境未提供 Playwright／Chromium，完整 UI 断言未执行；未安装依赖、替换浏览器组合或降低门禁 |
| `python3 /opt/symphony/scripts/check_isolated.py baseline` | 退出0；652项 ExUnit、0失败、6项原 live skip，seed 337123；日志 `/tmp/gh7-resume-baseline.log`，工具产物 `.check-evidence/baseline-vbt_a_02/` |
| `python3 /opt/symphony/scripts/check_isolated.py candidate` | 退出0；format、specs、Credo、652项 ExUnit（0失败、6项原 live skip，seed 310026）、100%覆盖率、Dialyzer和 escript 构建通过；日志 `/tmp/gh7-resume-candidate.log`，工具产物 `.check-evidence/candidate-jdu7eecw/`；candidate／baseline 的有效政策均无变化 |

固定包 SHA256 与迁移记录一致，来源 manifest 与预置 manifest 字节一致；36个源码
文件齐全，仅已登记的6个来源文件有差异，无嵌套 Git。包内 `SOURCE_MANIFEST.json`
为制品元数据，在仓库中保存为 `view/docs/source-manifest.json`。
实际版本为 Python 3.12.3、Node v24.19.0、codex-transcript-viewer 0.5.0；
三个浏览器脚本通过 Node 语法检查，但语法检查不能替代浏览器验收。

GH7-A11／A12／A16／A17 的完整浏览器及 CI 浏览器步骤仍未通过本轮验证；
需要在准确修复候选上验证 README／CI 指定的 Playwright 1.62.1 与配套 Chromium，
并由获准负责人复验 Windows＋WSL 真实采集和完整浏览器流程。GH7-A15 的实施前
远端核查历史记录或所有者例外决定仍缺失；本会话不补造历史事实或实机证据。

## 严格候选库存失败后的日志回归（2026-10-02）

本会话 base HEAD 为 `f5e68a9a964e6c7c1ca32440bccee7d2f462a2f1`，修改未提交。
只读 `/evidence/round-5/check-3.log` 在执行 View suite 前拒绝了候选，具体原因是
`disk file list differs from HEAD, including ignored files`。当前工作区已有
`elixir/log/`、预置依赖及未提交的测试日志配置调整；日志未列出差异文件，不能断言
启动日志是上次失败的唯一来源。没有改库存校验、忽略额外文件或删除已有产物／证据。

保留并验证 `elixir/config/config.exs` 中的修复：只在 test 环境将应用启动日志放入
每次 VM 调用独有的系统临时目录，正常退出时先释放 disk_log handler 再清理轮转文件。
新增 `scripts/tests/test_mix_startup_logs.py` 使用无第三方依赖的真实 Mix 应用，加载实际
配置和实际 LogFile 模块，在 test_helper 运行前写入并同步日志；断言正常测试退出、
helper 抛错和随后重试均不在项目目录写日志、各调用路径不同且目录完全清理。
另实际加载 dev 配置，确认原日志默认值保持不变。不宣称硬杀 VM 的 at_exit 会执行。
指定隔离门禁继续使用冻结配置；本次候选配置由上述真实 Mix 回归单独覆盖。

| 本会话命令／诊断 | 结果／原始记录 |
| --- | --- |
| `/opt/toolchain/view-validation/python/bin/python -B scripts/run_view_checks.py --node /opt/toolchain/view-validation/node/bin/node --output /tmp/gh7-repair-code-checks` | 退出0；26项 Python、10项 JS，无 skip；实际 self_check、6份 HTML、完整迁移比较、8种入口通过；报告为输出目录的 `code-check-result.json` |
| `RUN_MIX_INTEGRATION=1 python3 -B -m unittest discover -s scripts/tests -p test_mix_startup_logs.py -v` | 退出0；2项新回归通过；`/tmp/gh7-repair-log-targeted.log`。首轮夹具错误地要求 Mix 自身的 lock/pubsub 临时目录也不存在，修正为核对本次日志目录及全部轮转文件后通过 |
| 在私有 Mix 项目中将配置替换为 HEAD 的旧配置，再运行同一日志回归 | 三次调用均被路径断言拒绝，日志实际写入私有项目的 `log/`；`/tmp/gh7-repair-old-config-probe.log`。这是预期失败的负向诊断，不是候选失败或旧配置通过声明 |
| `RUN_MIX_INTEGRATION=1 python3 -B -m unittest discover -s scripts/tests -v` | 退出0；57项、0失败，原2项宿主隔离集成 skip；`/tmp/gh7-repair-scripts-final.log` |
| `PATH=/opt/toolchain/view-validation/node/bin:/opt/toolchain/view-validation/python/bin:$PATH VIEW_TEST_SOURCE_PACKAGE=/opt/symphony/scripts/view_validation/source/view-source.zip VIEW_TEST_SOURCE_MANIFEST=/opt/symphony/scripts/view_validation/source/source-manifest.json /opt/toolchain/view-validation/python/bin/python -B -m unittest discover -s scripts/view_validation/tests -v` | 退出0；24项、无 skip；包括损坏报告、额外忽略文件、脏候选及缺依赖拒绝回归 |
| `MIX_ENV=test mix format --check-formatted config/config.exs`（elixir 内）、三个浏览器脚本的 Node `--check`、`git diff --check`、固定来源核对 | 退出0；36个原始文件齐全，仅已登记的6个来源文件有差异；manifest 与预置文件字节一致，无嵌套 Git |
| `/opt/toolchain/view-validation/node/bin/node view/tests/browser-fixture.cjs /tmp/gh7-repair-code-checks/fixture` | 退出1：`Cannot find module 'playwright/package.json'`，`MODULE_NOT_FOUND`；UI断言未执行。没有安装依赖、替换浏览器组合或跳过失败；完整 CI View job 尚未在本环境通过 |

首轮并行的 candidate 和 baseline 隔离检查均失败，工具原始产物分别保留在
`.check-evidence/candidate-guazb8z5/` 和 `.check-evidence/baseline-env8lyev/`。
candidate 为打包入口创建线程失败：`Resource temporarily unavailable (11)`，退出1；
baseline 为 WatchdogTest 的启动状态 `process` 为 nil，退出10。随后改为串行完整
复跑原命令，不修改测试、超时、过滤、覆盖率或冻结政策；复跑结果追加如下。

| 串行完整复跑 | 结果／记录 |
| --- | --- |
| `python3 /opt/symphony/scripts/check_isolated.py candidate` | 退出0；format、specs、Credo、652项 ExUnit（0失败、6项原 live skip，seed 7031）、100%覆盖率、Dialyzer及 escript 构建通过；`/tmp/gh7-repair-candidate-rerun.log`、`.check-evidence/candidate-zedhnhp0/` |
| `python3 /opt/symphony/scripts/check_isolated.py baseline` | 退出0；652项 ExUnit、0失败、6项原 live skip，seed 117777；`/tmp/gh7-repair-baseline-rerun.log` |

本轮环境与外部停点未改变：Playwright 1.62.1／配套 Chromium 完整浏览器及 CI 验证、
Windows＋WSL 准确新候选的实机复验、GH7-A15 历史记录或所有者明确例外决定仍缺失。
原2项宿主隔离与6项真实平台 live 测试的 skip 不算通过。干净已提交候选的正式 View
检查及独立 Review 仍归控制器；未运行 routing marker 作为宿主检查，也未改控制器证据。
本会话没有提交、发布、创建 PR、合并、部署或切换服务，不宣布 GH-7 全部验收完成。

## 第6轮库存拒绝后的产物生命周期复验（2026-10-02）

本次离线任务副本的 base HEAD 为 `63d47b7b33cf4520b171615a04b3b77514254e7a`。
修复未提交，该 SHA 不是含本次修复的候选；最终身份和独立 Review 仍由控制器负责。
只读 `/evidence/round-6/check-3.log` 在会话检查前拒绝了候选库存。
本次实际核实源码目录有未跟踪、被忽略的 `elixir/log/symphony.log.1`、`.idx`、`.siz`，
分别为0、18、13字节。先保存逐文件 SHA256、大小、base HEAD 和范围说明，并核对
独立副本字节，再将原目录移至 `/tmp/gh7-retained-logs-069cnoc_/original-log/`；副本和
manifest 同在该归档目录。仅移动本次可丢弃任务副本中的产物，没有删除真实服务数据、
日志或控制器证据，也没有放宽库存检查。

增强 `scripts/tests/test_mix_startup_logs.py`：包含遗留轮转文件的项目和全新项目均
执行成功、helper失败、应用启动失败及连续重试；构建与日志放在独立临时目录。
逐次比较源码完整文件清单及字节，证明测试不修改旧日志、不增加额外产物；再核对
明确保存并移出遗留文件后的清单，重复执行证明清洁候选保持清洁。非test配置实际
启动并写入原默认 `log/symphony.log`，退出后保留轮转文件。没有增加生产自动清理。
生成页120节点、document滚动、可见阅读锚点及非零位置的严格断言保持不变。
固定浏览器夹具只增加将截图／smoke报告写入夹具结果目录，真实smoke默认路径保留。

环境仍为离线 Linux；Python 3.12.3、Node v24.19.0、viewer 0.5.0、Elixir 1.19.5／
OTP 28.5。以下是工作区自检，不是正式候选通过报告。

| 本次命令／诊断 | 结果、退出码与原始记录 |
| --- | --- |
| `RUN_MIX_INTEGRATION=1 python3 -B -m unittest discover -s scripts/tests -p test_mix_startup_logs.py -v` | 退出0；3项真实Mix回归通过；`/tmp/gh7-lifecycle-targeted.log` |
| `RUN_MIX_INTEGRATION=1 python3 -B -m unittest discover -s scripts/tests -v` | 退出0；58项，56通过、原2项宿主sandbox集成skip；`/tmp/gh7-lifecycle-scripts.log` |
| `/opt/toolchain/view-validation/python/bin/python -B scripts/run_view_checks.py --node /opt/toolchain/view-validation/node/bin/node --output /tmp/gh7-lifecycle-view-final` | 退出0；26项Python、10项JS，无skip；self_check、6份实际HTML、完整迁移结果比较和8种入口通过；`/tmp/gh7-lifecycle-view-final.log`、输出目录的`code-check-result.json`。调整浏览器输出前同样通过的结果保留在`/tmp/gh7-lifecycle-view/` |
| `PATH=/opt/toolchain/view-validation/node/bin:/opt/toolchain/view-validation/python/bin:$PATH VIEW_TEST_SOURCE_PACKAGE=/opt/symphony/scripts/view_validation/source/view-source.zip VIEW_TEST_SOURCE_MANIFEST=/opt/symphony/scripts/view_validation/source/source-manifest.json /opt/toolchain/view-validation/python/bin/python -B -m unittest discover -s scripts/view_validation/tests -v` | 退出0；24项、无skip；`/tmp/gh7-lifecycle-validator.log` |
| 在私有项目去掉test日志重定向，运行相同回归 | 五次调用的路径断言及最终残留断言均拒绝旧配置，预期6个断言失败；确认脚本退出0；`/tmp/gh7-lifecycle-old-config-confirmed.log`。首次诊断包装器漏计最终残留断言，退出1的原记录保留在`/tmp/gh7-lifecycle-old-config.log`；没有候选回归失败 |
| 浏览器输出位置诊断（临时Playwright替身故意使launch失败） | 退出0；实际smoke及fixture子进程均将输出放在指定外部目录，源码清单及内容不变；原失败仍非零且报告`passed:false`；`/tmp/gh7-lifecycle-browser-output.log`。只证明输出生命周期，不计作任何UI断言通过 |
| 三个浏览器脚本的Node `--check`、固定包verify、manifest及36个来源文件、`git diff --check` | 通过；迁移差异仍为已登记的6个来源文件。扣除预置deps和指定工具生成的`.check-evidence`后，磁盘无额外源码文件；不把该诊断当作正式已提交候选认证 |
| `/opt/toolchain/view-validation/node/bin/node view/tests/browser-fixture.cjs /tmp/gh7-lifecycle-view-final/fixture` | 退出1：`Cannot find module 'playwright/package.json'`、`MODULE_NOT_FOUND`；`/tmp/gh7-lifecycle-browser-final.log`。完整UI断言未执行，未用替身、语法检查或数据等价替代浏览器验收 |
| `python3 /opt/symphony/scripts/check_isolated.py candidate` | 退出0；format、specs、Credo、652项ExUnit（0失败、6项原live skip，seed 225141）、100%覆盖率、Dialyzer及escript构建通过；`/tmp/gh7-lifecycle-candidate.log`、`.check-evidence/candidate-0h20qcj5/` |
| `python3 /opt/symphony/scripts/check_isolated.py baseline` | 退出0；652项ExUnit、0失败、6项原live skip，seed 44274；`/tmp/gh7-lifecycle-baseline.log`、`.check-evidence/baseline-3diuoltg/`；candidate及baseline均本会话串行执行，无需重跑，冻结政策未改变 |

Playwright 1.62.1／配套Chromium没有在此沙箱中预置，完整浏览器检查明确失败于
依赖加载；未修改依赖要求或检查政策。GH7-A11／A12／A16／A17的真实浏览器与
Windows＋WSL新候选复验、控制器启停隔离及只读外部状态对照、GH7-A15的实施前
远端核查记录或所有者例外决定仍未完成。6项live及2项宿主集成skip不算通过。
本轮未运行routing marker代替可信入口，没有提交、发布、PR、安装或服务切换。

## 外部复检计时失败后的迁移回归（2026-10-03）

本会话 base HEAD 为 `8148011a335e21171baa3e7c2a015b8bcd04a917`；新增修改未提交，
该 SHA 不是包含本轮回归的最终候选。环境仍是离线 Linux，Python 3.12.3、Node
24.19.0、viewer 0.5.0、Elixir 1.19.5／OTP 28.5。

只读外部复检日志 `/evidence/operator-rechecks/gh7-external-v2-1791007253535111464/check-1.log`
显示原看门狗打包测试耗时1606ms、上限1600ms；其余阶段通过。本轮 candidate
完整检查未复现该失败；没有修改看门狗实现、计时断言、覆盖率或冻结检查政策。

新增一项 View 回归：一个配置仍在采集时，另一个配置失败并重试，逐次断言失败及
重试脚本已清理、在途脚本字节不变、各配置结果正确、三次路径不同，最终无残留。
在仓库外私有副本移除清理语句后，同一用例明确拒绝残留脚本；不是仅以不抛异常通过。
原始来源、迁移黄金预期及展示语义保持原样。

| 本次命令／诊断 | 结果／原始记录 |
| --- | --- |
| `/opt/toolchain/view-validation/python/bin/python -I -B view/tests/test_migration.py -v` | 退出0；11项迁移回归；`/tmp/gh7-overlap-targeted.log` |
| `/opt/toolchain/view-validation/python/bin/python -B scripts/run_view_checks.py --node /opt/toolchain/view-validation/node/bin/node --output /tmp/gh7-overlap-view` | 退出0；27项Python、10项JS，无skip；实际self_check、6份HTML完整比较及8种入口通过；`/tmp/gh7-overlap-view.log`及输出目录的`code-check-result.json` |
| 私有副本移除临时脚本清理，再运行新增用例 | 诊断退出0；用例预期失败于残留脚本断言；`/tmp/gh7-overlap-negative.log`；未改工作区实现 |
| `PATH=/opt/toolchain/view-validation/node/bin:/opt/toolchain/view-validation/python/bin:$PATH VIEW_TEST_SOURCE_PACKAGE=/opt/symphony/scripts/view_validation/source/view-source.zip VIEW_TEST_SOURCE_MANIFEST=/opt/symphony/scripts/view_validation/source/source-manifest.json /opt/toolchain/view-validation/python/bin/python -B -m unittest discover -s scripts/view_validation/tests -v` | 退出0；24项，无skip；`/tmp/gh7-overlap-validator.log` |
| `/opt/toolchain/view-validation/node/bin/node --test scripts/view_validation/tests/browser_binding.test.cjs` | 退出0；16项，无skip；`/tmp/gh7-overlap-browser-binding.log` |
| `RUN_MIX_INTEGRATION=1 python3 -B -m unittest discover -s scripts/tests -v` | 退出0；58项，56通过、原2项宿主隔离集成skip；Mix真实集成已执行；`/tmp/gh7-overlap-scripts.log` |
| 固定包verify、逐文件来源摘要、三个浏览器脚本Node语法检查、Python AST与`git diff --check` | 通过；36个原始文件及manifest核对通过，仅原已登记的6个来源文件有迁移差异，无真实配置或嵌套Git |
| `python3 /opt/symphony/scripts/check_isolated.py candidate` | 退出0；全部6阶段通过，652项ExUnit、0失败、6项原live skip，seed 424187，100%覆盖率；`/tmp/gh7-current-candidate.log`、`.check-evidence/candidate-zbrhjyzb/` |
| `python3 /opt/symphony/scripts/check_isolated.py baseline` | 退出0；652项ExUnit、0失败、6项原live skip，seed 840468；`/tmp/gh7-current-baseline.log`、`.check-evidence/baseline-phypftax/`；与candidate串行运行，无需重跑 |
| `/opt/toolchain/view-validation/node/bin/node view/tests/browser-fixture.cjs /tmp/gh7-overlap-view/fixture` | 退出1；`Cannot find module 'playwright/package.json'`、`MODULE_NOT_FOUND`；`/tmp/gh7-overlap-browser.log`；UI断言未执行 |

完整浏览器及CI浏览器验证、Windows＋WSL真实采集、真实控制器启停隔离和只读状态
对照、实施前远端核查历史记录或所有者明确例外决定仍待外部验收。当前环境没有
`wsl.exe`，也没有宿主集成需要的`/sys/fs/cgroup`。原6项live测试需要真实平台凭据，
原2项宿主隔离集成需要获准的cgroup与挂载，均不算通过。上述代码检查不替代这些验收，
候选冻结及独立Review仍归控制器。本轮未提交、发布、创建PR、安装或切换服务。
