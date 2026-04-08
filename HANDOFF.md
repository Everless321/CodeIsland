# CodeIsland 交接文档

## 项目概述
macOS 原生 app，在屏幕顶部（刘海区域）显示多种 AI 编码工具的实时状态面板。支持 8 种 CLI/IDE 工具，通过 hooks/plugin + Unix socket 通信。

## 技术栈
- Swift 5.9+ / SwiftUI / AppKit (NSPanel)
- Unix domain socket IPC (`/tmp/codeisland.sock`)
- 原生 Swift 桥接二进制 (`~/.claude/hooks/codeisland-bridge`, 86K)
- Hook 脚本 dispatcher (`~/.claude/hooks/codeisland-hook.sh`) — 优先 exec 二进制，fallback nc
- 目标: macOS 14+, Apple Silicon + Intel

## 项目结构
```
vibe-notch/
├── Package.swift                       — SPM 配置 (两个 target)
├── build.sh                            — 构建 release + .app bundle
├── Info.plist                          — LSUIElement=true (无 Dock 图标)
├── Sources/CodeIsland/
│   ├── CodeIslandApp.swift              — @main 入口 + MenuBarExtra
│   ├── AppDelegate.swift               — 启动接线 (server + panel + 状态观察)
│   ├── Models.swift                    — AgentStatus, HookEvent, PermissionRequest
│   ├── AppState.swift                  — 全局状态 (多 session, 工具历史, 审批, 事件名归一化)
│   ├── HookServer.swift                — Unix socket 服务端 (NWListener)
│   ├── NotchPanelView.swift            — 主 UI (收起/展开, session 列表, 工具历史)
│   ├── PanelWindowController.swift     — NSPanel 管理 (自适应大小, SwiftUI 内部动画)
│   ├── PixelCharacterView.swift        — Claude 风格像素小人动画 (Clawd)
│   ├── DexView.swift                   — Codex 风格像素小人 (Dex, 白色云朵+黑色>_)
│   ├── OpenCodeView.swift              — OpenCode 风格像素小人 (OpBot, 深灰方块+{ }脸)
│   ├── ScreenDetector.swift            — 刘海检测 (auxiliaryTopLeftArea)
│   ├── SessionPersistence.swift        — Session 持久化 (~/.codeisland/sessions.json)
│   ├── ConfigInstaller.swift           — 自动安装/卸载 hooks (7 种 CLI, 3 种格式) + OpenCode 插件
│   ├── TerminalActivator.swift         — 点击 session 跳转终端/IDE (支持 IDE 跳转)
│   ├── Settings.swift                  — UserDefaults 管理
│   ├── SettingsView.swift              — 设置 GUI (显示所有 CLI 状态)
│   ├── SettingsWindowController.swift  — 设置窗口管理
│   ├── SoundManager.swift              — 8-bit 音效
│   └── Resources/                      — 音效文件 + codeisland-opencode.js 插件 + cli-icons/
├── Sources/CodeIslandBridge/
│   └── main.swift                      — 原生桥接二进制 (支持 --source 参数)
└── docs/
    └── superpowers/                    — 规划设计文档
```

## 支持的 CLI/IDE 工具

| CLI | 配置文件 | Hook 格式 | 事件数 | 跳转 | 状态 |
|-----|---------|----------|--------|------|------|
| Claude Code | `~/.claude/settings.json` | claude (matcher+hooks+async) | 13 | 终端 tab 级 | ✅ 完整 |
| Codex | `~/.codex/hooks.json` | nested (hooks) | 3 | 终端 | ✅ 基础 |
| Gemini CLI | `~/.gemini/settings.json` | nested (timeout=ms) | 6 | 终端 | ✅ |
| Cursor | `~/.cursor/hooks.json` | flat (command only) | 10 | IDE 跳转 | ✅ |
| Qoder | `~/.qoder/settings.json` | claude (fork) | 10 | IDE 跳转 | ✅ |
| Factory | `~/.factory/settings.json` | claude (fork, source=droid) | 10 | IDE 跳转 | ✅ |
| CodeBuddy | `~/.codebuddy/settings.json` | claude (fork) | 10 | APP/终端 | ✅ |
| OpenCode | `~/.config/opencode/plugins/` | JS 插件 (非 hooks) | 全量 | APP/终端 | ✅ |

注: Copilot CLI 已移除 — hooks 功能不工作（1.0.18 版本 bug）。
注: Codex/Cursor/Qoder/CodeBuddy/OpenCode 都有 APP 和 CLI 两种模式，跳转按 `termBundleId` 自动区分。

### Hook 格式差异

```
Claude 格式:  [{matcher:"*", hooks:[{type,command}]}]        (Claude fork 系: Qoder/Factory/CodeBuddy)
Nested 格式:  [{hooks:[{type,command,timeout}]}]              (Codex/Gemini)
Flat 格式:    [{command:"..."}]                                (Cursor)
Plugin 格式:  JS 文件直接连 socket (无 bridge)                 (OpenCode)
```

注: Claude Code 自身用 matcher="" + timeout + async 字段; fork 系用 matcher="*" 无 timeout（匹配 vibe-island 行为）。
注: Gemini timeout 单位是毫秒（5000），其他 CLI 是秒（5）。

### 事件名归一化 (AppState.normalizeEventName)

不同 CLI 的事件名映射到统一的内部名：

| 内部名 | Claude/Qoder/Factory/CodeBuddy | Cursor | Gemini |
|--------|-------------------------------|--------|--------|
| UserPromptSubmit | UserPromptSubmit | beforeSubmitPrompt | - |
| PreToolUse | PreToolUse | beforeShellExecution / beforeReadFile / beforeMCPExecution | BeforeTool |
| PostToolUse | PostToolUse | afterShellExecution / afterFileEdit / afterMCPExecution | AfterTool |
| Stop | Stop | stop | - |
| SessionStart | SessionStart | - | SessionStart |
| SessionEnd | SessionEnd | - | SessionEnd |
| SubagentStart | SubagentStart | - | BeforeAgent |
| SubagentStop | SubagentStop | - | AfterAgent |
| AfterAgentResponse | - | afterAgentResponse (Cursor 特有，携带 AI 回复) | - |
| Notification | Notification | afterAgentThought | - |

### CLI 特殊处理

