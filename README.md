# QuotaBar · 额度看板

A native macOS menu bar app for tracking AI quotas and daily token usage across Codex, GLM, and Kimi.

一个常驻 macOS 菜单栏的 AI 额度与本机 token 用量看板。点击菜单栏图标即可查看，Dock 不显示图标。

## 功能

- **剩余额度**：Codex 周额度、智谱 Coding Plan 的 5 小时及周额度、Kimi Code 的 5 小时及会员共享月额度。
- **已用进度**：数字显示剩余百分比，进度条显示已用比例。例如剩余 92% 时，进度条填充 8%。
- **每日用量**：按系统时区汇总最近 30 天的本机记录，提供 7 天趋势、来源明细及 CSV 导出。
- **自动刷新**：额度默认每 5 分钟更新，本机用量每分钟检查；支持手动刷新、失败退避和过期标记。
- **菜单栏选项**：仅显示图标，或固定显示某项剩余额度；支持开机启动及可选的低额度提醒。
- **原生体验**：Swift、SwiftUI 与 AppKit，支持浅色和深色模式；统一卡片与状态标识，提供用量总览和可选日期的趋势图。

## 安装（推荐）

支持 **macOS 13 及以上**，安装包为 **Universal 2**，同时支持 Intel 和 Apple Silicon。直接安装无需 Xcode 或 Command Line Tools。

