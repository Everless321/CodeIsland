# Changelog

## [v1.0.15] - 2026-04-07

### English
- Fix apps built with libghostty (e.g. Supacode) being misidentified as Ghostty (#27)
- Fix DMG release missing app icon by pre-building icns with all sizes
- Fix settings window opaque sidebar in .app bundle (add toolbar for translucent effect)
- Build universal binary (arm64 + x86_64) for DMG releases
- Use root Info.plist for DMG builds to include all required fields

### 中文
- 修复基于 libghostty 构建的应用（如 Supacode）被误识别为 Ghostty 的问题 (#27)
- 修复 DMG 发行版缺少应用图标的问题（预置完整尺寸 icns）
- 修复 .app 版本设置窗口侧边栏不透明的问题（添加 toolbar 实现毛玻璃效果）
- DMG 发行版改为 universal binary（arm64 + x86_64）
- DMG 构建使用完整 Info.plist，包含所有必要字段

## [v1.0.8] - 2026-04-07

### English
- Add GitHub Copilot CLI support as the 9th AI tool
- Allow horizontal drag of panel along the menu bar (Settings → General)
- Horizontal-only drag with no vertical jitter, 5px threshold to prevent accidental drag
- Reset panel to center when drag toggle is turned off
- Update mascot gif backgrounds to white for better README readability

### 中文
- 新增 GitHub Copilot CLI 支持（第 9 个 AI 工具）
- 允许沿菜单栏水平拖动面板（设置 → 通用）
- 仅水平拖动无垂直抖动，5px 阈值防误触
- 关闭拖动开关时面板自动归位居中
- 更新吉祥物 gif 为白色背景，提升 README 可读性

## [v1.0.7] - 2026-04-07

### English
- Add Homebrew Cask distribution support (`brew install --cask codeisland`)
- Add in-app auto-update: download, install and relaunch without leaving the app
- Add "Check for Updates" button in Settings → About
- Detect Homebrew installs and suggest `brew upgrade` instead of auto-update
- Add GitHub Actions CI for automated release builds
- Auto-approve safe internal tools (TaskCreate, TaskUpdate, etc.) to prevent hook blocking
- Fix compact bar showing project name and tool status from different sessions
- Fix restored sessions incorrectly shown as active when CLI process is idle
- Hide project name in tool status area when no tool is running

### 中文
- 新增 Homebrew Cask 分发支持（`brew install --cask codeisland`）
- 新增 App 内自动更新：下载、安装并重启，无需离开应用
- 设置 → 关于页面新增"检查更新"按钮
- 检测 Homebrew 安装并建议使用 `brew upgrade` 更新
- 新增 GitHub Actions CI 自动构建发布
- 自动放行安全内部工具（TaskCreate、TaskUpdate 等），防止 hook 阻塞
- 修复紧凑栏项目名和工具状态来自不同会话的问题
- 修复恢复的会话在 CLI 空闲时仍显示为活跃状态
- 修复无工具运行时仍显示项目名的问题

## [v1.0.6] - 2026-04-07

### English
- Show Claude and Codex session titles in the panel
- New idle state UI with hover interaction on the notch
- Add shimmer animation when AI is thinking
- Extend animation speed slider to 0% to freeze mascot animations
- Add Codex PreToolUse/PostToolUse hook events for tool status display
- Auto-configure codex_hooks=true in ~/.codex/config.toml
- Add IDE terminal detection for smarter notification suppress
- Add cmux terminal support
- Fix user messages rendered as markdown instead of plain text
- Add processing timeout fallback: reset to idle after 60s with no tool
- Fix idle mascot not aligned with the most recently active CLI

### 中文
- Claude 和 Codex 会话现在在面板中显示标题
- 新增空闲状态 UI，支持刘海区域悬停交互
- AI 思考时显示闪烁动画效果
- 动画速度滑块可调至 0% 以冻结吉祥物动画
- 新增 Codex PreToolUse/PostToolUse hook 事件，显示工具状态
- 自动配置 ~/.codex/config.toml 中的 codex_hooks=true
- 新增 IDE 终端检测，更智能的通知抑制
- 新增 cmux 终端支持
- 修复用户消息被渲染为 markdown 而非纯文本
- 增加处理超时回退：60 秒无工具调用后重置为空闲
- 修复空闲吉祥物未对齐最近活跃的 CLI

## [v1.0.5] - 2026-04-06

### English
- Smart suppress: only suppress notifications when looking at the specific session tab
- Support iTerm2, Ghostty, Terminal.app, WezTerm, kitty, and tmux tab detection
- Fix Codex Desktop not discovered due to case-sensitive path matching
- Fix npm/Homebrew Codex not discovered
- Fix OpenCode "Always allow" not persisting
- Fix model badge not showing
- Fix session short ID collision
- Fix bridge binary replacement drop window
- Fix hook script not updating for existing users
- Fix concurrent sessions in same repo incorrectly merged

### 中文
- 智能抑制：只有当你正在看该会话的标签页时才抑制通知
- 支持 iTerm2、Ghostty、Terminal.app、WezTerm、kitty、tmux 标签页检测
- 修复 Codex Desktop 因路径大小写不匹配无法发现
- 修复 npm/Homebrew 安装的 Codex 无法发现
- 修复 OpenCode "始终允许"没有持久化
- 修复 model 标签不显示
- 修复会话短 ID 冲突
- 修复 bridge 二进制替换存在时间窗口
- 修复已安装用户的 hook 脚本不会更新
- 修复同 repo 并发会话被错误合并

## [v1.0.4] - 2026-04-06

### English
- Fix OpenCode socket deadlock
- Fix stuck session states
- Fix AskUserQuestion parsing
- Fix double-click on outside click
- Performance: cache status/primarySource/activeSessionCount, reduce observation polling
- UI: smooth hover animations, panel collapse delay, entrance transitions

### 中文
- 修复 OpenCode socket 死锁
- 修复会话状态卡住
- 修复 AskUserQuestion 解析
- 修复外部点击双击问题
- 性能优化：缓存状态属性，减少轮询频率
- UI：平滑悬停动画，面板折叠延迟，入场过渡动画

## [v1.0.3] - 2026-04-06

### English
- Update checker: auto-check on launch + manual check
- Per-CLI hook toggles
- Boot sound: 8-bit startup jingle
- Behavior animations: animated previews for each setting
- Fix release build crash, OpenCode plugin install, hook fallback socket path

### 中文
- 更新检查器：启动时自动检查 + 手动检查
- 按 CLI 独立开关 hooks
- 启动音效：8-bit 开机音
- 行为动画：每个设置项的动画预览
- 修复发布版本崩溃、OpenCode 插件安装、hook socket 路径回退

## [v1.0.1] - 2026-04-06

### English
- Fix release build crash on Mascots/Hooks pages
- Fix OpenCode plugin installation in release builds
- Fix hook script fallback socket path
- Remove redundant page titles in settings

### 中文
- 修复吉祥物和 Hooks 设置页崩溃
- 修复发布版本中 OpenCode 插件安装
- 修复 hook 脚本 socket 路径回退
- 移除设置中多余的页面标题

## [v1.0.0] - 2026-04-06

### English
- Initial release

### 中文
- 初始发布