- **Cursor**: 无 `cwd` 字段，从 `workspace_roots` 数组取第一个; `afterAgentResponse` 携带 AI 回复 (`text` 字段)，`stop` 不带; 无 SessionStart/SessionEnd 事件，session 由 beforeSubmitPrompt 隐式创建
- **CodeBuddy**: `Stop` 事件不传 AI 回复内容，显示 `[回复完成]` 占位
- **Factory**: `--source droid`（历史原因/内部代号），代码中统一用 `"droid"`
- **Gemini**: timeout 单位是毫秒（5000），其他 CLI 是秒（5）
- **Codex**: 只有 3 个事件（SessionStart, UserPromptSubmit, Stop），无工具调用监控
- **Codex APP**: 每次用户消息会创建两个 session（真实 + 标题生成），标题生成 session 的 `transcript_path` 为 `null`，由 `handleEvent` 入口过滤
- **OpenCode**: JS 插件模式，不经过 bridge，直接连 socket。终端信息在 `_env` 子对象中（非顶层字段），`extractMetadata` 有 fallback 提取

## 架构：事件流

```
路径 A: Hook 系 CLI (Claude/Codex/Gemini/Cursor/Qoder/Factory/CodeBuddy)
  → codeisland-bridge --source <cli>
    → 读 stdin JSON → 验证 session_id → 注入 _source + 终端环境
    → POSIX socket → /tmp/codeisland-<uid>.sock → 等响应 "{}"

路径 B: Plugin 系 CLI (OpenCode)
  → codeisland-opencode.js 插件 (in-process, 无 bridge)
    → 监听 OpenCode 内部事件 → 映射为标准 hook_event_name
    → 终端环境放在 _env 子对象 → 直连 socket
    → 权限/问答: held connection 等响应 → in-process 回复 OpenCode API

共同入口:
  → HookServer (NWListener, main thread)
    → HookEvent 解析
    → AppState.handleEvent() — Codex 重复 session 过滤 → normalizeEventName() 归一化
    → extractMetadata() — 终端信息从顶层字段或 _env fallback 提取
    → 更新 session 状态 → SwiftUI @Observable 触发 UI 更新
```

## Session 生命周期管理

### 创建
1. **Hooks（主要）**: `SessionStart` 或首次收到任何事件时自动创建
2. **进程发现（启动时）**: 扫描 Claude/Codex 进程，匹配 transcript 文件
   - **新鲜度过滤**: 仅展示 transcript 最近 5 分钟内有更新的 session，过滤掉孤儿进程

### 清理（cleanupIdleSessions, 每 60 秒）
1. **孤儿进程检测**: ppid <= 1 的进程 → kill + 移除 session
2. **无监控 session 过期**: 无进程监控的 session（hook-only，如 Cursor/Gemini 等）idle 超 10 分钟 → 移除
3. **卡住 session 重置**: active 但 3 分钟无事件 → 重置为 idle
4. **用户超时**: 用户设置的 sessionTimeout → 对所有 session 生效（不覆盖第 2 步的默认值）

### SessionStart 特殊处理
SessionStart 会重建 session 对象。由于通用元数据提取在 switch 之前执行（会写入旧对象），SessionStart case 内会重新提取所有元数据（cwd, model, source, 终端信息, workspace_roots），确保新 session 不丢失数据。

## UI 风格：Terminal Style

### 像素小人系统

| 来源 | 小人 | 设计 |
|------|------|------|
| Claude | Clawd (ClawdView) | 橙色身体, 8-bit 风格 |
| Codex | Dex (DexView) | 白色云朵+黑色 `>_`, 灵感来自 Codex 图标 |
| Gemini | Gemini (GeminiView) | 紫色星形 |
| Cursor | CursorBot (CursorView) | 六角宝石 |
| Qoder | QoderBot (QoderView) | 绿色气泡 + Q 脸 |
| Factory | Droid (DroidView) | 橙色方块机器人 |
| CodeBuddy | Buddy (BuddyView) | 紫色方块 |
| OpenCode | OpBot (OpenCodeView) | 深灰几何方块 + `{ }` 代码括号脸 |

- Compact bar 根据最高优先级 session 的 source 选择显示哪个小人
- 非 Claude 的 session 卡片显示来源标签（如 "Codex", "Cursor", "Qoder" 等）

### Dex 像素小人 (DexView)
- **造型**: 白色 (off-white) 像素云朵 blob，顶部三个圆润凸起
- **脸部**: 黑色像素终端提示符 `>_`
- **idle**: 轻轻浮动，光标慢闪
- **working**: 弹跳打字，光标快闪，键盘按键闪光
- **alert**: 抖动 + `>_` 白/琥珀交替 + 感叹号

### Session 卡片
- **来源标签**: 非 Claude session 显示半透明白底标签
- **跳转按钮**: 终端 session 显示终端 app 图标; IDE session (Cursor/Qoder/CodeBuddy/Factory) 显示对应 IDE 图标

### 跳转支持 (TerminalActivator)

**APP vs CLI 自动区分**：`nativeAppBundles` 字典按 `termBundleId` 判断。匹配已知 APP bundle → 激活 APP；不匹配 → 走终端 tab 匹配。

| 目标 | 方式 |
|------|------|
| Ghostty | AppleScript: CWD 匹配 → session ID 前缀 → source 关键词 → 首个 CWD 匹配 |
| iTerm2 | AppleScript session ID |
| Terminal.app | AppleScript TTY |
| WezTerm | CLI wezterm (TTY → CWD) |
| kitty | CLI kitten (window ID → CWD → source 关键词) |
| tmux | CLI tmux pane ID |
| Codex APP | NSRunningApplication (`com.openai.codex`) |
| Cursor APP | NSRunningApplication (`com.todesktop.230313mzl4w4u92`) |
| Qoder APP | NSRunningApplication (`com.qoder.ide`) |
| CodeBuddy APP | NSRunningApplication (`com.tencent.codebuddy`) |
| Factory APP | NSRunningApplication (`com.factory.app`) |
| OpenCode APP | NSRunningApplication (`ai.opencode.desktop`) |
| Alacritty/Warp/Hyper/Tabby/Rio | open -a |

注：Ghostty 和 kitty 的 title 匹配使用 `session.source` 作为关键词（非硬编码 "claude"），同 CWD 多 CLI 不会互相抢。

### APP/CLI Bundle IDs (nativeAppBundles)
```
Codex:     com.openai.codex
Cursor:    com.todesktop.230313mzl4w4u92
Qoder:     com.qoder.ide
CodeBuddy: com.tencent.codebuddy
Factory:   com.factory.app
OpenCode:  ai.opencode.desktop
```

### 设计语言
- **字体**: 全部 monospaced 等宽字体（设置界面除外）
- **聊天标签**: `>` 用户（绿色）/ `$` AI（Claude 橙 #D97757）
- **Typing 指示器**: 闪烁光标 `_`
- **分隔线**: 虚线（4px 线段 + 3px 间隔）
- **设置/退出按钮**: SF Symbols `gearshape`/`power`

