# CodexUsage

CodexUsage 是一个本地优先的 macOS 菜单栏应用，用圆环展示 Codex 5 小时与每周额度余量，并统计今日、近 7 天和累计 token。主窗口还会把本机 Codex 对话和自动化任务整理成今日任务看板。

> 当前版本为 `0.1.0`。项目正在使用干净的 GitHub macOS Intel 环境完成首次构建验证；在 Release 发布前，请仅从源码或当前仓库的 CI 产物安装。

## 功能

- 菜单栏实时显示 5 小时、7 天额度圆环，圆环中央显示剩余百分比。
- 展示额度重置时间，并支持剩余量/已用量口径和多种菜单栏密度。
- 汇总单日、近 7 天和累计 token，细分未缓存输入、缓存输入与输出。
- 从本机 Codex 线程和启用中的 automation 生成今日任务看板；今日对话进度按 `今日已归档对话 / 今日对话任务总数` 估算，定时任务不计入完成率。
- 比较额度窗口已过时间与已用比例，标记“宽裕 / 正常 / 偏快”；该提示只反映使用节奏，不预测实际可用 token。
- 展示用量趋势、项目排行、工具与 Skill 使用统计。
- 可选读取 Claude Code 本机统计；不使用时不会影响 Codex 功能。
- `Command + U` 默认显示或隐藏主窗口，可在设置中修改。

## 安全与隐私

这个仓库没有直接 fork 上游历史，而是从固定提交 `cc800ff7afa254237fd088cb63004390d6492a99` 逐文件审计后，以白名单方式导入当前源码。完整证据、历史风险和排除项见 [上游安全审计](docs/SECURITY_AUDIT.md)，来源与许可证见 [UPSTREAM.md](UPSTREAM.md)。

- 无第三方 Swift、npm、Python、CocoaPods 或预编译框架依赖。
- 不读取 `~/.codex/auth.json`、Keychain、浏览器 cookie、SSH key 或云凭据。
- 不上传 usage、对话、任务、路径或账户数据。
- 唯一运行时公网请求是可选的 GitHub Release 元数据 `GET`；自动检查默认关闭。
- 不静默下载、替换或执行更新；下载页面只能由用户主动打开。
- CI 仅使用 GitHub 官方 Action，固定到完整提交哈希，权限为 `contents: read`，不读取 repository secrets。
- 每个 DMG 同时生成 SHA-256 文件，安装前应先校验。

静态审计能显著降低风险，但不能构成“永远无毒”的数学证明。发布前仍会在干净 runner 构建、检查签名与架构、挂载检查 DMG，并对最终产物重新计算哈希。安全报告方式和实际读取范围见 [SECURITY.md](SECURITY.md)。

## 数据来源

CodexUsage 在本机读取：

- `codex app-server` 的账户、额度和 usage 响应。
- `~/.codex/state_5.sqlite` 的线程与 token 元数据。
- `~/.codex/sessions/**/rollout-*.jsonl` 与归档 session 中的 token/tool 元数据。
- `~/.codex/automations/**/automation.toml` 的启用状态与任务元数据。
- 可选的 `~/.claude/` 本机 usage/task 元数据。

缓存只写入 `~/Library/Caches/CodexUsage/`。应用不需要也不读取 Codex 登录 token。

## 安装

从 GitHub Release 或已通过的 GitHub Actions 构建下载与你的 Mac 匹配的文件：

- Apple Silicon：`CodexUsage-<version>-mac-arm64.dmg`
- Intel：`CodexUsage-<version>-mac-x86_64.dmg`

先校验下载文件：

```sh
shasum -a 256 -c CodexUsage-<version>-mac-<arch>.dmg.sha256
```

然后打开 DMG，将 `CodexUsage.app` 拖入 `Applications`。当前个人测试构建为 ad-hoc 签名；首次打开如果被 Gatekeeper 阻止，请在 Finder 中右键应用选择“打开”，或在“系统设置 > 隐私与安全性”中选择“仍要打开”。

## 运行要求

- macOS 13 或更新版本。
- 本机已安装并登录 Codex。
- Codex 至少使用过一次，以生成本机状态数据库。

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

CodexUsage 不是 OpenAI 官方产品。Codex 额度接口提供滚动窗口百分比与重置时间，不提供绝对配额数量，因此应用显示的是剩余百分比。

## License

MIT，见 [LICENSE](LICENSE)。本项目包含来自 [shanggqm/codexU](https://github.com/shanggqm/codexU) 的 MIT 许可代码，并保留原始版权声明。
