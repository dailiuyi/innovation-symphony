# 2026-10-12 本机部署记录

来源：用户要求部署整个 innovation-symphony 并给网址，随后明确确认 Implement the plan。本次目标为 elma-ubuntu-pc 本机部署，不含真实任务派发。

固定源码提交 `119b13bdcd4a18cc69f45333e0421721d39fa52a`，来自当前 `codex/rootless-readiness-and-session-continuity` 分支。隔离源码包在 `.local/releases/119b13b-20261012`；采用固定 digest 的 Elixir 1.19 / OTP 28 Docker 镜像重新构建 escript。控制器沿用原 user unit，启动器改用容器；GitHub 凭据从现有 gh keyring 读取，经 stdin 传给进程，不写入工作流、镜像配置或日志。

现有 `.local`、旧运行配置、Erlang/Elixir 和 /opt rootless 桥缺失，不能恢复旧执行合同。新配置显式 `mvp.enabled=false`，只启动控制器观测和 View，未领取真实任务。旧模型管理及 HTTPS unit 所引用文件缺失，本次没有启动这两个服务。rootless、模型配置管理、HTTPS 与真实执行仍未恢复。

View 数据库、会话缓存继续使用原 view/data 与 view/build；在线 SQLite 备份和原 user unit 备份位于 `.local/deployment-20261012/backup`。原 /var/tmp 运行目录未找到，采集为 empty；数据库历史为 156 会话、7 尝试和 655 状态转移，不作为新执行证据。

验证：控制器首页、/api/v1/state、View 首页和 /api/bootstrap 均 HTTP 200；监听仅 127.0.0.1:4000 与 127.0.0.1:8613，两个服务 active/running、NRestarts=0，running/retrying/blocked 均零。页面人工视觉验收及真实任务验收未执行。构建成功不是完整门禁重跑。

网址：http://127.0.0.1:8613/（View）；http://127.0.0.1:4000/（控制器）。仅本机访问。清单为 `.local/deployment-20261012/deployment-result.json`。停止本次运行可执行 `systemctl --user stop innovation-symphony-controller.service innovation-symphony-view.service`；旧启动路径本来缺失，因此备份 unit 不构成可用旧版本回滚。没有删除或清理历史数据。

本次已保存、构建并启动核心服务；未 Git 提交、推送、合并或云部署。原 docs/OPERATIONS.md 未提交修改保留。