### 像素文字系统 (PixelText)
- **5×7 点阵**: 每个字符 35 个像素点，支持 A-Z + 0-9 + 符号
- **用途**: compact bar 详细模式的状态文字和 session 计数

## ConfigInstaller 架构

数据驱动设计，`CLIConfig` 结构体定义每个 CLI：
```swift
struct CLIConfig {
    let name: String           // 显示名
    let source: String         // --source 值
    let configPath: String     // 配置文件相对路径
    let configKey: String      // JSON key ("hooks")
    let format: HookFormat     // .claude / .nested / .flat
    let events: [(String, Int, Bool)]  // (事件名, timeout, async)
}
```

`ConfigInstaller.allCLIs` 包含所有 7 个 CLI 的配置，`install()`/`uninstall()` 统一遍历处理。

Claude Code 特殊：通过 hook script（shell dispatcher）调用 bridge，其他 CLI 直接调用 bridge + `--source` 参数。

## Session Discovery (进程发现)

### Claude Code
- 扫描 `~/.local/share/claude/versions/` 下的进程
- FSEventStream 监控 `~/.claude/projects/` 目录
- 匹配进程 CWD → transcript .jsonl 文件
- **5 分钟新鲜度过滤**: transcript 超过 5 分钟未更新的不展示（防孤儿进程）

### Codex
- 扫描 `@openai/codex` 路径下的进程
- 匹配 CWD → `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`
- **5 分钟新鲜度过滤**: 同上

### 其他 CLI (Gemini/Cursor/Qoder/Factory/CodeBuddy)
- 无进程发现，完全依赖 hooks 事件驱动
- 无进程监控，依赖 10 分钟 idle 自动清理

## Usage Stats（用量统计）

已在第一批改造中移除，日后重新设计。

## 全局状态优先级

收起状态的小人显示所有 session 中最高优先级的状态：
`waitingApproval > running > processing > idle`

`primarySource` 返回最高优先级 session 的 source，用于选择显示 Clawd 还是 Dex。

## 已知问题
1. **AppleScript 权限** — 每次 rebuild 失效 (ad-hoc 签名)
2. **Codex 进程发现** — 启动时扫描逻辑存在但实测不稳定，主要依赖 hooks
3. **CodeBuddy Stop 无回复** — Stop 事件不带 AI 回复内容，显示占位符
4. **Cursor 无 SessionStart/SessionEnd** — session 由首次事件隐式创建，依赖 idle 清理
5. **Ghostty 关 tab 不杀进程** — 终端 tab 关闭但 Claude 进程存活，依赖 transcript 新鲜度过滤

## 最近改动（2026-04-06 #2）— UI 大改 + Logo + Bug 修复

### 设置界面重构
- **侧边栏 7 页**: 通用、行为、外观、角色、声音、Hooks、关于（原来 4 页全堆在一起）
- **窗口标题**: `titleVisibility = .visible`，显示 "CodeIsland 设置"
- **每页大标题**: 自定义 `PageHeader`（20pt 粗体），因 macOS 不支持 `.toolbarTitleDisplayMode(.large)`
- **关于页**: Socket/Bridge 技术路径 → GitHub + Issues 链接按钮

### App Logo
- **设计**: 灵动岛药丸形状 + 橙色眼睛偷看的小生物，像素风
- **`AppLogoView`**: Canvas 绘制，支持 `showBackground` 参数（About 页白底，展开栏无背景）
- **Dock 图标**: 打开设置时动态渲染 `AppLogoView` 作为 `NSApp.applicationIconImage`
- **展开栏左侧**: 替换原 `ClaudeLogo`，36pt 无背景版，药丸颜色 50% 白

### CLI 官方图标系统
- **8 个 CLI 图标**: PNG 打包在 `Resources/cli-icons/`（claude/codex/gemini/cursor/qoder/factory/codebuddy/opencode）
- **来源**: 官网 favicon/SVG 转 256px PNG，透明背景（rsvg-convert）
- **`cliIcon(source:size:)`**: 全局函数，从 `Bundle.module` 加载
- **用途**: Hooks 设置页 CLI 状态行、角色页名称旁、CLI 分组标题

### 顶栏优化
- **按钮精简**: 删除"详细模式"切换按钮，只留 音效/设置/退出 三个
- **退出按钮**: 红色 tint 区分
- **筛选标签**: 从 session 列表移到顶栏左侧（logo 后面），8-bit 像素风格（PixelText + 方形边框）
- **按钮亮度**: 默认 0.75 透明度（原 0.5 太暗）

### Session Card 优化
- **标签区统一**: `SessionTag` 组件统一所有标签样式（9.5pt、6px/3px padding、5px 圆角）
- **项目名可点击**: 虚线下划线（跟随卡片 hover），点击打开 Finder，tooltip 显示完整路径
- **完成弹窗**: 点击整张卡片跳转终端（不只是跳转按钮）
- **"N sessions" 展开**: hover 0.6 秒延迟防误触 + 视觉优化（分隔线+下箭头）

### Bug 修复
- **iTerm2 跳转**: `ITERM_SESSION_ID` 格式 `w0t0p0:GUID`，AppleScript `unique ID` 只要 GUID → bridge/hook/fallback 三处统一截取冒号后的 GUID
- **Warp 终端识别**: Warp 的 `TERM_PROGRAM` 是 `"Apple_Terminal"` → `terminalName` 优先用 `termBundleId` 判断
- **Notification 声音不响**: question/askUserQuestion 调用 `handleEvent("Notification")` 但 SoundManager 无此映射 → 改为 `"PermissionRequest"` 复用审批音效
- **AI 回复行数**: 默认改为 1 行，UI 标签同步修正

### 死代码清理
- 删除 `compactBarDetailed`: SettingsKey/Defaults/Manager/UI toggle/compact bar 分支 全链路清理
- 删除 `expandedDetailed`: 硬编码 true → 去掉常量和 if 条件，简化 visibleMessages 逻辑
- 删除废弃 `sourceTagView` 函数、`displayModel` 属性

## 最近改动（2026-04-06）— Hover 崩溃修复 + OpenCode 集成 + APP/CLI 跳转

### NSHostingView Display Cycle 崩溃修复
- **根因**: `NSHostingView.updateConstraints()` 或 layout 阶段，SwiftUI view graph 更新触发 `setNeedsUpdateConstraints`/`setNeedsLayout`，重入 `_postWindowNeedsUpdateConstraints`/`_postWindowNeedsLayout` 抛异常
- **修复**: `NotchHostingView` 重写 `needsUpdateConstraints` 和 `needsLayout` setter，所有赋值延迟到下个 run-loop turn（`DispatchQueue.main.async`），`applyingDeferred` 标志防止递归延迟
- Hover timer 回调包裹 `Task { @MainActor in }` 修复编译器 actor 隔离警告