1. 下载 [QuotaBar 1.0.5 安装包](https://raw.githubusercontent.com/danchaofan/quotabar/main/installers/QuotaBar-1.0.5-universal.pkg)。
2. 如果已有旧版运行，先右键菜单栏图标，选择「退出额度看板」。
3. 双击 `.pkg`，按安装向导完成安装。应用固定安装到 `/Applications/额度看板.app`，安装过程可能要求管理员密码。
4. 在「应用程序」中打开「额度看板」。点击顶部菜单栏的柱状图图标使用；Dock 不显示图标。

升级会保留原有设置、账号连接和本机用量汇总。查询额度仍需要相应服务已有的本机登录或 Coding Plan API Key。点击面板外可收起，右键菜单栏图标可刷新、设置或退出；开机启动可在应用设置中开启。

当前应用使用 ad-hoc 签名，安装包尚未使用 Apple Developer 分发签名或公证。如果 macOS 拦截安装或首次启动，请确认下载来自本仓库，再到「系统设置 → 隐私与安全性」选择「仍要打开」。

安装包及其 [SHA-256 校验文件](installers/QuotaBar-1.0.5-universal.pkg.sha256) 均保存在仓库 `installers/` 中。将两者下载到同一目录后，可选运行：

```sh
shasum -a 256 -c QuotaBar-1.0.5-universal.pkg.sha256
```

## 从源码构建

需要 macOS 13 及以上，以及 Apple Command Line Tools 或 Xcode；本项目已在 Swift 5.8.1 下验证。

```sh
git clone https://github.com/danchaofan/quotabar.git
cd quotabar
bash build.sh
open "dist/额度看板.app"
```

`build.sh` 默认针对当前 Mac 架构编译。应用生成在 `dist/`，构建缓存位于 `.build/`，两者均不会纳入 Git。可将生成的 app 移入「应用程序」后启用开机启动。

如需生成同样的 Universal 2 安装包：

```sh
bash package.sh
```

脚本会重新构建 `arm64` 和 `x86_64`、合并应用、运行离线检查，再生成 `installers/QuotaBar-<版本>-universal.pkg` 及 SHA-256 校验文件。安装内容只有应用本身，不包含当前电脑的登录、设置或用量文件。安装器不运行额外安装脚本。

支持覆盖应用输出、构建缓存及安装包目录：

```sh
QUOTABAR_ARCHS="arm64 x86_64" \
QUOTABAR_OUTPUT_DIR=/tmp/quotabar-dist \
QUOTABAR_BUILD_DIR=/tmp/quotabar-build \
bash build.sh

QUOTABAR_BUILD_DIR=/tmp/quotabar-build \
QUOTABAR_PACKAGE_DIR=/tmp/quotabar-installers \
bash package.sh
```

## 账号连接

| 服务 | 查询方式 |
| --- | --- |
| Codex | 通过已安装并登录的 Codex CLI，调用官方 App Server 的 `account/rateLimits/read`。 |
| 智谱 Coding Plan | 默认读取 ZCode 本机的 Coding Plan 配置，调用额度查询接口；也可在设置中输入密钥并保存到 macOS 钥匙串。 |
| Kimi Code | 优先查询本机已有桌面或 CLI 服务的 `/api/v1/oauth/usage`；必要时临时启动已登录的官方 Kimi CLI 本地服务，查询后关闭。 |

查询不会发送模型推理请求，也不会自动购买或重置额度。接口未返回的字段会保持未知；查询失败时保留上次结果及更新时间。

## 每日 token 的统计范围

| 来源 | 本机数据 |
| --- | --- |
| Codex 桌面 / CLI | `~/.codex/sessions` 和 `archived_sessions`，优先统计逐响应的 `token_usage_record` 并按响应 ID 去重，兼容旧版累计记录。 |
| ZCode | 只读查询 `~/.zcode/cli/db/db.sqlite` 的 `model_usage` 数值字段。 |
| pi + GLM | `~/.pi/agent/sessions` 中带用量的助手消息、独立用量与压缩记录，仅纳入 GLM / 智谱来源。 |
| Kimi 桌面 / CLI | `~/.kimi-code/sessions` 中各 agent 的 `wire.jsonl`，仅统计 `usage.record`，不重复计算镜像事件。 |

总 token 为输入加输出。缓存读取、缓存写入已计入输入，推理子项已归入输出，不再次相加。各平台积分、订阅限额和原始 token 数属于不同口径，不能直接换算。

默认扫描用户目录，同时从本机 Codex 会话元数据中的工作目录自动识别 `work/runtime/pi/sessions` 与 `work/runtime/kimi/sessions`，覆盖 Codex 调用外部 CLI 时的项目内用量。其他自定义位置可在「设置 → 用量来源」添加会话目录；支持选择 `sessions` 本身或其上级 CLI 数据目录。重叠目录会按实际文件路径去重，不重复计数，也不会递归扫描整个项目或临时测试输出。

统计仅覆盖本机保留且含真实用量的记录。普通 ChatGPT 聊天、其他设备、已删除记录及未记录用量的请求不在覆盖范围内。Kimi 桌面与 CLI 使用共享记录，目前合并显示。应用重新启动时会补入现存的最近 30 天数据。

## 隐私与凭据

- 源码不包含 API Key、OAuth token、账号标识、真实用量快照或个人截图。测试数据为合成数据。
- 手动输入的智谱密钥保存到 macOS 钥匙串；本机客户端的登录由其自身管理。
- 本地日志解析只提取用量，应用不保存对话正文。
- 最近额度和每日数值汇总保存在 `~/Library/Application Support/QuotaBar/`，不会作为项目文件提交。
- `.gitignore` 排除了凭据文件、日志、数据库、CSV 导出、应用构建目录和本地调研快照；`installers/` 仅收录明确发布的安装包与校验文件。

诊断输出和导出的 CSV 包含个人用量。分享前请自行检查，不要把它们提交到仓库。

## 验证

离线回归检查不需要登录或网络，也不会读取个人用量：

```sh
"dist/额度看板.app/Contents/MacOS/QuotaBar" --self-test
```

当前包含 33 项额度解析、token 口径、去重、时区、进度条、CLI 运行环境、错误提示、项目目录发现、缓存和跨目录去重检查。

以下命令只在你明确需要检查自己的本机数据时使用：

```sh
# 查询真实额度及本机每日用量，输出 JSON
"dist/额度看板.app/Contents/MacOS/QuotaBar" --check

# 仅扫描本机用量，不联网查询额度
"dist/额度看板.app/Contents/MacOS/QuotaBar" --usage-only
```

## 项目结构

```text
Sources/
  App.swift           菜单栏应用入口
  Core.swift          数据模型与额度解析
  Providers.swift     本机连接与额度查询
  Usage.swift         日志扫描、数据库读取与分日汇总
  Model.swift         刷新、缓存、提醒及导出
  Views.swift         面板与设置界面
  Diagnostics.swift   诊断入口与合成数据回归检查
Info.plist
MakeIcon.swift        图标生成
build.sh              构建应用
package.sh            构建 Universal 2 安装包
packaging/            安装器配置与说明
installers/           已发布的 pkg 与 SHA-256 校验文件
```

## 接口参考

- [Codex App Server](https://learn.chatgpt.com/docs/app-server)
- [智谱官方用量查询插件](https://github.com/zai-org/zai-coding-plugins/blob/main/plugins/glm-plan-usage/skills/usage-query-skill/scripts/query-usage.mjs)
- [Kimi Code 本地服务接口](https://www.kimi.com/code/docs/en/kimi-code-cli/reference/server-api.html)
- [Kimi Code 源码](https://github.com/MoonshotAI/kimi-code)
- [Kimi 会员额度规则](https://www.kimi.com/help/membership/membership-update-rules)

客户端日志结构和接口可能随版本变化，未识别的数据需要更新适配器后才能纳入。
