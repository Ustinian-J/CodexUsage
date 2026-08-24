# CodexS

CodexS（Codex Secretary）是一个本地优先的 macOS 菜单栏与 Windows 托盘应用，用圆环/双条展示 Codex 5 小时与每周额度余量，并统计今日、近 7 天和累计 token。它还能提示任务运行、完成和未读状态，主窗口会把本机 Codex 对话和自动化任务整理成今日任务看板。

> 当前版本为 `0.4.0`。[项目仓库](https://github.com/Ustinian-J/CodexS)使用干净的 GitHub Intel 与 Apple Silicon macOS runner 构建验证；在 Release 发布前，请仅从源码或当前仓库的 CI 产物安装。

## 功能

- 菜单栏实时显示 5 小时、7 天额度圆环，圆环中央显示剩余百分比。
- 菜单栏右侧使用单一状态徽章：红色播放符号表示执行中，绿色勾表示空闲，灰色横线表示监控不可用；未读完成以独立黄色菱形角标闪烁，因此“执行中 + 未读”可同时表达。弹窗内保留带文字说明的红黄绿灯。
- 增量读取 Codex 本机会话事件，在任务完成或中断后发送可选的 macOS 本地通知，并提供“全部已读”清除黄灯。
- 可选监听 SSH 远程项目：在设置中填写 `~/.ssh/config` 主机别名，再点击“刷新”启动监听；Mac 与 Windows 版都会使用系统 OpenSSH，显示 `@主机`、项目名、运行/完成/中断状态。每轮最多连接 3 次，失败后停止，直到再次手动刷新。
- 展示额度重置时间，并支持剩余量/已用量口径和多种菜单栏密度。
- 汇总单日、近 7 天和累计 token，细分未缓存输入、缓存输入与输出。
- 从本机 Codex 线程和启用中的 automation 生成今日任务看板；今日对话进度按 `今日已归档对话 / 今日对话任务总数` 估算，定时任务不计入完成率。
- 比较额度窗口已过时间与已用比例，标记“宽裕 / 正常 / 偏快”；该提示只反映使用节奏，不预测实际可用 token。
- 可选开启 20%、10%、5% 低额度本地通知；默认关闭，每个额度重置周期的每个阈值最多提醒一次。
- 读取官方 `rateLimitResetCredits.availableCount` 和逐项 `expiresAt`，展示可用重置次数与每项到期时间。
- 账户周期页集中展示 5 小时、7 天额度重置时间、套餐、重置项明细和订阅到期倒计时。
- 订阅到期日为显式启用的本地记录；当前官方 `account/read` schema 不提供该字段，日期不会上传。
- 菜单栏弹窗可直接切换 Codex / Claude Code，每次只显示一个运行时；Codex 的额度重置与账户信息不会混入 Claude Code 视图。
- 菜单栏小页面用独立两行同时展示 5h 与 7d 下次重置时间；任务动态卡片显示运行数、未读数和最近完成；底部“打开主界面”只打开 CodexS 主窗口。
- 菜单栏的数字和进度填充默认都表示剩余额度，含义与手机电量一致；胶囊底色和描边用于和其他 App 状态项分隔。
- 未在本机显式设置订阅到期日时，界面会完全忽略该字段，不联网查询也不做推断。
- 展示用量趋势、项目排行、工具与 Skill 使用统计。
- 可选读取 Claude Code 本机统计；在设置中隐藏 Claude Code 后，后台不会继续扫描 `~/.claude`。
- `Command + U` 默认显示或隐藏主窗口，可在设置中修改。
- Windows x64 版是一个无第三方依赖的自包含 EXE，可免管理员安装到当前用户；托盘图标与 Mac 使用相同的双额度条、任务状态徽章和未读角标。

## 安全与隐私

这个仓库没有直接 fork 上游历史，而是从固定提交 `cc800ff7afa254237fd088cb63004390d6492a99` 逐文件审计后，以白名单方式导入当前源码。完整证据、历史风险和排除项见 [上游安全审计](docs/SECURITY_AUDIT.md)，来源与许可证见 [UPSTREAM.md](UPSTREAM.md)。

- 无第三方 Swift、npm、Python、CocoaPods 或预编译框架依赖。
- 不读取 `~/.codex/auth.json`、Keychain、浏览器 cookie 或云凭据；启用远程监听时由系统 OpenSSH 使用现有配置，CodexS 自身不打开、复制或保存 SSH key、密码。
- 不上传 usage、对话、任务、路径或账户数据。
- 任务监控只提取开始、完成和中断所需字段；即使日志行包含完成回复正文 `last_agent_message`，也会忽略且绝不保存、显示、通知或上传。
- Skill 静态统计只读取批准的本机 Skill 根目录内、大小不超过 1 MiB 的普通 `SKILL.md` 文件；拒绝符号链接、非普通文件和越界路径。
- 调试日志仅在显式设置 `CODEXUSAGE_DEBUG=1` 时写入系统提供的当前用户临时目录，日志文件拒绝符号链接并限制为当前用户读写。
- 唯一运行时公网请求是可选的 GitHub Release 元数据 `GET`；自动检查默认关闭。
- 不静默下载、替换或执行更新；下载页面只能由用户主动打开。
- CI 仅使用 GitHub 官方 Action，固定到完整提交哈希，权限为 `contents: read`，不读取 repository secrets。
- `test-source-security.sh` 持续拒绝凭据读取、网络写请求、下载器、登录持久化、第三方依赖清单和预编译库；SSH 仅允许出现在经过固定参数审计的远程任务监听器中。
- 远端解析器仅在 SSH 会话内存中运行，不安装服务、不写远端文件；只回传任务事件白名单元数据，绝不回传提示词、回答正文、工具参数、工具输出或 `last_agent_message`。
- 低额度通知完全由 macOS 本地通知中心发送，只包含额度窗口、剩余百分比和重置时间。
- 任务完成通知同样完全本地发送，只显示结果类型，不包含任务标题、项目路径或对话正文。
- 每个 DMG 同时生成 SHA-256 文件，安装前应先校验。

静态审计能显著降低风险，但不能构成“永远无毒”的数学证明。发布前仍会在干净 runner 构建、检查签名与架构、挂载检查 DMG，并对最终产物重新计算哈希。安全报告方式和实际读取范围见 [SECURITY.md](SECURITY.md)。

## 数据来源

CodexS 在本机读取：

- `codex app-server` 的账户、额度和 usage 响应。
- `~/.codex/state_5.sqlite` 的线程与 token 元数据。
- `~/.codex/sessions/**/rollout-*.jsonl` 与归档 session 中的 token/tool 元数据，以及任务开始、完成和中断事件。
- `~/.codex/automations/**/automation.toml` 的启用状态与任务元数据。
- 仅在 Claude Code Runtime 可见时读取 `~/.claude/` 本机 usage/task 元数据。

为保留旧版本设置与缓存，CodexS 继续使用 `com.ustinianj.codexusage` bundle ID、`CodexUsage.*` 设置键和 `~/Library/Caches/CodexUsage/` 缓存目录。应用不需要也不读取 Codex 登录 token。

## 安装

从 GitHub Release 或已通过的 GitHub Actions 构建下载与你的 Mac 匹配的文件：

- Apple Silicon：`CodexS-<version>-mac-arm64.dmg`
- Intel：`CodexS-<version>-mac-x86_64.dmg`
- Windows x64：`CodexS-<version>-windows-x64.exe`

先校验下载文件：

```sh
shasum -a 256 -c CodexS-<version>-mac-<arch>.dmg.sha256
```

Windows 可在 PowerShell 中用 `Get-FileHash CodexS-<version>-windows-x64.exe -Algorithm SHA256` 与 `.sha256` 文件比对；双击 EXE 后可选择安装或仅运行一次。

然后打开 DMG，将 `CodexS.app` 拖入 `Applications`。如果之前安装过 `CodexUsage.app`，请在确认 CodexS 正常运行后手动移除旧应用，避免两个相同 bundle ID 的应用并存。当前个人测试构建为 ad-hoc 签名；首次打开如果被 Gatekeeper 阻止，请在 Finder 中右键应用选择“打开”，或在“系统设置 > 隐私与安全性”中选择“仍要打开”。

## 运行要求

- macOS 13 或更新版本。
- 本机已安装并登录 Codex。
- Codex 至少使用过一次，以生成本机状态数据库。
- Windows 版监控原生 Windows Codex 会话，也可通过 SSH 监听装有 Python 3 的 Linux/macOS 远程主机；仅存在于本机 WSL 且未通过 SSH 配置的会话暂不支持。

## 从源码构建

需要与当前 macOS SDK 匹配的 Xcode 或 Xcode Command Line Tools：

```sh
make build
make run
```

常用检查：

```sh
make probe
make test-ci-security
make test-macos-compatibility
```

打包当前架构：

```sh
make release
```

显式构建 Intel 目标：

```sh
make release-intel
# 等价的底层覆盖方式：
make clean release TARGET_TRIPLE="x86_64-apple-macos13.0"
```

签名、公证和完整发布验证见 [DISTRIBUTION.md](DISTRIBUTION.md)。

## 非官方声明

CodexS 不是 OpenAI 官方产品。Codex 额度接口提供滚动窗口百分比与重置时间，不提供绝对配额数量，因此应用显示的是剩余百分比。

## License

MIT，见 [LICENSE](LICENSE)。本项目包含来自 [shanggqm/codexU](https://github.com/shanggqm/codexU) 的 MIT 许可代码，并保留原始版权声明。