### OpenCode 集成（第 8 种 CLI）
- **插件**: `Resources/codeisland-opencode.js` — JS 插件直连 socket，不经 bridge
  - 事件映射: session.created/deleted/updated → SessionStart/End, message.part.updated → UserPromptSubmit/PreToolUse/PostToolUse, session.status idle → Stop
  - 权限审批: held connection 等 CodeIsland 响应 → in-process 回复 OpenCode `/permission/{id}/reply` API
  - 问答: 同审批模式 → `/question/{id}/reply`
  - 终端环境: `_env` 子对象（非顶层字段），`extractMetadata` 有 fallback 提取
- **ConfigInstaller**: `installOpencodePlugin` 写 JS 到 `~/.config/opencode/plugins/codeisland.js`，注册到 `config.json` 的 `plugin` 数组，清理旧 `vibe-island.js`
- **OpBot 像素小人** (`OpenCodeView.swift`): 深灰 (#383838) 几何方块体 + 浅灰 (#8C8C91) 边框 + `{ }` 代码括号脸，极简风
- MascotView、SettingsView（mascotList + hooks 状态）、DebugHarness（`case opencode` + allcli 第 8 个）、CLI 分组 (`cliOrder`) 全部同步

### APP vs CLI 跳转区分
- `TerminalActivator.appSources` 清空 → 全部改由 `nativeAppBundles`（按 `termBundleId`）处理
- 6 个 APP bundle ID: Codex (`com.openai.codex`)、Cursor (`com.todesktop.230313mzl4w4u92`)、Qoder (`com.qoder.ide`)、Factory (`com.factory.app`)、CodeBuddy (`com.tencent.codebuddy`)、OpenCode (`ai.opencode.desktop`)
- APP 模式（bundle 匹配）→ `NSRunningApplication.activate`；CLI 模式（bundle 是终端）→ 终端 tab 匹配
- `SessionSnapshot.terminalName` 和 `TerminalJumpButton.sourceBundleIds` 同步按 `termBundleId` 判断
- Ghostty/kitty title 匹配: 硬编码 `"claude"` → `session.source` 动态关键词，同 CWD 多 CLI 不互抢

### Codex APP 重复 Session 过滤
- Codex APP 每次消息创建两个 session：真实（有 `transcript_path`）+ 标题生成（`transcript_path: null`）
- `handleEvent` 入口: source=="codex" && 新 session && `transcript_path is NSNull` → 丢弃

### Session 持久化与恢复
- **发现 `SessionPersistence` 模块**（交接文档遗漏）: session 保存到 `~/.codeisland/sessions.json`，重启时恢复
- **修复**: `restoreSessions()` 恢复 `lastUserPrompt`/`lastAssistantMessage` 后重建 `recentMessages`，修复重启后面板只显示 AI 回复、缺少用户消息的问题

### 其他修复
- `displayName`: CWD 最后一段为纯数字（如 CodeBuddy 时间戳目录 `20260406010126`）时回退到父目录名
- Cursor CWD: `workspace_roots` 为空时从 `transcript_path` 提取项目路径（`~/.cursor/projects/<project>/...`）
- `_env` 子对象 fallback: OpenCode 插件的终端信息 (`TERM_PROGRAM`, `__CFBundleIdentifier`, `ITERM_SESSION_ID`, `KITTY_WINDOW_ID`, `TMUX_PANE`) 从 `_env` 提取

## 最近改动（2026-04-05 #6）— Bug 修复 + 代码清理

### Compact Bar 详细模式补全
- 详细模式原承诺"收起时显示项目名、当前工具和模型名"，实际只显示了当前工具 + session 计数
- **左翼**新增项目名显示（10pt monospaced，半透明白色），跟随轮询 session 变化
- **右翼**新增模型缩写显示（`SessionSnapshot.shortModelName`，如 `claude-opus-4-6` → `opus`）
- 现在详细模式完整显示：`[小人] [项目名] [工具状态] ···notch··· [bell?] [模型名] [session数]`

### Hooks 重新安装按钮修复
- **Bug 1**：`installExternalHooks` 原为 void，6 个外部 CLI 安装失败时 `install()` 仍返回 true，用户看到"安装成功"但实际失败。改为返回 `Bool`，所有 7 个 CLI 的结果都纳入最终状态
- **Bug 2**：`installExternalHooks` 内部先调 `isHooksInstalled()`，已安装就 return，"重新安装"按钮实际什么都不做。移除该检查，改为先 `removeAll` 旧 hooks 再写入新的，实现真正的幂等重装

### 代码清理
- `rotatingSession` 计算属性从 CompactLeftWing/CompactRightWing 的重复定义提取到 `AppState` 上
- `shortModel()` 从 View 层 private 函数移到 `SessionSnapshot.shortModelName` 计算属性，与 `displayName`、`sourceLabel` 放在一起

## 最近改动（2026-04-05 #5）— 项目重命名 + 两批改造

### 项目重命名 VibeNotch → CodeIsland

全项目重命名，涉及：
- 目录：`Sources/VibeNotch/` → `Sources/CodeIsland/`、`VibeNotchCore/` → `CodeIslandCore/`、`VibeNotchBridge/` → `Sources/CodeIslandBridge/`
- 入口：`VibeNotchApp.swift` → `CodeIslandApp.swift`、`struct CodeIslandApp`
- Package.swift：包名、target 名、bridge 名全部改为 CodeIsland 系列
- Bundle ID：`com.vibenotch.app` → `com.codeisland.app`
- Socket：`/tmp/codeisland-<uid>.sock`
- Bridge：`codeisland-bridge`、`codeisland-hook.sh`
- 环境变量：`CODEISLAND_SOCKET_PATH`、`CODEISLAND_SKIP`、`CODEISLAND_DEBUG`
- 数据目录：`~/.codeisland/`
- Logger subsystem：`com.codeisland`
- **迁移兼容**：`ConfigInstaller.containsOurHook()` 同时检测 `"codeisland"` 和旧的 `"vibenotch"`，确保升级时能识别并替换旧 hooks

### 第一批改造：基础修复

**1. Universal Binary（双架构编译）**
- `build.sh` 分别编译 `arm64` 和 `x86_64`，用 `lipo -create` 合并
- 主程序 `CodeIsland` 和 `codeisland-bridge` 都做 universal binary
- `dev.sh` 保持单架构（开发迭代速度优先）
- `dev.sh` 同时杀 `CodeIsland` 和 `VibeNotch` 旧进程

**2. 删除 Usage 功能**
- 完全移除 `UsageData` struct、`fetchUsageFromAPI()`、`startUsagePolling()`
- 移除 compact bar 的 5h/7d 用量百分比显示
- 移除 Settings 中的 `showUsageStats` 开关
- 移除 SessionSnapshot reducer 中 Stop 事件的 `.fetchUsage` effect
- **保留** OAuth/keychain 相关代码用于日后重新设计

**3. 设置 GUI 重构（6 tab → 4 tab）**
```
旧：通用 | 显示 | 声音 | 角色 | Hooks | 关于
新：通用 | 外观 | 声音 | 关于
```
- **通用（General）**: 系统（登录启动、显示器选择）、行为（全屏隐藏、无session隐藏、智能抑制、鼠标离开收起、详细模式）、Session（超时清理、工具历史上限）、Hooks（CLI 状态列表 + 安装/卸载按钮 + 状态消息）
- **外观（Appearance）**: 面板（最大高度 slider）、内容（字体大小、AI 行数、Agent 详情）、角色（预览状态选择器 + 7 个内置小人画廊）
- **声音（Sound）**: 不变（主开关 + 音量 + 5 个事件开关 + 试听）
- **关于（About）**: 版本信息 + Socket/Bridge 路径
- 删除了 `NotchPreviewCard`/`PanelPreviewCard` 预览卡片
- **Dock 图标**：`SettingsWindowController` 已有 `NSApp.setActivationPolicy(.regular/.accessory)` 逻辑，打开设置时 Dock 出现图标，关闭后隐藏

**4. DebugHarness CLI 场景扩展**
- 新增 8 个 `--preview` 场景：`claude`、`codex`、`gemini`、`cursor`、`qoder`、`factory`、`codebuddy`、`allcli`
- 每个 CLI 场景注入正确的 `source` 字段，验证小人选择、source 标签、跳转按钮
- `allcli` 综合场景：7 个 CLI 各一个 session，混合状态（2 running / 2 processing / 1 approval / 1 idle / 1 interrupted）
- 总计 14 个场景可用（6 原始 + 8 新增）

### 第二批改造：体验优化

**1. Compact Bar 小人轮询切换**
- `AppState.rotatingSessionId: String?` — 当前轮显的 session ID
- `AppState.rotationTimer: Timer?` — 3 秒定时器
- `startRotationIfNeeded()`：收集非 idle session，>1 个时启动轮询，≤1 个时停止
- `rotateToNextSession()`：按 sorted session ID 循环前进
- 触发点：`handleEvent()` 末尾、`removeSession()` 末尾
- `CompactLeftWing` 使用 `rotatingSession` 计算属性获取当前轮显 session 的 source/status/tool
- 详细模式的状态文字（WAIT/RUN/INT）也跟随轮询 session 变化
- `.id(displaySource)` + `.transition(.opacity)` + `.animation(.easeInOut(duration: 0.3))` 淡入淡出

**2. Session Card 分组切换**
- `Settings.sessionGroupingMode: String` — `"all"` / `"status"` / `"cli"`，默认 `"all"`
- `SessionListView` 顶部自定义分组切换器（仅多 session 时显示）：
  - 样式：绿色文字 + 绿色小圆点（选中态），淡灰文字（未选中态），无背景框
  - 标签：`全部` / `状态` / `CLI`
- `groupedSessions` 计算属性：
  - `"all"`：flat list，按 session ID 排序
  - `"status"`：按状态分组（运行中 → 等待中 → 处理中 → 空闲），`waitingApproval` 和 `waitingQuestion` 合并为"等待中"
  - `"cli"`：按 source 分组（Claude → Codex → Gemini → Cursor → Qoder → Factory → CodeBuddy），未知 source 归入"其他"
- 分组 header：11pt monospaced medium，白色 50% 透明

## 未完成的任务

自定义小人和自定义音效功能已取消，不再计划实现。

**相关规划文档（仅供参考，已废弃）：**
- 设计：`docs/superpowers/specs/2026-04-05-batch1-foundation-design.md`
- 设计：`docs/superpowers/specs/2026-04-05-batch2-ux-design.md`
- 计划：`docs/superpowers/plans/2026-04-05-batch1-foundation.md`
- 计划：`docs/superpowers/plans/2026-04-05-batch2-ux.md`

## 最近改动（2026-04-05 #3）

### Parallel Permission Approval Queue（并行审批队列）
- `pendingPermission: PermissionRequest?` / `pendingQuestion: QuestionRequest?` 替换为 `permissionQueue: [PermissionRequest]` / `questionQueue: [QuestionRequest]` FIFO 数组
- 原字段名保留为 computed property（返回 `.first`），UI 代码向后兼容
- 新请求入队，UI 只在队首时展示；approve/deny 后 `removeFirst()` + `showNextPending()` 自动展示下一个
- `drainPermissions(forSession:)` / `drainQuestions(forSession:)` — 按 session 清空队列并 resume continuation，用于 removeSession 和互斥切换
- `showNextPending()` — 优先展示 permission 队首，其次 question 队首，都没有则 collapse
- `removeSession` 调用 drain + showNextPending 替代直接 collapse，杜绝 continuation 泄漏
- ApprovalBar / QuestionBar 新增 `queuePosition` / `queueTotal` 参数，队列 >1 时显示 "1/N" 计数器

### JSONC Comment Support
- `ConfigInstaller.stripJSONComments(_:)` — static 方法（非 private，供 AppState YOLO 检测复用）
- 状态机：追踪字符串（处理 `\"` 转义）、`//` 单行注释、`/* */` 块注释
- `parseJSONFile(at:fm:)` — 先 strip 注释再 JSONSerialization 解析
- ConfigInstaller 所有 4 处 JSON 解析（installClaudeHooks、installExternalHooks、uninstallHooks、isHooksInstalled）统一走 parseJSONFile

### Hooks Auto-Recovery
- `ConfigInstaller.verifyAndRepair() -> [String]` — 遍历已安装 CLI，检查 hooks 是否还在，缺失则修复，返回修复的 CLI 名
- 触发时机：`NSWorkspace.didActivateApplicationNotification` + 300 秒定时器
- 60 秒防抖（`lastHookCheck`），避免频繁检查
- 每次 verify 前先更新 bridge binary + hook script

### Minimized Window Recovery + Cross-Space Jump
- `bringToFront()` 从 `Process("/usr/bin/open")` 改为 `NSRunningApplication.activate(options: .activateIgnoringOtherApps)` — 支持跨 Space 切换 + unhide
- 未运行的 app fallback 到 `open -a`
- IDE 跳转同样用 NSRunningApplication
- iTerm2 AppleScript：遍历 window 时 `set miniaturized of aWindow to false`
- Terminal.app AppleScript：匹配 tab 时 `set miniaturized of w to false`
- Ghostty：AppleScript 前先 NSRunningApplication activate（Ghostty AppleScript 无 miniaturized 属性）

### Cursor YOLO Mode Detection
- `SessionSnapshot.isYoloMode: Bool?` — 三态：`nil` 未检测、`false` 非 YOLO、`true` YOLO
- `AppState.detectCursorYoloMode()` — 读 `~/Library/Application Support/Cursor/User/settings.json`，检查 `cursor.general.yoloMode` / `cursor.agent.enableYoloMode`，用 `ConfigInstaller.stripJSONComments` 处理注释
- 首次收到 Cursor source 事件时检测一次（`isYoloMode == nil` guard），缓存结果
- SessionCard 在 Interrupted 标签和 source 标签之间显示红色 "YOLO" 标签

### Subagent Worktree Hook 事件过滤
- `handleEvent` 入口检查 `event.rawJSON["cwd"]` 是否包含 `/.claude/worktrees/agent-` 或 `/.git/worktrees/agent-`
- 匹配则跳过（不建 session、不弹 completion card），避免 subagent 完成时弹窗
- 阻塞事件（PermissionRequest、Question）不过滤 — 保留安全审批，不绕过权限模型
- 与进程发现的 worktree 过滤互补：进程发现过滤进程扫描路径，handleEvent 过滤 hook 事件路径

## 最近改动（2026-04-05 #2）

### NotchPanelShape 连续曲率曲线
- 底部圆角从 `addArc`（圆弧）升级为 `addCurve`（cubic bezier），使用 `k=0.62` 超椭圆近似，消除弧/线交界处的曲率突变
- 肩部（wing tip 弯角）从 `addQuadCurve` 升级为 `addCurve`，control 点严格保持切线连续：cp1 与起点同 Y（水平切线），cp2 与终点同 X（垂直切线），factor=0.35
- 底部 squircle 风格 + 顶部紧凑肩部，形成"底软顶锐"的视觉层次
- animatableData 不变（topExtension + bottomRadius），动画完全兼容

### Bridge fail-open 加固
- **SIGPIPE 全局忽略** — `signal(SIGPIPE, SIG_IGN)` + socket 级 `SO_NOSIGPIPE` 双保险
- **SIGALRM 硬超时** — 三阶段保护：
  1. `alarm(5)` 保护 stdin 读取（防调用进程未关 pipe）
  2. `alarm(8)` 保护 env 收集 + connect + send（所有事件类型）
  3. blocking 事件在 `recvAll` 前 `alarm(0)` 取消（允许长等待）
- **非阻塞 connect** — `O_NONBLOCK` + `poll(3s)` + `SO_ERROR` 检查，替代同步 `connect()`
- 信号处理用 `_exit(0)`（async-signal-safe），不用 `exit()`

### 进程退出 grace period 防抖
- `monitorProcess` 的 DispatchSource 退出回调改为 `handleProcessExit`（不再直接 `removeSession`）
- `handleProcessExit`：先 `stopMonitor` 拆除死监控，等 5 秒后检查：
  - `processMonitors[sessionId] != nil` → 新进程接管 → 保留
  - `lastActivity > exitTime` → grace period 内有新事件 → 保留
  - 都没有 → `removeSession`
- 解决 Claude Code 自动更新/进程重启时 session 短暂消失的问题

### Stuck session 检测优化
- `cleanupIdleSessions` step 2：有 `processMonitors` 的 session 跳过 3 分钟 stuck 重置
- 只有无进程监控的 hook-only session（Cursor/Gemini 等）才走 stuck 重置
- 解决长时间对话（40min+）中 session 被误判为卡住、小人突然变 idle 的问题

### removeSession continuation 清理（修复 pre-existing bug）
- 把 `pendingPermission` / `pendingQuestion` continuation resume 和 `surface` collapse 从 `executeEffect(.removeSession)` 移入 `removeSession` 本身
- 所有移除路径（cleanup timer、orphan kill、grace period、reducer effect）统一走 `removeSession`，杜绝 continuation 泄漏 / NWConnection 泄漏
- `executeEffect(.removeSession)` 简化为一行 `removeSession(sid)`

### Debug Harness 场景注入
- 新文件 `DebugHarness.swift`：通过 `--preview <scenario>` 启动参数注入模拟数据
- 6 个场景：`working`（工具调用中）、`approval`（权限审批）、`question`（问答）、`completion`（完成通知）、`multi`（3 session 混合状态）、`busy`（subagents + 多 CLI）
- `AppDelegate` 检测 `--preview` 参数，注入后跳过 boot 动画，直接展开面板
- socket server 正常运行，preview 模式下也可接收真实事件
- approval/question 场景为 UI-only（无 continuation），不可交互

## 最近改动（2026-04-05）

### AskUserQuestion 路由到 QuestionBar
- `PermissionRequest` 事件中 `tool_name == "AskUserQuestion"` 时，不再显示 ApprovalBar（DENY/ALLOW/ALWAYS），而是路由到 QuestionBar 显示问题和选项
- `QuestionRequest` 增加 `isFromPermission` 标志，answer 时返回 PermissionRequest allow 格式，skip 时返回 deny 格式
- 涉及文件：`HookServer.swift`、`AppState.swift`、`Models.swift`、`NotchPanelView.swift`

### @Observable 迁移
- `AppState` 从 `ObservableObject` + `@Published` 迁移到 `@Observable final class`
- 好处：SwiftUI 只在实际访问的属性变化时刷新对应 view，而非整个对象
- `NotchPanelView` 中 `@ObservedObject var appState` → `var appState`
- `PanelWindowController` 移除 Combine 依赖，`$sessions` sink → `withObservationTracking` Task 循环
- **注意**：`@Observable` 对 Dictionary 下标的排他性检查更严格，不能在同一表达式中同时读写 `sessions`（如 `sessions[id]?.model = ...sessions[id]?.cwd`），必须先读到局部变量再写入
- `deinit` 中访问 `@MainActor` 属性需要 `MainActor.assumeIsolated` 包裹

### Hover 延迟展开
- 鼠标进入 notch 区域后等 0.5s 才展开面板，避免鼠标路过时误触
- 鼠标离开时立即收起（保持原有行为）
- 使用 `@State private var hoverTimer: Timer?`，hover 进入时启动，离开时 invalidate

### 保护可操作状态
- `SessionSnapshot` reducer 中，当 session 处于 `waitingApproval` 或 `waitingQuestion` 时，`PreToolUse`/`PostToolUse`/`SubagentStart`/`SubagentStop` 等事件不再覆盖 status
- 防止用户正在看审批/问答 UI 时被突然冲掉

### Subagent 进程过滤
- 进程发现（`findActiveClaudeSessions`）中排除 CWD 包含 `/.claude/worktrees/agent-` 或 `/.git/worktrees/agent-` 的进程
- 避免 Claude Code subagent 被当作独立 session 显示

### Session Card UI 优化
- **去重**: completionCard 去掉独立的 `lastAssistantMessage` 预览（SessionCard 已包含）; `lastUserPrompt` 在详细模式有聊天记录时隐藏（避免和 recentMessages 重复）
- **Thinking 指示器**: AI 回复中无工具调用时显示 `$ thinking_` 而非单纯闪烁光标 `$ _`
- **Subagent 像素图标**: 自制 7×7 像素小机器人头（MiniAgentIcon），网格排列在 Clawd 下方（每行 4 个，8px），运行中绿色+光晕，完成后灰色
- **项目名状态色**: displayName 颜色随状态变化 — 工作中绿色、等待审批/问答橙色、中断红橙色、空闲白色
- **清理**: 删除废弃的 `DotPatternView`（原点阵背景）

### dev.sh 开发脚本
- 新增 `dev.sh`：自动杀旧进程 → 编译 → 打包 → 启动，简化开发迭代

## 已修复的关键 Bug
1. **Spring 过冲露出刘海底边** — 收缩动画 `dampingFraction: 0.8` 会过冲，VStack 高度短暂低于 `notchHeight`，导致 `NotchPanelShape` 的 `rect.maxY` 比物理刘海底边更高。修复：`NotchPanelShape` 加 `minHeight` 参数（不在 `animatableData` 中，不参与动画），`path()` 中用 `max(rect.maxY, rect.minY + minHeight)` 兜底
2. **panelWidth 用错屏幕** — `panelWidth` 原来用 `NSScreen.main` 计算 maxWidth，多显示器时面板在非主屏会算错宽度。修复：`NotchPanelView` 增加 `screenWidth` 参数，由 `PanelWindowController` 传入实际目标屏幕宽度
3. **双重动画叠加** — `onHover` 的 `withAnimation(.spring)` 和外层 `.animation(.spring, value: isExpanded)` 对同一值变化叠加。修复：移除外层 `.animation(value: isExpanded)`，仅保留 `withAnimation`（transition 需要它）

## 构建和运行
```bash
cd /Users/wxt/code/vibe-notch
./build.sh                    # 仅编译打包
open .build/release/CodeIsland.app

./dev.sh                      # 杀旧进程 + 编译 + 启动（开发迭代用）
```

## 关键设计决策
1. **Unix socket 而非 HTTP** — 用户有代理配置会走代理
2. **自适应 NSPanel + SwiftUI 内部动画** — 面板宽度/高度根据屏幕尺寸动态计算，避免 NSHostingView 崩溃
3. **Bridge 必须等响应** — NWListener main-thread dispatch race
4. **~~事件驱动 Usage~~** — 已移除，日后重新设计
5. **全局状态优先级** — 多 session 时不遗漏工作状态
6. **数据驱动 ConfigInstaller** — CLIConfig 结构体描述每个 CLI，泛化安装逻辑
7. **事件名归一化** — normalizeEventName() 统一处理不同 CLI 的事件命名差异
8. **IDE 跳转** — 非终端来源的 session 直接 `open -a` 对应 IDE
9. **Clawd 保持 8-bit** — 低分辨率像素风是灵魂，不升级
14. **屏幕自适应布局** — 紧凑栏翼区宽度、小人尺寸、面板宽高、设置窗口均根据实际屏幕参数动态计算，适配 14"/16" MacBook（刘海）、Mac Studio/Mini 外接显示器（无刘海）等各种机型
10. **Dex 白色云朵** — 基于 Codex 官方图标设计，黑色 `>_` 在深色面板醒目
11. **Factory source=droid** — 保持和 vibe-island 一致，代码中统一用 "droid"
12. **Transcript 新鲜度过滤** — 进程发现时只展示 5 分钟内有更新的 session，避免孤儿进程造成僵尸 session
13. **分层清理策略** — 有进程监控的 session 用用户设置的超时; 无监控的 hook-only session 10 分钟 idle 自动清理
15. **NotchPanelShape minHeight 兜底** — spring 动画的 animatableData 会过冲，minHeight 不参与动画，确保 shape 永远覆盖物理刘海
16. **panelWidth 使用目标屏幕宽度** — 多显示器下不能用 NSScreen.main，必须用面板实际所在屏幕的宽度
17. **@Observable 替代 ObservableObject** — 细粒度追踪，避免 Dictionary 下标同表达式读写（排他性冲突会 SIGABRT）
18. **AskUserQuestion → QuestionBar** — PermissionRequest 中的 AskUserQuestion 不是权限请求，路由到问答 UI
19. **Hover 延迟 0.5s** — 防止鼠标路过时面板意外展开
20. **保护 waiting 状态** — activity 事件不覆盖 waitingApproval/waitingQuestion，防 UI 被冲掉
21. **Subagent 进程过滤** — 排除 worktree agent 路径，避免重复 session
22. **项目名状态色** — 用 displayName 颜色区分 session 状态，不加额外装饰元素，最克制的方案
23. **MiniAgentIcon 像素风** — subagent 图标保持 8-bit 风格，网格排在主小人下方，视觉层级清晰
24. **连续曲率 NotchPanelShape** — 底部用 cubic bezier (k=0.62 squircle)，肩部用 cubic bezier (factor=0.35)，全路径 G1 连续
25. **Bridge 三阶段 alarm** — stdin 5s → env+connect+send 8s → blocking recv 无 alarm，覆盖所有阻塞点
26. **进程退出 5s grace period** — 不立即删 session，等待新进程接管或新事件到达
27. **removeSession 统一清理** — continuation/surface/monitor 清理集中在 removeSession，所有调用方无需重复处理
28. **Stuck 检测跳过有进程监控的 session** — 长对话不会被误判为卡住
29. **Debug Harness --preview** — 启动参数注入 mock session，不修改主体架构
30. **Permission/Question 队列** — FIFO 数组替代单值 Optional，多 session 并行审批不丢 continuation
31. **JSONC stripJSONComments static** — 非 private，ConfigInstaller 和 AppState YOLO 检测共用
32. **Hooks 自修复 60s 防抖** — didActivateApplication 每次 app 切换都触发，必须防抖
33. **NSRunningApplication 替代 open -a** — 支持跨 Space + unhide，open -a 仅作 fallback
34. **YOLO isYoloMode: Bool?** — 三态避免每次 Cursor 事件都读 settings 文件
35. **Worktree hook 过滤仅限非阻塞事件** — PermissionRequest/Question 不过滤，保留安全审批
36. **installExternalHooks 返回 Bool** — 和 installClaudeHooks 统一，install() 汇总所有 CLI 结果
37. **重装幂等** — 先 removeAll 旧 hooks 再写入新的，不跳过已安装的 CLI
38. **rotatingSession 在 AppState 上** — 避免多个 View 重复定义相同计算属性
39. **shortModelName 在 SessionSnapshot 上** — 模型名缩写是域逻辑，和 displayName/sourceLabel 放在一起
40. **NSHostingView needsUpdateConstraints/needsLayout 延迟** — 所有赋值 async 到下个 run-loop，applyingDeferred 防递归，一 tick 延迟不可感知
41. **nativeAppBundles 替代 appSources** — 按 termBundleId 精确区分 APP/CLI，appSources 作为空的 fallback 保留
42. **Ghostty/kitty source 关键词匹配** — 替代硬编码 "claude"，支持多 CLI 共享 CWD 时精确跳转
43. **Codex transcript_path is NSNull 过滤** — 结构性判断，不依赖消息内容，稳定区分真实 session 和标题生成 session
44. **OpenCode JS 插件直连 socket** — 不经 bridge，plugin 系统内 in-process 运行，权限/问答用 held connection + HTTP API 回复
45. **Session 持久化到 ~/.codeisland/sessions.json** — 重启恢复 session，30 分钟过期；恢复时重建 recentMessages
46. **displayName 纯数字回退** — 避免 CodeBuddy 时间戳目录名作为 session 名显示
47. **_env 子对象 fallback** — OpenCode 插件的终端信息格式不同于 bridge，extractMetadata 统一处理

---

## 2026-04-08 会话改动记录

本次会话对标了 xmqywx/CodeIsland、erha19/ping-island、jackson-storm/DynamicNotch、sk-ruban/notchi 等同类项目，提取了实用改进并修复了已知问题。

### 新增功能

1. **工具状态结构化显示** (`Models.swift: toolDescription`) — 按工具类型智能提取关键信息：Bash 显示 description 字段而非原始命令，Read 带行号偏移，Grep 带搜索目录，WebSearch 显示 query，WebFetch 显示域名，Agent 显示任务描述。
2. **诊断导出** (`DiagnosticsExporter.swift`) — Settings → About 一键导出 zip（metadata/settings/session 状态/CLI 配置/系统日志/崩溃报告），用于 bug 反馈。
3. **自定义音效** (`SoundManager.swift`, `SettingsView.swift`) — 每个音效事件支持选择自定义音频文件替代内置 8-bit WAV。
4. **MorphText 组件** (`NotchAnimation.swift`) — 文字变化时 blur morph 过渡，用于工具描述和 session 行的实时状态。
5. **BlurFade transition** (`NotchAnimation.swift`) — 展开面板内容切换使用 blur+opacity 组合过渡，替代纯 opacity。

### Session 监控加固

6. **PID 存活验证** (`AppState.swift: cleanupIdleSessions`) — 每 30s（原 60s）用 `kill(pid, 0)` 验证所有被监控 PID 是否还活着，DispatchSourceProcess 静默失效时也能发现。
7. **所有 session 都做 stuck 检测** — 移除了 "有 monitor 就跳过" 的逻辑。按 (hasTool, hasMonitor) 四象限分层：60s/120s/180s/300s。
8. **无 monitor 有 PID 的 session 也做存活检查** — 覆盖 Gemini/Cursor 等 CLI 有 PID 但 monitor 建立失败的场景。
9. **进程退出时立即重置状态** (`handleProcessExit`) — 不再等 5s grace period 期间显示陈旧的 "running Edit"，立即 idle + drain pending。

### Bug 修复

10. **Subagent 父 session 状态同步** (`SessionSnapshot.swift: handleSubagentEvent`) — 之前 subagent 工作时父 session 显示 idle。修复：SubagentStart 设父 session 为 running + "Agent"，SubagentStop 在无更多 subagent 时回退为 processing，PreToolUse 保持父 session 为 running。
11. **Hover 展开闪烁** (`NotchPanelView.swift`) — expand timer 的 Task 和 collapse timer 存在竞态。修复：加 `isHovered` 状态追踪，Task 内 guard 检查。

### Session 优先级

12. **轮播按紧急程度排序** (`AppState.swift: refreshActiveIds, statusPriority`) — waitingApproval > waitingQuestion > running > processing > idle，同优先级按最近活跃时间。
13. **紧急 session 打断轮播** (`startRotationIfNeeded`) — 更紧急的 session 出现时立即 snap，不等 3s。
14. **mostActiveSessionId 也用优先级** — 展开面板默认选中最紧急的 session。

### 跳转改进

15. **iTerm2 fallback** (`TerminalActivator.swift`) — 无 session ID 时先试 tty 匹配，再试 cwd 目录名匹配 session name/path。
16. **Terminal.app fallback** — 无 tty 时用 cwd 目录名匹配 tab 的 custom title。

### 其他

17. **Socket 权限** (`HookServer.swift`) — listener ready 后 chmod 0o700。
18. **StatusItemController KVO 重构** (`StatusItemController.swift`, `AppDelegate.swift`) — 用 KVO observe 替代 UserDefaults.didChangeNotification 全局监听，menu 只创建一次。
19. **自定义吉祥物代码清理** — 删除 CustomMascotView.swift、PixelEditorView.swift，清理 L10n/SettingsView/MascotView 中的相关代码。

### 竞品分析结论

已分析项目：xmqywx/CodeIsland、erha19/ping-island、jackson-storm/DynamicNotch、sk-ruban/notchi、AppGram/agentnotch、edwluo/vibe-island-updates、BadRat-in/MacIsland、boring.notch 等。
- 我们的 NotchPanelShape（cubic bezier + squircle）优于所有竞品的二次贝塞尔方案
- 我们的 DispatchSourceProcess 进程监控优于竞品的 kill(pid, 0) 轮询
- 我们的终端跳转（iTerm2 unique ID、Terminal.app tty、Ghostty session ID）比竞品更精准
- 不需要 SessionPhase 状态机（过度工程）、JSONL 解析（hook 已覆盖）、EmojiPixelView（非实用）
